import Foundation

/// Bundle layout constants (PRD: Bundle).
public enum BundleLayout {
    public static let fileExtension = "arhunt"
    public static let uti = "ie.ncad.arhunt"
    public static let manifest = "manifest.json"
    public static let assets = "assets"
    public static let maps = "maps"
    public static let markers = "markers"
    public static let thumbnail = "thumbnail.png"

    /// Files that never travel inside a bundle.
    static func isJunk(_ components: [String]) -> Bool {
        components.first == "__MACOSX" || components.last == ".DS_Store" || components.last?.hasPrefix("._") == true
    }
}

public enum BundleError: Error, Equatable, CustomStringConvertible {
    case missingManifest
    case invalidManifest(String)
    case missingSchemaVersion
    case readOnly
    case tooLarge(limitBytes: Int)
    case tooManyFiles(limit: Int)

    public var description: String {
        switch self {
        case .missingManifest: "This isn't an AR experience: it has no manifest.json."
        case .invalidManifest(let why): "The experience's manifest can't be read: \(why)"
        case .missingSchemaVersion: "The manifest has no schemaVersion."
        case .readOnly: "This experience was made with a newer version of the app and opens read-only."
        case .tooLarge(let l): "The experience unpacks to more than \(l / 1_000_000) MB."
        case .tooManyFiles(let n): "The experience contains more than \(n) files."
        }
    }
}

/// Reads and writes manifest.json, migrating older schemas and keeping
/// newer ones intact.
public enum ManifestCodec {
    public struct ReadResult: Sendable {
        public var experience: Experience
        /// The manifest came from a newer app version. Unknown keys are kept,
        /// but saving is refused so nothing is silently downgraded.
        public var isFromNewerVersion: Bool
        public var migratedFrom: Int?
    }

    /// Migration steps keyed by the version they upgrade *from*. Each step
    /// rewrites the raw JSON so the typed decoder only ever sees the current
    /// schema. Version 1 is the first published schema, so there are none yet.
    static let migrations: [Int: @Sendable ([String: JSONValue]) -> [String: JSONValue]] = [:]

    public static func decode(_ data: Data) throws -> ReadResult {
        let raw: JSONValue
        do { raw = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw BundleError.invalidManifest("it isn't valid JSON.")
        }
        guard case .object(var obj) = raw else { throw BundleError.invalidManifest("the top level isn't an object.") }
        guard case .number(let v)? = obj["schemaVersion"] else { throw BundleError.missingSchemaVersion }
        var version = Int(v)
        let original = version
        while version < Experience.currentSchemaVersion {
            guard let step = migrations[version] else {
                throw BundleError.invalidManifest("schema version \(version) can't be upgraded.")
            }
            obj = step(obj)
            version += 1
            obj["schemaVersion"] = .number(Double(version))
        }
        do {
            let fixed = try JSONEncoder().encode(JSONValue.object(obj))
            let exp = try JSONDecoder().decode(Experience.self, from: fixed)
            return ReadResult(experience: exp,
                              isFromNewerVersion: original > Experience.currentSchemaVersion,
                              migratedFrom: original < Experience.currentSchemaVersion ? original : nil)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw BundleError.invalidManifest("missing \"\(key.stringValue)\" at \(path(ctx)).")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw BundleError.invalidManifest("wrong type at \(path(ctx)).")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw BundleError.invalidManifest("missing value at \(path(ctx)).")
        } catch {
            throw BundleError.invalidManifest(String(describing: error))
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return p.isEmpty ? "the top level" : String(p.drop { $0 == "." })
    }

    /// Stable, human-readable output: sorted keys, two-space indent.
    public static func encode(_ experience: Experience) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(experience)
    }
}

/// An experience on disk as an unpacked `.arhunt` folder (fast to edit),
/// packed to a zip only for sharing (PRD: Storage).
public struct ExperienceBundle: Sendable {
    public let folder: URL
    public var experience: Experience
    public private(set) var isReadOnly: Bool

    /// Safety limits for unpacking files from untrusted sources.
    public struct UnpackLimits: Sendable {
        public var maxTotalBytes: Int
        public var maxFiles: Int
        public init(maxTotalBytes: Int = 2_000_000_000, maxFiles: Int = 5_000) {
            self.maxTotalBytes = maxTotalBytes; self.maxFiles = maxFiles
        }
    }

    public static func open(folder: URL) throws -> ExperienceBundle {
        let m = folder.appendingPathComponent(BundleLayout.manifest)
        guard FileManager.default.fileExists(atPath: m.path) else { throw BundleError.missingManifest }
        let r = try ManifestCodec.decode(Data(contentsOf: m))
        return ExperienceBundle(folder: folder, experience: r.experience, isReadOnly: r.isFromNewerVersion)
    }

    /// Creates `<parent>/<experience.id>.arhunt/` with the standard subfolders.
    public static func create(_ experience: Experience, in parent: URL) throws -> ExperienceBundle {
        let folder = parent.appendingPathComponent(folderName(for: experience), isDirectory: true)
        let fm = FileManager.default
        for sub in [BundleLayout.assets, BundleLayout.maps, BundleLayout.markers] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let b = ExperienceBundle(folder: folder, experience: experience, isReadOnly: false)
        try b.save()
        return b
    }

    /// Writes manifest.json atomically.
    public func save() throws {
        guard !isReadOnly else { throw BundleError.readOnly }
        let data = try ManifestCodec.encode(experience)
        try data.write(to: folder.appendingPathComponent(BundleLayout.manifest), options: .atomic)
    }

    public func url(for relativePath: String) throws -> URL {
        try SafePath.resolve(relativePath, under: folder)
    }

    public func fileExists(_ relativePath: String) -> Bool {
        guard let u = try? url(for: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// Copies a file into the bundle under `subfolder`, picking a unique,
    /// tidy name. Returns the bundle-relative path to store in the manifest.
    @discardableResult
    public func importFile(_ source: URL, subfolder: String = BundleLayout.assets, preferredName: String? = nil) throws -> String {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(subfolder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        let base = Self.slug(preferredName ?? source.deletingPathExtension().lastPathComponent)
        var name = ext.isEmpty ? base : "\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        }
        try fm.copyItem(at: source, to: dir.appendingPathComponent(name))
        return "\(subfolder)/\(name)"
    }

    /// Writes data into the bundle at a relative path, replacing any file there.
    public func write(_ data: Data, to relativePath: String) throws {
        let u = try url(for: relativePath)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    /// The on-disk folder name for an experience: one folder per id, so
    /// reopening a shared bundle replaces the older copy.
    public static func folderName(for experience: Experience) -> String {
        "\(slug(experience.id)).\(BundleLayout.fileExtension)"
    }

    /// Lowercase ASCII, digits and dashes: safe in every file system and URL.
    public static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var out = ""
        var dash = false
        for ch in folded.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch); dash = false
            } else if !dash, !out.isEmpty {
                out.append("-"); dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "file" : String(out.prefix(60))
    }

    /// Every file in the bundle with its size, relative paths sorted.
    public func files() throws -> [(path: String, bytes: Int)] {
        let fm = FileManager.default
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [(String, Int)] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let u as URL in e {
            let v = try u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v.isRegularFile == true else { continue }
            let full = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(prefix) else { continue }
            let rel = String(full.dropFirst(prefix.count))
            if BundleLayout.isJunk(rel.split(separator: "/").map(String.init)) { continue }
            out.append((rel, v.fileSize ?? 0))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    public func totalBytes() throws -> Int { try files().reduce(0) { $0 + $1.bytes } }

    /// Packs the bundle into a `.arhunt` zip, manifest first (PRD S1).
    public func pack(to destination: URL) throws {
        let w = try ZipWriter(url: destination)
        try w.add(data: try ManifestCodec.encode(experience), path: BundleLayout.manifest)
        for f in try files() where f.path != BundleLayout.manifest {
            try w.add(file: try url(for: f.path), path: f.path)
        }
        try w.finish()
    }

    /// Unpacks a `.arhunt` zip into `<parent>/<id>.arhunt/`, replacing an
    /// earlier copy of the same experience. Accepts archives whose content
    /// sits inside one top-level folder, as Finder's "Compress" produces.
    public static func unpack(_ archive: URL, into parent: URL, limits: UnpackLimits = UnpackLimits()) throws -> ExperienceBundle {
        let zip = try ZipReader(url: archive)
        var items: [(entry: ZipEntry, parts: [String])] = []
        var total = 0
        for e in zip.entries where !e.isDirectory {
            let parts = try SafePath.components(e.path)
            if BundleLayout.isJunk(parts) { continue }
            items.append((e, parts))
            total += e.uncompressedSize
        }
        guard items.count <= limits.maxFiles else { throw BundleError.tooManyFiles(limit: limits.maxFiles) }
        guard total <= limits.maxTotalBytes else { throw BundleError.tooLarge(limitBytes: limits.maxTotalBytes) }

        // Find manifest.json at the root or inside a single wrapper folder.
        var strip = 0
        if !items.contains(where: { $0.parts == [BundleLayout.manifest] }) {
            let wrapped = items.filter { $0.parts.count == 2 && $0.parts[1] == BundleLayout.manifest }
            guard wrapped.count == 1 else { throw BundleError.missingManifest }
            let top = wrapped[0].parts[0]
            items = items.filter { $0.parts.first == top && $0.parts.count > 1 }
            strip = 1
        }
        guard let manifestItem = items.first(where: { Array($0.parts.dropFirst(strip)) == [BundleLayout.manifest] }) else {
            throw BundleError.missingManifest
        }
        let read = try ManifestCodec.decode(try zip.contents(of: manifestItem.entry))

        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for item in items {
            let rel = Array(item.parts.dropFirst(strip))
            let dest = rel.reduce(staging) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.contents(of: item.entry).write(to: dest)
        }
        let finalFolder = parent.appendingPathComponent(folderName(for: read.experience), isDirectory: true)
        if fm.fileExists(atPath: finalFolder.path) { try fm.removeItem(at: finalFolder) }
        try fm.moveItem(at: staging, to: finalFolder)
        return ExperienceBundle(folder: finalFolder, experience: read.experience, isReadOnly: read.isFromNewerVersion)
    }
}
