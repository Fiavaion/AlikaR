import Foundation

/// A 3-component vector in metres (position) or unitless factors (scale).
/// Encoded as a JSON array `[x, y, z]`, matching manifest v1.
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let one = Vec3(1, 1, 1)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        z = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }

    public func distance(to other: Vec3) -> Double { (self - other).length }
}

/// A unit quaternion `[x, y, z, w]`.
public struct Quat: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    public static let identity = Quat(0, 0, 0, 1)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        z = try c.decode(Double.self)
        w = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z); try c.encode(w)
    }

    public var normalized: Quat {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        guard n > 0 else { return .identity }
        return Quat(x / n, y / n, z / n, w / n)
    }

    /// Builds a rotation from Euler angles in degrees, applied yaw (Y), then
    /// pitch (X), then roll (Z) — the order the inspector presents them in.
    public init(eulerDegrees e: EulerAngles) {
        let p = e.pitch * .pi / 360, y = e.yaw * .pi / 360, r = e.roll * .pi / 360
        let cp = cos(p), sp = sin(p), cy = cos(y), sy = sin(y), cr = cos(r), sr = sin(r)
        // q = qYaw * qPitch * qRoll
        self.init(
            cy * sp * cr + sy * cp * sr,
            sy * cp * cr - cy * sp * sr,
            cy * cp * sr - sy * sp * cr,
            cy * cp * cr + sy * sp * sr
        )
    }

    /// Inverse of `init(eulerDegrees:)`.
    public var eulerDegrees: EulerAngles {
        let q = normalized
        // Rotation matrix terms for the Y-X-Z convention.
        let sinPitch = 2 * (q.w * q.x - q.y * q.z)
        let pitch: Double
        let yaw: Double
        let roll: Double
        if abs(sinPitch) >= 0.999999 {
            // Gimbal lock: fold roll into yaw.
            pitch = copysign(.pi / 2, sinPitch)
            yaw = atan2(-2 * (q.x * q.z - q.w * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
            roll = 0
        } else {
            pitch = asin(sinPitch)
            yaw = atan2(2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y))
            roll = atan2(2 * (q.x * q.y + q.w * q.z), 1 - 2 * (q.x * q.x + q.z * q.z))
        }
        let d = 180 / Double.pi
        return EulerAngles(pitch: pitch * d, yaw: yaw * d, roll: roll * d)
    }
}

/// Human-facing rotation in degrees for the numeric inspector (PRD A7).
public struct EulerAngles: Hashable, Sendable {
    public var pitch: Double
    public var yaw: Double
    public var roll: Double

    public init(pitch: Double, yaw: Double, roll: Double) {
        self.pitch = pitch; self.yaw = yaw; self.roll = roll
    }
}

/// An element's placement relative to its anchor.
public struct Transform: Codable, Hashable, Sendable {
    public var position: Vec3
    public var rotation: Quat
    public var scale: Vec3

    public init(position: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = .one) {
        self.position = position; self.rotation = rotation; self.scale = scale
    }

    public static let identity = Transform()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        position = try c.decode("position", default: .zero)
        rotation = try c.decode("rotation", default: .identity)
        scale = try c.decode("scale", default: .one)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(position, "position")
        try c.put(rotation, "rotation")
        try c.put(scale, "scale")
    }
}

/// A column-major 4×4 matrix (ARKit `simd_float4x4` flattened), stored as 16
/// numbers. Used for an anchor's transform inside a saved world map.
public struct Matrix4: Codable, Hashable, Sendable {
    public var values: [Double]

    public init(_ values: [Double]) { self.values = values }

    public static let identity = Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    /// The PRD example writes `[]` as a placeholder; anything but 16 numbers is
    /// flagged by the validator rather than rejected at decode.
    public var isValid: Bool { values.count == 16 && values.allSatisfy(\.isFinite) }

    public var translation: Vec3? {
        guard isValid else { return nil }
        return Vec3(values[12], values[13], values[14])
    }

    public init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([Double].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}
