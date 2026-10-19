#if canImport(SwiftUI) && os(iOS)
import ARKit
import CuardachAR
import CuardachCore
import RealityKit
import SwiftUI
import UIKit

/// Hosts the controller's ARView in SwiftUI and forwards taps.
struct ARViewContainer: UIViewRepresentable {
    let controller: ARSceneController
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> ARView {
        let view = controller.arView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (CGPoint) -> Void
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }
        @objc func tapped(_ g: UITapGestureRecognizer) { onTap(g.location(in: g.view)) }
    }
}

/// The precision badge on every element (PRD L6).
struct PrecisionBadge: View {
    let precision: Precision?
    var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
            if showsExplanation, let p = precision {
                Text(LocalizedStringKey(p.explanation)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    var title: LocalizedStringKey {
        switch precision {
        case .streetPrecise?: "Street-precise"
        case .sitePrecise?: "Site-precise"
        case .markerPrecise?: "Marker-precise"
        case .objectPrecise?: "Object-precise"
        case .approximate?: "Approximate"
        case nil: "Not anchored"
        }
    }

    var symbol: String {
        switch precision {
        case .streetPrecise?: "location.north.circle.fill"
        case .sitePrecise?: "viewfinder"
        case .markerPrecise?: "qrcode"
        case .objectPrecise?: "cube"
        case .approximate?: "location.circle"
        case nil: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch precision {
        case .markerPrecise?, .streetPrecise?, .objectPrecise?: .green
        case .sitePrecise?: .teal
        case .approximate?: .orange
        case nil: .red
        }
    }
}

/// A large, labelled, circular control for AR overlays (PRD P11: big targets).
struct OverlayButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .foregroundStyle(prominent ? .white : .primary)
        }
        .accessibilityLabel(title)
        .buttonStyle(.plain)
    }
}

/// Short-lived message over the AR view.
struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

extension ValidationIssue.Severity {
    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "lightbulb"
        }
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .note: .blue
        }
    }
}

extension ElementKind {
    var symbol: String {
        switch self {
        case .model: "cube"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .text: "textformat"
        case .splat: "aqi.medium"
        default: "questionmark.square.dashed"
        }
    }
}

/// Share sheet for files the system ShareLink can't express (generated PDFs).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// The text to show a student for an error. CuardachCore's bundle and zip
/// errors describe themselves in plain sentences but aren't `LocalizedError`,
/// so their `localizedDescription` would be a generic system message.
func readableMessage(_ error: Error) -> String {
    switch error {
    case let e as BundleError: e.description
    case let e as ZipError: e.description
    default: error.localizedDescription
    }
}

/// Minute of the local day, for time-window triggers.
func minuteOfDay(_ date: Date = Date()) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

/// Loads detection images for every image anchor in an experience.
@MainActor
func referenceImages(for x: Experience, in bundle: ExperienceBundle) -> Set<ARReferenceImage> {
    var out = Set<ARReferenceImage>()
    for a in x.elements.flatMap(\.anchors) where a.tier == .image {
        guard let path = a.imageFile, let url = try? bundle.url(for: path),
              let image = UIImage(contentsOfFile: url.path),
              let ref = MarkerRenderer.referenceImage(for: a, image: image) else { continue }
        out.insert(ref)
    }
    return out
}
#endif
