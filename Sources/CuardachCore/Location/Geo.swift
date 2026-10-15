import Foundation

/// A WGS84 latitude/longitude in degrees.
public struct Coordinate: Codable, Hashable, Sendable {
    public var lat: Double
    public var long: Double

    public init(lat: Double, long: Double) { self.lat = lat; self.long = long }

    public var isValid: Bool {
        lat.isFinite && long.isFinite && (-90...90).contains(lat) && (-180...180).contains(long)
    }
}

public enum Geo {
    public static let earthRadiusM = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = (b.lat - a.lat) * .pi / 180
        let dλ = (b.long - a.long) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadiusM * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north, 0..<360.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dλ = (b.long - a.long) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return normalizeDegrees(atan2(y, x) * 180 / .pi)
    }

    /// The angle an on-screen arrow should point, relative to the direction
    /// the device faces. 0 = straight ahead, 90 = to the right.
    public static func relativeBearing(from a: Coordinate, to b: Coordinate, deviceHeading: Double) -> Double {
        normalizeDegrees(bearing(from: a, to: b) - deviceHeading)
    }

    public static func normalizeDegrees(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Moves a coordinate by metres east and north. Accurate to centimetres
    /// over the few hundred metres a site spans.
    public static func offset(_ c: Coordinate, eastM: Double, northM: Double) -> Coordinate {
        let dLat = northM / earthRadiusM * 180 / .pi
        let dLong = eastM / (earthRadiusM * cos(c.lat * .pi / 180)) * 180 / .pi
        return Coordinate(lat: c.lat + dLat, long: c.long + dLong)
    }

    /// A circle containing every coordinate: centroid plus the farthest
    /// distance from it. Not minimal, but stable and good enough for a map
    /// overview (PRD L9).
    public static func enclosingCircle(_ coords: [Coordinate], minimumRadiusM: Double = 30)
        -> (center: Coordinate, radiusM: Double)?
    {
        let valid = coords.filter(\.isValid)
        guard !valid.isEmpty else { return nil }
        // Average on the unit sphere so sites straddling ±180° still work.
        var x = 0.0, y = 0.0, z = 0.0
        for c in valid {
            let φ = c.lat * .pi / 180, λ = c.long * .pi / 180
            x += cos(φ) * cos(λ); y += cos(φ) * sin(λ); z += sin(φ)
        }
        let n = Double(valid.count)
        x /= n; y /= n; z /= n
        let center = Coordinate(lat: atan2(z, (x * x + y * y).squareRoot()) * 180 / .pi,
                                long: atan2(y, x) * 180 / .pi)
        let r = valid.map { distance(center, $0) }.max() ?? 0
        return (center, max(minimumRadiusM, (r * 1.15).rounded(.up)))
    }
}

/// What the player HUD shows on the way to an element (PRD P4).
public enum ApproachGuidance: Equatable, Sendable {
    /// Far away: arrow plus distance.
    case navigate(distanceM: Double, relativeBearing: Double)
    /// Close enough that the anchor should resolve: prompt to look around.
    case lookAround(distanceM: Double)
    /// No location for this element: only a marker or scan will find it.
    case noLocation

    public static let lookAroundRadiusM = 15.0

    public static func make(player: Coordinate?, heading: Double?, target: Coordinate?) -> ApproachGuidance {
        guard let target else { return .noLocation }
        guard let player else { return .navigate(distanceM: .infinity, relativeBearing: 0) }
        let d = Geo.distance(player, target)
        if d <= lookAroundRadiusM { return .lookAround(distanceM: d) }
        let rel = Geo.relativeBearing(from: player, to: target, deviceHeading: heading ?? 0)
        return .navigate(distanceM: d, relativeBearing: rel)
    }

    /// Distances phrased for a player: "8 m", "240 m", "1.3 km".
    public static func format(distanceM d: Double) -> String {
        guard d.isFinite else { return "–" }
        if d < 1000 { return "\(Int(d.rounded())) m" }
        return String(format: "%.1f km", d / 1000)
    }
}

/// Detects sustained walking from speed samples so the player can show a
/// "look up" banner (PRD P12, C8). Speed comes from CoreMotion pedometer
/// cadence or CoreLocation; this type only decides.
public struct WalkingDetector: Sendable {
    public var thresholdMps: Double
    public var sustainS: Double
    public var releaseS: Double

    public private(set) var isWalking = false
    private var aboveSince: Double?
    private var belowSince: Double?

    public init(thresholdMps: Double = 0.7, sustainS: Double = 2.5, releaseS: Double = 2) {
        self.thresholdMps = thresholdMps; self.sustainS = sustainS; self.releaseS = releaseS
    }

    /// Feed a speed sample (m/s) at time `t` (seconds). Returns `isWalking`.
    @discardableResult
    public mutating func update(speedMps: Double, at t: Double) -> Bool {
        if speedMps >= thresholdMps {
            belowSince = nil
            if aboveSince == nil { aboveSince = t }
            if let s = aboveSince, t - s >= sustainS { isWalking = true }
        } else {
            aboveSince = nil
            if belowSince == nil { belowSince = t }
            if let s = belowSince, t - s >= releaseS { isWalking = false }
        }
        return isWalking
    }
}
