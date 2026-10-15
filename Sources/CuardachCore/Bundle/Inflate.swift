import Foundation
#if canImport(Compression)
import Compression
#endif

public enum InflateError: Error, Equatable {
    case truncated
    case invalidBlockType
    case invalidStoredLength
    case invalidHuffmanCode
    case invalidDistance
    case sizeMismatch
}

/// Raw DEFLATE (RFC 1951) decoding for ZIP method 8. Bundles written by
/// Cuardach are stored uncompressed, but bundles zipped by Finder, `zip` or
/// other tools are deflated, and must open everywhere, including Linux CI.
public enum Inflate {
    public static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        if expectedSize > 0, let out = systemDecompress(input, expectedSize: expectedSize) {
            return out
        }
        #endif
        let out = try decompressPortable(input)
        guard out.count == expectedSize else { throw InflateError.sizeMismatch }
        return out
    }

    #if canImport(Compression)
    private static func systemDecompress(_ input: Data, expectedSize: Int) -> Data? {
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }
    #endif

    /// Pure-Swift decoder after Mark Adler's `puff`: small and auditable.
    public static func decompressPortable(_ input: Data) throws -> Data {
        var s = State(input: [UInt8](input))
        var last = false
        repeat {
            last = try s.bits(1) == 1
            switch try s.bits(2) {
            case 0: try s.stored()
            case 1: try s.codes(lengths: Fixed.lengths, distances: Fixed.distances)
            case 2:
                let (l, d) = try s.dynamicTables()
                try s.codes(lengths: l, distances: d)
            default: throw InflateError.invalidBlockType
            }
        } while !last
        return Data(s.output)
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
                if left < 0 { throw InflateError.invalidHuffmanCode }  // over-subscribed
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    enum Fixed {
        static let lengths: Huffman = {
            var l = [Int](repeating: 8, count: 288)
            for i in 144..<256 { l[i] = 9 }
            for i in 256..<280 { l[i] = 7 }
            return try! Huffman(lengths: l)
        }()
        static let distances: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 30))
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    struct State {
        let input: [UInt8]
        var pos = 0
        var bitBuf = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(input: [UInt8]) {
            self.input = input
            output.reserveCapacity(input.count * 3)
        }

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuf
            while bitCount < need {
                guard pos < input.count else { throw InflateError.truncated }
                val |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            bitBuf = val >> need
            bitCount -= need
            return val & ((1 << need) - 1)
        }

        mutating func stored() throws {
            bitBuf = 0
            bitCount = 0
            guard pos + 4 <= input.count else { throw InflateError.truncated }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            pos += 4
            guard len == (~nlen & 0xFFFF) else { throw InflateError.invalidStoredLength }
            guard pos + len <= input.count else { throw InflateError.truncated }
            output.append(contentsOf: input[pos..<(pos + len)])
            pos += len
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.invalidHuffmanCode
        }

        mutating func codes(lengths: Huffman, distances: Huffman) throws {
            while true {
                var sym = try decode(lengths)
                if sym < 256 {
                    output.append(UInt8(sym))
                } else if sym == 256 {
                    return
                } else {
                    sym -= 257
                    guard sym < 29 else { throw InflateError.invalidHuffmanCode }
                    let len = Inflate.lengthBase[sym] + (try bits(Inflate.lengthExtra[sym]))
                    let dsym = try decode(distances)
                    guard dsym < 30 else { throw InflateError.invalidDistance }
                    let dist = Inflate.distBase[dsym] + (try bits(Inflate.distExtra[dsym]))
                    guard dist <= output.count else { throw InflateError.invalidDistance }
                    let start = output.count - dist
                    for i in 0..<len { output.append(output[start + i]) }
                }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let nlen = try bits(5) + 257
            let ndist = try bits(5) + 1
            let ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw InflateError.invalidHuffmanCode }
            var cl = [Int](repeating: 0, count: 19)
            for i in 0..<ncode { cl[Inflate.codeLengthOrder[i]] = try bits(3) }
            let clh = try Huffman(lengths: cl)
            var lengths: [Int] = []
            lengths.reserveCapacity(nlen + ndist)
            while lengths.count < nlen + ndist {
                let sym = try decode(clh)
                switch sym {
                case 0..<16:
                    lengths.append(sym)
                case 16:
                    guard let prev = lengths.last else { throw InflateError.invalidHuffmanCode }
                    lengths += [Int](repeating: prev, count: 3 + (try bits(2)))
                case 17:
                    lengths += [Int](repeating: 0, count: 3 + (try bits(3)))
                default:
                    lengths += [Int](repeating: 0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == nlen + ndist, lengths[256] != 0 else { throw InflateError.invalidHuffmanCode }
            return (try Huffman(lengths: Array(lengths[0..<nlen])),
                    try Huffman(lengths: Array(lengths[nlen...])))
        }
    }
}
