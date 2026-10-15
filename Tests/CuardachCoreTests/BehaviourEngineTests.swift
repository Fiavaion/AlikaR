import XCTest
@testable import CuardachCore

final class BehaviourEngineTests: XCTestCase {
    func experience(_ elements: [Element]) -> Experience {
        var x = Experience(id: "x", title: "T", author: "A")
        x.elements = elements
        return x
    }

    func element(_ id: String, kind: ElementKind = .model, _ behaviours: [Behaviour] = [], hidden: Bool = false) -> Element {
        var e = Element(id: id, name: id, kind: kind, asset: "assets/\(id)")
        e.behaviours = behaviours
        if hidden { e.state = ElementState.hidden }
        return e
    }

    func performs(_ events: [EngineEvent]) -> [Invocation] {
        events.compactMap { if case .perform(let i) = $0 { i } else { nil } }
    }

    func testStartFiresOnceOnFirstResolve() {
        let b = Behaviour(trigger: .start, actions: [[.playAnimation("idle", loop: true)]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        let first = performs(eng.elementResolved("e", at: 0))
        XCTAssertEqual(first.map(\.action.clip), ["idle"])
        XCTAssertFalse(first[0].awaitsCompletion, "looping animations don't block the sequence")
        XCTAssertTrue(eng.elementResolved("e", at: 1).isEmpty)
    }

    func testSequentialGroupsWaitForCompletion() {
        let b = Behaviour(trigger: .tap, actions: [
            [.playAnimation("fly"), .playAudio()],
            [.setState("found")],
            [.playAnimation("land")],
        ])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        let tap = eng.tap("e", at: 1)
        let group1 = performs(tap)
        XCTAssertEqual(group1.map(\.action.type), [.playAnimation, .playAudio])
        XCTAssertTrue(tap.contains(.found(elementId: "e")), "tapping marks found (P8)")

        XCTAssertTrue(performs(eng.complete(invocation: group1[0].id, at: 2)).isEmpty, "one of two parallel actions done")
        let next = eng.complete(invocation: group1[1].id, at: 3)
        // setState group completes instantly and flows straight into the next group.
        XCTAssertTrue(next.contains(.state(elementId: "e", value: "found")))
        XCTAssertEqual(performs(next).map(\.action.clip), ["land"])
        XCTAssertFalse(eng.isIdle)
        let last = performs(next)[0]
        _ = eng.complete(invocation: last.id, at: 4)
        XCTAssertTrue(eng.isIdle)
    }

    func testDelayIsTimedByEngine() {
        let b = Behaviour(trigger: .tap, actions: [[.delay(2)], [.playAudio()]])
        var eng = BehaviourEngine(experience: experience([element("e", kind: .audio, [b])]))
        _ = eng.elementResolved("e", at: 0)
        XCTAssertTrue(performs(eng.tap("e", at: 10)).isEmpty)
        XCTAssertTrue(performs(eng.tick(at: 11.9)).isEmpty)
        XCTAssertEqual(performs(eng.tick(at: 12)).map(\.action.type), [.playAudio])
    }

    func testChainedDelaysWithinOneFrameRunInOrder() {
        let b = Behaviour(trigger: .tap, actions: [[.delay(0.1)], [.delay(0.1)], [.setState("a")], [.delay(0.1)], [.setState("b")]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        _ = eng.tap("e", at: 0)
        let events = eng.tick(at: 5)
        XCTAssertEqual(events, [.state(elementId: "e", value: "a"), .state(elementId: "e", value: "b")])
    }

    func testRetriggerAfterComplete() {
        let b = Behaviour(trigger: .tap, retrigger: .afterComplete, actions: [[.playAnimation("spin")]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        let inv = performs(eng.tap("e", at: 1))[0]
        XCTAssertTrue(performs(eng.tap("e", at: 1.5)).isEmpty, "ignored while running")
        _ = eng.complete(invocation: inv.id, at: 2)
        XCTAssertEqual(performs(eng.tap("e", at: 3)).count, 1, "fires again once done")
    }

    func testRetriggerImmediatelyCancelsRendererWork() {
        var move = Action(.moveTo); move.position = Vec3(0, 1, 0); move.duration = 3
        let b = Behaviour(trigger: .tap, retrigger: .immediately, actions: [[.playAnimation("spin"), move]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        let first = performs(eng.tap("e", at: 1))
        let second = eng.tap("e", at: 1.5)
        XCTAssertTrue(second.contains(.cancel(invocationId: first[0].id)))
        XCTAssertTrue(second.contains(.cancel(invocationId: first[1].id)))
        XCTAssertEqual(performs(second).count, 2)
        // A late completion of a cancelled invocation is ignored.
        XCTAssertTrue(eng.complete(invocation: first[0].id, at: 2).isEmpty)
    }

    func testRetriggerNever() {
        let b = Behaviour(trigger: .tap, retrigger: .never, actions: [[.setState("x")]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        XCTAssertTrue(eng.tap("e", at: 1).contains(.state(elementId: "e", value: "x")))
        XCTAssertFalse(eng.tap("e", at: 2).contains(.state(elementId: "e", value: "x")))
    }

    func testHiddenElementIgnoresTapsUntilShown() {
        let reveal = Behaviour(trigger: .proximityEnter, actions: [[.show(fade: 0.5)]])
        let tap = Behaviour(trigger: .tap, actions: [[.setState("tapped")]])
        var eng = BehaviourEngine(experience: experience([element("e", [reveal, tap], hidden: true)]))
        _ = eng.elementResolved("e", at: 0)
        XCTAssertFalse(eng.isVisible("e"))
        XCTAssertTrue(eng.tap("e", at: 1).isEmpty)
        // Hidden elements are not found by walking up to them.
        let near = eng.update(observations: [Observation(elementId: "e", distanceM: 0.5, inView: true)], at: 2)
        XCTAssertTrue(near.contains(.visibility(elementId: "e", visible: true, fadeS: 0.5)))
        XCTAssertFalse(near.contains(.found(elementId: "e")))
        XCTAssertTrue(eng.isVisible("e"))
        XCTAssertTrue(eng.tap("e", at: 3).contains(.state(elementId: "e", value: "tapped")))
    }

    func testProximityEnterExitWithHysteresis() {
        var enter = Behaviour(trigger: .proximityEnter, actions: [[.setState("in")]]); enter.proximityM = 3
        var exit = Behaviour(trigger: .proximityExit, actions: [[.setState("out")]]); exit.proximityM = 3
        var eng = BehaviourEngine(experience: experience([element("e", [enter, exit])]))
        _ = eng.elementResolved("e", at: 0)
        func at(_ d: Double, _ t: Double) -> [EngineEvent] {
            eng.update(observations: [Observation(elementId: "e", distanceM: d, inView: false)], at: t)
        }
        XCTAssertTrue(at(5, 1).isEmpty, "exit never fires before an enter")
        XCTAssertTrue(at(2.9, 2).contains(.state(elementId: "e", value: "in")))
        XCTAssertTrue(at(3.1, 3).isEmpty, "inside the hysteresis band")
        XCTAssertTrue(at(3.3, 4).contains(.state(elementId: "e", value: "out")))
    }

    func testFoundByApproach() {
        var eng = BehaviourEngine(experience: experience([element("e")]))
        _ = eng.elementResolved("e", at: 0)
        XCTAssertTrue(eng.update(observations: [Observation(elementId: "e", distanceM: 1.5, inView: true)], at: 1).isEmpty)
        let ev = eng.update(observations: [Observation(elementId: "e", distanceM: 0.9, inView: true)], at: 2)
        XCTAssertEqual(ev, [.found(elementId: "e"), .state(elementId: "e", value: "found")])
        XCTAssertTrue(eng.update(observations: [Observation(elementId: "e", distanceM: 0.5, inView: true)], at: 3).isEmpty)
    }

    func testUnresolvedElementsAreIgnored() {
        let b = Behaviour(trigger: .proximityEnter, actions: [[.setState("in")]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        XCTAssertTrue(eng.update(observations: [Observation(elementId: "e", distanceM: 0.1, inView: true)], at: 1).isEmpty)
        XCTAssertTrue(eng.tap("e", at: 1).isEmpty)
    }

    func testDwellRequiresContinuousAttention() {
        var b = Behaviour(trigger: .dwell, actions: [[.setState("seen")]]); b.dwellS = 3
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        func look(_ inView: Bool, _ t: Double) -> [EngineEvent] {
            eng.update(observations: [Observation(elementId: "e", distanceM: 4, inView: inView)], at: t)
        }
        _ = look(true, 1)
        _ = look(true, 2.5)
        _ = look(false, 3)          // glanced away: timer resets
        _ = look(true, 4)
        XCTAssertTrue(look(true, 6.9).isEmpty)
        XCTAssertTrue(look(true, 7).contains(.state(elementId: "e", value: "seen")))
        XCTAssertTrue(look(true, 20).isEmpty, "fires once per uninterrupted look")
        _ = look(false, 21)
        _ = look(true, 22)
        XCTAssertTrue(look(true, 25).contains(.state(elementId: "e", value: "seen")))
    }

    func testTimeWindowFiresOnEntry() {
        var b = Behaviour(trigger: .timeWindow, actions: [[.show()]])
        b.window = TimeWindow(from: "18:00", to: "23:00")
        var eng = BehaviourEngine(experience: experience([element("e", [b], hidden: true)]))
        XCTAssertTrue(eng.elementResolved("e", at: 0, minuteOfDay: 17 * 60).isEmpty)
        let opens = eng.update(observations: [], at: 1, minuteOfDay: 18 * 60)
        XCTAssertTrue(opens.contains(.visibility(elementId: "e", visible: true, fadeS: 0.3)))
        XCTAssertTrue(eng.update(observations: [], at: 2, minuteOfDay: 19 * 60).isEmpty)
    }

    func testTimeWindowAlreadyOpenAtResolve() {
        var b = Behaviour(trigger: .timeWindow, actions: [[.setState("night")]])
        b.window = TimeWindow(from: "21:00", to: "05:00")
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        XCTAssertTrue(eng.elementResolved("e", at: 0, minuteOfDay: 23 * 60).contains(.state(elementId: "e", value: "night")))
    }

    func testCrossElementTargetsAndUnlock() {
        let key = Behaviour(trigger: .tap, actions: [[.setState("visible", target: "door")]])
        var eng = BehaviourEngine(experience: experience([element("key", [key]), element("door", hidden: true)]))
        _ = eng.elementResolved("key", at: 0)
        _ = eng.elementResolved("door", at: 0)
        XCTAssertFalse(eng.isVisible("door"))
        let ev = eng.tap("key", at: 1)
        XCTAssertTrue(ev.contains(.visibility(elementId: "door", visible: true, fadeS: 0.3)))
        XCTAssertTrue(eng.isVisible("door"))
    }

    func testVariants() {
        var chair = element("chair", [Behaviour(trigger: .tap, actions: [[Action(.cycleVariant)]])])
        chair.variants = [Variant(id: "oak", name: "Oak", asset: "a"), Variant(id: "ash", name: "Ash", asset: "b")]
        var set = Action(.setVariant, target: "chair"); set.variant = "ash"
        var bogus = Action(.setVariant, target: "chair"); bogus.variant = "teak"
        let remote = element("button", [Behaviour(trigger: .tap, actions: [[set], [bogus]])])
        var eng = BehaviourEngine(experience: experience([chair, remote]))
        _ = eng.elementResolved("chair", at: 0)
        _ = eng.elementResolved("button", at: 0)
        XCTAssertTrue(eng.tap("chair", at: 1).contains(.variant(elementId: "chair", variantId: "oak")))
        XCTAssertTrue(eng.tap("chair", at: 2).contains(.variant(elementId: "chair", variantId: "ash")))
        XCTAssertTrue(eng.tap("chair", at: 3).contains(.variant(elementId: "chair", variantId: "oak")))
        let ev = eng.tap("button", at: 4)
        XCTAssertTrue(ev.contains(.variant(elementId: "chair", variantId: "ash")))
        XCTAssertEqual(ev.filter { if case .variant = $0 { true } else { false } }.count, 1, "unknown variant ignored")
    }

    func testSavedStatesRestore() {
        var eng = BehaviourEngine(experience: experience([element("a"), element("b", hidden: true)]),
                                  savedStates: ["a": "found", "b": "visible"])
        XCTAssertEqual(eng.found, ["a"])
        XCTAssertTrue(eng.isVisible("b"))
        _ = eng.elementResolved("a", at: 0)
        XCTAssertTrue(eng.tap("a", at: 1).isEmpty, "already found")
    }

    func testUnknownActionsAreSkipped() {
        let b = Behaviour(trigger: .tap, actions: [[Action(ActionType(rawValue: "teleport"))], [.setState("after")]])
        var eng = BehaviourEngine(experience: experience([element("e", [b])]))
        _ = eng.elementResolved("e", at: 0)
        XCTAssertTrue(eng.tap("e", at: 1).contains(.state(elementId: "e", value: "after")))
    }
}
