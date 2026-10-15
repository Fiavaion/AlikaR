import Foundation

/// CRC-32 (IEEE 802.3), as used by ZIP.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public private(set) var value: UInt32 = 0
    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var s = state
        let t = Self.table
        for b in bytes { s = t[Int((s ^ UInt32(b)) & 0xFF)] ^ (s >> 8) }
        state = s
        value = s ^ 0xFFFF_FFFF
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}
