import Foundation

/// What starts a behaviour. Aero's vocabulary (start, tap, proximity) plus two
/// time-based triggers for durational and site-specific work.
public struct Trigger: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Fires when the element first resolves in the player's world.
    public static let start = Trigger(rawValue: "start")
    /// Fires when the player taps the element.
    public static let tap = Trigger(rawValue: "tap")
    /// Fires when the player's device comes within `proximityM` of the element.
    public static let proximityEnter = Trigger(rawValue: "proximityEnter")
    /// Fires when the player's device moves back beyond `proximityM`.
    public static let proximityExit = Trigger(rawValue: "proximityExit")
    /// Studio extension: fires after the player has kept the element in view
    /// for `dwellS` seconds. Rewards slow looking.
    public static let dwell = Trigger(rawValue: "dwell")
    /// Studio extension: fires when the element is resolved and the local
    /// time is inside `window` (e.g. only after dusk).
    public static let timeWindow = Trigger(rawValue: "timeWindow")

    public static let known: [Trigger] = [.start, .tap, .proximityEnter, .proximityExit, .dwell, .timeWindow]
}

/// What happens when a trigger fires while the behaviour is still running
/// or has already run. Aero's three modes, verbatim.
public struct Retrigger: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Restart the actions from the beginning, even mid-run.
    public static let immediately = Retrigger(rawValue: "immediately")
    /// Ignore triggers while running; fire again once finished.
    public static let afterComplete = Retrigger(rawValue: "afterComplete")
    /// Run once per play session.
    public static let never = Retrigger(rawValue: "never")

    public static let known: [Retrigger] = [.immediately, .afterComplete, .never]
}

/// A local wall-clock window, `"HH:mm"` to `"HH:mm"`. Wraps past midnight
/// when `to` is earlier than `from` (e.g. 21:00 → 05:00).
public struct TimeWindow: Codable, Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) { self.from = from; self.to = to }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    public var isValid: Bool { Self.minutes(from) != nil && Self.minutes(to) != nil }

    /// Whether `minuteOfDay` (0–1439) falls inside the window.
    public func contains(minuteOfDay: Int) -> Bool {
        guard let a = Self.minutes(from), let b = Self.minutes(to) else { return false }
        if a == b { return true }
        return a < b ? (minuteOfDay >= a && minuteOfDay < b) : (minuteOfDay >= a || minuteOfDay < b)
    }
}

/// A trigger plus ordered groups of actions. Each inner array runs in
/// parallel; the next group starts when every action in the previous one
/// has finished (Aero's model).
public struct Behaviour: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var trigger: Trigger
    public var retrigger: Retrigger
    public var actions: [[Action]]
    /// proximityEnter / proximityExit / dwell: distance in metres. Default 2 m.
    public var proximityM: Double?
    /// dwell: seconds the element must stay in view. Default 3 s.
    public var dwellS: Double?
    /// timeWindow: when the behaviour may fire.
    public var window: TimeWindow?
    public var extra: Extras = [:]

    public static let defaultProximityM = 2.0
    public static let defaultDwellS = 3.0

    public init(id: String = UUID().uuidString, trigger: Trigger, retrigger: Retrigger = .afterComplete,
                actions: [[Action]] = []) {
        self.id = id
        self.trigger = trigger
        self.retrigger = retrigger
        self.actions = actions
    }

    public var effectiveProximityM: Double { proximityM ?? Self.defaultProximityM }
    public var effectiveDwellS: Double { dwellS ?? Self.defaultDwellS }

    static let known: Set<String> = ["id", "trigger", "retrigger", "actions", "proximityM", "dwellS", "window"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        trigger = try c.decode("trigger")
        // Manifests from other tools may omit ids. The engine keys behaviours
        // by element and index, so a fresh id here only serves UI identity.
        id = try c.decode("id", default: UUID().uuidString)
        retrigger = try c.decode("retrigger", default: .afterComplete)
        actions = try c.decode("actions", default: [])
        proximityM = try c.decodeOptional("proximityM")
        dwellS = try c.decodeOptional("dwellS")
        window = try c.decodeOptional("window")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(id, "id")
        try c.put(trigger, "trigger")
        try c.put(retrigger, "retrigger")
        try c.put(actions, "actions")
        try c.putIfPresent(proximityM, "proximityM")
        try c.putIfPresent(dwellS, "dwellS")
        try c.putIfPresent(window, "window")
    }
}

public struct ActionType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let playAnimation = ActionType(rawValue: "playAnimation")
    public static let stopAnimation = ActionType(rawValue: "stopAnimation")
    public static let show = ActionType(rawValue: "show")
    public static let hide = ActionType(rawValue: "hide")
    public static let moveTo = ActionType(rawValue: "moveTo")
    public static let rotate = ActionType(rawValue: "rotate")
    public static let scale = ActionType(rawValue: "scale")
    public static let playAudio = ActionType(rawValue: "playAudio")
    public static let playVideo = ActionType(rawValue: "playVideo")
    public static let delay = ActionType(rawValue: "delay")
    public static let setState = ActionType(rawValue: "setState")
    /// Studio extension: switch the element to a named variant.
    public static let setVariant = ActionType(rawValue: "setVariant")
    /// Studio extension: advance to the element's next variant.
    public static let cycleVariant = ActionType(rawValue: "cycleVariant")

    public static let known: [ActionType] = [
        .playAnimation, .stopAnimation, .show, .hide, .moveTo, .rotate, .scale,
        .playAudio, .playVideo, .delay, .setState, .setVariant, .cycleVariant,
    ]

    /// Actions the engine completes by itself without asking the renderer.
    public var isEngineInternal: Bool { self == .delay || self == .setState }
}

/// One step of a behaviour. Parameters are flat optional fields so the JSON
/// stays readable; the validator reports missing required parameters.
public struct Action: Codable, Hashable, Sendable {
    public var type: ActionType
    /// Element the action applies to. Nil means the behaviour's own element.
    public var target: String?

    /// playAnimation / stopAnimation: clip name; nil means the first clip.
    public var clip: String?
    /// playAnimation / playVideo / playAudio: loop instead of finishing.
    public var loop: Bool?
    /// playAnimation: playback speed multiplier.
    public var speed: Double?
    /// moveTo / rotate / scale / show / hide: seconds. Zero is instant.
    public var duration: Double?
    /// moveTo: destination relative to the element's anchor.
    public var position: Vec3?
    /// rotate: rotation to add, in degrees about the Y axis (spin).
    public var degrees: Double?
    /// scale: target uniform scale factor.
    public var factor: Double?
    /// playAudio: asset path in the bundle; nil plays the element's own audio.
    public var asset: String?
    /// playAudio: volume 0–1.
    public var volume: Double?
    /// delay: seconds to wait.
    public var seconds: Double?
    /// setState: new state value ("found", "hidden" or custom).
    public var value: String?
    /// setVariant: variant id.
    public var variant: String?
    public var extra: Extras = [:]

    public init(_ type: ActionType, target: String? = nil) {
        self.type = type
        self.target = target
    }

    static let known: Set<String> = [
        "type", "target", "clip", "loop", "speed", "duration", "position", "degrees", "factor",
        "asset", "volume", "seconds", "value", "variant",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = try c.decode("type")
        target = try c.decodeOptional("target")
        clip = try c.decodeOptional("clip")
        loop = try c.decodeOptional("loop")
        speed = try c.decodeOptional("speed")
        duration = try c.decodeOptional("duration")
        position = try c.decodeOptional("position")
        degrees = try c.decodeOptional("degrees")
        factor = try c.decodeOptional("factor")
        asset = try c.decodeOptional("asset")
        volume = try c.decodeOptional("volume")
        seconds = try c.decodeOptional("seconds")
        value = try c.decodeOptional("value")
        variant = try c.decodeOptional("variant")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(type, "type")
        try c.putIfPresent(target, "target")
        try c.putIfPresent(clip, "clip")
        try c.putIfPresent(loop, "loop")
        try c.putIfPresent(speed, "speed")
        try c.putIfPresent(duration, "duration")
        try c.putIfPresent(position, "position")
        try c.putIfPresent(degrees, "degrees")
        try c.putIfPresent(factor, "factor")
        try c.putIfPresent(asset, "asset")
        try c.putIfPresent(volume, "volume")
        try c.putIfPresent(seconds, "seconds")
        try c.putIfPresent(value, "value")
        try c.putIfPresent(variant, "variant")
    }
}

extension Action {
    public static func show(fade: Double = 0.3, target: String? = nil) -> Action {
        var a = Action(.show, target: target); a.duration = fade; return a
    }
    public static func hide(fade: Double = 0.3, target: String? = nil) -> Action {
        var a = Action(.hide, target: target); a.duration = fade; return a
    }
    public static func delay(_ seconds: Double) -> Action {
        var a = Action(.delay); a.seconds = seconds; return a
    }
    public static func setState(_ value: String, target: String? = nil) -> Action {
        var a = Action(.setState, target: target); a.value = value; return a
    }
    public static func playAnimation(_ clip: String? = nil, loop: Bool = false, target: String? = nil) -> Action {
        var a = Action(.playAnimation, target: target); a.clip = clip; a.loop = loop; return a
    }
    public static func playAudio(_ asset: String? = nil, target: String? = nil) -> Action {
        var a = Action(.playAudio, target: target); a.asset = asset; return a
    }
}
