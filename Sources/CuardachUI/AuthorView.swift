#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import PhotosUI
import ReplayKit
import SwiftUI
import UniformTypeIdentifiers

enum AuthorSheet: String, Identifiable {
    case scene, inspector, behaviours, anchors, studio, crit, export, importReview, experience
    var id: String { rawValue }
}

/// Author mode. The model (which owns an ARSession) is created once, on
/// appear, rather than every time SwiftUI re-initialises this view.
public struct AuthorView: View {
    let bundle: ExperienceBundle
    /// A file sent to the app to import as soon as author mode opens (PRD A1).
    let importing: URL?
    @State private var model: AuthorModel?

    public init(bundle: ExperienceBundle, importing: URL? = nil) {
        self.bundle = bundle
        self.importing = importing
    }

    public var body: some View {
        if let model {
            AuthorScreen(model: model, importOnOpen: importing)
        } else {
            Color.black.ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .onAppear { model = AuthorModel(bundle: bundle) }
        }
    }
}

struct AuthorScreen: View {
    let model: AuthorModel
    var importOnOpen: URL?
    @State private var importedOnOpen = false
    @State private var sheet: AuthorSheet?
    @State private var showingFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var addingText = false
    @State private var newText = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ARViewContainer(controller: model.ar) { model.handleTap($0) }
                .ignoresSafeArea()

            if !model.cleanFrame {
                if model.selection == nil, !model.isPreviewing { crosshair }
                VStack(spacing: 0) {
                    topBar
                    statusLine
                    Spacer()
                    if case .geoSession = model.pin { geoPinBar } else { bottomBar }
                }
            } else if model.isRecording {
                VStack {
                    Spacer()
                    OverlayButton(title: "Stop recording", systemImage: "stop.fill", prominent: true) {
                        Task { await model.toggleRecording() }
                    }
                    .tint(.red)
                    .padding(.bottom, 24)
                }
            }

            if let t = model.toast {
                VStack { Spacer(); Toast(text: t).padding(.bottom, 140) }
                    .transition(.opacity)
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(5))
                        if model.toast == t { withAnimation { model.toast = nil } }
                    }
            }
            if model.isBusy { ProgressView().controlSize(.large).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
        }
        .statusBarHidden(model.cleanFrame)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { model.start() }
        .task {
            // The same review, warnings and placement as Add > From Files.
            guard let media = importOnOpen, !importedOnOpen else { return }
            importedOnOpen = true
            await model.importFile(media)
            LibraryStore.discardStagedMedia(media)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await model.save() } }
        }
        .onChange(of: model.pendingImport != nil) { _, has in if has { sheet = .importReview } }
        .sheet(item: $sheet) { which in
            NavigationStack { panel(which) }
                .presentationDetents(which == .export || which == .importReview ? [.large] : [.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: Self.importTypes) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let file = try? await item.loadTransferable(type: PickedFile.self) { await model.importFile(file.url) }
                photoItem = nil
            }
        }
        .alert("Add text", isPresented: $addingText) {
            TextField("Text", text: $newText, axis: .vertical)
            Button("Add") { model.addText(newText); newText = "" }
            Button("Cancel", role: .cancel) { newText = "" }
        } message: {
            Text("A short line of text that floats in space and turns to face the viewer.")
        }
        .sheet(isPresented: Binding(get: { model.recordingPreview != nil }, set: { if !$0 { model.recordingPreview = nil } })) {
            if let vc = model.recordingPreview { RecordingPreview(controller: vc) { model.recordingPreview = nil } }
        }
    }

    static let importTypes: [UTType] = {
        var t: [UTType] = [.usdz, .image, .movie, .audio, .png, .jpeg, .heic, .mpeg4Movie, .quickTimeMovie, .wav, .mp3]
        for ext in ["glb", "gltf", "reality"] { if let u = UTType(filenameExtension: ext) { t.append(u) } }
        return t
    }()

    // MARK: Chrome

    private var crosshair: some View {
        Image(systemName: "plus")
            .font(.title.weight(.light))
            .foregroundStyle(.white.opacity(0.8))
            .shadow(radius: 2)
            .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.stop(); dismiss() }
            } label: {
                Label("Done", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)

            Button { sheet = .experience } label: {
                Text(model.experience.title).font(.headline).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit title, statement and completion message")

            Spacer()
            Button { model.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.undo.canUndo)
                .accessibilityLabel("Undo")
            Button { model.redoLast() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.undo.canRedo)
                .accessibilityLabel("Redo")
            Button { Task { await model.save() } } label: { Image(systemName: "square.and.arrow.down") }
                .accessibilityLabel("Save")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var statusLine: some View {
        HStack {
            Text(model.scanQuality)
            if let hint = model.ar.trackingHint { Text("· \(hint)") }
            Spacer()
            if model.isPreviewing { Label("Previewing as player", systemImage: "play.fill").foregroundStyle(.green) }
        }
        .font(.caption)
        .padding(.horizontal).padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.7))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let e = model.selectedElement, !model.isPreviewing {
                HStack {
                    Image(systemName: e.kind.symbol)
                    Text(e.name).font(.headline).lineLimit(1)
                    PrecisionBadge(precision: e.precision)
                    Spacer()
                    Button { model.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Deselect")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if model.isPreviewing {
                        OverlayButton(title: "Stop preview", systemImage: "stop.fill", prominent: true) { model.stopPreview() }
                    } else {
                        Menu {
                            Button { showingFiles = true } label: { Label("From Files", systemImage: "folder") }
                            Button { showingPhotos = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                            Button { addingText = true } label: { Label("Text", systemImage: "textformat") }
                        } label: {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).frame(width: 56, height: 56)
                                .background(.tint, in: Circle()).foregroundStyle(.white)
                        }
                        .accessibilityLabel("Add element")
                        OverlayButton(title: "Elements", systemImage: "list.bullet") { sheet = .scene }
                        if model.selection != nil {
                            OverlayButton(title: "Adjust", systemImage: "slider.horizontal.3") { sheet = .inspector }
                            OverlayButton(title: "Behaviours", systemImage: "hand.tap") { sheet = .behaviours }
                            OverlayButton(title: "Anchors", systemImage: "mappin.and.ellipse") { sheet = .anchors }
                            OverlayButton(title: "Label, credit and variants", systemImage: "text.book.closed") { sheet = .studio }
                        }
                        OverlayButton(title: "Crit notes", systemImage: "bubble.left.and.text.bubble.right") { sheet = .crit }
                        OverlayButton(title: "Preview as player", systemImage: "play.fill") { model.startPreview() }
                    }
                    OverlayButton(title: "Take a documentation photo", systemImage: "camera") { Task { await model.takePhoto() } }
                    OverlayButton(title: "Record a documentation video", systemImage: "record.circle") { Task { await model.toggleRecording() } }
                    if !model.isPreviewing {
                        OverlayButton(title: "Share and export", systemImage: "square.and.arrow.up") { sheet = .export }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    private var geoPinBar: some View {
        VStack(spacing: 12) {
            Label(model.ar.geoLocalised ? "Localised" : "Localising… look at building fronts",
                  systemImage: model.ar.geoLocalised ? "checkmark.seal.fill" : "location.magnifyingglass")
                .padding(10).background(.ultraThinMaterial, in: Capsule())
            HStack(spacing: 20) {
                Button("Cancel", role: .cancel) { model.endGeoSession() }.buttonStyle(.bordered)
                Button("Pin here") { Task { await model.confirmGeoPin() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.ar.geoLocalised)
            }
            .controlSize(.large)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func panel(_ which: AuthorSheet) -> some View {
        switch which {
        case .scene: SceneListPanel(model: model) { sheet = $0 }
        case .inspector: InspectorPanel(model: model)
        case .behaviours: BehaviourPanel(model: model)
        case .anchors: AnchorsPanel(model: model)
        case .studio: StudioPanel(model: model)
        case .crit: CritPanel(model: model)
        case .export: ExportPanel(model: model)
        case .importReview: ImportReviewPanel(model: model) { sheet = nil }
        case .experience: ExperiencePanel(model: model)
        }
    }
}

/// A file picked from Photos, copied somewhere the importer can read it.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}

/// ReplayKit's trim-and-save screen for documentation videos.
struct RecordingPreview: UIViewControllerRepresentable {
    let controller: RPPreviewViewController
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> RPPreviewViewController {
        controller.previewControllerDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ vc: RPPreviewViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, RPPreviewViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func previewControllerDidFinish(_ previewController: RPPreviewViewController) { onFinish() }
    }
}
#endif
