import Foundation

/// Per-frame facts about one resolved element, measured by the AR layer.
public struct ElementObservation: Sendable, Equatable {
    public var elementId: String
    /// Distance from the camera to the element's origin, in metres.
    public var distanceM: Double
    /// Whether the element's bounds are within the central part of the view.
    public var inView: Bool

    public init(elementId: String, distanceM: Double, inView: Bool) {
        self.elementId = elementId; self.distanceM = distanceM; self.inView = inView
    }
}

/// An action the renderer must carry out.
public struct Invocation: Sendable, Equatable {
    public var id: Int
    /// The element the action applies to (target resolved).
    public var elementId: String
    /// The action with engine-resolved parameters (e.g. cycleVariant → variant).
    public var action: Action
    /// True when the renderer must call `complete(invocation:)` when the
    /// media finishes (or fails). False when the engine times it itself.
    public var awaitsCompletion: Bool
}

/// What the engine asks the renderer and app to do.
public enum EngineEvent: Sendable, Equatable {
    /// Run an animation, move, rotate, scale, audio or video action.
    case perform(Invocation)
    /// Stop a running invocation early (its behaviour was retriggered).
    case cancel(invocationId: Int)
    /// Fade an element in or out.
    case visibility(elementId: String, visible: Bool, fadeS: Double)
    /// Swap an element's asset to one of its variants.
    case variant(elementId: String, variantId: String)
    /// An element's state changed; persist it per device (PRD P8).
    case state(elementId: String, value: String)
    /// An element was found for the first time.
    case found(elementId: String)
}

/// Runs authored behaviours: trigger → sequential groups of parallel actions,
/// with Aero's re-trigger modes. Pure and deterministic: time is passed in,
/// so the same engine drives the player, author-mode "simulate", and tests.
public struct BehaviourEngine: Sendable {
    /// Approaching within this distance marks a visible element found (PRD P8).
    public var foundDistanceM = 1.0
    /// Extra distance before a proximity zone counts as exited, so standing
    /// on the boundary doesn't flicker enter/exit.
    public var proximityHysteresisM = 0.25

    public private(set) var states: [String: String]
    public private(set) var found: Set<String>

    private struct Key: Hashable, Sendable { let element: String; let index: Int }

    private struct Run: Sendable {
        var group: Int
        var pending: Set<Int>
    }

    private var behaviours: [Key: Behaviour] = [:]
    private var elementIds: [String] = []
    private var variantsByElement: [String: [Variant]] = [:]
    private var currentVariant: [String: String] = [:]
    private var visible: [String: Bool] = [:]
    private var resolved: Set<String> = []
    private var runs: [Key: Run] = [:]
    private var hasFired: Set<Key> = []
    private var invocationOwner: [Int: Key] = [:]
    private var timers: [Int: Double] = [:]
    /// Invocations handed to the renderer, which must be told to cancel them.
    private var rendered: Set<Int> = []
    private var nextInvocation = 1
    private var insideProximity: Set<Key> = []
    private var dwellSince: [Key: Double] = [:]
    private var dwellFired: Set<Key> = []
    private var insideWindow: Set<Key> = []
    private var now: Double = 0

    public init(experience: Experience, savedStates: [String: String] = [:]) {
        states = [:]
        found = []
        for el in experience.elements {
            elementIds.append(el.id)
            for (i, b) in el.behaviours.enumerated() { behaviours[Key(element: el.id, index: i)] = b }
            variantsByElement[el.id] = el.variants
            let initial = savedStates[el.id] ?? el.state ?? ElementState.visible
            states[el.id] = initial
            if initial == ElementState.found { found.insert(el.id) }
            switch savedStates[el.id] {
            case ElementState.hidden?: visible[el.id] = false
            case ElementState.visible?: visible[el.id] = true
            default: visible[el.id] = !el.startsHidden
            }
        }
    }

    public func isVisible(_ elementId: String) -> Bool { visible[elementId] ?? false }
    public func isResolved(_ elementId: String) -> Bool { resolved.contains(elementId) }
    public func variant(of elementId: String) -> String? { currentVariant[elementId] }
    public var isIdle: Bool { runs.isEmpty }

    // MARK: Inputs

    /// The element's anchor resolved for the first time: fire `start`, and
    /// `timeWindow` if the window is already open (PRD P7).
    public mutating func elementResolved(_ id: String, at t: Double, minuteOfDay: Int? = nil) -> [EngineEvent] {
        var out = advance(to: t)
        guard !resolved.contains(id), elementIds.contains(id) else { return out }
        resolved.insert(id)
        for key in keys(for: id, trigger: .start) { out += fire(key) }
        if let m = minuteOfDay { out += evaluateWindows(minuteOfDay: m) }
        return out
    }

    /// The player tapped an element. Ignored while it is hidden.
    public mutating func tap(_ id: String, at t: Double) -> [EngineEvent] {
        var out = advance(to: t)
        guard resolved.contains(id), isVisible(id) else { return out }
        out += markFound(id)
        for key in keys(for: id, trigger: .tap) { out += fire(key) }
        return out
    }

    /// Per-frame update with distances to resolved elements.
    public mutating func update(observations: [ElementObservation], at t: Double, minuteOfDay: Int? = nil) -> [EngineEvent] {
        var out = advance(to: t)
        for o in observations where resolved.contains(o.elementId) {
            if o.distanceM <= foundDistanceM, isVisible(o.elementId) { out += markFound(o.elementId) }
            for (key, b) in behaviours where key.element == o.elementId {
                switch b.trigger {
                case .proximityEnter, .proximityExit:
                    let r = b.effectiveProximityM
                    let wasInside = insideProximity.contains(key)
                    if !wasInside, o.distanceM <= r {
                        insideProximity.insert(key)
                        if b.trigger == .proximityEnter { out += fire(key) }
                    } else if wasInside, o.distanceM > r + proximityHysteresisM {
                        insideProximity.remove(key)
                        if b.trigger == .proximityExit { out += fire(key) }
                    }
                case .dwell:
                    let near = b.proximityM.map { o.distanceM <= $0 } ?? true
                    if o.inView, near {
                        let since = dwellSince[key] ?? t
                        dwellSince[key] = since
                        if t - since >= b.effectiveDwellS, !dwellFired.contains(key) {
                            dwellFired.insert(key)
                            out += fire(key)
                        }
                    } else {
                        dwellSince[key] = nil
                        dwellFired.remove(key)
                    }
                default:
                    break
                }
            }
        }
        if let m = minuteOfDay { out += evaluateWindows(minuteOfDay: m) }
        return out
    }

    /// The renderer finished (or failed) an invocation that awaited completion.
    public mutating func complete(invocation id: Int, at t: Double) -> [EngineEvent] {
        var out = advance(to: t)
        out += finish(invocation: id)
        return out
    }

    /// Fires one behaviour as if its trigger had happened: the author's
    /// "simulate" button (PRD A10). Re-trigger rules still apply.
    public mutating func simulate(_ elementId: String, behaviour index: Int, at t: Double) -> [EngineEvent] {
        var out = advance(to: t)
        resolved.insert(elementId)
        out += fire(Key(element: elementId, index: index))
        return out
    }

    /// Advances timers (delays, fades, moves) without any other input.
    public mutating func tick(at t: Double) -> [EngineEvent] { advance(to: t) }

    // MARK: Internals

    private func keys(for element: String, trigger: Trigger) -> [Key] {
        behaviours.filter { $0.key.element == element && $0.value.trigger == trigger }
            .map(\.key).sorted { $0.index < $1.index }
    }

    private mutating func evaluateWindows(minuteOfDay: Int) -> [EngineEvent] {
        var out: [EngineEvent] = []
        let windowed = behaviours.filter { $0.value.trigger == .timeWindow }.sorted {
            ($0.key.element, $0.key.index) < ($1.key.element, $1.key.index)
        }
        for (key, b) in windowed where resolved.contains(key.element) {
            let inside = b.window?.contains(minuteOfDay: minuteOfDay) ?? false
            if inside, !insideWindow.contains(key) {
                insideWindow.insert(key)
                out += fire(key)
            } else if !inside {
                insideWindow.remove(key)
            }
        }
        return out
    }

    private mutating func markFound(_ id: String) -> [EngineEvent] {
        guard !found.contains(id) else { return [] }
        found.insert(id)
        states[id] = ElementState.found
        return [.found(elementId: id), .state(elementId: id, value: ElementState.found)]
    }

    private mutating func fire(_ key: Key) -> [EngineEvent] {
        guard let b = behaviours[key] else { return [] }
        var out: [EngineEvent] = []
        if b.retrigger == .never, hasFired.contains(key) { return [] }
        if let running = runs[key] {
            guard b.retrigger == .immediately else { return [] }
            for inv in running.pending.sorted() {
                if rendered.remove(inv) != nil { out.append(.cancel(invocationId: inv)) }
                timers[inv] = nil
                invocationOwner[inv] = nil
            }
            runs[key] = nil
        }
        hasFired.insert(key)
        runs[key] = Run(group: -1, pending: [])
        out += startGroup(key, b.actions, index: 0)
        return out
    }

    private mutating func startGroup(_ key: Key, _ groups: [[Action]], index: Int) -> [EngineEvent] {
        var out: [EngineEvent] = []
        var i = index
        // Skip through groups whose actions all complete instantly.
        while i < groups.count {
            runs[key]?.group = i
            runs[key]?.pending = []
            for action in groups[i] { out += start(action, owner: key) }
            if !(runs[key]?.pending.isEmpty ?? true) { return out }
            i += 1
        }
        runs[key] = nil
        return out
    }

    private mutating func start(_ original: Action, owner key: Key) -> [EngineEvent] {
        let target = original.target ?? key.element
        let id = nextInvocation
        nextInvocation += 1
        var action = original
        action.target = target

        func timed(_ seconds: Double) {
            guard seconds > 0 else { return }
            invocationOwner[id] = key
            timers[id] = now + seconds
            runs[key]?.pending.insert(id)
        }

        switch action.type {
        case .delay:
            timed(action.seconds ?? 0)
            return []
        case .setState:
            guard let value = action.value else { return [] }
            states[target] = value
            var out: [EngineEvent] = [.state(elementId: target, value: value)]
            if value == ElementState.found, !found.contains(target) {
                found.insert(target)
                out.insert(.found(elementId: target), at: 0)
            }
            if value == ElementState.hidden || value == ElementState.visible {
                let v = value == ElementState.visible
                visible[target] = v
                out.append(.visibility(elementId: target, visible: v, fadeS: 0.3))
            }
            return out
        case .show, .hide:
            let v = action.type == .show
            visible[target] = v
            let fade = max(0, action.duration ?? 0.3)
            timed(fade)
            return [.visibility(elementId: target, visible: v, fadeS: fade)]
        case .setVariant:
            guard let variant = action.variant,
                  variantsByElement[target]?.contains(where: { $0.id == variant }) == true else { return [] }
            currentVariant[target] = variant
            return [.variant(elementId: target, variantId: variant)]
        case .cycleVariant:
            guard let vs = variantsByElement[target], !vs.isEmpty else { return [] }
            let idx = currentVariant[target].flatMap { cur in vs.firstIndex { $0.id == cur } }
            let next = vs[((idx ?? -1) + 1) % vs.count].id
            currentVariant[target] = next
            return [.variant(elementId: target, variantId: next)]
        case .moveTo, .rotate, .scale:
            let d = max(0, action.duration ?? 1)
            timed(d)
            if d > 0 { rendered.insert(id) }
            return [.perform(Invocation(id: id, elementId: target, action: action, awaitsCompletion: false))]
        case .stopAnimation:
            return [.perform(Invocation(id: id, elementId: target, action: action, awaitsCompletion: false))]
        case .playAnimation, .playAudio, .playVideo:
            let waits = !(action.loop ?? false)
            if waits {
                invocationOwner[id] = key
                runs[key]?.pending.insert(id)
                rendered.insert(id)
            }
            return [.perform(Invocation(id: id, elementId: target, action: action, awaitsCompletion: waits))]
        default:
            // Unknown action from a newer manifest: skip without blocking.
            return []
        }
    }

    private mutating func finish(invocation id: Int) -> [EngineEvent] {
        guard let key = invocationOwner.removeValue(forKey: id) else { return [] }
        timers[id] = nil
        rendered.remove(id)
        guard var run = runs[key] else { return [] }
        run.pending.remove(id)
        runs[key] = run
        guard run.pending.isEmpty, let b = behaviours[key] else { return [] }
        return startGroup(key, b.actions, index: run.group + 1)
    }

    /// Fires due timers in deadline order, so a chain of short delays that
    /// all fall due within one frame still runs in sequence.
    private mutating func advance(to t: Double) -> [EngineEvent] {
        var out: [EngineEvent] = []
        while let next = timers.min(by: { ($0.value, $0.key) < ($1.value, $1.key) }), next.value <= t {
            now = next.value
            out += finish(invocation: next.key)
        }
        now = max(now, t)
        return out
    }
}
