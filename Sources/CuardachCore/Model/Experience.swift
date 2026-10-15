import Foundation

public struct ElementKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let model = ElementKind(rawValue: "model")
    public static let video = ElementKind(rawValue: "video")
    public static let image = ElementKind(rawValue: "image")
    public static let audio = ElementKind(rawValue: "audio")
    /// Gaussian splat (.ply / .spz). Rendered on iOS 27+; post-MVP import.
    public static let splat = ElementKind(rawValue: "splat")
    /// Studio extension: a floating text panel (titles, poems, instructions).
    public static let text = ElementKind(rawValue: "text")

    public static let known: [ElementKind] = [.model, .video, .image, .audio, .splat, .text]
}

/// How an element's media plays (PRD A8, A9).
public struct Playback: Codable, Hashable, Sendable {
    /// Animation clip to play by default; nil means the first clip.
    public var clip: String?
    public var loop: Bool
    public var speed: Double
    public var muted: Bool
    /// Hex colour to key out of video ("#00FF00"). Post-MVP rendering.
    public var chromaKey: String?
    public var chromaTolerance: Double?
    /// Spatial audio: distance in metres at which the sound is at full volume.
    public var audioFalloffM: Double?
    public var extra: Extras = [:]

    public init(clip: String? = nil, loop: Bool = true, speed: Double = 1, muted: Bool = false) {
        self.clip = clip; self.loop = loop; self.speed = speed; self.muted = muted
    }

    static let known: Set<String> = ["clip", "loop", "speed", "muted", "chromaKey", "chromaTolerance", "audioFalloffM"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        clip = try c.decodeOptional("clip")
        loop = try c.decode("loop", default: true)
        speed = try c.decode("speed", default: 1)
        muted = try c.decode("muted", default: false)
        chromaKey = try c.decodeOptional("chromaKey")
        chromaTolerance = try c.decodeOptional("chromaTolerance")
        audioFalloffM = try c.decodeOptional("audioFalloffM")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.putIfPresent(clip, "clip")
        try c.put(loop, "loop")
        try c.put(speed, "speed")
        try c.put(muted, "muted")
        try c.putIfPresent(chromaKey, "chromaKey")
        try c.putIfPresent(chromaTolerance, "chromaTolerance")
        try c.putIfPresent(audioFalloffM, "audioFalloffM")
    }
}

/// Built-in element states. Any other string is a custom state for the
/// future game layer.
public enum ElementState {
    public static let hidden = "hidden"
    public static let visible = "visible"
    public static let found = "found"
}

/// One piece of content placed in the world.
public struct Element: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ElementKind
    /// Path inside the bundle, e.g. "assets/heron.usdz". Text elements have none.
    public var asset: String?
    public var transform: Transform
    public var anchors: [Anchor]
    public var behaviours: [Behaviour]
    /// Initial state. "hidden" starts invisible until a show action.
    public var state: String?
    public var playback: Playback?
    /// Turn to face the viewer on the Y axis (billboard), PRD A7.
    public var faceViewer: Bool

    // Studio extensions
    public var label: WallLabel?
    public var credit: Credit?
    public var variants: [Variant]
    public var designSize: DesignSize?
    /// Text elements: the text to render.
    public var text: String?

    public var extra: Extras = [:]

    public init(id: String = UUID().uuidString, name: String, kind: ElementKind, asset: String?,
                transform: Transform = .identity) {
        self.id = id; self.name = name; self.kind = kind; self.asset = asset
        self.transform = transform; self.anchors = []; self.behaviours = []
        self.faceViewer = false; self.variants = []
    }

    public var startsHidden: Bool { state == ElementState.hidden }

    /// The best precision this element can achieve, from the anchors it has.
    public var precision: Precision? {
        anchors.filter(\.tier.isKnown).map(\.tier.precision).min()
    }

    /// Anchors in the order a player should try them (PRD P5).
    public var anchorsInResolutionOrder: [Anchor] {
        anchors.sorted { ($0.priority, $0.tier.defaultRank, $0.id) < ($1.priority, $1.tier.defaultRank, $1.id) }
    }

    /// Every bundle path this element depends on.
    public var referencedFiles: [String] {
        var files = [asset].compactMap { $0 }
        files += anchors.flatMap(\.referencedFiles)
        files += variants.map(\.asset)
        files += behaviours.flatMap { $0.actions.flatMap { $0.compactMap(\.asset) } }
        if let ad = label?.audioDescription { files.append(ad) }
        return files
    }

    static let known: Set<String> = [
        "id", "name", "kind", "asset", "transform", "anchors", "behaviours", "state", "playback",
        "faceViewer", "label", "credit", "variants", "designSize", "text",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode("id")
        name = try c.decode("name", default: "")
        kind = try c.decode("kind")
        asset = try c.decodeOptional("asset")
        transform = try c.decode("transform", default: .identity)
        anchors = try c.decode("anchors", default: [])
        behaviours = try c.decode("behaviours", default: [])
        state = try c.decodeOptional("state")
        playback = try c.decodeOptional("playback")
        faceViewer = try c.decode("faceViewer", default: false)
        label = try c.decodeOptional("label")
        credit = try c.decodeOptional("credit")
        variants = try c.decode("variants", default: [])
        designSize = try c.decodeOptional("designSize")
        text = try c.decodeOptional("text")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(kind, "kind")
        try c.putIfPresent(asset, "asset")
        try c.put(transform, "transform")
        try c.put(anchors, "anchors")
        try c.put(behaviours, "behaviours")
        try c.putIfPresent(state, "state")
        try c.putIfPresent(playback, "playback")
        if faceViewer { try c.put(faceViewer, "faceViewer") }
        try c.putIfPresent(label, "label")
        try c.putIfPresent(credit, "credit")
        try c.putIfNotEmpty(variants, "variants")
        try c.putIfPresent(designSize, "designSize")
        try c.putIfPresent(text, "text")
    }
}

/// Where the experience happens, for the overview map (PRD L9).
public struct SiteHint: Codable, Hashable, Sendable {
    public var lat: Double
    public var long: Double
    public var radiusM: Double
    public var extra: Extras = [:]

    public init(lat: Double, long: Double, radiusM: Double) {
        self.lat = lat; self.long = long; self.radiusM = radiusM
    }

    public var coordinate: Coordinate { Coordinate(lat: lat, long: long) }

    static let known: Set<String> = ["lat", "long", "radiusM"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lat = try c.decode("lat")
        long = try c.decode("long")
        radiusM = try c.decode("radiusM", default: 50)
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(lat, "lat")
        try c.put(long, "long")
        try c.put(radiusM, "radiusM")
    }
}

/// The root of a bundle's manifest.json.
public struct Experience: Codable, Hashable, Sendable, Identifiable {
    /// The newest schema this build writes. Older manifests are migrated on
    /// read; newer ones open read-only with their unknown keys intact.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var author: String
    public var created: String
    public var elements: [Element]
    public var siteHint: SiteHint?
    /// Bundle path of the cover image.
    public var cover: String?

    // Studio extensions
    /// The experience's statement and credits, as on a gallery wall.
    public var label: WallLabel?
    /// Spatial critique notes left by lecturers and peers.
    public var annotations: [CritNote]
    /// Message shown when a player has found every element (game layer hook).
    public var completionMessage: String?

    public var extra: Extras = [:]

    public init(id: String = UUID().uuidString, title: String, author: String, created: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id; self.title = title; self.author = author
        self.created = ISO8601.string(from: created)
        self.elements = []; self.annotations = []
    }

    public func element(id: String) -> Element? { elements.first { $0.id == id } }

    public var allReferencedFiles: [String] {
        var files = elements.flatMap(\.referencedFiles)
        if let cover { files.append(cover) }
        if let ad = label?.audioDescription { files.append(ad) }
        return files
    }

    /// Recomputes the site hint from every located anchor (PRD L9).
    public mutating func refreshSiteHint(minimumRadiusM: Double = 30) {
        let coords = elements.flatMap(\.anchors).compactMap(\.coordinate)
        siteHint = Geo.enclosingCircle(coords, minimumRadiusM: minimumRadiusM)
            .map { SiteHint(lat: $0.center.lat, long: $0.center.long, radiusM: $0.radiusM) }
    }

    static let known: Set<String> = [
        "schemaVersion", "id", "title", "author", "created", "elements", "siteHint", "cover",
        "label", "annotations", "completionMessage",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        schemaVersion = try c.decode("schemaVersion")
        id = try c.decode("id")
        title = try c.decode("title", default: "Untitled")
        author = try c.decode("author", default: "")
        created = try c.decode("created", default: "")
        elements = try c.decode("elements", default: [])
        siteHint = try c.decodeOptional("siteHint")
        cover = try c.decodeOptional("cover")
        label = try c.decodeOptional("label")
        annotations = try c.decode("annotations", default: [])
        completionMessage = try c.decodeOptional("completionMessage")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(schemaVersion, "schemaVersion")
        try c.put(id, "id")
        try c.put(title, "title")
        try c.put(author, "author")
        try c.put(created, "created")
        try c.put(elements, "elements")
        try c.putIfPresent(siteHint, "siteHint")
        try c.putIfPresent(cover, "cover")
        try c.putIfPresent(label, "label")
        try c.putIfNotEmpty(annotations, "annotations")
        try c.putIfPresent(completionMessage, "completionMessage")
    }
}
