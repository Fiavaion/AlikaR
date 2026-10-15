import Foundation

/// What this device can do, checked once when a session starts.
public struct AnchorCapabilities: Sendable, Equatable {
    /// `ARGeoTrackingConfiguration.isSupported` and `checkAvailability(at:)` passed.
    public var geoTracking: Bool
    /// iOS 27 object tracking available.
    public var objectTracking: Bool

    public init(geoTracking: Bool, objectTracking: Bool) {
        self.geoTracking = geoTracking; self.objectTracking = objectTracking
    }

    public func supports(_ tier: AnchorTier) -> Bool {
        switch tier {
        case .geo: geoTracking
        case .object: objectTracking
        case .worldmap, .image, .gps: true
        default: false
        }
    }
}

/// How one element is currently placed in the player's world.
public enum ElementResolution: Sendable, Equatable {
    case searching
    case resolved(anchorId: String, tier: AnchorTier)
    /// No precise anchor resolved; content sits on the nearest plane (PRD P6).
    case onNearestPlane

    public var precision: Precision? {
        switch self {
        case .searching: nil
        case .resolved(_, let tier): tier.precision
        case .onNearestPlane: .approximate
        }
    }

    public var isPlaced: Bool { self != .searching }
}

public enum ResolverEvent: Sendable, Equatable {
    /// Place (or move) the element using this anchor. Sent again when a
    /// better anchor resolves later, so content silently snaps to it.
    case place(elementId: String, anchorId: String, tier: AnchorTier)
    /// Fall back to the nearest detected plane in front of the player.
    case placeOnNearestPlane(elementId: String)
    /// The anchor that placed this element is gone and nothing replaces it.
    case unplace(elementId: String)
    /// A world map has been matching for too long: suggest another angle.
    case relocalisationSlow(mapFile: String)
}

/// Anchors the AR layer should arm right now.
public struct ResolutionPlan: Sendable, Equatable {
    public var geo: [Anchor] = []
    public var images: [Anchor] = []
    public var objects: [Anchor] = []
    /// ARKit relocalises against one world map at a time.
    public var worldMap: String?
}

/// Chooses, for every element, the best anchor that has resolved, walking
/// each element's anchors in priority order (PRD P5, P6). Pure and
/// time-injected like `BehaviourEngine`.
public struct AnchorResolver: Sendable {
    public static let relocalisationTimeoutS = 30.0

    public let capabilities: AnchorCapabilities
    public private(set) var activeWorldMap: String?

    private let elements: [Element]
    private var resolvedAnchors: Set<String> = []
    private var current: [String: ElementResolution] = [:]
    private var relocalisingSince: Double?
    private var slowHintSent = false
    private var insideRadiusSince: [String: Double] = [:]

    public init(experience: Experience, capabilities: AnchorCapabilities) {
        self.capabilities = capabilities
        self.elements = experience.elements
        for e in elements { current[e.id] = .searching }
    }

    public func resolution(of elementId: String) -> ElementResolution { current[elementId] ?? .searching }

    /// Usable anchors for an element in resolution order.
    public func candidates(for element: Element) -> [Anchor] {
        element.anchorsInResolutionOrder.filter { capabilities.supports($0.tier) }
    }

    /// Anchors to arm. Picks the world map nearest the player, else the map
    /// used by most unresolved elements (PRD L8).
    public func plan(player: Coordinate?) -> ResolutionPlan {
        var p = ResolutionPlan()
        var maps: [String: (count: Int, coordinate: Coordinate?)] = [:]
        for e in elements {
            for a in candidates(for: e) {
                switch a.tier {
                case .geo: p.geo.append(a)
                case .image: p.images.append(a)
                case .object: p.objects.append(a)
                case .worldmap:
                    guard let f = a.mapFile, !resolvedAnchors.contains(a.id) else { continue }
                    let prev = maps[f]
                    maps[f] = ((prev?.count ?? 0) + 1, prev?.coordinate ?? a.coordinate)
                default: break
                }
            }
        }
        if let active = activeWorldMap {
            p.worldMap = active
        } else if let player, let nearest = maps.compactMap({ k, v in v.coordinate.map { (k, Geo.distance(player, $0)) } })
            .min(by: { ($0.1, $0.0) < ($1.1, $1.0) }) {
            p.worldMap = nearest.0
        } else {
            p.worldMap = maps.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
        }
        return p
    }

    /// The AR layer started relocalising against a world map.
    public mutating func beginRelocalising(mapFile: String, at t: Double) -> [ResolverEvent] {
        var out: [ResolverEvent] = []
        if let old = activeWorldMap, old != mapFile {
            // A new map means a new coordinate space: content placed by the old
            // map's anchors must re-resolve.
            let oldIds = Set(elements.flatMap(\.anchors).filter { $0.tier == .worldmap && $0.mapFile == old }.map(\.id))
            out += invalidate(oldIds)
        }
        activeWorldMap = mapFile
        relocalisingSince = t
        slowHintSent = false
        return out
    }

    /// The session relocalised against `mapFile`: its anchors are now live.
    public mutating func relocalised(mapFile: String, at t: Double) -> [ResolverEvent] {
        relocalisingSince = nil
        let ids = elements.flatMap(\.anchors).filter { $0.tier == .worldmap && $0.mapFile == mapFile }.map(\.id)
        return ids.flatMap { anchorResolved($0) }
    }

    /// A geo, image or object anchor was detected.
    public mutating func anchorResolved(_ anchorId: String) -> [ResolverEvent] {
        resolvedAnchors.insert(anchorId)
        return reevaluate()
    }

    /// Anchors that no longer hold (e.g. the AR session was reset).
    public mutating func invalidate(_ anchorIds: Set<String>) -> [ResolverEvent] {
        resolvedAnchors.subtract(anchorIds)
        return reevaluate()
    }

    /// Timeouts and GPS fallback. Call about once a second.
    public mutating func update(at t: Double, player: Coordinate?) -> [ResolverEvent] {
        var out: [ResolverEvent] = []
        if let since = relocalisingSince, let map = activeWorldMap, !slowHintSent,
           t - since >= Self.relocalisationTimeoutS {
            slowHintSent = true
            out.append(.relocalisationSlow(mapFile: map))
        }
        for e in elements where current[e.id] == .searching {
            guard let gps = candidates(for: e).first(where: { $0.tier == .gps && $0.allowPlaneFallback == true }),
                  let target = gps.coordinate, let player else {
                insideRadiusSince[e.id] = nil
                continue
            }
            let inside = Geo.distance(player, target) <= (gps.radiusM ?? 15)
            if !inside { insideRadiusSince[e.id] = nil; continue }
            let since = insideRadiusSince[e.id] ?? t
            insideRadiusSince[e.id] = since
            // Give precise anchors a fair chance first, unless GPS is all there is.
            let onlyGps = candidates(for: e).allSatisfy { $0.tier == .gps }
            if onlyGps || t - since >= Self.relocalisationTimeoutS {
                current[e.id] = .onNearestPlane
                out.append(.placeOnNearestPlane(elementId: e.id))
            }
        }
        return out
    }

    private mutating func reevaluate() -> [ResolverEvent] {
        var out: [ResolverEvent] = []
        for e in elements {
            let best = candidates(for: e).first { $0.tier != .gps && resolvedAnchors.contains($0.id) }
            let before = current[e.id] ?? .searching
            if let best {
                let next = ElementResolution.resolved(anchorId: best.id, tier: best.tier)
                if next != before {
                    current[e.id] = next
                    out.append(.place(elementId: e.id, anchorId: best.id, tier: best.tier))
                }
            } else if case .resolved = before {
                current[e.id] = .searching
                out.append(.unplace(elementId: e.id))
            }
        }
        return out
    }
}

extension Element {
    /// Where this element is on a map: the first located anchor in
    /// resolution order (geo coordinates are the most accurate).
    public var coordinate: Coordinate? {
        anchorsInResolutionOrder.lazy.compactMap(\.coordinate).first
    }
}

extension Experience {
    /// The nearest element not yet found that has a location (PRD P3, P4).
    public func nearestUnfound(from player: Coordinate, found: Set<String>) -> (element: Element, distanceM: Double)? {
        elements.filter { !found.contains($0.id) }
            .compactMap { e in e.coordinate.map { (e, Geo.distance(player, $0)) } }
            .min { $0.1 < $1.1 }
    }
}
