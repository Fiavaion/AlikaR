#if canImport(RealityKit) && os(iOS)
import AVFoundation
import CuardachCore
import RealityKit
import UIKit

/// Marks the root entity of a placed element so hit tests and the runtime
/// can map RealityKit entities back to manifest elements.
public struct ElementTag: Component {
    public var elementId: String
    public init(elementId: String) { self.elementId = elementId }
}

/// Builds RealityKit content for manifest elements. Each element becomes a
/// `ModelEntity` container (so it can carry collision and gestures) holding
/// the loaded asset as a child; swapping variants replaces only the child.
@MainActor
public enum EntityFactory {
    public static func registerComponents() {
        ElementTag.registerComponent()
    }

    public struct Built {
        public var container: ModelEntity
        public var content: Entity
        /// For video elements: the player to drive play/pause.
        public var videoPlayer: AVPlayer?
        /// For audio elements and playAudio actions: the loaded sound.
        public var audio: AudioFileResource?
        public var clips: [String]
        /// Notification tokens to remove when this content is replaced.
        public var observers: [NSObjectProtocol] = []

        public func tearDown() {
            videoPlayer?.pause()
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }

    public static func build(_ element: Element, bundle: ExperienceBundle, assetOverride: String? = nil) async throws -> Built {
        let container = ModelEntity()
        container.name = element.name
        container.components.set(ElementTag(elementId: element.id))
        container.components.set(OpacityComponent(opacity: 1))

        var built: Built
        let assetPath = assetOverride ?? element.asset
        switch element.kind {
        case .model:
            let url = try bundle.url(for: try require(assetPath))
            let entity = try await loadModel(url)
            let clips = entity.availableAnimations.compactMap(\.name)
            built = Built(container: container, content: entity, videoPlayer: nil, audio: nil, clips: clips)
        case .image:
            let url = try bundle.url(for: try require(assetPath))
            built = Built(container: container, content: try await imagePlane(url), videoPlayer: nil, audio: nil, clips: [])
        case .video:
            let url = try bundle.url(for: try require(assetPath))
            let (plane, player, observer) = try await videoPlane(url, playback: element.playback)
            built = Built(container: container, content: plane, videoPlayer: player, audio: nil, clips: [],
                          observers: observer.map { [$0] } ?? [])
        case .audio:
            let url = try bundle.url(for: try require(assetPath))
            let resource = try AudioFileResource.load(contentsOf: url, inputMode: .spatial,
                                                      loadingStrategy: .preload, shouldLoop: element.playback?.loop ?? false)
            built = Built(container: container, content: soundMarker(), videoPlayer: nil, audio: resource, clips: [])
        case .text:
            built = Built(container: container, content: textPanel(element.text ?? element.name), videoPlayer: nil, audio: nil, clips: [])
        default:
            // Splats and kinds from newer versions: show a labelled placeholder.
            built = Built(container: container, content: textPanel("\(element.name)\n(\(element.kind) not supported yet)"),
                          videoPlayer: nil, audio: nil, clips: [])
        }

        container.addChild(built.content)
        if element.faceViewer { container.components.set(BillboardComponent()) }
        fitCollision(container)
        return built
    }

    /// Replaces the asset inside an existing container (variants).
    public static func swapContent(of built: inout Built, with element: Element, variantAsset: String,
                                   bundle: ExperienceBundle) async throws {
        let replacement = try await build(element, bundle: bundle, assetOverride: variantAsset)
        built.tearDown()
        built.content.removeFromParent()
        let child = replacement.content
        child.removeFromParent()
        built.container.addChild(child)
        built.content = child
        built.clips = replacement.clips
        built.videoPlayer = replacement.videoPlayer
        built.audio = replacement.audio ?? built.audio
        built.observers = replacement.observers
        fitCollision(built.container)
    }

    /// Box collision around the visual bounds, so taps and gestures work for
    /// any content, including meshes without their own collision.
    public static func fitCollision(_ container: ModelEntity) {
        let b = container.visualBounds(relativeTo: container)
        let extents = SIMD3<Float>(max(b.extents.x, 0.05), max(b.extents.y, 0.05), max(b.extents.z, 0.05))
        let shape = ShapeResource.generateBox(size: extents).offsetBy(translation: b.center)
        container.collision = CollisionComponent(shapes: [shape])
    }

    static func require(_ path: String?) throws -> String {
        guard let path else { throw CocoaError(.fileNoSuchFile) }
        return path
    }

    static func loadModel(_ url: URL) async throws -> Entity {
        switch url.pathExtension.lowercased() {
        case "glb", "gltf":
            return try await GLTFLoading.load(url)
        default:
            return try await Entity(contentsOf: url)
        }
    }

    /// An unlit, double-sided plane at the image's aspect ratio, 1 m on its long side.
    static func imagePlane(_ url: URL) async throws -> Entity {
        let texture = try await TextureResource(contentsOf: url)
        let aspect = Float(texture.width) / Float(max(texture.height, 1))
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        material.faceCulling = .none
        let w: Float = aspect >= 1 ? 1 : aspect
        let h: Float = aspect >= 1 ? 1 / aspect : 1
        let plane = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [material])
        plane.position.y = h / 2
        return plane
    }

    static func videoPlane(_ url: URL, playback: Playback?) async throws -> (Entity, AVPlayer, NSObjectProtocol?) {
        let asset = AVURLAsset(url: url)
        var size = CGSize(width: 16, height: 9)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = playback?.muted ?? false
        player.actionAtItemEnd = (playback?.loop ?? true) ? .none : .pause
        var observer: NSObjectProtocol?
        if playback?.loop ?? true {
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
        var material = VideoMaterial(avPlayer: player)
        material.faceCulling = .none
        let aspect = Float(size.width / max(size.height, 1))
        let w: Float = aspect >= 1 ? 1 : aspect
        let h: Float = aspect >= 1 ? 1 / aspect : 1
        let plane = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [material])
        plane.position.y = h / 2
        return (plane, player, observer)
    }

    /// Sound elements are invisible to players; authors see a small marker.
    static func soundMarker() -> Entity {
        let material = UnlitMaterial(color: UIColor.systemTeal.withAlphaComponent(0.6))
        let marker = ModelEntity(mesh: .generateSphere(radius: 0.06), materials: [material])
        marker.name = "author-only"
        return marker
    }

    static func textPanel(_ text: String) -> Entity {
        let mesh = MeshResource.generateText(
            text, extrusionDepth: 0.002, font: .systemFont(ofSize: 0.08, weight: .semibold),
            containerFrame: CGRect(x: -0.6, y: -0.6, width: 1.2, height: 1.2),
            alignment: .center, lineBreakMode: .byWordWrapping)
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let b = entity.visualBounds(relativeTo: nil)
        entity.position = SIMD3<Float>(-b.center.x, -b.min.y, 0)
        return entity
    }
}
#endif
