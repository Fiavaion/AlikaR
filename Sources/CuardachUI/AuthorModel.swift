#if canImport(SwiftUI) && os(iOS)
import ARKit
import CuardachAR
import CuardachCore
import Observation
import RealityKit
import ReplayKit
import UIKit
import os

/// Author mode (PRD A1–A16, L1–L9): place, adjust, anchor, give behaviours,
/// preview, save. Owns the AR session for the editing session and keeps the
/// manifest, the RealityKit scene and the undo history in step.
@MainActor
@Observable
public final class AuthorModel {
    public enum PinState: Equatable {
        case idle
        case checking
        /// Running a geotracking session to pin this element (PRD L2).
        case geoSession(elementId: String)
    }

    public private(set) var bundle: ExperienceBundle
    public var experience: Experience { bundle.experience }

    let ar = ARSceneController()
    let location = LocationService()
    @ObservationIgnored let capture = DocumentationCapture()
    @ObservationIgnored private(set) var runtime: SceneRuntime

    var selection: String?
    var toast: String?
    var pendingImport: ImportPipeline.Result?
    var isBusy = false
    var isPreviewing = false
    var cleanFrame = false
    var isRecording = false
    var recordingPreview: RPPreviewViewController?
    var showCritLayer = true { didSet { refreshCritLayer() } }
    var pin: PinState = .idle
    var lastSaved: Date?
    private(set) var undo = UndoStack<Experience>()

    /// The world map this editing session extends (PRD L8).
    @ObservationIgnored private(set) var currentMapFile: String
    @ObservationIgnored private var gestureBefore: Experience?
    @ObservationIgnored private var relays: [String: GestureRelay] = [:]
    @ObservationIgnored private var building: Set<String> = []
    @ObservationIgnored private var detectedMarkers: [String: ARImageAnchor] = [:]
    @ObservationIgnored private var restoredAnchors: [String: ARAnchor] = [:]
    /// Where removed elements hung, so undoing a delete puts them back.
    @ObservationIgnored private var lastAnchorWorld: [String: simd_float4x4] = [:]
    @ObservationIgnored private var previewEngine: BehaviourEngine?
    @ObservationIgnored private var previewClock: TimeInterval = 0
    @ObservationIgnored private var sinceObservation: TimeInterval = 0
    @ObservationIgnored private var manifestSaveTask: Task<Void, Never>?

    /// The author session that is running, so `RootView` can save and stop it
    /// before replacing the navigation stack for a file sent to the app.
    static weak var active: AuthorModel?

    public init(bundle: ExperienceBundle) {
        self.bundle = bundle
        self.runtime = SceneRuntime(bundle: bundle, scene: ar.arView.scene)
        runtime.showHiddenAsGhosts = true
        let maps = bundle.experience.elements.flatMap(\.anchors).filter { $0.tier == .worldmap }
        let latest = maps.max { ($0.capturedAt ?? "") < ($1.capturedAt ?? "") }
        currentMapFile = latest?.mapFile ?? "maps/scan-\(Int(Date().timeIntervalSince1970)).arworldmap"
        runtime.onComplete = { [weak self] id in self?.previewCompleted(id) }
    }

    var selectedElement: Element? { selection.flatMap { experience.element(id: $0) } }
    var isReadOnly: Bool { bundle.isReadOnly }

    // MARK: Lifecycle

    func start() {
        Self.active = self
        location.start()
        ar.onAnchor = { [weak self] a in self?.anchorAppeared(a) }
        ar.onRelocalised = { [weak self] in self?.toast = String(localized: "Recognised this place. Your elements are back.") }
        ar.onUpdate = { [weak self] dt in self?.frame(dt) }
        let map = bundle.fileExists(currentMapFile) ? try? WorldMapStore.load(currentMapFile, in: bundle) : nil
        Log.session.notice("Author mode: \(self.experience.elements.count) elements, saved map \(map != nil ? "loaded" : "none", privacy: .public)")
        ar.runAuthoring(initialMap: map, images: referenceImages(for: experience, in: bundle))
        if map != nil {
            toast = String(localized: "Look around the space you scanned last time to bring your elements back.")
        }
    }

    func stop() async {
        if Self.active === self { Self.active = nil }
        if previewEngine != nil { stopPreview() }
        await save()
        ar.pause()
        location.stop()
    }

    // MARK: Editing

    /// Applies a change to the manifest with undo (PRD A15) and a deferred save.
    func edit(_ label: String, coalesce: Bool = false, _ change: (inout Experience) -> Void) {
        guard !isReadOnly else { toast = String(localized: "This experience was made with a newer version of the app and can't be edited."); return }
        let before = bundle.experience
        change(&bundle.experience)
        guard bundle.experience != before else { return }
        undo.record(before, label: label, coalesce: coalesce)
        runtime.update(experience: bundle.experience)
        saveManifestSoon()
    }

    func editElement(_ id: String, _ label: String, coalesce: Bool = false, _ change: (inout Element) -> Void) {
        edit(label, coalesce: coalesce) { x in
            guard let i = x.elements.firstIndex(where: { $0.id == id }) else { return }
            change(&x.elements[i])
        }
        syncEntity(id)
    }

    func undoLast() {
        guard let previous = undo.undo(current: bundle.experience) else { return }
        restore(previous)
    }

    func redoLast() {
        guard let next = undo.redo(current: bundle.experience) else { return }
        restore(next)
    }

    private func restore(_ x: Experience) {
        let removed = Set(bundle.experience.elements.map(\.id)).subtracting(x.elements.map(\.id))
        bundle.experience = x
        runtime.update(experience: x)
        for id in removed { forget(id) }
        for e in x.elements {
            if !ar.isPlaced(e.id), let world = lastAnchorWorld[e.id] {
                let local = e.transform
                Task { await buildAndPlace(e.id) { c in self.ar.place(c, elementId: e.id, world: world, local: local) } }
            } else {
                syncEntity(e.id)
            }
        }
        saveManifestSoon()
    }

    /// Pushes an element's manifest state onto its entity.
    func syncEntity(_ id: String) {
        guard let e = experience.element(id: id), let c = runtime.container(id) else { return }
        c.transform = RealityKit.Transform(e.transform)
        if e.faceViewer { c.components.set(BillboardComponent()) } else { c.components.remove(BillboardComponent.self) }
        runtime.setInitialVisibility(id, visible: !e.startsHidden)
        installGestures(for: id)
        refreshCritLayer()
    }

    // MARK: Import and placement (PRD A1, A2, A4, A6)

    func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        isBusy = true
        defer { isBusy = false }
        do {
            pendingImport = try await ImportPipeline.importAsset(url, into: bundle)
        } catch {
            Log.importing.error("Import failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code) \(error, privacy: .private)")
            toast = error.localizedDescription
        }
    }

    /// Places the reviewed import on the surface at the centre of the screen.
    /// Returns false, keeping the import for another try, while AR has no
    /// surface or camera frame yet.
    @discardableResult
    func placePendingImport(name: String) -> Bool {
        guard let r = pendingImport, !r.path.isEmpty else { pendingImport = nil; return true }
        var e = Element(name: name, kind: r.kind, asset: r.path)
        if r.kind == .video { e.playback = Playback(loop: true) }
        if r.kind == .image || r.kind == .video { e.faceViewer = false }
        if !r.metrics.animationClips.isEmpty { e.playback = Playback(clip: r.metrics.animationClips.first, loop: true) }
        // Models exported in centimetres arrive 100× too big: start them at a sensible size.
        if let size = r.metrics.boundingSize, max(size.x, size.y, size.z) > 20 {
            let s = 1 / max(size.x, size.y, size.z)
            e.transform.scale = Vec3(s, s, s)
        }
        e.credit = Credit(creator: experience.author, source: String(localized: "Own work"))
        guard add(e) else { return false }
        pendingImport = nil
        return true
    }

    func addText(_ text: String) {
        var e = Element(name: String(text.prefix(24)), kind: .text, asset: nil)
        e.text = text
        e.faceViewer = true
        if !add(e) { toast = Self.noSurfaceYet }
    }

    static var noSurfaceYet: String { String(localized: "AR is still starting. Move the camera slowly for a moment, then try again.") }

    /// Adds an element at the crosshair; false if AR has no surface or camera frame yet.
    private func add(_ element: Element) -> Bool {
        guard let world = ar.surfaceAtCentre() ?? inFrontOfCamera() else {
            Log.anchors.notice("No surface or camera frame yet; element not added")
            return false
        }
        edit(String(localized: "Add \(element.name)")) { $0.elements.append(element) }
        selection = element.id
        Task { await buildAndPlace(element.id) { c in self.ar.place(c, elementId: element.id, world: world, local: element.transform) } }
        return true
    }

    private func inFrontOfCamera(distance: Float = 1) -> simd_float4x4? {
        guard let cam = ar.cameraTransform else { return nil }
        var t = matrix_identity_float4x4
        let forward = -SIMD3<Float>(cam.columns.2.x, 0, cam.columns.2.z)
        let pos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y - 0.5, cam.columns.3.z) + simd_normalize(forward) * distance
        t.columns.3 = SIMD4(pos, 1)
        return t
    }

    /// Builds an element's entity once and hands its container to `place`.
    private func buildAndPlace(_ id: String, place: @escaping (ModelEntity) -> Void) async {
        if let c = runtime.container(id) {
            place(c)
            syncEntity(id)
            return
        }
        guard !building.contains(id), let e = experience.element(id: id) else { return }
        building.insert(id)
        defer { building.remove(id) }
        do {
            let built = try await EntityFactory.build(e, bundle: bundle)
            runtime.register(built, for: id)
            place(built.container)
            syncEntity(id)
        } catch {
            Log.behaviours.error("Entity build failed for \(id, privacy: .public) (\(e.kind.rawValue, privacy: .public)): \((error as NSError).domain, privacy: .public) \((error as NSError).code) \(error, privacy: .private)")
            toast = String(localized: "“\(e.name)” couldn't be shown: \(error.localizedDescription)")
        }
    }

    func handleTap(_ point: CGPoint) {
        let hit = ar.elementId(at: point)
        if isPreviewing, var engine = previewEngine {
            if let hit { runtime.apply(engine.tap(hit, at: previewClock)) }
            previewEngine = engine
            return
        }
        selection = hit
    }

    // MARK: Gestures (PRD A6)

    private func installGestures(for id: String) {
        guard let c = runtime.container(id), let e = experience.element(id: id) else { return }
        relays[id]?.detach()
        var g: ARView.EntityGestures = [.translation, .rotation]
        if !(e.designSize?.lockScale ?? false) { g.insert(.scale) }
        let recognizers = ar.arView.installGestures(g, for: c).compactMap { $0 as? UIGestureRecognizer }
        let relay = GestureRelay(recognizers: recognizers) { [weak self] state in
            self?.gesture(state, elementId: id)
        }
        relays[id] = relay
    }

    private func gesture(_ state: UIGestureRecognizer.State, elementId id: String) {
        guard !isPreviewing else { return }
        switch state {
        case .began:
            gestureBefore = bundle.experience
            selection = id
        case .ended, .cancelled:
            guard let before = gestureBefore, let c = runtime.container(id),
                  let i = bundle.experience.elements.firstIndex(where: { $0.id == id }) else { return }
            gestureBefore = nil
            bundle.experience.elements[i].transform = CuardachCore.Transform(c.transform)
            if bundle.experience != before {
                undo.record(before, label: String(localized: "Move"))
                saveManifestSoon()
            }
        default:
            break
        }
    }

    /// Lifts the selected element by a height offset (PRD A6 slider).
    func setHeightOffset(_ y: Double) {
        guard let id = selection else { return }
        editElement(id, String(localized: "Height"), coalesce: true) { $0.transform.position.y = y }
    }

    /// Snaps the selected element down onto the surface beneath it.
    func snapToSurface() {
        guard let id = selection, let c = runtime.container(id) else { return }
        let p = c.position(relativeTo: nil)
        let results = ar.arView.scene.raycast(origin: p + [0, 0.5, 0], direction: [0, -1, 0], length: 5, query: .nearest)
            .filter { $0.entity.components[ElementTag.self] == nil }
        let below = ar.arView.session.raycast(ARRaycastQuery(origin: p + [0, 0.5, 0], direction: [0, -1, 0],
                                                             allowing: .estimatedPlane, alignment: .horizontal))
        guard let y = below.first?.worldTransform.columns.3.y ?? results.first?.position.y else {
            toast = String(localized: "No surface found below.")
            return
        }
        let localDrop = c.convert(position: [p.x, y, p.z], from: nil)
        editElement(id, String(localized: "Snap to surface")) { $0.transform.position.y += Double(localDrop.y) }
    }

    // MARK: Scene list (PRD A12)

    private func forget(_ id: String) {
        if let w = ar.anchorWorld(of: id) { lastAnchorWorld[id] = w }
        ar.remove(elementId: id)
        relays.removeValue(forKey: id)?.detach()
    }

    func delete(_ id: String) {
        forget(id)
        edit(String(localized: "Delete")) { x in
            x.elements.removeAll { $0.id == id }
            x.annotations.removeAll { $0.elementId == id }
        }
        if selection == id { selection = nil }
    }

    func duplicate(_ id: String) {
        guard var copy = experience.element(id: id), let world = ar.worldTransform(of: id) else { return }
        copy.id = UUID().uuidString
        copy.name += String(localized: " copy")
        copy.anchors = []
        var shifted = world
        shifted.columns.3.x += 0.3
        edit(String(localized: "Duplicate")) { $0.elements.append(copy) }
        selection = copy.id
        let local = CuardachCore.Transform(scale: copy.transform.scale)
        Task { await buildAndPlace(copy.id) { c in self.ar.place(c, elementId: copy.id, world: shifted.withoutScale, local: local) } }
    }

    // MARK: Saving (PRD A13, L1, L7, L9)

    private func saveManifestSoon() {
        manifestSaveTask?.cancel()
        manifestSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.isReadOnly else { return }
            try? self.bundle.save()
        }
    }

    /// Full save: every placed element gets a world-map anchor at its current
    /// position, the world map is captured, and the manifest written.
    func save() async {
        guard !isReadOnly, !isPreviewing else { return }
        manifestSaveTask?.cancel()
        isBusy = true
        defer { isBusy = false }
        let status = WorldMapStore.status(ar.mappingStatus)
        var x = bundle.experience
        var mapAnchors: [(id: String, world: simd_float4x4)] = []
        var replace: [(id: String, world: simd_float4x4, local: CuardachCore.Transform)] = []
        let now = Date()

        if ar.mode == .authoring, ar.mappingStatus != .notAvailable {
            for i in x.elements.indices {
                let id = x.elements[i].id
                guard let world = ar.worldTransform(of: id) else { continue }
                let rigid = world.withoutScale
                let scale = world.scale
                let anchorId = x.elements[i].anchors.first { $0.tier == .worldmap && $0.mapFile == currentMapFile }?.id ?? "\(id)-map"
                mapAnchors.append((anchorId, rigid))
                x.elements[i].transform = CuardachCore.Transform(scale: Vec3(Double(scale.x), Double(scale.y), Double(scale.z)))
                var a = CuardachCore.Anchor.worldmap(id: anchorId, mapFile: currentMapFile, transform: Matrix4(rigid), capturedAt: now,
                                        mappingStatus: status, coordinate: location.coordinate)
                if let old = x.elements[i].anchors.first(where: { $0.id == anchorId }) { a.priority = old.priority; a.extra = old.extra }
                x.elements[i].anchors.removeAll { $0.id == anchorId }
                x.elements[i].anchors.append(a)
                replace.append((id, rigid, x.elements[i].transform))
            }
        }
        do {
            if !mapAnchors.isEmpty {
                let map = try await ar.captureWorldMap(anchors: mapAnchors)
                try bundle.write(try WorldMapStore.data(for: map), to: currentMapFile)
                Log.anchors.notice("Saved world map \(self.currentMapFile, privacy: .public), mapping \(status, privacy: .public)")
                if ar.mappingStatus == .limited {
                    toast = String(localized: "Saved, but the scan is weak. Walk slowly around the area and save again.")
                }
            }
            x.refreshSiteHint()
            if x.cover == nil, let image = try? await capture.photo(of: ar.arView),
               let data = image.preparingThumbnail(of: CGSize(width: 600, height: 600 * image.size.height / max(image.size.width, 1)))?.pngData() {
                try bundle.write(data, to: BundleLayout.thumbnail)
                x.cover = BundleLayout.thumbnail
            }
            bundle.experience = x
            runtime.update(experience: x)
            try bundle.save()
            // Re-parent containers under their new anchors so memory matches the file.
            for r in replace {
                if let c = runtime.container(r.id) { ar.place(c, elementId: r.id, world: r.world, local: r.local) }
            }
            lastSaved = now
        } catch {
            Log.anchors.error("Save failed, scan not saved: \((error as NSError).domain, privacy: .public) \((error as NSError).code) \(error, privacy: .private)")
            try? bundle.save()
            toast = String(localized: "Saved the experience, but not the scan: \(error.localizedDescription)")
        }
    }

    var scanQuality: String {
        switch ar.mappingStatus {
        case .mapped: String(localized: "Scan: good")
        case .extending: String(localized: "Scan: building")
        case .limited: String(localized: "Scan: weak, keep moving")
        default: String(localized: "Scan: not started")
        }
    }

    // MARK: Anchors (PRD L2–L4)

    /// "Pin to location": geotracking where Apple supports it, otherwise a
    /// GPS approach anchor and a prompt to strengthen the scan.
    func pinSelectedToLocation() async {
        guard let id = selection else { return }
        guard let here = location.coordinate else {
            toast = location.isDenied
                ? String(localized: "Location is off for Cuardach. Turn it on in Settings to pin elements to places.")
                : String(localized: "Waiting for GPS… try again in a moment, outdoors if you can.")
            return
        }
        pin = .checking
        if await ARSceneController.geoAvailable(at: here) {
            await save()
            pin = .geoSession(elementId: id)
            ar.runGeo(images: [])
            toast = String(localized: "Apple Location Anchors work here. Look at nearby buildings until it says Localised, then aim at the spot and tap Pin here.")
        } else {
            let radius = max(15, (location.horizontalAccuracyM ?? 10) * 1.5)
            editElement(id, String(localized: "Pin to location")) { e in
                e.anchors.removeAll { $0.tier == .gps }
                e.anchors.append(.gps(id: "\(id)-gps", coordinate: here, radiusM: radius, allowPlaneFallback: true))
            }
            pin = .idle
            toast = String(localized: "Location anchors aren't available here, so players will be guided to within about \(Int(radius)) m by GPS. Walk slowly around the spot for 30 seconds to strengthen the scan, then save.")
        }
    }

    /// Converts the surface at the screen centre to a geo anchor (PRD L2).
    func confirmGeoPin() async {
        guard case .geoSession(let id) = pin else { return }
        guard ar.geoLocalised, let t = ar.surfaceAtCentre() else {
            toast = String(localized: "Not localised yet. Point at building fronts and street features.")
            return
        }
        do {
            let (coordinate, altitude) = try await ar.geoLocation(of: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z))
            let heading = location.heading
            editElement(id, String(localized: "Pin to location")) { e in
                e.anchors.removeAll { $0.tier == .geo }
                e.anchors.append(.geo(id: "\(id)-geo", lat: coordinate.lat, long: coordinate.long, alt: altitude, heading: heading))
            }
            toast = String(localized: "Pinned. Street-precise for players with a supported iPhone.")
        } catch {
            toast = error.localizedDescription
        }
        endGeoSession()
    }

    func endGeoSession() {
        pin = .idle
        try? bundle.save()
        let map = bundle.fileExists(currentMapFile) ? try? WorldMapStore.load(currentMapFile, in: bundle) : nil
        ar.runAuthoring(initialMap: map, images: referenceImages(for: experience, in: bundle))
    }

    /// Generates a printable marker for the selected element (PRD L4). It
    /// links itself the first time the camera sees the printed poster while
    /// the element is in place.
    func addMarkerToSelected(widthM: Double = 0.18) {
        guard let e = selectedElement else { return }
        let path = "\(BundleLayout.markers)/\(ExperienceBundle.slug(e.id)).png"
        guard let png = MarkerRenderer.patternImage(seed: e.id).pngData() else { return }
        do { try bundle.write(png, to: path) } catch { toast = error.localizedDescription; return }
        // The chosen width is the whole printed image, quiet zone included,
        // so an 18 cm marker leaves A4's unprintable margins clear.
        let printedWidth = widthM
        editElement(e.id, String(localized: "Add marker")) { el in
            el.anchors.removeAll { $0.tier == .image }
            var a = CuardachCore.Anchor.image(id: "\(e.id)-marker", imageFile: path, physicalWidthM: printedWidth)
            a.transform = nil  // linked on first sighting
            el.anchors.append(a)
        }
        ar.updateDetectionImages(referenceImages(for: experience, in: bundle))
        toast = String(localized: "Marker added. Print it from Share → Marker sheets, fix it near “\(e.name)”, then point the camera at it to link them.")
    }

    private func anchorAppeared(_ a: ARAnchor) {
        if let image = a as? ARImageAnchor, let anchorId = image.referenceImage.name {
            detectedMarkers[anchorId] = image
            guard image.isTracked, let element = experience.elements.first(where: { $0.anchors.contains { $0.id == anchorId } }) else { return }
            let anchor = element.anchors.first { $0.id == anchorId }!
            if anchor.transform == nil, let world = ar.worldTransform(of: element.id) {
                // Link: store the element's pose relative to the marker.
                let relative = image.transform.inverse * world.withoutScale
                editElement(element.id, String(localized: "Link marker")) { el in
                    guard let i = el.anchors.firstIndex(where: { $0.id == anchorId }) else { return }
                    el.anchors[i].transform = CuardachCore.Transform(RealityKit.Transform(matrix: relative))
                }
                toast = String(localized: "Marker linked to “\(element.name)”.")
            } else if !ar.isPlaced(element.id), let rel = anchor.transform {
                var local = rel
                local.scale = element.transform.scale
                Task { await buildAndPlace(element.id) { c in self.ar.place(c, elementId: element.id, on: image, local: local) } }
            }
            return
        }
        guard let name = a.name, name.hasPrefix(ARSceneController.anchorPrefix) else { return }
        let anchorId = String(name.dropFirst(ARSceneController.anchorPrefix.count))
        restoredAnchors[anchorId] = a
        guard let element = experience.elements.first(where: { $0.anchors.contains { $0.id == anchorId && $0.tier == .worldmap } }),
              !ar.isPlaced(element.id) else { return }
        Task { await buildAndPlace(element.id) { c in self.ar.place(c, elementId: element.id, on: a, local: element.transform) } }
    }

    // MARK: Preview as player (PRD A16, A10 simulate)

    func startPreview() {
        guard !isPreviewing else { return }
        selection = nil
        isPreviewing = true
        runtime.showHiddenAsGhosts = false
        previewClock = 0
        var engine = BehaviourEngine(experience: experience)
        var events: [EngineEvent] = []
        for e in experience.elements where ar.isPlaced(e.id) {
            runtime.setInitialVisibility(e.id, visible: engine.isVisible(e.id))
            events += engine.elementResolved(e.id, at: 0, minuteOfDay: minuteOfDay())
        }
        previewEngine = engine
        runtime.apply(events)
        refreshCritLayer()
    }

    func stopPreview() {
        previewEngine = nil
        isPreviewing = false
        runtime.stopAll()
        runtime.showHiddenAsGhosts = true
        for e in experience.elements { syncEntity(e.id) }
        refreshCritLayer()
        // Variants may have swapped content during the preview.
        Task {
            await runtime.restoreBaseAssets()
            for e in experience.elements { syncEntity(e.id) }
        }
    }

    func runSimulation(_ elementId: String, _ index: Int) {
        guard var engine = previewEngine else { return }
        runtime.apply(engine.simulate(elementId, behaviour: index, at: previewClock))
        previewEngine = engine
    }

    /// Adds an alternative asset to the selected element (Studio: variants).
    func addVariant(from url: URL, name: String) async {
        guard let e = selectedElement else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try await ImportPipeline.importAsset(url, into: bundle)
            guard !r.path.isEmpty, r.kind == e.kind else {
                toast = String(localized: "A variant must be the same kind of file as the element.")
                return
            }
            editElement(e.id, String(localized: "Add variant")) { el in
                if el.variants.isEmpty, let base = el.asset {
                    el.variants.append(Variant(id: "original", name: String(localized: "Original"), asset: base))
                }
                el.variants.append(Variant(id: ExperienceBundle.slug(name) + "-\(el.variants.count)", name: name, asset: r.path))
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    private func previewCompleted(_ id: Int) {
        guard var engine = previewEngine else { return }
        runtime.apply(engine.complete(invocation: id, at: previewClock))
        previewEngine = engine
    }

    private func frame(_ dt: TimeInterval) {
        runtime.step(dt)
        guard var engine = previewEngine else { return }
        previewClock += dt
        sinceObservation += dt
        guard sinceObservation >= 0.1 else { return }
        sinceObservation = 0
        runtime.apply(engine.update(observations: ar.observations(), at: previewClock, minuteOfDay: minuteOfDay()))
        previewEngine = engine
    }

    // MARK: Crit notes (Studio extension)

    func addCritNote(author: String, kind: CritNote.Kind, text: String) {
        let elementId = selection
        var offset: Vec3?
        if let id = elementId, let c = runtime.container(id), let cam = ar.cameraTransform {
            let forward = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
            let world = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z) + forward * 0.6
            let local = c.convert(position: world, from: nil)
            offset = Vec3(Double(local.x), Double(local.y), Double(local.z))
        }
        let note = CritNote(author: author, kind: kind, text: text, elementId: elementId, offset: offset)
        edit(String(localized: "Add crit note")) { $0.annotations.append(note) }
        refreshCritLayer()
    }

    func resolveCritNote(_ id: String, reply: String) {
        edit(String(localized: "Resolve crit note")) { x in
            guard let i = x.annotations.firstIndex(where: { $0.id == id }) else { return }
            x.annotations[i].resolved = true
            x.annotations[i].reply = reply.isEmpty ? nil : reply
        }
        refreshCritLayer()
    }

    /// Floating labels for open crit notes, beside the elements they discuss.
    private func refreshCritLayer() {
        for e in experience.elements {
            guard let c = runtime.container(e.id) else { continue }
            for child in Array(c.children) where child.name.hasPrefix("crit:") { child.removeFromParent() }
            guard showCritLayer, !isPreviewing, !cleanFrame else { continue }
            for n in experience.annotations where n.elementId == e.id && !n.resolved {
                let mesh = MeshResource.generateText("\(n.author): \(n.text)", extrusionDepth: 0.001,
                                                     font: .systemFont(ofSize: 0.035),
                                                     containerFrame: CGRect(x: -0.3, y: -0.3, width: 0.6, height: 0.6),
                                                     alignment: .left, lineBreakMode: .byWordWrapping)
                let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemYellow)])
                label.name = "crit:\(n.id)"
                let o = n.offset ?? Vec3(0, 0.4, 0)
                label.position = SIMD3(Float(o.x), Float(o.y), Float(o.z))
                label.components.set(BillboardComponent())
                c.addChild(label)
            }
        }
    }

    // MARK: Documentation (Studio extension)

    func takePhoto() async {
        cleanFrame = true
        refreshCritLayer()
        defer { cleanFrame = false; refreshCritLayer() }
        do {
            let image = try await capture.photo(of: ar.arView)
            try await capture.saveToPhotos(image)
            toast = String(localized: "Saved to Photos.")
        } catch {
            Log.capture.error("Documentation photo failed: \(error, privacy: .public)")
            toast = error.localizedDescription
        }
    }

    func toggleRecording() async {
        do {
            if isRecording {
                recordingPreview = try await capture.stopRecording()
                isRecording = false
                cleanFrame = false
                refreshCritLayer()
            } else {
                cleanFrame = true
                refreshCritLayer()
                try await capture.startRecording()
                isRecording = true
            }
        } catch {
            Log.capture.error("Recording \(self.isRecording ? "stop" : "start", privacy: .public) failed: \(error, privacy: .public)")
            isRecording = false
            cleanFrame = false
            toast = error.localizedDescription
        }
    }

    /// Scales the selected element so its bounding box matches its design size.
    func fitToDesignSize() {
        guard let id = selection, let e = selectedElement, let size = e.designSize, let c = runtime.container(id) else { return }
        let b = c.visualBounds(relativeTo: c)
        let current = e.transform.scale.x
        let native = Vec3(Double(b.extents.x) / current, Double(b.extents.y) / current, Double(b.extents.z) / current)
        guard let s = size.uniformScale(forNativeSize: native) else { return }
        editElement(id, String(localized: "Fit to size")) { $0.transform.scale = Vec3(s, s, s) }
    }

    /// Measured size of the selected element, in millimetres, for the inspector.
    func measuredSize(_ id: String) -> String? {
        guard let c = runtime.container(id) else { return nil }
        let b = c.visualBounds(relativeTo: c.parent)
        return DesignSize(widthM: Double(b.extents.x), heightM: Double(b.extents.y), depthM: Double(b.extents.z)).formattedMillimetres
    }

    func clips(_ id: String) -> [String] { runtime.built[id]?.clips ?? [] }
}

/// Bridges entity gesture recognizers to a closure.
@MainActor
final class GestureRelay: NSObject {
    private var recognizers: [UIGestureRecognizer]
    private let handler: (UIGestureRecognizer.State) -> Void

    init(recognizers: [UIGestureRecognizer], handler: @escaping (UIGestureRecognizer.State) -> Void) {
        self.recognizers = recognizers
        self.handler = handler
        super.init()
        for r in recognizers { r.addTarget(self, action: #selector(changed(_:))) }
    }

    @objc private func changed(_ r: UIGestureRecognizer) { handler(r.state) }

    func detach() {
        for r in recognizers {
            r.removeTarget(self, action: #selector(changed(_:)))
            r.view?.removeGestureRecognizer(r)
        }
        recognizers = []
    }
}

extension simd_float4x4 {
    var scale: SIMD3<Float> {
        SIMD3(simd_length(SIMD3(columns.0.x, columns.0.y, columns.0.z)),
              simd_length(SIMD3(columns.1.x, columns.1.y, columns.1.z)),
              simd_length(SIMD3(columns.2.x, columns.2.y, columns.2.z)))
    }

    /// Rotation and translation only.
    var withoutScale: simd_float4x4 {
        let s = scale
        var m = self
        m.columns.0 /= max(s.x, 1e-6)
        m.columns.1 /= max(s.y, 1e-6)
        m.columns.2 /= max(s.z, 1e-6)
        m.columns.0.w = 0; m.columns.1.w = 0; m.columns.2.w = 0
        return m
    }
}
#endif
