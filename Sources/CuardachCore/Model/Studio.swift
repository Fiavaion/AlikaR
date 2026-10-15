import Foundation

// Studio extensions: optional manifest keys that support how art and design
// students actually present, credit, critique and evaluate work. They are
// additive to schema v1; a reader that does not know them preserves them.

/// A gallery-style label. On an experience it is the artist or designer
/// statement; on an element it is the object label beside the work.
public struct WallLabel: Codable, Hashable, Sendable {
    /// Work title, if different from the element or experience name.
    public var title: String?
    /// Maker(s), as they wish to be credited.
    public var artist: String?
    public var year: String?
    /// Medium line, e.g. "Photogrammetry scan, spatial audio, 3 min loop".
    public var medium: String?
    /// Physical or nominal dimensions, e.g. "Life size" or "1200 × 450 × 450 mm".
    public var dimensions: String?
    /// Statement or interpretive text. Kept short on device; full in the catalogue.
    public var statement: String?
    /// Plain-language description for blind and low-vision players (VoiceOver).
    public var altText: String?
    /// Bundle path of a recorded audio description.
    public var audioDescription: String?
    public var extra: Extras = [:]

    public init(title: String? = nil, artist: String? = nil, year: String? = nil, medium: String? = nil,
                dimensions: String? = nil, statement: String? = nil, altText: String? = nil) {
        self.title = title; self.artist = artist; self.year = year; self.medium = medium
        self.dimensions = dimensions; self.statement = statement; self.altText = altText
    }

    public var isEmpty: Bool {
        [title, artist, year, medium, dimensions, statement, altText, audioDescription]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static let known: Set<String> = ["title", "artist", "year", "medium", "dimensions", "statement", "altText", "audioDescription"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = try c.decodeOptional("title")
        artist = try c.decodeOptional("artist")
        year = try c.decodeOptional("year")
        medium = try c.decodeOptional("medium")
        dimensions = try c.decodeOptional("dimensions")
        statement = try c.decodeOptional("statement")
        altText = try c.decodeOptional("altText")
        audioDescription = try c.decodeOptional("audioDescription")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.putIfPresent(title, "title")
        try c.putIfPresent(artist, "artist")
        try c.putIfPresent(year, "year")
        try c.putIfPresent(medium, "medium")
        try c.putIfPresent(dimensions, "dimensions")
        try c.putIfPresent(statement, "statement")
        try c.putIfPresent(altText, "altText")
        try c.putIfPresent(audioDescription, "audioDescription")
    }
}

/// Where an asset came from and on what terms. Students routinely build on
/// downloaded models, scans and sounds; recording this makes attribution
/// part of the workflow rather than an afterthought.
public struct Credit: Codable, Hashable, Sendable {
    public var creator: String?
    /// Where it came from: "Own work", "Sketchfab", "Freesound", "NCAD scan rig", a URL.
    public var source: String?
    /// SPDX-style id where one exists: "CC-BY-4.0", "CC0-1.0", "All-rights-reserved", "Own-work".
    public var licence: String?
    public var url: String?
    public var notes: String?
    public var extra: Extras = [:]

    public init(creator: String? = nil, source: String? = nil, licence: String? = nil, url: String? = nil) {
        self.creator = creator; self.source = source; self.licence = licence; self.url = url
    }

    /// Licences that require attribution when the work is shown.
    public var requiresAttribution: Bool {
        guard let l = licence?.uppercased() else { return true }
        return l.hasPrefix("CC-BY")
    }

    /// Licences under which the asset may not be shared further, or which
    /// forbid commercial use. Flagged in the catalogue and validator.
    public var restrictions: [String] {
        guard let l = licence?.uppercased() else { return ["Licence unknown"] }
        var out: [String] = []
        if l.contains("-NC") { out.append("Non-commercial only") }
        if l.contains("-ND") { out.append("No derivatives") }
        if l == "ALL-RIGHTS-RESERVED" { out.append("All rights reserved: permission needed to show") }
        return out
    }

    static let known: Set<String> = ["creator", "source", "licence", "url", "notes"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        creator = try c.decodeOptional("creator")
        source = try c.decodeOptional("source")
        licence = try c.decodeOptional("licence")
        url = try c.decodeOptional("url")
        notes = try c.decodeOptional("notes")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.putIfPresent(creator, "creator")
        try c.putIfPresent(source, "source")
        try c.putIfPresent(licence, "licence")
        try c.putIfPresent(url, "url")
        try c.putIfPresent(notes, "notes")
    }
}

/// An alternative asset for an element: a colourway, material, finish,
/// iteration or alternate state. Lets product designers compare CMF options
/// in context, and artists stage a work that changes.
public struct Variant: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var asset: String
    /// Why this option exists: the design rationale shown in crit.
    public var note: String?
    public var extra: Extras = [:]

    public init(id: String, name: String, asset: String, note: String? = nil) {
        self.id = id; self.name = name; self.asset = asset; self.note = note
    }

    static let known: Set<String> = ["id", "name", "asset", "note"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode("id")
        name = try c.decode("name", default: "")
        asset = try c.decode("asset")
        note = try c.decodeOptional("note")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(asset, "asset")
        try c.putIfPresent(note, "note")
    }
}

/// The real-world size the author intends, in metres. With `lockScale` on,
/// pinch-to-scale is disabled and the inspector shows true dimensions:
/// the product sits in the room at 1:1.
public struct DesignSize: Codable, Hashable, Sendable {
    public var widthM: Double
    public var heightM: Double
    public var depthM: Double
    public var lockScale: Bool
    public var extra: Extras = [:]

    public init(widthM: Double, heightM: Double, depthM: Double, lockScale: Bool = true) {
        self.widthM = widthM; self.heightM = heightM; self.depthM = depthM; self.lockScale = lockScale
    }

    /// Uniform scale that makes an asset with the given native bounding box
    /// match this size. Uses the largest axis so nothing is distorted.
    public func uniformScale(forNativeSize native: Vec3) -> Double? {
        let pairs = [(widthM, native.x), (heightM, native.y), (depthM, native.z)].filter { $0.1 > 0 && $0.0 > 0 }
        guard let largest = pairs.max(by: { $0.1 < $1.1 }) else { return nil }
        return largest.0 / largest.1
    }

    /// "1200 × 450 × 450 mm"
    public var formattedMillimetres: String {
        func mm(_ m: Double) -> String { String(Int((m * 1000).rounded())) }
        return "\(mm(widthM)) × \(mm(heightM)) × \(mm(depthM)) mm"
    }

    static let known: Set<String> = ["widthM", "heightM", "depthM", "lockScale"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        widthM = try c.decode("widthM")
        heightM = try c.decode("heightM")
        depthM = try c.decode("depthM")
        lockScale = try c.decode("lockScale", default: true)
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(widthM, "widthM")
        try c.put(heightM, "heightM")
        try c.put(depthM, "depthM")
        try c.put(lockScale, "lockScale")
    }
}

/// Spatial critique: a note pinned in space, near an element. Lecturers and
/// peers open a student's bundle, leave notes where they stand, and hand the
/// file back — crit without a server.
public struct CritNote: Codable, Hashable, Sendable, Identifiable {
    public struct Kind: OpenEnum {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let question = Kind(rawValue: "question")
        public static let suggestion = Kind(rawValue: "suggestion")
        public static let strength = Kind(rawValue: "strength")
        public static let issue = Kind(rawValue: "issue")
        public static let known: [Kind] = [.question, .suggestion, .strength, .issue]
    }

    public var id: String
    public var author: String
    public var kind: Kind
    public var text: String
    public var created: String
    /// Element the note is about; nil means the experience as a whole.
    public var elementId: String?
    /// Offset from the element's origin, so the note floats where it was left.
    public var offset: Vec3?
    public var resolved: Bool
    /// Author's reply when resolving.
    public var reply: String?
    public var extra: Extras = [:]

    public init(id: String = UUID().uuidString, author: String, kind: Kind, text: String,
                created: Date = Date(), elementId: String? = nil, offset: Vec3? = nil) {
        self.id = id; self.author = author; self.kind = kind; self.text = text
        self.created = ISO8601.string(from: created); self.elementId = elementId
        self.offset = offset; self.resolved = false
    }

    static let known: Set<String> = ["id", "author", "kind", "text", "created", "elementId", "offset", "resolved", "reply"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode("id")
        author = try c.decode("author", default: "")
        kind = try c.decode("kind", default: .suggestion)
        text = try c.decode("text", default: "")
        created = try c.decode("created", default: "")
        elementId = try c.decodeOptional("elementId")
        offset = try c.decodeOptional("offset")
        resolved = try c.decode("resolved", default: false)
        reply = try c.decodeOptional("reply")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(id, "id")
        try c.put(author, "author")
        try c.put(kind, "kind")
        try c.put(text, "text")
        try c.put(created, "created")
        try c.putIfPresent(elementId, "elementId")
        try c.putIfPresent(offset, "offset")
        try c.put(resolved, "resolved")
        try c.putIfPresent(reply, "reply")
    }
}
