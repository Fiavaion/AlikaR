import XCTest
@testable import CuardachCore

final class BundleTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cuardach-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeBundle() throws -> ExperienceBundle {
        var b = try ExperienceBundle.create(Experience(id: "Courtyard-1", title: "Courtyard", author: "Tests"),
                                            in: tmp.appendingPathComponent("authoring"))
        let src = tmp.appendingPathComponent("Blue Héron (final).usdz")
        try Data((0..<300_000).map { UInt8($0 % 251) }).write(to: src)
        let path = try b.importFile(src)
        XCTAssertEqual(path, "assets/blue-heron-final.usdz")
        XCTAssertEqual(try b.importFile(src), "assets/blue-heron-final-2.usdz")
        var e = Element(id: "e1", name: "Heron", kind: .model, asset: path)
        e.anchors = [.image(id: "a1", imageFile: "markers/e1.png", physicalWidthM: 0.21)]
        try b.write(Data("png".utf8), to: "markers/e1.png")
        b.experience.elements = [e]
        try b.save()
        return b
    }

    func testPackUnpackRoundTrip() throws {
        let b = try makeBundle()
        let zip = tmp.appendingPathComponent("out.arhunt")
        try b.pack(to: zip)

        let reader = try ZipReader(url: zip)
        XCTAssertEqual(reader.entries.first?.path, "manifest.json", "manifest is written first")
        XCTAssertEqual(Set(reader.entries.map(\.path)),
                       ["manifest.json", "assets/blue-heron-final.usdz", "assets/blue-heron-final-2.usdz", "markers/e1.png"])

        let opened = try ExperienceBundle.unpack(zip, into: tmp.appendingPathComponent("library"))
        XCTAssertEqual(opened.experience, b.experience)
        XCTAssertEqual(opened.folder.lastPathComponent, "courtyard-1.arhunt")
        XCTAssertEqual(try Data(contentsOf: opened.url(for: "assets/blue-heron-final.usdz")),
                       try Data(contentsOf: b.url(for: "assets/blue-heron-final.usdz")))
        XCTAssertTrue(BundleValidator(bundle: opened).validate(opened.experience).filter { $0.severity == .error }.isEmpty)

        // Reopening the same experience replaces the earlier copy.
        let again = try ExperienceBundle.unpack(zip, into: tmp.appendingPathComponent("library"))
        XCTAssertEqual(again.folder, opened.folder)
    }

    func testOpensDeflatedWrappedZipFromOtherTools() throws {
        let zip = tmp.appendingPathComponent("finder.zip")
        try XCTUnwrap(Data(base64Encoded: Fixtures.wrappedDeflatedBundle)).write(to: zip)
        let reader = try ZipReader(url: zip)
        XCTAssertTrue(reader.entries.contains { $0.method == 8 })

        let b = try ExperienceBundle.unpack(zip, into: tmp)
        XCTAssertEqual(b.experience.title, "Deflated Hunt")
        XCTAssertEqual(b.experience.extra["someFutureFeature"], .object(["enabled": .bool(true)]))
        XCTAssertEqual(try b.files().map(\.path), ["assets/note.png", "manifest.json"], "junk is skipped and the wrapper folder stripped")
        XCTAssertEqual(try Data(contentsOf: b.url(for: "assets/note.png")).count, Fixtures.wrappedPayloadCount)
    }

    func testInflateSmall() throws {
        let r = try ZipReader(data: XCTUnwrap(Data(base64Encoded: Fixtures.smallDeflated)))
        let e = try XCTUnwrap(r.entry("a.txt"))
        XCTAssertEqual(String(decoding: try r.contents(of: e), as: UTF8.self), "hello hello hello")
    }

    func testInflateRejectsGarbage() {
        XCTAssertThrowsError(try Inflate.decompressPortable(Data([0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try Inflate.decompressPortable(Data()))
    }

    func testZipSlipIsRejected() throws {
        let zip = tmp.appendingPathComponent("slip.zip")
        try XCTUnwrap(Data(base64Encoded: Fixtures.zipSlip)).write(to: zip)
        XCTAssertThrowsError(try ExperienceBundle.unpack(zip, into: tmp.appendingPathComponent("lib"))) { err in
            XCTAssertEqual(err as? ZipError, .unsafePath("../evil.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("evil.txt").path))
    }

    func testSafePath() {
        for bad in ["/etc/passwd", "../x", "a/../../x", "C:\\x", "a/./b", "", "a\\..\\b"] {
            XCTAssertThrowsError(try SafePath.components(bad), bad)
        }
        XCTAssertEqual(try SafePath.components("assets//heron.usdz"), ["assets", "heron.usdz"])
    }

    func testUnpackLimits() throws {
        let b = try makeBundle()
        let zip = tmp.appendingPathComponent("out.arhunt")
        try b.pack(to: zip)
        XCTAssertThrowsError(try ExperienceBundle.unpack(zip, into: tmp, limits: .init(maxTotalBytes: 1000, maxFiles: 100)))
        XCTAssertThrowsError(try ExperienceBundle.unpack(zip, into: tmp, limits: .init(maxTotalBytes: .max, maxFiles: 2)))
    }

    func testCorruptEntryDetected() throws {
        let b = try makeBundle()
        let zip = tmp.appendingPathComponent("out.arhunt")
        try b.pack(to: zip)
        var d = try Data(contentsOf: zip)
        // Flip a byte inside the first asset's data.
        let reader = try ZipReader(data: d)
        let e = try XCTUnwrap(reader.entry("assets/blue-heron-final.usdz"))
        d[e.localHeaderOffset + 30 + e.path.utf8.count + 100] ^= 0xFF
        let broken = try ZipReader(data: d)
        XCTAssertThrowsError(try broken.contents(of: XCTUnwrap(broken.entry(e.path)))) {
            XCTAssertEqual($0 as? ZipError, .checksumMismatch(path: e.path))
        }
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipReader(data: Data("hello".utf8)))
        XCTAssertThrowsError(try ZipReader(data: Data(repeating: 0, count: 100)))
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testManifestErrors() {
        XCTAssertThrowsError(try ManifestCodec.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try ManifestCodec.decode(Data(#"{"id":"x"}"#.utf8))) {
            XCTAssertEqual($0 as? BundleError, .missingSchemaVersion)
        }
        XCTAssertThrowsError(try ManifestCodec.decode(Data(#"{"schemaVersion":1,"id":"x","elements":[{"name":"no id"}]}"#.utf8))) {
            guard case .invalidManifest(let why)? = $0 as? BundleError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("elements[0]"), why)
        }
    }

    func testNewerSchemaOpensReadOnly() throws {
        let folder = tmp.appendingPathComponent("future.arhunt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":7,"id":"f","title":"Future","author":"","elements":[],"hyperspace":true}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let b = try ExperienceBundle.open(folder: folder)
        XCTAssertTrue(b.isReadOnly)
        XCTAssertThrowsError(try b.save()) { XCTAssertEqual($0 as? BundleError, .readOnly) }
        XCTAssertEqual(b.experience.extra["hyperspace"], .bool(true))
    }

    func testSlug() {
        XCTAssertEqual(ExperienceBundle.slug("Blue Héron (final)"), "blue-heron-final")
        XCTAssertEqual(ExperienceBundle.slug("Cuairt na Cathrach — Éire"), "cuairt-na-cathrach-eire")
        XCTAssertEqual(ExperienceBundle.slug("///"), "file")
    }
}
