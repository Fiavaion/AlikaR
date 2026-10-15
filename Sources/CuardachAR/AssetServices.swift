#if canImport(RealityKit) && os(iOS)
import ARKit
import AVFoundation
import CuardachCore
import ImageIO
import RealityKit
import UIKit
import UniformTypeIdentifiers

/// GLB/glTF loading is injected by the app target, which links GLTFKit2
/// (the one third-party dependency the PRD allows). Keeping it out of this
/// package keeps CuardachAR dependency-free and testable without it.
@MainActor
public enum GLTFLoading {
    public static var loader: ((URL) async throws -> Entity)?

    public struct Unavailable: LocalizedError {
        public var errorDescription: String? {
            "This build can't open GLB files. Convert the model to USDZ on a Mac (Reality Converter or the AROR pipeline)."
        }
    }

    static func load(_ url: URL) async throws -> Entity {
        guard let loader else { throw Unavailable() }
        return try await loader(url)
    }
}

/// Saves and loads ARWorldMaps inside a bundle (PRD L1, L8).
public enum WorldMapStore {
    public static func data(for map: ARWorldMap) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
    }

    public static func load(_ relativePath: String, in bundle: ExperienceBundle) throws -> ARWorldMap {
        let data = try Data(contentsOf: bundle.url(for: relativePath))
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    public static func status(_ s: ARFrame.WorldMappingStatus) -> String {
        switch s {
        case .mapped: "mapped"
        case .extending: "extending"
        case .limited: "limited"
        default: "notAvailable"
        }
    }
}

/// Prepares imported files: strips location metadata (PRD C5), downscales
/// large images (A14), and measures assets for the warning list (A2).
public enum ImportPipeline {
    public struct Result {
        public var path: String
        public var kind: ElementKind
        public var metrics: AssetMetrics
        public var warnings: [ImportWarning]
    }

    public enum Failure: LocalizedError {
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "Files of type .\(ext) can't be imported."
            }
        }
    }

    /// Copies `source` into the bundle and returns what the author should see
    /// before accepting it. Blocking warnings mean the file was not kept.
    @MainActor
    public static func importAsset(_ source: URL, into bundle: ExperienceBundle) async throws -> Result {
        let ext = source.pathExtension.lowercased()
        guard let format = AssetPolicy.format(forExtension: ext) else { throw Failure.unsupported(ext) }

        var working = source
        var cleanup: URL?
        switch format.kind {
        case .image:
            working = try sanitisedImage(source)
            cleanup = working
        case .video:
            working = try await sanitisedVideo(source)
            cleanup = working
        default:
            break
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }

        let bytes = (try? working.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var metrics = AssetMetrics(bytes: bytes)
        switch format {
        case .glb:
            let dir = source.deletingLastPathComponent()
            metrics = (try? GLBInspector.inspect(glb: Data(contentsOf: source), resourceExists: {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            })) ?? metrics
        case .usdz, .reality:
            if let entity = try? await Entity(contentsOf: working) {
                metrics.triangles = triangleCount(entity)
                metrics.animationClips = entity.availableAnimations.compactMap(\.name)
                let e = entity.visualBounds(relativeTo: nil).extents
                metrics.boundingSize = Vec3(Double(e.x), Double(e.y), Double(e.z))
            }
        case .png, .jpg, .heic:
            metrics.maxTextureDimension = pixelSize(source).map { max($0.width, $0.height) }
        default:
            break
        }
        metrics.bytes = bytes
        let warnings = metrics.warnings(format: format)
        if warnings.contains(where: { $0.severity == .blocking }) {
            return Result(path: "", kind: format.kind, metrics: metrics, warnings: warnings)
        }
        let path = try bundle.importFile(working, preferredName: source.deletingPathExtension().lastPathComponent)
        return Result(path: path, kind: format.kind, metrics: metrics, warnings: warnings)
    }

    static func triangleCount(_ entity: Entity) -> Int {
        var total = 0
        func visit(_ e: Entity) {
            if let model = e.components[ModelComponent.self] {
                for m in model.mesh.contents.models {
                    for part in m.parts { total += (part.triangleIndices?.count ?? 0) / 3 }
                }
            }
            e.children.forEach(visit)
        }
        visit(entity)
        return total
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Re-encodes an image without GPS metadata, capped at 2048 px.
    static func sanitisedImage(_ url: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let size = pixelSize(url)
        if let size, max(size.width, size.height) > AssetPolicy.maxTextureDimension {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: AssetPolicy.maxTextureDimension,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            CGImageDestinationAddImage(dest, thumb, nil)  // no metadata at all
        } else {
            let strip: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any]
            CGImageDestinationAddImageFromSource(dest, src, 0, strip as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out
    }

    /// Re-wraps a video without location or other identifying metadata.
    static func sanitisedVideo(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let isMov = url.pathExtension.lowercased() == "mov"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(isMov ? "mov" : "mp4")
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        try await session.export(to: out, as: isMov ? .mov : .mp4)
        return out
    }
}
#endif
