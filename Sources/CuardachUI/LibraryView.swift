#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import os

/// Where an experience is opened.
enum Route: Hashable {
    case author(URL)
    /// Author mode that starts by importing a file sent to the app (PRD A1).
    case authorImporting(URL, media: URL)
    case play(URL)
    case briefs
}

/// The app's root: library, routing, and handling of opened files and links.
public struct RootView: View {
    let store: LibraryStore
    @State private var path: [Route] = []
    @State private var error: String?
    @Binding var incoming: URL?
    /// A model, image, video or sound waiting for the author to pick an experience.
    @State private var incomingMedia: StagedMedia?
    @State private var mediaRoute: Route?
    @AppStorage("authorName") private var authorName = ""

    /// `store` is owned by the App so it is created exactly once.
    public init(store: LibraryStore, incoming: Binding<URL?>) {
        self.store = store
        _incoming = incoming
    }

    public var body: some View {
        NavigationStack(path: $path) {
            LibraryView(store: store, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .author(let folder):
                        if let b = try? ExperienceBundle.open(folder: folder) { AuthorView(bundle: b) }
                    case .authorImporting(let folder, let media):
                        if let b = try? ExperienceBundle.open(folder: folder) { AuthorView(bundle: b, importing: media) }
                    case .play(let folder):
                        if let b = try? ExperienceBundle.open(folder: folder) { PlayerView(bundle: b, store: store.progress) }
                    case .briefs:
                        BriefsView()
                    }
                }
        }
        .onChange(of: incoming) { _, url in
            guard let url else { return }
            incoming = nil
            Task { await open(url) }
        }
        .sheet(item: $incomingMedia, onDismiss: {
            guard let r = mediaRoute else { return }
            mediaRoute = nil
            // Save and stop an open author session first, so its unsaved
            // placements are on disk before the experience is reopened.
            Task {
                await AuthorModel.active?.stop()
                path = [r]
            }
        }) { media in
            ChooseExperienceSheet(fileName: media.file.lastPathComponent, experiences: store.authored) { choice in
                importMedia(media.file, into: choice)
            } cancel: {
                LibraryStore.discardStagedMedia(media.file)
                incomingMedia = nil
            }
            .interactiveDismissDisabled()
        }
        .alert("Couldn't open", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .overlay {
            if store.isDownloading {
                ProgressView("Downloading…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    /// Files from AirDrop/Files/Mail, `cuardach://open?url=` links and https links (PRD P1, S4).
    func open(_ url: URL) async {
        do {
            if url.isFileURL, !Self.isBundleFile(url) {
                Log.library.notice("Incoming media \(url.lastPathComponent, privacy: .private)")
                try openMedia(url)
                return
            }
            let b: ExperienceBundle
            if url.isFileURL {
                Log.library.notice("Incoming experience file \(url.lastPathComponent, privacy: .private)")
                b = try store.open(file: url)
            } else if let link = DeepLink.parse(url) {
                Log.library.notice("Incoming \(url.scheme ?? "?", privacy: .public) link, downloading")
                b = try await store.download(link)
            } else {
                throw URLError(.unsupportedURL)
            }
            await AuthorModel.active?.stop()
            Log.library.notice("Opened experience \(b.experience.id, privacy: .public) to play")
            path = [.play(b.folder)]
        } catch {
            Log.library.error("Couldn't open incoming \(url.isFileURL ? "file" : "link", privacy: .public): \((error as NSError).domain, privacy: .public) \((error as NSError).code) \(error, privacy: .private)")
            self.error = readableMessage(error)
        }
    }

    static func isBundleFile(_ url: URL) -> Bool {
        [BundleLayout.fileExtension, "zip"].contains(url.pathExtension.lowercased())
    }

    /// A model, image, video or sound from AirDrop or "Open in…" (PRD A1):
    /// formats the importer refuses get the same message as the Files picker;
    /// anything else waits for the author to choose an experience.
    private func openMedia(_ url: URL) throws {
        let staged = try store.stageIncomingMedia(url)
        if let refusal = Self.importRefusal(staged) {
            Log.library.error("Incoming media refused: .\(staged.pathExtension, privacy: .public)")
            LibraryStore.discardStagedMedia(staged)
            error = refusal
            return
        }
        if let previous = incomingMedia { LibraryStore.discardStagedMedia(previous.file) }
        incomingMedia = StagedMedia(file: staged)
    }

    /// Why the importer would turn a file away, using its own messages.
    static func importRefusal(_ file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        guard let format = AssetPolicy.format(forExtension: ext) else {
            return ImportPipeline.Failure.unsupported(ext).localizedDescription
        }
        return AssetMetrics(bytes: 0).warnings(format: format).first { $0.severity == .blocking }?.message
    }

    /// Opens author mode on the chosen experience (or a new one named after
    /// the file) and runs the usual import there, once the sheet has gone.
    private func importMedia(_ file: URL, into choice: ExperienceBundle?) {
        do {
            let target = try choice ?? store.create(title: file.deletingPathExtension().lastPathComponent, author: authorName)
            Log.library.notice("Incoming media goes to \(choice == nil ? "a new" : "an existing", privacy: .public) experience \(target.experience.id, privacy: .public)")
            mediaRoute = .authorImporting(target.folder, media: file)
        } catch {
            Log.library.error("Couldn't create an experience for incoming media: \(error, privacy: .private)")
            LibraryStore.discardStagedMedia(file)
            self.error = error.localizedDescription
        }
        incomingMedia = nil
    }
}

struct StagedMedia: Identifiable {
    let id = UUID()
    let file: URL
}

/// Asks where a file sent to the app should go (PRD A1).
struct ChooseExperienceSheet: View {
    let fileName: String
    let experiences: [ExperienceBundle]
    let choose: (ExperienceBundle?) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { choose(nil) } label: {
                        Label("New experience", systemImage: "plus")
                    }
                } footer: {
                    Text("You'll place \(fileName) at the crosshair, as with Add from Files.")
                }
                if !experiences.isEmpty {
                    Section("My experiences") {
                        ForEach(experiences, id: \.folder) { b in
                            Button { choose(b) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.experience.title).font(.headline).foregroundStyle(.primary)
                                    Text(b.experience.author).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to which experience?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
    }
}

struct LibraryView: View {
    let store: LibraryStore
    @Binding var path: [Route]
    @State private var creating = false
    @State private var newTitle = ""
    @AppStorage("authorName") private var authorName = ""
    @State private var importing = false
    @State private var scanning = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if store.authored.isEmpty {
                    Button { creating = true } label: {
                        Label("Make your first experience", systemImage: "sparkles")
                    }
                }
                ForEach(store.authored, id: \.folder) { b in
                    row(b, authoring: true)
                }
            } header: { Text("My experiences") }

            Section {
                if store.opened.isEmpty {
                    Text("Experiences you open from AirDrop, Files, a link or a QR code appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.opened, id: \.folder) { b in
                    row(b, authoring: false)
                }
            } header: { Text("Opened") }

            Section {
                NavigationLink(value: Route.briefs) {
                    Label("Studio briefs", systemImage: "lightbulb")
                }
            } footer: {
                Text("Project ideas for Fine Art Media, Product Design and Communication Design.")
            }
        }
        .navigationTitle("Cuardach")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder") }
                    .accessibilityLabel("Scan a QR code")
                    .disabled(!(DataScannerViewController.isSupported && DataScannerViewController.isAvailable))
                Button { importing = true } label: { Image(systemName: "tray.and.arrow.down") }
                    .accessibilityLabel("Open a file")
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New experience")
            }
        }
        .refreshable { store.refresh() }
        .alert("New experience", isPresented: $creating) {
            TextField("Title", text: $newTitle)
            TextField("Your name", text: $authorName)
            Button("Create") {
                do {
                    let b = try store.create(title: newTitle.isEmpty ? String(localized: "Untitled") : newTitle, author: authorName)
                    newTitle = ""
                    path.append(.author(b.folder))
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(exportedAs: BundleLayout.uti), .zip]) { result in
            if case .success(let url) = result {
                do { path.append(.play(try store.open(file: url).folder)) } catch { self.error = readableMessage(error) }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { payload in
                scanning = false
                guard let link = DeepLink.parse(qrPayload: payload) else {
                    error = String(localized: "That QR code isn't a link to an experience.")
                    return
                }
                Task {
                    do { path.append(.play(try await store.download(link).folder)) } catch { self.error = readableMessage(error) }
                }
            }
            .ignoresSafeArea()
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func row(_ b: ExperienceBundle, authoring: Bool) -> some View {
        Button {
            path.append(authoring ? .author(b.folder) : .play(b.folder))
        } label: {
            HStack(spacing: 12) {
                cover(b)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.experience.title).font(.headline).foregroundStyle(.primary)
                    Text(b.experience.author).font(.subheadline).foregroundStyle(.secondary)
                    if !authoring {
                        let c = store.progress.load(b.experience.id).foundCount(in: b.experience)
                        Text("\(c.found) of \(c.total) found").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            if authoring {
                Button { path.append(.play(b.folder)) } label: { Label("Play", systemImage: "play") }
            } else {
                Button {
                    do { path.append(.author(try store.remix(b, by: authorName).folder)) } catch { self.error = error.localizedDescription }
                } label: { Label("Remix a copy", systemImage: "scissors") }
                if let src = store.sourceURL(for: b) {
                    Link(destination: src) { Label("Open original link", systemImage: "link") }
                }
            }
            Button(role: .destructive) { try? store.delete(b) } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions {
            Button(role: .destructive) { try? store.delete(b) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func cover(_ b: ExperienceBundle) -> some View {
        if let c = b.experience.cover, let u = try? b.url(for: c), let img = UIImage(contentsOfFile: u.path) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.teal.gradient).frame(width: 64, height: 64)
                .overlay(Image(systemName: "arkit").foregroundStyle(.white))
                .accessibilityHidden(true)
        }
    }
}

/// In-app QR scanner (PRD P1, S3) using VisionKit.
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // Start once the scanner is on screen, not while it's being built.
        if !vc.isScanning { try? vc.startScanning() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let s = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                found(s)
            }
        }
    }
}

/// Studio briefs (see StudioBrief).
struct BriefsView: View {
    @State private var filter: StudioBrief.Discipline?

    var body: some View {
        List {
            Picker("Discipline", selection: $filter) {
                Text("All").tag(StudioBrief.Discipline?.none)
                ForEach(StudioBrief.Discipline.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            ForEach(StudioBrief.all.filter { filter == nil || $0.disciplines.contains(filter!) }) { b in
                NavigationLink {
                    BriefDetail(brief: b)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.title).font(.headline)
                        Text(b.disciplines.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Studio briefs")
    }
}

struct BriefDetail: View {
    let brief: StudioBrief

    var body: some View {
        List {
            Section { Text(brief.prompt) }
            Section("Uses") { ForEach(brief.uses, id: \.self) { Label($0, systemImage: "wrench.and.screwdriver") } }
            Section("Reflect") { ForEach(brief.reflect, id: \.self) { Text($0) } }
            Section("Look at") { ForEach(brief.lookAt, id: \.self) { Text($0) } }
        }
        .navigationTitle(brief.title)
    }
}
#endif
