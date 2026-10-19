import AVFoundation
import ImageIO
import RealityKit
import XCTest
@testable import CuardachAR
@testable import CuardachCore

/// Runs the app's ImportPipeline over the local test media (never committed;
/// see Support.mediaDir) into a temporary bundle, and checks the outcome
/// against the README's predictions. After import, the stored file is built
/// through EntityFactory to prove it is renderable.
@MainActor
final class ImportTests: XCTestCase {
    override func setUp() async throws {
        Support.installLoader()
        EntityFactory.registerComponents()
    }

    private func importFile(_ name: String, into bundle: ExperienceBundle) async throws -> (ImportPipeline.Result, URL?) {
        let src = try Support.media(name)
        let r = try await ImportPipeline.importAsset(src, into: bundle)
        return (r, r.path.isEmpty ? nil : try bundle.url(for: r.path))
    }

    private func counts(_ r: ImportPipeline.Result) -> (blocking: Int, warning: Int, info: Int) {
        (r.warnings.filter { $0.severity == .blocking }.count,
         r.warnings.filter { $0.severity == .warning }.count,
         r.warnings.filter { $0.severity == .info }.count)
    }

    /// Build the imported file as a new element of the right kind.
    private func build(_ r: ImportPipeline.Result, in bundle: ExperienceBundle) async throws -> EntityFactory.Built {
        let el = Element(id: "imported", name: "Imported", kind: r.kind, asset: r.path)
        return try await EntityFactory.build(el, bundle: bundle)
    }

    func testBottleUSDZNoWarningsAndTrueScale() async throws {
        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("mesh-1-small-usdz-bottle.usdz", into: bundle)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        XCTAssertNotNil(url)
        XCTAssertEqual(r.metrics.triangles, 4510)
        let built = try await build(r, in: bundle)
        XCTAssertEqual(built.content.visualBounds(relativeTo: nil).extents.y, 0.26, accuracy: 0.02)
    }

    func testFoxGLBInfoLinesAndLoads() async throws {
        let bundle = try Support.newBundle()
        let (r, _) = try await importFile("mesh-2-animated-glb-fox.glb", into: bundle)
        let c = counts(r)
        XCTAssertEqual(c.blocking, 0)
        XCTAssertEqual(c.warning, 0, "\(r.warnings)")
        XCTAssertEqual(c.info, 2, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.message.hasPrefix("Animated GLB files") })
        XCTAssertTrue(r.warnings.contains { $0.message.contains("exported in centimetres") })
        XCTAssertEqual(r.metrics.triangles, 576)
        XCTAssertEqual(Set(r.metrics.animationClips), ["Survey", "Walk", "Run"])
        XCTAssertFalse(r.path.isEmpty)
        let built = try await build(r, in: bundle)
        XCTAssertNotNil(Support.firstModel(built.content), "GLB did not load through GLTFKit2")
    }

    func testSkullGLBTriangleAndExtensionWarnings() async throws {
        let bundle = try Support.newBundle()
        let (r, _) = try await importFile("mesh-3-heavy-glb-skull-189k-triangles.glb", into: bundle)
        XCTAssertEqual(counts(r).blocking, 0)
        XCTAssertEqual(r.metrics.triangles, 188_871)
        XCTAssertTrue(r.warnings.contains { $0.severity == .warning && $0.message.contains("triangles. Above") })
        let expected: Set<String> = ["KHR_xmp_json_ld", "KHR_materials_diffuse_transmission", "KHR_materials_volume",
                                     "KHR_materials_dispersion", "KHR_materials_volume_scatter", "KHR_materials_ior"]
        XCTAssertEqual(Set(r.metrics.unsupportedExtensions), expected)
        XCTAssertEqual(counts(r).warning, 1 + expected.count, "\(r.warnings)")
        XCTAssertFalse(r.path.isEmpty, "warnings must not block")
        let built = try await build(r, in: bundle)
        XCTAssertNotNil(Support.firstModel(built.content))
    }

    func testObjIsBlockedWithConvertMessage() async throws {
        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("mesh-4-unsupported-cube.obj", into: bundle)
        XCTAssertNil(url)
        XCTAssertEqual(r.path, "")
        XCTAssertEqual(counts(r).blocking, 1)
        let msg = try XCTUnwrap(r.warnings.first { $0.severity == .blocking }).message
        XCTAssertTrue(msg.contains("Convert to USDZ on a Mac"), msg)
        XCTAssertTrue(try bundle.files().filter { $0.path.hasPrefix("assets/") }.isEmpty, "nothing may be added")
    }

    func testTransparentPNGKeepsAlpha() async throws {
        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("image-1-transparent-png.png", into: bundle)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        let props = try XCTUnwrap(Support.imageProps(try XCTUnwrap(url)))
        XCTAssertEqual(props[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 800)
        // Corner pixel is transparent in the stored copy.
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(url) as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 255, count: 4)
        let corner = try XCTUnwrap(img.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(px[3], 0, "corner should be transparent")
        _ = try await build(r, in: bundle)
    }

    func testLargeJPEGDownscaledAndGPSRemoved() async throws {
        let src = try Support.media("image-2-large-4032px-jpeg-with-gps.jpg")
        let original = try XCTUnwrap(Support.imageProps(src))
        XCTAssertNotNil(original[kCGImagePropertyGPSDictionary], "fixture should carry GPS to make this test meaningful")

        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("image-2-large-4032px-jpeg-with-gps.jpg", into: bundle)
        let c = counts(r)
        XCTAssertEqual(c.info, 1, "\(r.warnings)")
        XCTAssertEqual(c.warning + c.blocking, 0)
        XCTAssertTrue(r.warnings[0].message.contains("4032 px will be downscaled to 2048 px"), "\(r.warnings)")
        let props = try XCTUnwrap(Support.imageProps(try XCTUnwrap(url)))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 1536)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS survived in stored copy")
        // Only structural EXIF (colour space, pixel size) may remain: no camera, date or location tags.
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let structural: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        XCTAssertTrue(Set(exif.keys.map { $0 as String }).isSubset(of: structural), "identifying EXIF kept: \(exif)")
        XCTAssertNil(props[kCGImagePropertyTIFFDictionary], "TIFF (camera make/model) kept")
        _ = try await build(r, in: bundle)
    }

    func testH264VideoNoWarningsKeepsSoundAndLoads() async throws {
        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("video-1-h264-720p-10s-with-sound.mp4", into: bundle)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        let asset = AVURLAsset(url: try XCTUnwrap(url))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "sound track lost in re-wrap")
        let video = try await asset.loadTracks(withMediaType: .video)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
        let secs = try await asset.load(.duration).seconds
        XCTAssertEqual(secs, 10, accuracy: 0.5)
        let built = try await build(r, in: bundle)
        XCTAssertTrue((built.content as? ModelEntity)?.model?.materials.first is VideoMaterial)
        built.tearDown()
    }

    func testHEVCAlphaVideoKeepsAlphaAfterImport() async throws {
        let src = try Support.media("video-2-hevc-alpha-transparent.mov")
        let before = try await Support.hasAlpha(videoAt: src)
        XCTAssertTrue(before, "fixture has no alpha flag; test meaningless")
        let bundle = try Support.newBundle()
        let (r, url) = try await importFile("video-2-hevc-alpha-transparent.mov", into: bundle)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
        let after = try await Support.hasAlpha(videoAt: try XCTUnwrap(url))
        XCTAssertTrue(after, "alpha lost in the passthrough re-wrap")
        let built = try await build(r, in: bundle)
        XCTAssertTrue((built.content as? ModelEntity)?.model?.materials.first is VideoMaterial)
        built.tearDown()
    }

    func testFourKVideoOver25MBWarns() async throws {
        let bundle = try Support.newBundle()
        let (r, _) = try await importFile("video-3-4k-h264-10s-over-25MB.mp4", into: bundle)
        let c = counts(r)
        XCTAssertEqual(c.warning, 1, "\(r.warnings)")
        XCTAssertEqual(c.blocking + c.info, 0, "\(r.warnings)")
        XCTAssertTrue(r.warnings[0].message.contains("Over 25 MB"))
        XCTAssertFalse(r.path.isEmpty)
        let built = try await build(r, in: bundle)
        XCTAssertNotNil(built.videoPlayer)
        built.tearDown()
    }

    func testAudioAACAndWAVNoWarningsAndLoad() async throws {
        for name in ["audio-1-aac-4s.m4a", "audio-2-wav-4s.wav"] {
            let bundle = try Support.newBundle()
            let (r, _) = try await importFile(name, into: bundle)
            XCTAssertTrue(r.warnings.isEmpty, "\(name): \(r.warnings)")
            XCTAssertEqual(r.kind, .audio)
            let built = try await build(r, in: bundle)
            XCTAssertNotNil(built.audio, name)
        }
    }
}
