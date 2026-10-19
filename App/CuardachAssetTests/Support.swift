import AVFoundation
import CoreMedia
import GLTFKit2
import ImageIO
import RealityKit
import XCTest
@testable import CuardachAR
@testable import CuardachCore

/// Shared setup for the asset tests: injects the GLB loader the same way
/// CuardachApp does, and locates the sample bundles and the local test media.
@MainActor
enum Support {
    static func installLoader() {
        GLTFLoading.loader = { url in try await GLTFRealityKitLoader.load(from: url) }
    }

    /// Repo root, derived from this file's location (the simulator reads the host filesystem).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sample(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Samples/\(name).arhunt", isDirectory: true)
    }

    /// Test media is licensed for personal testing only and is never committed.
    /// Override the location with CUARDACH_TEST_MEDIA.
    static var mediaDir: URL {
        if let p = ProcessInfo.processInfo.environment["CUARDACH_TEST_MEDIA"] { return URL(fileURLWithPath: p) }
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Desktop/Cuardach Demo/Test media", isDirectory: true)
    }

    static func media(_ name: String) throws -> URL {
        let u = mediaDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else {
            throw XCTSkip("Test media \(name) not found in \(mediaDir.path); see README.txt there")
        }
        return u
    }

    static func temporaryParent() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("assettests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A fresh empty bundle to import into.
    static func newBundle() throws -> ExperienceBundle {
        try ExperienceBundle.create(Experience(title: "Asset test", author: "Tests"), in: temporaryParent())
    }

    static func firstModel(_ e: Entity) -> ModelComponent? {
        if let m = e.components[ModelComponent.self] { return m }
        for c in e.children { if let m = firstModel(c) { return m } }
        return nil
    }

    static func hasAlpha(videoAt url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let descs = try await track.load(.formatDescriptions)
        return descs.contains { d in
            let ext = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
            return (ext as? Bool) == true || (ext as? NSNumber)?.boolValue == true
        }
    }

    static func imageProps(_ url: URL) -> [CFString: Any]? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
    }
}
