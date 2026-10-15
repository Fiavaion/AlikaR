import Foundation

/// A lossless JSON value. Used to carry manifest keys this version of the app
/// does not understand, so that opening and re-saving a bundle written by a
/// newer version never drops data (PRD S6).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A coding key built from any string, so manifest types can read every key
/// present in an object and keep the ones they do not model.
public struct AnyKey: CodingKey, Hashable, ExpressibleByStringLiteral, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }

    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
    public init(stringLiteral value: String) { stringValue = value }
}

/// Keys this build does not model, kept verbatim and written back on save.
public typealias Extras = [String: JSONValue]

extension KeyedDecodingContainer where Key == AnyKey {
    /// Every key in this object that is not in `known`, decoded losslessly.
    func extras(known: Set<String>) throws -> Extras {
        var out: Extras = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return out
    }

    func decode<T: Decodable>(_ key: String, default value: T) throws -> T {
        try decodeIfPresent(T.self, forKey: AnyKey(key)) ?? value
    }

    func decode<T: Decodable>(_ key: String) throws -> T {
        try decode(T.self, forKey: AnyKey(key))
    }

    func decodeOptional<T: Decodable>(_ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: AnyKey(key))
    }
}

extension KeyedEncodingContainer where Key == AnyKey {
    mutating func encodeExtras(_ extras: Extras) throws {
        for (k, v) in extras {
            try encode(v, forKey: AnyKey(k))
        }
    }

    mutating func put<T: Encodable>(_ value: T, _ key: String) throws {
        try encode(value, forKey: AnyKey(key))
    }

    mutating func putIfPresent<T: Encodable>(_ value: T?, _ key: String) throws {
        try encodeIfPresent(value, forKey: AnyKey(key))
    }

    /// Writes an array only when it is non-empty, keeping manifests readable.
    mutating func putIfNotEmpty<T: Encodable>(_ value: [T], _ key: String) throws {
        if !value.isEmpty { try encode(value, forKey: AnyKey(key)) }
    }
}

/// An open string enumeration: known values are static constants, unknown
/// values from newer manifests survive a round trip instead of failing decode.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
    static var known: [Self] { get }
}

extension OpenEnum {
    public var isKnown: Bool { Self.known.contains(self) }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
