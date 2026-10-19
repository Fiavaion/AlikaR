#if canImport(RealityKit) && os(iOS)
import AVFoundation
import Combine
import CuardachCore
import RealityKit
import UIKit
import os

/// Carries out `BehaviourEngine` events on RealityKit entities: animations,
/// moves, spins, fades, sound, video and variant swaps. Reports completion
/// of media back to the engine through `onComplete`.
@MainActor
public final class SceneRuntime {
    public private(set) var built: [String: EntityFactory.Built] = [:]
    /// Called when an invocation that awaited completion finishes or fails.
    public var onComplete: ((Int) -> Void)?
    /// Author mode shows hidden elements as ghosts instead of removing them.
    public var showHiddenAsGhosts = false

    private let bundle: ExperienceBundle
    private var experience: Experience
    private var animations: [Int: AnimationPlaybackController] = [:]
    private var audio: [Int: AudioPlaybackController] = [:]
    private var videoObservers: [Int: NSObjectProtocol] = [:]
    private var subscriptions: [Int: Cancellable] = [:]
    private var audioCache: [String: AudioFileResource] = [:]
    private var moves: [AnimationPlaybackController] = []
    /// Elements showing a variant rather than their base asset.
    public private(set) var swapped: Set<String> = []
    private var tweens: [Tween] = []
    private weak var scene: RealityKit.Scene?

    private struct Tween {
        enum Kind { case opacity(from: Float, to: Float, disableAtEnd: Bool), spin(radians: Float, done: Float) }
        let entity: Entity
        var kind: Kind
        var elapsed: TimeInterval = 0
        let duration: TimeInterval
        let invocation: Int?

        var isOpacity: Bool { if case .opacity = kind { true } else { false } }
    }

    public init(bundle: ExperienceBundle, scene: RealityKit.Scene) {
        self.bundle = bundle
        self.experience = bundle.experience
        self.scene = scene
    }

    public func register(_ b: EntityFactory.Built, for elementId: String) {
        built[elementId] = b
    }

    public func update(experience: Experience) { self.experience = experience }

    public func container(_ elementId: String) -> ModelEntity? { built[elementId]?.container }

    // MARK: Events

    public func apply(_ events: [EngineEvent]) {
        for e in events {
            switch e {
            case .perform(let inv): perform(inv)
            case .cancel(let id): cancel(id)
            case .visibility(let id, let visible, let fade): setVisible(id, visible, fade: fade)
            case .variant(let id, let variant): Task { await swapVariant(id, variant) }
            case .state, .found: break  // persisted by the model
            }
        }
    }

    /// Applies initial visibility without animation.
    public func setInitialVisibility(_ elementId: String, visible: Bool) {
        guard let c = built[elementId]?.container else { return }
        if visible {
            c.isEnabled = true
            c.components.set(OpacityComponent(opacity: 1))
        } else if showHiddenAsGhosts {
            c.isEnabled = true
            c.components.set(OpacityComponent(opacity: 0.3))
        } else {
            c.components.set(OpacityComponent(opacity: 0))
            c.isEnabled = false
        }
    }

    private func perform(_ inv: Invocation) {
        Log.behaviours.debug("Perform \(inv.action.type.rawValue, privacy: .public) on \(inv.elementId, privacy: .public)")
        guard let b = built[inv.elementId] else {
            Log.behaviours.info("Skipped \(inv.action.type.rawValue, privacy: .public): \(inv.elementId, privacy: .public) isn't built")
            return finish(inv)
        }
        let a = inv.action
        switch a.type {
        case .playAnimation:
            let clips = b.content.availableAnimations
            guard let clip = a.clip.flatMap({ name in clips.first { $0.name == name } }) ?? clips.first else {
                return finish(inv)
            }
            let resource = (a.loop ?? false) ? clip.repeat() : clip
            let controller = b.content.playAnimation(resource, transitionDuration: 0.2, startsPaused: false)
            controller.speed = Float(a.speed ?? 1)
            animations[inv.id] = controller
            if inv.awaitsCompletion, let scene {
                subscriptions[inv.id] = scene.subscribe(to: AnimationEvents.PlaybackCompleted.self, on: b.content) { [weak self] event in
                    guard event.playbackController == controller else { return }
                    self?.finish(inv)
                }
            }
        case .stopAnimation:
            b.content.stopAllAnimations()
        case .moveTo:
            guard let p = a.position else { return }
            var t = b.container.transform
            t.translation = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            moves.append(b.container.move(to: t, relativeTo: b.container.parent, duration: a.duration ?? 1, timingFunction: .easeInOut))
        case .scale:
            guard let f = a.factor else { return }
            var t = b.container.transform
            t.scale = SIMD3<Float>(repeating: Float(f))
            moves.append(b.container.move(to: t, relativeTo: b.container.parent, duration: a.duration ?? 1, timingFunction: .easeInOut))
        case .rotate:
            // A per-frame spin, so turns of 180° and more go the long way round.
            let radians = Float((a.degrees ?? 0) * .pi / 180)
            tweens.append(Tween(entity: b.container, kind: .spin(radians: radians, done: 0), duration: max(0.01, a.duration ?? 1), invocation: nil))
        case .playAudio:
            guard let resource = audioResource(for: a, element: inv.elementId, awaits: inv.awaitsCompletion) else { return finish(inv) }
            // Input mode is now set on the entity, not the resource: keep sounds spatial.
            if !b.container.components.has(SpatialAudioComponent.self) { b.container.components.set(SpatialAudioComponent()) }
            let controller = b.container.playAudio(resource)
            if let v = a.volume { controller.gain = 20 * log10(max(0.001, v)) }
            audio[inv.id] = controller
            if inv.awaitsCompletion {
                controller.completionHandler = { [weak self] in self?.finish(inv) }
            }
        case .playVideo:
            guard let player = b.videoPlayer else { return finish(inv) }
            player.seek(to: .zero)
            player.play()
            if inv.awaitsCompletion, let item = player.currentItem {
                videoObservers[inv.id] = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(inv) }
                }
            }
        default:
            finish(inv)
        }
    }

    /// The sound for a playAudio action. A sound the behaviour waits on is
    /// always loaded non-looping, or its completion would never arrive.
    private func audioResource(for a: Action, element: String, awaits: Bool) -> AudioFileResource? {
        let loop = awaits ? false : (a.loop ?? false)
        guard let path = a.asset ?? experience.element(id: element)?.asset else { return built[element]?.audio }
        let key = "\(path)#\(loop)"
        if let cached = audioCache[key] { return cached }
        guard let url = try? bundle.url(for: path),
              let r = try? AudioFileResource.load(contentsOf: url, configuration: .init(loadingStrategy: .preload, shouldLoop: loop))
        else {
            Log.behaviours.error("Sound for \(element, privacy: .public) couldn't be loaded")
            return nil
        }
        audioCache[key] = r
        return r
    }

    private func finish(_ inv: Invocation) {
        cleanup(inv.id)
        if inv.awaitsCompletion { onComplete?(inv.id) }
    }

    private func cancel(_ id: Int) {
        animations[id]?.stop()
        audio[id]?.stop()
        cleanup(id)
    }

    private func cleanup(_ id: Int) {
        animations[id] = nil
        audio[id] = nil
        subscriptions.removeValue(forKey: id)?.cancel()
        if let o = videoObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
    }

    private func setVisible(_ id: String, _ visible: Bool, fade: Double) {
        guard let c = built[id]?.container else { return }
        let current = c.components[OpacityComponent.self]?.opacity ?? (c.isEnabled ? 1 : 0)
        let target: Float = visible ? 1 : (showHiddenAsGhosts ? 0.3 : 0)
        c.isEnabled = true
        tweens.removeAll { $0.entity === c && $0.isOpacity }
        if fade <= 0 {
            c.components.set(OpacityComponent(opacity: target))
            c.isEnabled = visible || showHiddenAsGhosts
        } else {
            tweens.append(Tween(entity: c, kind: .opacity(from: current, to: target, disableAtEnd: !visible && !showHiddenAsGhosts),
                                duration: fade, invocation: nil))
        }
    }

    private func swapVariant(_ id: String, _ variantId: String) async {
        guard var b = built[id], let element = experience.element(id: id),
              let variant = element.variants.first(where: { $0.id == variantId }) else { return }
        do {
            try await EntityFactory.swapContent(of: &b, with: element, variantAsset: variant.asset, bundle: bundle)
            built[id] = b
            if variant.asset == element.asset { swapped.remove(id) } else { swapped.insert(id) }
        } catch {
            // A missing variant asset leaves the current one in place; the validator reports it.
            Log.behaviours.error("Variant \(variantId, privacy: .public) of \(id, privacy: .public) couldn't be shown: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    /// Advance fades and spins. Call from the scene update loop.
    public func step(_ dt: TimeInterval) {
        guard !tweens.isEmpty else { return }
        var remaining: [Tween] = []
        for var t in tweens {
            t.elapsed += dt
            let k = Float(min(1, t.elapsed / t.duration))
            switch t.kind {
            case .opacity(let from, let to, let disable):
                let eased = k * k * (3 - 2 * k)
                t.entity.components.set(OpacityComponent(opacity: from + (to - from) * eased))
                if k >= 1, disable { t.entity.isEnabled = false }
            case .spin(let radians, let done):
                let target = radians * k
                t.entity.orientation = simd_quatf(angle: target - done, axis: [0, 1, 0]) * t.entity.orientation
                t.kind = .spin(radians: radians, done: target)
            }
            if k < 1 { remaining.append(t) }
        }
        tweens = remaining
    }

    public func stopAll() {
        for id in Array(animations.keys) + Array(audio.keys) { cancel(id) }
        for b in built.values { b.videoPlayer?.pause() }
        moves.forEach { $0.stop() }
        moves.removeAll()
        tweens.removeAll()
    }

    /// Puts every element that is showing a variant back on its base asset.
    public func restoreBaseAssets() async {
        for id in swapped {
            guard var b = built[id], let element = experience.element(id: id), let base = element.asset else { continue }
            try? await EntityFactory.swapContent(of: &b, with: element, variantAsset: base, bundle: bundle)
            built[id] = b
        }
        swapped.removeAll()
    }
}
#endif
