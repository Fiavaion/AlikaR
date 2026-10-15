#if canImport(RealityKit) && canImport(ReplayKit) && os(iOS)
import Photos
import RealityKit
import ReplayKit
import UIKit

/// Studio extension: documentation of work in situ. Site-specific and AR
/// work is ephemeral; the photo or clip a student takes on the day is what
/// goes in the portfolio and the degree-show archive. Capture hides the
/// editing UI ("clean frame") and saves straight to Photos, on request only.
@MainActor
public final class DocumentationCapture {
    public enum Failure: LocalizedError {
        case notAllowed
        case snapshotFailed
        public var errorDescription: String? {
            switch self {
            case .notAllowed: "Cuardach isn't allowed to add to your Photos. You can change this in Settings."
            case .snapshotFailed: "The photo couldn't be taken."
            }
        }
    }

    public init() {}

    public var isRecording: Bool { RPScreenRecorder.shared().isRecording }

    /// A full-resolution still of the AR view (camera plus content, no UI).
    public func photo(of arView: ARView) async throws -> UIImage {
        try await withCheckedThrowingContinuation { cont in
            arView.snapshot(saveToHDR: false) { image in
                if let image { cont.resume(returning: image) } else { cont.resume(throwing: Failure.snapshotFailed) }
            }
        }
    }

    public func saveToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Screen recording with the microphone off by default (spatial audio is
    /// captured from the app). The UI layer hides its controls while recording.
    public func startRecording(microphone: Bool = false) async throws {
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = microphone
        try await recorder.startRecording()
    }

    /// Stops recording and returns ReplayKit's preview, where the student
    /// trims and saves the clip.
    public func stopRecording() async throws -> RPPreviewViewController {
        try await RPScreenRecorder.shared().stopRecording()
    }
}
#endif
