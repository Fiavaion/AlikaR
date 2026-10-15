#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Where an experience is opened.
enum Route: Hashable {
    case author(URL)
    case play(URL)
    case briefs
}

/// The app's root: library, routing, and handling of opened files and links.
public struct RootView: View {
    @State private var store = LibraryStore()
    @State private var path: [Route] = []
    @State private var error: String?
    @Binding var incoming: URL?

    public init(incoming: Binding<URL?>) { _incoming = incoming }

    public var body: some View {
        NavigationStack(path: $path) {
            LibraryView(store: store, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .author(let folder):
                        if let b = try? ExperienceBundle.open(folder: folder) { AuthorView(bundle: b) }
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
            let b: ExperienceBundle
            if url.isFileURL {
                b = try store.open(file: url)
            } else if let link = DeepLink.parse(url) {
                b = try await store.download(link)
            } else {
                throw URLError(.unsupportedURL)
            }
            path = [.play(b.folder)]
        } catch {
            self.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
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
                do { path.append(.play(try store.open(file: url).folder)) } catch { self.error = "\(error)" }
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
                    do { path.append(.play(try await store.download(link).folder)) } catch { self.error = error.localizedDescription }
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
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
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
