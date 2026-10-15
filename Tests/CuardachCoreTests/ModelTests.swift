import XCTest
@testable import CuardachCore

final class ModelTests: XCTestCase {
    /// The example manifest from the PRD, verbatim apart from the elided id.
    static let prdManifest = """
    {
      "schemaVersion": 1,
      "id": "8d6c",
      "title": "Courtyard Hunt",
      "author": "NCAD Product Design",
      "siteHint": { "lat": 53.3436, "long": -6.2806, "radiusM": 120 },
      "elements": [
        {
          "id": "e1", "name": "Blue Heron", "kind": "model", "asset": "assets/heron.usdz",
          "transform": { "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1] },
          "anchors": [
            { "id": "a1", "tier": "worldmap", "priority": 2, "mapFile": "maps/court.arworldmap", "anchorTransform": [], "lat": 53.3436, "long": -6.2806 },
            { "id": "a2", "tier": "image", "priority": 1, "imageFile": "markers/e1.png", "physicalWidthM": 0.21 }
          ],
          "behaviours": [
            { "trigger": "tap", "retrigger": "afterComplete", "actions": [[{ "type": "playAnimation", "clip": "fly" }], [{ "type": "setState", "value": "found" }]] }
          ],
          "state": "hidden"
        }
      ]
    }
    """

    func testDecodesPRDExample() throws {
        let r = try ManifestCodec.decode(Data(Self.prdManifest.utf8))
        let x = r.experience
        XCTAssertFalse(r.isFromNewerVersion)
        XCTAssertEqual(x.title, "Courtyard Hunt")
        XCTAssertEqual(x.siteHint?.radiusM, 120)
        let e = try XCTUnwrap(x.elements.first)
        XCTAssertEqual(e.kind, .model)
        XCTAssertTrue(e.startsHidden)
        XCTAssertEqual(e.anchorsInResolutionOrder.map(\.id), ["a2", "a1"])
        XCTAssertEqual(e.precision, .markerPrecise)
        XCTAssertEqual(e.behaviours.first?.trigger, .tap)
        XCTAssertEqual(e.behaviours.first?.actions.count, 2)
        XCTAssertEqual(e.behaviours.first?.actions[0][0].clip, "fly")
        XCTAssertEqual(e.anchors[0].anchorTransform?.isValid, false)
        XCTAssertEqual(e.coordinate, Coordinate(lat: 53.3436, long: -6.2806))
    }

    func testUnknownKeysAndValuesSurviveRoundTrip() throws {
        let json = """
        {"schemaVersion":1,"id":"x","title":"T","author":"A","created":"2026-10-15T10:00:00Z",
         "futureTopLevel":{"a":[1,2,{"b":null}]},
         "elements":[{"id":"e","name":"n","kind":"hologram","asset":"assets/h.bin","flavour":"mint",
           "anchors":[{"id":"a","tier":"lidarVPS","priority":0,"vpsId":"abc"}],
           "behaviours":[{"id":"b1","trigger":"onShake","retrigger":"afterComplete","shakeG":2.5,
             "actions":[[{"type":"explode","power":9},{"type":"show","duration":0.5,"easing":"spring"}]]}]}]}
        """
        let x = try ManifestCodec.decode(Data(json.utf8)).experience
        XCTAssertEqual(x.extra["futureTopLevel"], .object(["a": .array([.number(1), .number(2), .object(["b": .null])])]))
        let e = x.elements[0]
        XCTAssertEqual(e.kind.rawValue, "hologram")
        XCTAssertFalse(e.kind.isKnown)
        XCTAssertEqual(e.extra["flavour"], .string("mint"))
        XCTAssertEqual(e.anchors[0].tier.rawValue, "lidarVPS")
        XCTAssertEqual(e.anchors[0].extra["vpsId"], .string("abc"))
        XCTAssertEqual(e.behaviours[0].extra["shakeG"], .number(2.5))
        XCTAssertEqual(e.behaviours[0].actions[0][1].extra["easing"], .string("spring"))

        let again = try ManifestCodec.decode(try ManifestCodec.encode(x)).experience
        XCTAssertEqual(again, x)
        // Re-encoding is byte-stable.
        XCTAssertEqual(try ManifestCodec.encode(again), try ManifestCodec.encode(x))
    }

    func testFullModelRoundTrip() throws {
        var x = Experience(id: "rt", title: "Round trip", author: "Me", created: Date(timeIntervalSince1970: 1_760_000_000))
        x.label = WallLabel(title: "RT", artist: "Me", year: "2026", medium: "AR", statement: "Para one.\n\nPara two.", altText: "A test")
        x.completionMessage = "Well done"
        var e = Element(id: "e1", name: "Chair", kind: .model, asset: "assets/chair.usdz",
                        transform: Transform(position: Vec3(1, 0, -2), rotation: Quat(0, 0.7071, 0, 0.7071), scale: Vec3(2, 2, 2)))
        e.anchors = [
            .worldmap(id: "w", mapFile: "maps/m.arworldmap", transform: .identity, capturedAt: Date(timeIntervalSince1970: 0),
                      mappingStatus: "mapped", coordinate: Coordinate(lat: 53, long: -6)),
            .image(id: "i", imageFile: "markers/e1.png", physicalWidthM: 0.2),
            .gps(id: "g", coordinate: Coordinate(lat: 53, long: -6), radiusM: 10, allowPlaneFallback: true),
        ]
        var b = Behaviour(id: "b", trigger: .timeWindow, retrigger: .never, actions: [[.show(), .playAudio("assets/s.wav")], [.delay(2)], [.setState("found")]])
        b.window = TimeWindow(from: "21:00", to: "05:00")
        e.behaviours = [b]
        e.playback = Playback(clip: "idle", loop: true, speed: 1.5, muted: true)
        e.faceViewer = true
        e.credit = Credit(creator: "Ann", source: "Own work", licence: "CC-BY-4.0")
        e.variants = [Variant(id: "oak", name: "Oak", asset: "assets/oak.usdz", note: "Warm")]
        e.designSize = DesignSize(widthM: 0.45, heightM: 0.8, depthM: 0.5)
        x.elements = [e]
        x.annotations = [CritNote(id: "n", author: "Lecturer", kind: .question, text: "Why here?", elementId: "e1", offset: Vec3(0, 1, 0))]
        x.refreshSiteHint()

        let decoded = try ManifestCodec.decode(try ManifestCodec.encode(x)).experience
        XCTAssertEqual(decoded, x)
        XCTAssertNotNil(decoded.siteHint)
        XCTAssertEqual(decoded.elements[0].precision, .markerPrecise)
    }

    func testMissingBehaviourIdIsGenerated() throws {
        let json = #"{"trigger":"tap","actions":[]}"#
        let b = try JSONDecoder().decode(Behaviour.self, from: Data(json.utf8))
        XCTAssertFalse(b.id.isEmpty)
        XCTAssertEqual(b.retrigger, .afterComplete)
    }

    func testEulerRoundTrip() {
        let cases = [
            EulerAngles(pitch: 0, yaw: 0, roll: 0),
            EulerAngles(pitch: 0, yaw: 90, roll: 0),
            EulerAngles(pitch: 30, yaw: -45, roll: 10),
            EulerAngles(pitch: -60, yaw: 170, roll: -35),
            EulerAngles(pitch: 10, yaw: 20, roll: 30),
        ]
        for e in cases {
            let back = Quat(eulerDegrees: e).eulerDegrees
            XCTAssertEqual(back.pitch, e.pitch, accuracy: 1e-6, "\(e)")
            XCTAssertEqual(back.yaw, e.yaw, accuracy: 1e-6, "\(e)")
            XCTAssertEqual(back.roll, e.roll, accuracy: 1e-6, "\(e)")
        }
        // 90° yaw is a rotation about +Y.
        let q = Quat(eulerDegrees: EulerAngles(pitch: 0, yaw: 90, roll: 0))
        XCTAssertEqual(q.y, 0.5.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(q.w, 0.5.squareRoot(), accuracy: 1e-9)
    }

    func testTimeWindow() {
        let night = TimeWindow(from: "21:00", to: "05:00")
        XCTAssertTrue(night.contains(minuteOfDay: 22 * 60))
        XCTAssertTrue(night.contains(minuteOfDay: 4 * 60 + 59))
        XCTAssertFalse(night.contains(minuteOfDay: 5 * 60))
        XCTAssertFalse(night.contains(minuteOfDay: 12 * 60))
        let day = TimeWindow(from: "09:30", to: "17:00")
        XCTAssertTrue(day.contains(minuteOfDay: 9 * 60 + 30))
        XCTAssertFalse(day.contains(minuteOfDay: 17 * 60))
        XCTAssertFalse(TimeWindow(from: "25:00", to: "1").isValid)
    }

    func testPrecisionOrdering() {
        XCTAssertEqual([Precision.approximate, .sitePrecise, .markerPrecise].min(), .markerPrecise)
        XCTAssertEqual(AnchorTier.geo.precision, .streetPrecise)
        XCTAssertEqual(AnchorTier(rawValue: "future").precision, .approximate)
    }
}
