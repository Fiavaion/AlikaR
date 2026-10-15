import Foundation

/// The high-contrast pattern printed on a marker (PRD L4). ARKit image
/// detection wants dense, non-repeating, evenly spread features; a seeded
/// random block grid with a solid frame and one orientation notch gives
/// exactly that, and the same element id always yields the same pattern,
/// so a lost poster can be reprinted and still match.
public struct MarkerPattern: Sendable, Equatable {
    public let size: Int
    /// Row-major cells; true is black.
    public let cells: [Bool]

    public subscript(row: Int, col: Int) -> Bool { cells[row * size + col] }

    public init(seed: String, size: Int = 12) {
        precondition(size >= 6, "Marker grids smaller than 6×6 are not distinctive enough")
        self.size = size
        var rng = SplitMix64(seed: Self.fnv1a(seed))
        var c = [Bool](repeating: false, count: size * size)
        for r in 0..<size {
            for col in 0..<size {
                let border = r == 0 || col == 0 || r == size - 1 || col == size - 1
                if border {
                    c[r * size + col] = true
                } else {
                    c[r * size + col] = rng.next() & 1 == 1
                }
            }
        }
        // Orientation notch: a white 2×2 inside the top-left corner and a
        // solid 2×2 in the bottom-right, so the pattern is never symmetric.
        for (r, col) in [(1, 1), (1, 2), (2, 1), (2, 2)] { c[r * size + col] = false }
        for (r, col) in [(size - 3, size - 3), (size - 3, size - 2), (size - 2, size - 3), (size - 2, size - 2)] {
            c[r * size + col] = true
        }
        cells = c
    }

    /// Fraction of black cells inside the frame. ARKit rejects images that
    /// are nearly blank or nearly solid; a healthy marker is 35–65 %.
    public var interiorDensity: Double {
        var black = 0
        for r in 1..<(size - 1) { for col in 1..<(size - 1) where self[r, col] { black += 1 } }
        return Double(black) / Double((size - 2) * (size - 2))
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

/// Small, fast, deterministic PRNG (public domain, Vigna).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
