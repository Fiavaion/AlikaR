import AVFoundation
import RealityKit
import XCTest
@testable import CuardachAR
@testable import CuardachCore

/// Opens the committed sample bundles and builds every element through the
/// app's own EntityFactory / SceneRuntime.
@MainActor
final class DemoBundleTests: XCTestCase {
    override func setUp() async throws {
        Support.installLoader()
        EntityFactory.registerComponents()
    }

    private func open(_ name: String) throws -> ExperienceBundle {
        let url = Support.sample(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name).arhunt missing at \(url.path)") }
        return try ExperienceBundle.open(folder: url)
    }

    private func assertBuilds(_ element: Element, in bundle: ExperienceBundle, file: StaticString = #filePath, line: UInt = #line) async throws -> EntityFactory.Built {
        let built = try await EntityFactory.build(element, bundle: bundle)
        XCTAssertEqual(built.container.components[ElementTag.self]?.elementId, element.id, file: file, line: line)
        XCTAssertNotNil(built.container.components[CollisionComponent.self], "\(element.id): collision", file: file, line: line)
        switch element.kind {
        case .model:
            XCTAssertNotNil(Support.firstModel(built.content), "\(element.id): model has no ModelComponent", file: file, line: line)
            XCTAssertGreaterThan(ImportPipeline.triangleCount(built.content), 0, "\(element.id): no triangles", file: file, line: line)
        case .image:
            let m = try XCTUnwrap(built.content as? ModelEntity, file: file, line: line)
            XCTAssertTrue(m.model?.materials.first is UnlitMaterial, file: file, line: line)
        case .video:
            let m = try XCTUnwrap(built.content as? ModelEntity, file: file, line: line)
            XCTAssertTrue(m.model?.materials.first is VideoMaterial, "\(element.id): expected VideoMaterial", file: file, line: line)
            XCTAssertNotNil(built.videoPlayer, file: file, line: line)
        case .audio:
            XCTAssertNotNil(built.audio, "\(element.id): audio resource", file: file, line: line)
        case .text:
            XCTAssertNotNil(Support.firstModel(built.content), "\(element.id): text mesh", file: file, line: line)
        default: break
        }
        built.tearDown()
        return built
    }

    func testStudioDemoEveryElementBuilds() async throws {
        let bundle = try open("studio-demo")
        XCTAssertEqual(bundle.experience.elements.count, 10)
        for e in bundle.experience.elements { _ = try await assertBuilds(e, in: bundle) }
    }

    func testCourtyardHuntEveryElementBuilds() async throws {
        let bundle = try open("courtyard-hunt")
        for e in bundle.experience.elements { _ = try await assertBuilds(e, in: bundle) }
    }

    func testEveryReferencedFileExistsAndModelVariantsLoad() async throws {
        for name in ["studio-demo", "courtyard-hunt"] {
            let bundle = try open(name)
            for e in bundle.experience.elements {
                for f in e.referencedFiles where !f.hasPrefix("markers/") {
                    XCTAssertTrue(bundle.fileExists(f), "\(name): \(f) missing")
                }
                for v in e.variants {
                    let built = try await EntityFactory.build(e, bundle: bundle, assetOverride: v.asset)
                    XCTAssertNotNil(Support.firstModel(built.content), "\(name)/\(e.id) variant \(v.asset)")
                }
            }
        }
    }

    func testBottleIsTrueScaleAbout26cm() async throws {
        let bundle = try open("studio-demo")
        let bottle = try XCTUnwrap(bundle.experience.element(id: "bottle"))
        for asset in [bottle.asset!] + bottle.variants.map(\.asset) {
            let built = try await EntityFactory.build(bottle, bundle: bundle, assetOverride: asset)
            let h = built.content.visualBounds(relativeTo: nil).extents.y
            XCTAssertEqual(h, 0.26, accuracy: 0.02, "\(asset) height")
        }
    }

    func testRingAlphaVideoHasAlphaTrackAndVideoMaterial() async throws {
        let bundle = try open("studio-demo")
        let ring = try XCTUnwrap(bundle.experience.element(id: "ring"))
        let url = try bundle.url(for: ring.asset!)
        let alpha = try await Support.hasAlpha(videoAt: url)
        XCTAssertTrue(alpha, "ring-alpha.mov lost its alpha channel flag")
        let built = try await assertBuilds(ring, in: bundle)
        XCTAssertTrue((built.content as? ModelEntity)?.model?.materials.first is VideoMaterial)
    }

    func testAudioLoadsViaFactoryAndSceneRuntime() async throws {
        let bundle = try open("studio-demo")
        // EntityFactory async path (audio element).
        let ping = try XCTUnwrap(bundle.experience.element(id: "ping"))
        let pingBuilt = try await assertBuilds(ping, in: bundle)
        XCTAssertNotNil(pingBuilt.audio)

        // SceneRuntime.audioResource, reached through a playAudio invocation
        // carrying an explicit asset (the poster's chime.m4a) and one using the element's own sound.
        let arView = ARView(frame: .init(x: 0, y: 0, width: 100, height: 100), cameraMode: .nonAR, automaticallyConfigureSession: false)
        let runtime = SceneRuntime(bundle: bundle, scene: arView.scene)
        let anchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(anchor)

        let poster = try XCTUnwrap(bundle.experience.element(id: "poster"))
        let posterBuilt = try await EntityFactory.build(poster, bundle: bundle)
        anchor.addChild(posterBuilt.container)
        runtime.register(posterBuilt, for: "poster")
        var chime = Action(.playAudio); chime.asset = "assets/chime.m4a"
        runtime.apply([.perform(Invocation(id: 1, elementId: "poster", action: chime, awaitsCompletion: false))])
        XCTAssertTrue(posterBuilt.container.components.has(SpatialAudioComponent.self),
                      "chime.m4a did not load through SceneRuntime.audioResource")

        anchor.addChild(pingBuilt.container)
        runtime.register(pingBuilt, for: "ping")
        runtime.apply([.perform(Invocation(id: 2, elementId: "ping", action: Action(.playAudio), awaitsCompletion: false))])
        XCTAssertTrue(pingBuilt.container.components.has(SpatialAudioComponent.self))
        runtime.stopAll()

        // Courtyard hunt's WAV through the same runtime path.
        let court = try open("courtyard-hunt")
        let bell = try XCTUnwrap(court.experience.element(id: "bell"))
        let bellBuilt = try await EntityFactory.build(bell, bundle: court)
        XCTAssertNotNil(bellBuilt.audio)
        var wav = Action(.playAudio); wav.asset = "assets/chime.wav"
        let rt2 = SceneRuntime(bundle: court, scene: arView.scene)
        anchor.addChild(bellBuilt.container)
        rt2.register(bellBuilt, for: "bell")
        rt2.apply([.perform(Invocation(id: 3, elementId: "bell", action: wav, awaitsCompletion: false))])
        XCTAssertTrue(bellBuilt.container.components.has(SpatialAudioComponent.self))
        rt2.stopAll()
    }
}
