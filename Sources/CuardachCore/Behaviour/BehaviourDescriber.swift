import Foundation

/// Plain-English summaries of behaviours, for the behaviour list in author
/// mode, the exhibition catalogue and the command-line inspector:
/// "When tapped: play “fly”, then mark found."
public enum BehaviourDescriber {
    public static func describe(_ b: Behaviour, on element: Element, in x: Experience) -> String {
        let groups = b.actions.filter { !$0.isEmpty }.map { group in
            group.map { describe($0, self: element, in: x) }.joined(separator: " and ")
        }
        let body = groups.isEmpty ? "do nothing" : groups.joined(separator: ", then ")
        var s = "\(trigger(b)): \(body)."
        switch b.retrigger {
        case .never: s += " Once only."
        case .immediately: s += " Restarts if triggered again."
        default: break
        }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public static func trigger(_ b: Behaviour) -> String {
        switch b.trigger {
        case .start: "when it appears"
        case .tap: "when tapped"
        case .proximityEnter: "when someone comes within \(metres(b.effectiveProximityM))"
        case .proximityExit: "when someone walks away beyond \(metres(b.effectiveProximityM))"
        case .dwell: "after being looked at for \(seconds(b.effectiveDwellS))"
        case .timeWindow: b.window.map { "between \($0.from) and \($0.to)" } ?? "at a set time"
        default: "on \(b.trigger)"
        }
    }

    public static func describe(_ a: Action, self element: Element, in x: Experience) -> String {
        let target = a.target.flatMap { id in id == element.id ? nil : x.element(id: id) }
        let on = target.map { " “\($0.name)”" } ?? ""
        switch a.type {
        case .playAnimation: return "play " + (a.clip.map { "“\($0)”" } ?? "the animation") + on + (a.loop == true ? " on loop" : "")
        case .stopAnimation: return "stop the animation" + on
        case .show: return target.map { "reveal “\($0.name)”" } ?? "appear"
        case .hide: return target.map { "hide “\($0.name)”" } ?? "disappear"
        case .moveTo: return "move" + on + (a.duration.map { " over \(seconds($0))" } ?? "")
        case .rotate: return "turn" + on + (a.degrees.map { " \(Int($0))°" } ?? "")
        case .scale: return "scale" + on + (a.factor.map { " to \(String(format: "%g", $0))×" } ?? "")
        case .playAudio: return "play a sound" + on
        case .playVideo: return "play the video" + on
        case .delay: return "wait \(seconds(a.seconds ?? 0))"
        case .setState:
            switch a.value {
            case ElementState.found?: return "mark" + (target.map { " “\($0.name)”" } ?? "") + " found"
            case ElementState.visible?: return target.map { "unlock “\($0.name)”" } ?? "become visible"
            case let v?: return "set" + on + " to “\(v)”"
            case nil: return "change state"
            }
        case .setVariant:
            let owner = target ?? element
            let name = owner.variants.first { $0.id == a.variant }?.name ?? a.variant ?? "?"
            return "switch" + on + " to “\(name)”"
        case .cycleVariant: return "show the next variant" + on
        default: return "\(a.type)"
        }
    }

    static func metres(_ m: Double) -> String { m == m.rounded() ? "\(Int(m)) m" : String(format: "%.1f m", m) }
    static func seconds(_ s: Double) -> String {
        let v = s == s.rounded() ? "\(Int(s))" : String(format: "%.1f", s)
        return "\(v) second\(s == 1 ? "" : "s")"
    }
}
