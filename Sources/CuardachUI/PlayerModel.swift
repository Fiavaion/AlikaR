#if canImport(SwiftUI) && os(iOS)
import ARKit
import CuardachAR
import CuardachCore
import Observation
import RealityKit
import UIKit

/// Player mode (PRD P1–P12): resolve anchors in priority order, run
/// behaviours, guide the player, remember what they found on this device.
@MainActor
@Observable
public final class PlayerModel {
    public let bundle: ExperienceBundle
    var experience: Experience { bundle.experience }

    let ar = ARSceneController()
    let location = LocationService()
    let walking = WalkingMonitor()
    @ObservationIgnored private let store: PlayerProgressStore
    @ObservationIgnored private var runtime: SceneRuntime
    @ObservationIgnored private var engine: BehaviourEngine
    @ObservationIgnored private var resolver: AnchorResolver
    @ObservationIgnored private var sessionAnchors: [String: ARAnchor] = [:]
    @ObservationIgnored private var building: Set<String> = []
    @ObservationIgnored private var clock: TimeInterval = 0
    @ObservationIgnored private var sinceObservation: TimeInterval = 0
    @ObservationIgnored private var sinceResolver: TimeInterval = 0
    @ObservationIgnored private var sinceModeCheck: TimeInterval = 0
    @ObservationIgnored private var currentMode: SessionMode?

    private(set) var progress: PlayerProgress
    private(set) var resolutions: [String: ElementResolution] = [:]
    var hint: String?
    var completed = false
    var reduceMotion = false

    public init(bundle: ExperienceBundle, store: PlayerProgressStore) {
        self.bundle = bundle
        self.store = store
        let p = store.load(bundle.experience.id)
        progress = p
        engine = BehaviourEngine(experience: bundle.experience, savedStates: p.states)
        resolver = AnchorResolver(experience: bundle.experience, capabilities: .init(geoTracking: false, objectTracking: false))
        runtime = SceneRuntime(bundle: bundle, scene: ar.arView.scene)
        runtime.onComplete = { [weak self] id in self?.completeInvocation(id) }
    }

    var foundCount: (found: Int, total: Int) { progress.foundCount(in: experience) }

    var guidance: ApproachGuidance {
        guard let here = location.coordinate,
              let next = experience.nearestUnfound(from: here, found: progress.foundSet) else {
            return experience.elements.contains { $0.coordinate != nil } ? .navigate(distanceM: .infinity, relativeBearing: 0) : .noLocation
        }
        return ApproachGuidance.make(player: here, heading: location.heading, target: next.element.coordinate)
    }

    var nextElementName: String? {
        guard let here = location.coordinate else { return nil }
        return experience.nearestUnfound(from: here, found: progress.foundSet)?.element.name
    }

    // MARK: Lifecycle

    func start() async {
        location.start()
        walking.start()
        ar.onAnchor = { [weak self] a in self?.anchorSeen(a) }
        ar.onRelocalised = { [weak self] in self?.relocalised() }
        ar.onUpdate = { [weak self] dt in self?.frame(dt) }

        let probe = location.coordinate ?? experience.siteHint?.coordinate
        var geo = false
        if let probe, ARSceneController.geoTrackingSupported {
            geo = await ARSceneController.geoAvailable(at: probe)
        }
        resolver = AnchorResolver(experience: experience, capabilities: .init(geoTracking: geo, objectTracking: false))
        runSession(resolver.preferredMode(player: location.coordinate))
    }

    func stop() {
        runtime.stopAll()
        ar.pause()
        location.stop()
        walking.stop()
        try? store.save(progress)
    }

    func resetProgress() {
        try? store.reset(experience.id)
        progress = PlayerProgress(experienceId: experience.id)
        completed = false
        engine = BehaviourEngine(experience: experience)
        runSession(resolver.preferredMode(player: location.coordinate))
    }

    private func runSession(_ mode: SessionMode) {
        runtime.stopAll()
        currentMode = mode
        sessionAnchors.removeAll()
        let images = referenceImages(for: experience, in: bundle)
        // A new session is a new coordinate space: everything re-resolves.
        let allAnchorIds = Set(experience.elements.flatMap(\.anchors).map(\.id))
        _ = resolver.invalidate(allAnchorIds)
        resolutions = [:]
        switch mode {
        case .geo:
            ar.runGeo(images: images)
            for e in experience.elements {
                for a in e.anchors where a.tier == .geo {
                    if let c = a.coordinate { ar.addGeoAnchor(id: a.id, coordinate: c, altitude: a.alt) }
                }
            }
        case .world(let mapFile):
            let map = mapFile.flatMap { try? WorldMapStore.load($0, in: bundle) }
            ar.runWorld(map: map, images: images)
            if let mapFile, map != nil { handle(resolver.beginRelocalising(mapFile: mapFile, at: clock)) }
        }
    }

    // MARK: Anchors (PRD P5, P6)

    private func anchorSeen(_ a: ARAnchor) {
        let id: String?
        if let image = a as? ARImageAnchor {
            guard image.isTracked else { return }
            id = image.referenceImage.name
        } else if let geo = a as? ARGeoAnchor {
            guard geo.isTracked, let name = geo.name, name.hasPrefix(ARSceneController.anchorPrefix) else { return }
            id = String(name.dropFirst(ARSceneController.anchorPrefix.count))
        } else if let name = a.name, name.hasPrefix(ARSceneController.anchorPrefix) {
            // Restored from the world map: wait for relocalisation to confirm it.
            sessionAnchors[String(name.dropFirst(ARSceneController.anchorPrefix.count))] = a
            return
        } else {
            return
        }
        guard let id else { return }
        let isNew = sessionAnchors[id] == nil
        sessionAnchors[id] = a
        if isNew { handle(resolver.anchorResolved(id)) }
    }

    private func relocalised() {
        hint = nil
        guard case .world(let mapFile?)? = currentMode else { return }
        handle(resolver.relocalised(mapFile: mapFile, at: clock))
    }

    private func handle(_ events: [ResolverEvent]) {
        for e in events {
            switch e {
            case .place(let elementId, let anchorId, let tier):
                guard let element = experience.element(id: elementId), let arAnchor = sessionAnchors[anchorId] else { continue }
                var local = element.transform
                if tier == .image, let rel = element.anchors.first(where: { $0.id == anchorId })?.transform {
                    local = rel
                    local.scale = element.transform.scale
                }
                place(element) { c in self.ar.place(c, elementId: elementId, on: arAnchor, local: local) }
                resolutions[elementId] = resolver.resolution(of: elementId)
            case .placeOnNearestPlane(let elementId):
                guard let element = experience.element(id: elementId), let world = ar.surfaceAtCentre() else { continue }
                place(element) { c in self.ar.place(c, elementId: elementId, world: world, local: element.transform) }
                resolutions[elementId] = .onNearestPlane
            case .unplace(let elementId):
                ar.remove(elementId: elementId)
                resolutions[elementId] = .searching
            case .relocalisationSlow:
                hint = String(localized: "Still matching this place. Try a different angle, or look for a printed marker.")
            }
        }
    }

    private func place(_ element: Element, _ attach: @escaping (ModelEntity) -> Void) {
        if let c = runtime.container(element.id) {
            attach(c)
            return
        }
        guard !building.contains(element.id) else { return }
        building.insert(element.id)
        Task {
            defer { building.remove(element.id) }
            do {
                let built = try await EntityFactory.build(element, bundle: bundle)
                // Sound elements are heard, not seen.
                if element.kind == .audio { built.content.isEnabled = false }
                runtime.register(built, for: element.id)
                attach(built.container)
                runtime.setInitialVisibility(element.id, visible: engine.isVisible(element.id))
                if let v = engine.variant(of: element.id) { runtime.apply([.variant(elementId: element.id, variantId: v)]) }
                apply(engine.elementResolved(element.id, at: clock, minuteOfDay: minuteOfDay()))
                UIAccessibility.post(notification: .announcement,
                                     argument: String(localized: "\(element.label?.altText ?? element.name) is here."))
            } catch {
                hint = String(localized: "“\(element.name)” couldn't be shown.")
            }
        }
    }

    // MARK: Behaviours (PRD P7, P8)

    func tap(_ point: CGPoint) {
        guard let id = ar.elementId(at: point) else { return }
        apply(engine.tap(id, at: clock))
    }

    private func completeInvocation(_ id: Int) {
        apply(engine.complete(invocation: id, at: clock))
    }

    private func apply(_ events: [EngineEvent]) {
        guard !events.isEmpty else { return }
        runtime.apply(events)
        let before = progress
        progress.apply(events)
        for case .found(let id) in events {
            let name = experience.element(id: id)?.name ?? ""
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Found \(name)."))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        if progress != before {
            try? store.save(progress)
            let count = foundCount
            if count.total > 0, count.found == count.total { completed = true }
        }
    }

    private func frame(_ dt: TimeInterval) {
        clock += dt
        runtime.step(reduceMotion ? 10 : dt)
        sinceObservation += dt
        if sinceObservation >= 0.1 {
            sinceObservation = 0
            apply(engine.update(observations: ar.observations(), at: clock, minuteOfDay: minuteOfDay()))
        }
        sinceResolver += dt
        if sinceResolver >= 1 {
            sinceResolver = 0
            handle(resolver.update(at: clock, player: location.coordinate))
        }
        sinceModeCheck += dt
        if sinceModeCheck >= 15 {
            sinceModeCheck = 0
            let preferred = resolver.preferredMode(player: location.coordinate)
            // Switching resets the session, so only do it when nothing is in view.
            if preferred != currentMode, ar.observations().allSatisfy({ !$0.inView }) { runSession(preferred) }
        }
    }
}
#endif
