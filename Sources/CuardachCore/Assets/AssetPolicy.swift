import Foundation

/// Import limits and file-type rules (PRD A1, A2, A4, A14, S2).
public enum AssetPolicy {
    public static let maxTextureDimension = 2048
    public static let triangleWarning = 100_000
    public static let assetWarningBytes = 25_000_000
    public static let bundleWarningBytes = 50_000_000

    public enum Format: String, Sendable, CaseIterable {
        case usdz, reality, glb, gltf, obj
        case png, jpg, heic
        case mp4, mov
        case wav, mp3, aac, m4a
        case ply, spz

        public var kind: ElementKind {
            switch self {
            case .usdz, .reality, .glb, .gltf, .obj: .model
            case .png, .jpg, .heic: .image
            case .mp4, .mov: .video
            case .wav, .mp3, .aac, .m4a: .audio
            case .ply, .spz: .splat
            }
        }

        /// Whether MVP accepts this format at import.
        public var supportedInMVP: Bool {
            switch self {
            case .obj, .ply, .spz: false  // A3, A5: Later
            default: true
            }
        }
    }

    public static func format(forExtension ext: String) -> Format? {
        switch ext.lowercased() {
        case "jpeg": .jpg
        case "m4v": .mp4
        case "hevc": .mov
        default: Format(rawValue: ext.lowercased())
        }
    }
}

/// A problem found while importing an asset, shown before the author accepts it.
public struct ImportWarning: Sendable, Equatable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        case info, warning, blocking
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity; self.message = message
    }
}

/// What an importer measured about an asset. Platform code fills in what it
/// can (image pixel size via ImageIO, triangles via RealityKit); GLB fields
/// come from `GLBInspector` on any platform.
public struct AssetMetrics: Sendable, Equatable {
    public var bytes: Int
    public var triangles: Int?
    public var maxTextureDimension: Int?
    public var animationClips: [String] = []
    public var missingTextures: [String] = []
    public var unsupportedExtensions: [String] = []
    /// Native bounding box size in metres, where known.
    public var boundingSize: Vec3?

    public init(bytes: Int) { self.bytes = bytes }

    /// Turns measurements into the warning list (PRD A2, A14).
    public func warnings(format: AssetPolicy.Format) -> [ImportWarning] {
        var w: [ImportWarning] = []
        if !format.supportedInMVP {
            w.append(.init(.blocking, "\(format.rawValue.uppercased()) files can't be imported yet. Convert to USDZ on a Mac (Reality Converter or the AROR pipeline)."))
        }
        if let t = triangles, t > AssetPolicy.triangleWarning {
            w.append(.init(.warning, "\(t.formatted()) triangles. Above \(AssetPolicy.triangleWarning.formatted()) it may stutter on older iPhones; decimate in Blender if you can."))
        }
        if let d = maxTextureDimension, d > AssetPolicy.maxTextureDimension {
            w.append(.init(.info, "Textures up to \(d) px will be downscaled to \(AssetPolicy.maxTextureDimension) px."))
        }
        if bytes > AssetPolicy.assetWarningBytes {
            w.append(.init(.warning, "This file is \(ByteSize.format(bytes)). Over 25 MB, sharing by AirDrop and loading get slow."))
        }
        for t in missingTextures {
            w.append(.init(.warning, "Missing texture: \(t). The surface will render without it."))
        }
        for e in unsupportedExtensions {
            w.append(.init(.warning, "Uses \(e), which the on-device loader doesn't support. Parts may look wrong; converting to USDZ on a Mac is more reliable."))
        }
        if format == .glb || format == .gltf, !animationClips.isEmpty {
            w.append(.init(.info, "Animated GLB files can play back imperfectly on device. For degree-show work, convert to USDZ on a Mac."))
        }
        if let b = boundingSize, max(b.x, b.y, b.z) > 50 {
            w.append(.init(.info, "The model is \(Int(max(b.x, b.y, b.z))) m across. It may have been exported in centimetres; check the scale after placing."))
        }
        return w.sorted { $0.severity > $1.severity }
    }
}

public enum ByteSize {
    public static func format(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(max(1, bytes / 1000)) KB"
    }
}
