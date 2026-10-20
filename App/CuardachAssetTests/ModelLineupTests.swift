import RealityKit
import XCTest
@testable import CuardachAR
@testable import CuardachCore

/// Builds the personal AR test models (Desktop/Cuardach Demo/Test models, never
/// committed) and the packed model-lineup experience through the app's own
/// ImportPipeline / EntityFactory. Skips when the files are absent.
@MainActor
final class ModelLineupTests: XCTestCase {
    override func setUp() async throws {
        Support.installLoader()
        EntityFactory.registerComponents()
    }

    private static var demoDir: URL { Support.mediaDir.deletingLastPathComponent() }
    private static var modelsDir: URL { demoDir.appendingPathComponent("Test models", isDirectory: true) }

    /// Animation availability that is known not to come through for a file, with the reason.
    /// Drop an entry when GLTFKit2 gains animation support.
    /// GLTFKit2's RealityKit loader (GLTFRealityKit.swift) has "TODO: Morph targets, skinned
    /// animation, etc." and creates no AnimationResource, so animated GLBs load but never play.
    private static let glbNoAnimation = "GLTFKit2 RealityKit loader does not convert glTF animations (no AnimationResource), so availableAnimations is empty"
    private static let knownNoAnimation: [String: String] = [
        "anim-fox-walk.glb": glbNoAnimation,
        "anim-cesium-man.glb": glbNoAnimation,
        "anim-brainstem-robot.glb": glbNoAnimation,
    ]

    private func modelFiles() throws -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDir, includingPropertiesForKeys: nil)) ?? []
        let files = all.filter { ["usdz", "glb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.isEmpty { throw XCTSkip("No models in \(Self.modelsDir.path)") }
        return files
    }

    func testEveryTestModelLoadsAndAnimatedOnesHaveClips() async throws {
        let files = try modelFiles()
        for src in files {
            let name = src.lastPathComponent
            let bundle = try Support.newBundle()
            let r = try await ImportPipeline.importAsset(src, into: bundle)
            XCTAssertFalse(r.warnings.contains { $0.severity == .blocking }, "\(name): \(r.warnings)")
            XCTAssertFalse(r.path.isEmpty, "\(name): import produced no asset")
            let el = Element(id: "m", name: name, kind: r.kind, asset: r.path)
            let built = try await EntityFactory.build(el, bundle: bundle)
            XCTAssertNotNil(Support.firstModel(built.content), "\(name): no ModelComponent")
            XCTAssertGreaterThan(ImportPipeline.triangleCount(built.content), 0, "\(name): no triangles")
            let vb = built.content.visualBounds(relativeTo: nil)
            let ext = vb.extents
            let anims = built.content.availableAnimations
            let line = "MODEL \(name) | extents(m) \(ext.x) \(ext.y) \(ext.z) | min \(vb.min) max \(vb.max) | tris \(ImportPipeline.triangleCount(built.content)) | clips \(anims.compactMap(\.name)) (\(anims.count)) | import clips \(r.metrics.animationClips)"
            print(line)
            XCTContext.runActivity(named: line) { _ in }
            if name.hasPrefix("anim-") {
                if let why = Self.knownNoAnimation[name] {
                    XCTExpectFailure("\(name): \(why)") { XCTAssertGreaterThanOrEqual(anims.count, 1) }
                } else {
                    XCTAssertGreaterThanOrEqual(anims.count, 1, "\(name): no available animation")
                }
            }
            built.tearDown()
        }
    }

    func testModelLineupEveryElementBuilds() async throws {
        let archive = Self.demoDir.appendingPathComponent("model-lineup.arhunt")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("model-lineup.arhunt not found at \(archive.path)") }
        let bundle = try ExperienceBundle.unpack(archive, into: try Support.temporaryParent())
        XCTAssertFalse(bundle.experience.elements.isEmpty)
        for e in bundle.experience.elements {
            let built = try await EntityFactory.build(e, bundle: bundle)
            XCTAssertEqual(built.container.components[ElementTag.self]?.elementId, e.id)
            XCTAssertNotNil(Support.firstModel(built.content), "\(e.id): no ModelComponent")
            if e.behaviours.contains(where: { $0.actions.joined().contains { $0.type == .playAnimation } }) {
                let count = built.content.availableAnimations.count
                if let why = Self.knownNoAnimation[URL(fileURLWithPath: e.asset ?? "").lastPathComponent] {
                    XCTExpectFailure("\(e.id): \(why)") { XCTAssertGreaterThanOrEqual(count, 1) }
                } else {
                    XCTAssertGreaterThanOrEqual(count, 1, "\(e.id): playAnimation but no clips")
                }
            }
            built.tearDown()
        }
    }
}
