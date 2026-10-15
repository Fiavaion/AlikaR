import Foundation

/// How an element is tied to the physical world. Every element keeps all the
/// anchors its author captured; the player resolves the best one available.
public struct AnchorTier: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// ARGeoAnchor (Apple Location Anchors): sub-metre outdoors on covered streets.
    public static let geo = AnchorTier(rawValue: "geo")
    /// Saved ARWorldMap plus the element's transform inside it.
    public static let worldmap = AnchorTier(rawValue: "worldmap")
    /// A printed, high-contrast marker.
    public static let image = AnchorTier(rawValue: "image")
    /// A trained reference object (iOS 27). Post-MVP.
    public static let object = AnchorTier(rawValue: "object")
    /// Latitude/longitude with a radius: approach guidance only.
    public static let gps = AnchorTier(rawValue: "gps")

    public static let known: [AnchorTier] = [.geo, .worldmap, .image, .object, .gps]

    /// Default resolution order when two anchors share a priority (PRD P5):
    /// geo → image → worldmap → object → gps.
    public var defaultRank: Int {
        switch self {
        case .geo: 0
        case .image: 1
        case .worldmap: 2
        case .object: 3
        case .gps: 4
        default: 99
        }
    }

    /// The precision a player gets once this tier resolves (PRD L6).
    public var precision: Precision {
        switch self {
        case .geo: .streetPrecise
        case .worldmap: .sitePrecise
        case .image: .markerPrecise
        case .object: .objectPrecise
        default: .approximate
        }
    }
}

/// The precision badge shown on every element (PRD L6). Ordered best first.
public enum Precision: Int, Comparable, CaseIterable, Sendable, Codable {
    case markerPrecise = 0
    case objectPrecise
    case sitePrecise
    case streetPrecise
    case approximate

    public static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .streetPrecise: "Street-precise"
        case .sitePrecise: "Site-precise"
        case .markerPrecise: "Marker-precise"
        case .objectPrecise: "Object-precise"
        case .approximate: "Approximate"
        }
    }

    /// One-line explanation shown under the badge.
    public var explanation: String {
        switch self {
        case .streetPrecise:
            "Pinned with Apple Location Anchors: within a metre outdoors, facing the right way."
        case .sitePrecise:
            "Pinned to a scan of this space: centimetre-accurate once a player's device recognises it. Changes in lighting or furniture can stop it matching."
        case .markerPrecise:
            "Pinned to a printed marker: centimetre-accurate whenever the marker is in view. The most reliable option."
        case .objectPrecise:
            "Pinned to a recognised object, such as a sculpture or bench."
        case .approximate:
            "GPS only: players are guided to within 5–15 m, then content appears on the nearest surface."
        }
    }
}

/// One way of locating an element. The tier decides which payload fields
/// are meaningful; unused fields stay nil and are not written.
public struct Anchor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var tier: AnchorTier
    /// Lower resolves first. Ties fall back to `tier.defaultRank`.
    public var priority: Int

    // geo, worldmap, gps
    public var lat: Double?
    public var long: Double?
    // geo
    public var alt: Double?
    public var heading: Double?
    // worldmap
    public var mapFile: String?
    public var anchorTransform: Matrix4?
    public var capturedAt: String?
    /// Reported ARWorldMap mapping status at capture ("mapped", "extending", "limited").
    public var mappingStatus: String?
    // image
    public var imageFile: String?
    public var physicalWidthM: Double?
    // object
    public var referenceObjectFile: String?
    // image, object: element pose relative to the detected anchor
    public var transform: Transform?
    // gps
    public var radiusM: Double?
    /// When true and nothing better resolves, a player inside the radius gets
    /// the content on the nearest detected plane (PRD P6).
    public var allowPlaneFallback: Bool?

    public var extra: Extras = [:]

    public init(id: String, tier: AnchorTier, priority: Int? = nil) {
        self.id = id
        self.tier = tier
        self.priority = priority ?? tier.defaultRank
    }

    /// The anchor's geographic position, if it carries one.
    public var coordinate: Coordinate? {
        guard let lat, let long else { return nil }
        return Coordinate(lat: lat, long: long)
    }

    /// Asset paths inside the bundle that this anchor depends on.
    public var referencedFiles: [String] {
        [mapFile, imageFile, referenceObjectFile].compactMap { $0 }
    }

    static let known: Set<String> = [
        "id", "tier", "priority", "lat", "long", "alt", "heading", "mapFile", "anchorTransform",
        "capturedAt", "mappingStatus", "imageFile", "physicalWidthM", "referenceObjectFile",
        "transform", "radiusM", "allowPlaneFallback",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode("id")
        tier = try c.decode("tier")
        priority = try c.decode("priority", default: tier.defaultRank)
        lat = try c.decodeOptional("lat")
        long = try c.decodeOptional("long")
        alt = try c.decodeOptional("alt")
        heading = try c.decodeOptional("heading")
        mapFile = try c.decodeOptional("mapFile")
        anchorTransform = try c.decodeOptional("anchorTransform")
        capturedAt = try c.decodeOptional("capturedAt")
        mappingStatus = try c.decodeOptional("mappingStatus")
        imageFile = try c.decodeOptional("imageFile")
        physicalWidthM = try c.decodeOptional("physicalWidthM")
        referenceObjectFile = try c.decodeOptional("referenceObjectFile")
        transform = try c.decodeOptional("transform")
        radiusM = try c.decodeOptional("radiusM")
        allowPlaneFallback = try c.decodeOptional("allowPlaneFallback")
        extra = try c.extras(known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtras(extra)
        try c.put(id, "id")
        try c.put(tier, "tier")
        try c.put(priority, "priority")
        try c.putIfPresent(lat, "lat")
        try c.putIfPresent(long, "long")
        try c.putIfPresent(alt, "alt")
        try c.putIfPresent(heading, "heading")
        try c.putIfPresent(mapFile, "mapFile")
        try c.putIfPresent(anchorTransform, "anchorTransform")
        try c.putIfPresent(capturedAt, "capturedAt")
        try c.putIfPresent(mappingStatus, "mappingStatus")
        try c.putIfPresent(imageFile, "imageFile")
        try c.putIfPresent(physicalWidthM, "physicalWidthM")
        try c.putIfPresent(referenceObjectFile, "referenceObjectFile")
        try c.putIfPresent(transform, "transform")
        try c.putIfPresent(radiusM, "radiusM")
        try c.putIfPresent(allowPlaneFallback, "allowPlaneFallback")
    }
}

extension Anchor {
    public static func geo(id: String, lat: Double, long: Double, alt: Double?, heading: Double?) -> Anchor {
        var a = Anchor(id: id, tier: .geo)
        a.lat = lat; a.long = long; a.alt = alt; a.heading = heading
        return a
    }

    public static func worldmap(id: String, mapFile: String, transform: Matrix4, capturedAt: Date,
                                mappingStatus: String?, coordinate: Coordinate?) -> Anchor {
        var a = Anchor(id: id, tier: .worldmap)
        a.mapFile = mapFile
        a.anchorTransform = transform
        a.capturedAt = ISO8601.string(from: capturedAt)
        a.mappingStatus = mappingStatus
        a.lat = coordinate?.lat; a.long = coordinate?.long
        return a
    }

    public static func image(id: String, imageFile: String, physicalWidthM: Double, transform: Transform = .identity) -> Anchor {
        var a = Anchor(id: id, tier: .image)
        a.imageFile = imageFile
        a.physicalWidthM = physicalWidthM
        a.transform = transform
        return a
    }

    public static func gps(id: String, coordinate: Coordinate, radiusM: Double, allowPlaneFallback: Bool) -> Anchor {
        var a = Anchor(id: id, tier: .gps)
        a.lat = coordinate.lat; a.long = coordinate.long
        a.radiusM = radiusM
        a.allowPlaneFallback = allowPlaneFallback
        return a
    }
}

/// ISO 8601 timestamps as plain strings in the manifest, so a manifest written
/// by any tool round-trips byte-for-byte in its date fields.
public enum ISO8601 {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }
}
