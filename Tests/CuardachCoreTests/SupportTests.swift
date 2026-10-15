import XCTest
@testable import CuardachCore

final class GeoTests: XCTestCase {
    func testDistanceAndBearing() {
        let ncad = Coordinate(lat: 53.3436, long: -6.2806)
        let gpo = Coordinate(lat: 53.3498, long: -6.2603)  // GPO, O'Connell Street
        XCTAssertEqual(Geo.distance(ncad, gpo), 1500, accuracy: 60)
        let b = Geo.bearing(from: ncad, to: gpo)
        XCTAssertTrue((55...70).contains(b), "\(b)")  // east-north-east
        XCTAssertEqual(Geo.bearing(from: ncad, to: Coordinate(lat: 54, long: -6.2806)), 0, accuracy: 1e-9)
        XCTAssertEqual(Geo.relativeBearing(from: ncad, to: Coordinate(lat: 54, long: -6.2806), deviceHeading: 90), 270, accuracy: 1e-9)
    }

    func testOffsetRoundTrip() {
        let c = Coordinate(lat: 53.3436, long: -6.2806)
        let moved = Geo.offset(c, eastM: 30, northM: 40)
        XCTAssertEqual(Geo.distance(c, moved), 50, accuracy: 0.05)
    }

    func testEnclosingCircle() {
        let c = Coordinate(lat: 53.3436, long: -6.2806)
        let pts = [Geo.offset(c, eastM: -100, northM: 0), Geo.offset(c, eastM: 100, northM: 0)]
        let circle = try! XCTUnwrap(Geo.enclosingCircle(pts))
        XCTAssertEqual(Geo.distance(circle.center, c), 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(circle.radiusM, 100)
        XCTAssertEqual(Geo.enclosingCircle([c])?.radiusM, 30, "minimum radius")
        XCTAssertNil(Geo.enclosingCircle([Coordinate(lat: 200, long: 0)]))
    }

    func testApproachGuidance() {
        let target = Coordinate(lat: 53.3436, long: -6.2806)
        XCTAssertEqual(ApproachGuidance.make(player: nil, heading: nil, target: nil), .noLocation)
        if case .lookAround(let d) = ApproachGuidance.make(player: Geo.offset(target, eastM: 10, northM: 0), heading: 0, target: target) {
            XCTAssertEqual(d, 10, accuracy: 0.05)
        } else { XCTFail() }
        if case .navigate(let d, let rel) = ApproachGuidance.make(player: Geo.offset(target, eastM: 0, northM: -100), heading: 0, target: target) {
            XCTAssertEqual(d, 100, accuracy: 0.1)
            XCTAssertEqual(rel, 0, accuracy: 0.01)
        } else { XCTFail() }
        XCTAssertEqual(ApproachGuidance.format(distanceM: 8.4), "8 m")
        XCTAssertEqual(ApproachGuidance.format(distanceM: 1340), "1.3 km")
    }

    func testWalkingDetector() {
        var w = WalkingDetector()
        XCTAssertFalse(w.update(speedMps: 1.2, at: 0))
        XCTAssertFalse(w.update(speedMps: 1.2, at: 2))
        XCTAssertTrue(w.update(speedMps: 1.2, at: 2.5))
        XCTAssertTrue(w.update(speedMps: 0.1, at: 3), "brief pause keeps the banner")
        XCTAssertFalse(w.update(speedMps: 0.1, at: 5))
    }
}

final class AssetTests: XCTestCase {
    /// Builds a GLB: a 12-triangle cube with an animation, one external
    /// texture and a Draco extension.
    func makeGLB() -> Data {
        let json = """
        {"asset":{"version":"2.0"},
         "extensionsUsed":["KHR_materials_unlit","KHR_draco_mesh_compression"],
         "accessors":[{"count":24,"min":[-0.5,0,-0.5],"max":[0.5,1,0.5]},{"count":36}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
         "images":[{"uri":"tex%20ture.png"},{"uri":"data:image/png;base64,AAAA"}],
         "animations":[{"name":"fly"},{"name":""}]}
        """
        var j = Data(json.utf8)
        while j.count % 4 != 0 { j.append(0x20) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(UInt32(12 + 8 + j.count))
        u32(UInt32(j.count)); u32(0x4E4F_534A)
        d.append(j)
        return d
    }

    func testGLBInspection() throws {
        let m = try GLBInspector.inspect(glb: makeGLB(), resourceExists: { $0 == "nothing" })
        XCTAssertEqual(m.triangles, 12)
        XCTAssertEqual(m.animationClips, ["fly", "Animation 2"])
        XCTAssertEqual(m.missingTextures, ["tex ture.png"])
        XCTAssertEqual(m.unsupportedExtensions, ["KHR_draco_mesh_compression"])
        XCTAssertEqual(m.boundingSize, Vec3(1, 1, 1))
        let w = m.warnings(format: .glb)
        XCTAssertTrue(w.contains { $0.message.contains("Missing texture: tex ture.png") })
        XCTAssertTrue(w.contains { $0.message.contains("KHR_draco_mesh_compression") })
    }

    func testGLBRejectsOtherFiles() {
        XCTAssertThrowsError(try GLBInspector.inspect(glb: Data("not a glb at all.....".utf8))) {
            XCTAssertEqual($0 as? GLBError, .notGLB)
        }
    }

    func testWarnings() {
        var m = AssetMetrics(bytes: 30_000_000)
        m.triangles = 250_000
        m.maxTextureDimension = 4096
        m.boundingSize = Vec3(180, 90, 40)
        let w = m.warnings(format: .usdz)
        XCTAssertEqual(w.first?.severity, .warning)
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(AssetMetrics(bytes: 1).warnings(format: .obj).first?.severity, .blocking)
        XCTAssertEqual(AssetPolicy.format(forExtension: "JPEG"), .jpg)
        XCTAssertEqual(AssetPolicy.format(forExtension: "mov")?.kind, .video)
        XCTAssertNil(AssetPolicy.format(forExtension: "fbx"))
    }
}

final class SharingTests: XCTestCase {
    func testDeepLinks() throws {
        let file = try XCTUnwrap(URL(string: "https://ncad.example/hunts/court yard.arhunt?v=2&x=1".replacingOccurrences(of: " ", with: "%20")))
        let link = try XCTUnwrap(DeepLink.openLink(for: file))
        XCTAssertEqual(link.scheme, "cuardach")
        XCTAssertEqual(DeepLink.parse(link), .download(file))
        XCTAssertEqual(DeepLink.parse(qrPayload: "  \(file.absoluteString)\n"), .download(file))
        for bad in ["http://insecure.example/x.arhunt", "file:///etc/passwd", "cuardach://open?url=http%3A%2F%2Fx", "cuardach://evil?url=https%3A%2F%2Fx",
                    "https://user:pw@host/x", "javascript:alert(1)"] {
            XCTAssertNil(DeepLink.parse(qrPayload: bad), bad)
        }
        XCTAssertNil(DeepLink.openLink(for: URL(string: "http://x/y")!))
    }

    func testUndoStack() {
        var u = UndoStack<Int>(limit: 3)
        var v = 0
        for n in 1...5 { u.record(v, label: "edit"); v = n }
        XCTAssertEqual(v, 5)
        v = u.undo(current: v)!; XCTAssertEqual(v, 4)
        v = u.undo(current: v)!; XCTAssertEqual(v, 3)
        v = u.undo(current: v)!; XCTAssertEqual(v, 2)
        XCTAssertNil(u.undo(current: v), "limited to 3")
        v = u.redo(current: v)!; XCTAssertEqual(v, 3)
        u.record(v, label: "new"); v = 99
        XCTAssertFalse(u.canRedo, "a new edit clears redo")
        // Coalescing a drag keeps the state from before the gesture.
        var d = UndoStack<Int>()
        d.record(10, label: "Move", coalesce: true)
        d.record(11, label: "Move", coalesce: true)
        d.record(12, label: "Move", coalesce: true)
        XCTAssertEqual(d.undo(current: 13), 10)
        XCTAssertFalse(d.canUndo)
    }

    func testPlayerProgressStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlayerProgressStore(directory: dir)
        var p = store.load("Hunt-1")
        XCTAssertTrue(p.found.isEmpty)
        p.apply([.found(elementId: "a"), .state(elementId: "a", value: "found"), .found(elementId: "a")])
        try store.save(p)
        XCTAssertEqual(store.load("Hunt-1").found, ["a"])
        XCTAssertTrue(store.load("other").found.isEmpty)
        var x = Experience(id: "Hunt-1", title: "", author: "")
        x.elements = [Element(id: "a", name: "a", kind: .model, asset: nil), Element(id: "b", name: "b", kind: .image, asset: nil),
                      Element(id: "s", name: "s", kind: .audio, asset: nil)]
        XCTAssertTrue(store.load("Hunt-1").foundCount(in: x) == (1, 2))
        try store.reset("Hunt-1")
        XCTAssertTrue(store.load("Hunt-1").found.isEmpty)
    }
}
