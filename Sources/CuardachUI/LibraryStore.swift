#if canImport(SwiftUI) && os(iOS)
import CuardachCore
import Foundation
import Observation

/// Experiences on this device (PRD P2, Storage): ones the user is authoring,
/// and ones they opened from someone else. Both are unpacked `.arhunt`
/// folders in Documents, visible in the Files app.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var authored: [ExperienceBundle] = []
    public private(set) var opened: [ExperienceBundle] = []
    public private(set) var isDownloading = false
    public var lastError: String?

    public let authoringDir: URL
    public let libraryDir: URL
    public let progress: PlayerProgressStore
    private let sourcesFile: URL
    private var sources: [String: String] = [:]

    public init(root: URL? = nil) {
        let docs = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        authoringDir = docs.appendingPathComponent("My Experiences", isDirectory: true)
        libraryDir = docs.appendingPathComponent("Opened", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        progress = PlayerProgressStore(directory: support.appendingPathComponent("Progress", isDirectory: true))
        sourcesFile = support.appendingPathComponent("sources.json")
        for d in [authoringDir, libraryDir, support] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        sources = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourcesFile))) ?? [:]
        refresh()
    }

    public func refresh() {
        authored = Self.bundles(in: authoringDir)
        opened = Self.bundles(in: libraryDir)
    }

    static func bundles(in dir: URL) -> [ExperienceBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == BundleLayout.fileExtension }
            .compactMap { try? ExperienceBundle.open(folder: $0) }
            .sorted { $0.experience.title.localizedCaseInsensitiveCompare($1.experience.title) == .orderedAscending }
    }

    public func create(title: String, author: String) throws -> ExperienceBundle {
        let b = try ExperienceBundle.create(Experience(title: title, author: author), in: authoringDir)
        refresh()
        return b
    }

    /// Opens a `.arhunt` file from Files, AirDrop or Mail (PRD P1).
    public func open(file url: URL) throws -> ExperienceBundle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let b = try ExperienceBundle.unpack(url, into: libraryDir)
        refresh()
        return b
    }

    /// Downloads a bundle from an HTTPS link or QR code, then opens it (PRD P1, S3).
    public func download(_ link: DeepLink) async throws -> ExperienceBundle {
        guard case .download(let remote) = link else { throw URLError(.unsupportedURL) }
        isDownloading = true
        defer { isDownloading = false }
        let (tmp, response) = try await URLSession.shared.download(from: remote)
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let b = try ExperienceBundle.unpack(tmp, into: libraryDir)
        sources[b.experience.id] = remote.absoluteString
        try? JSONEncoder().encode(sources).write(to: sourcesFile, options: .atomic)
        refresh()
        return b
    }

    /// Where an opened experience was downloaded from, if anywhere (P2).
    public func sourceURL(for b: ExperienceBundle) -> URL? {
        sources[b.experience.id].flatMap(URL.init(string:))
    }

    public func delete(_ b: ExperienceBundle) throws {
        try FileManager.default.removeItem(at: b.folder)
        try? progress.reset(b.experience.id)
        refresh()
    }

    /// Studio extension: remix. Copies an opened experience into My
    /// Experiences with a new id, so a student can take apart a lecturer's
    /// example. The original author stays credited in the label.
    public func remix(_ b: ExperienceBundle, by author: String) throws -> ExperienceBundle {
        var x = b.experience
        let original = x.author
        x.id = UUID().uuidString
        x.title = "\(x.title) (remix)"
        x.author = author
        x.created = ISO8601.string(from: Date())
        x.annotations = []
        var label = x.label ?? WallLabel()
        let note = "Remixed from “\(b.experience.title)” by \(original)."
        label.statement = [note, label.statement].compactMap { $0 }.joined(separator: "\n\n")
        x.label = label
        let dest = authoringDir.appendingPathComponent(ExperienceBundle.folderName(for: x), isDirectory: true)
        try FileManager.default.copyItem(at: b.folder, to: dest)
        var copy = try ExperienceBundle.open(folder: dest)
        copy.experience = x
        try copy.save()
        refresh()
        return copy
    }
}
#endif
