import Foundation

public enum ZipError: Error, Equatable, CustomStringConvertible {
    case notAZip
    case zip64Unsupported
    case unsupportedMethod(UInt16, path: String)
    case encrypted(path: String)
    case corrupt(String)
    case checksumMismatch(path: String)
    case unsafePath(String)
    case tooLarge(path: String)

    public var description: String {
        switch self {
        case .notAZip: "The file is not a zip archive."
        case .zip64Unsupported: "The archive is larger than 4 GB, which is not supported."
        case .unsupportedMethod(let m, let p): "\(p) uses compression method \(m), which is not supported."
        case .encrypted(let p): "\(p) is encrypted."
        case .corrupt(let why): "The archive is damaged: \(why)."
        case .checksumMismatch(let p): "\(p) is damaged (checksum mismatch)."
        case .unsafePath(let p): "The archive contains an unsafe path: \(p)."
        case .tooLarge(let p): "\(p) is larger than 4 GB."
        }
    }
}

/// Validates an archive entry name and turns it into safe relative path
/// components: no absolute paths, no `..`, no drive letters (zip slip).
public enum SafePath {
    public static func components(_ raw: String) throws -> [String] {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        guard !unified.hasPrefix("/"), !unified.contains(":") else { throw ZipError.unsafePath(raw) }
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw ZipError.unsafePath(raw) }
        for p in parts where p == ".." || p == "." || p.contains("\0") {
            throw ZipError.unsafePath(raw)
        }
        return parts
    }

    /// Resolves a bundle-relative path under `root`, refusing escapes.
    public static func resolve(_ relative: String, under root: URL) throws -> URL {
        try components(relative).reduce(root) { $0.appendingPathComponent($1) }
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func le16(at o: Int) -> UInt16 {
        UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }

    func le32(at o: Int) -> UInt32 {
        UInt32(le16(at: o)) | UInt32(le16(at: o + 2)) << 16
    }
}

/// Writes a ZIP archive with stored (uncompressed) entries. Bundle contents
/// — USDZ, HEVC, PNG, world maps — are already compressed, so storing them
/// costs little and keeps the writer simple and streaming.
public final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private let date: Date
    private var finished = false

    public init(url: URL, date: Date = Date()) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.date = date
    }

    deinit { try? handle.close() }

    public func add(data: Data, path: String) throws {
        _ = try SafePath.components(path)
        try writeEntry(path: path, size: data.count, crc: CRC32.checksum(data)) {
            try handle.write(contentsOf: data)
        }
    }

    /// Streams a file into the archive in 1 MB chunks: one pass for the
    /// checksum, one to copy, so large assets never sit in memory.
    public func add(file: URL, path: String) throws {
        _ = try SafePath.components(path)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        var crc = CRC32()
        try Self.chunks(of: file) { crc.update($0) }
        try writeEntry(path: path, size: size, crc: crc.value) {
            try Self.chunks(of: file) { try handle.write(contentsOf: $0) }
        }
    }

    private static func chunks(of file: URL, _ body: (Data) throws -> Void) throws {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            try body(chunk)
        }
    }

    private func writeEntry(path: String, size: Int, crc: UInt32, body: () throws -> Void) throws {
        precondition(!finished, "ZipWriter used after finish()")
        guard size < Int(UInt32.max), offset < UInt64(UInt32.max) else { throw ZipError.tooLarge(path: path) }
        let name = Data(path.utf8)
        let (t, d) = Self.dos(date)
        var h = Data()
        h.le32(0x0403_4B50)
        h.le16(20)          // version needed
        h.le16(0x0800)      // UTF-8 names
        h.le16(0)           // stored
        h.le16(t); h.le16(d)
        h.le32(crc)
        h.le32(UInt32(size)); h.le32(UInt32(size))
        h.le16(UInt16(name.count)); h.le16(0)
        h.append(name)
        try handle.write(contentsOf: h)
        try body()
        entries.append(Entry(name: name, crc: crc, size: UInt32(size), offset: UInt32(offset), dosTime: t, dosDate: d))
        offset += UInt64(h.count) + UInt64(size)
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        guard entries.count < 0xFFFF, offset < UInt64(UInt32.max) else { throw ZipError.zip64Unsupported }
        var cd = Data()
        for e in entries {
            cd.le32(0x0201_4B50)
            cd.le16(0x0314)     // made by: Unix, spec 2.0
            cd.le16(20)
            cd.le16(0x0800)
            cd.le16(0)
            cd.le16(e.dosTime); cd.le16(e.dosDate)
            cd.le32(e.crc)
            cd.le32(e.size); cd.le32(e.size)
            cd.le16(UInt16(e.name.count))
            cd.le16(0); cd.le16(0)  // extra, comment
            cd.le16(0); cd.le16(0)  // disk, internal attrs
            cd.le32(0o100644 << 16) // -rw-r--r--
            cd.le32(e.offset)
            cd.append(e.name)
        }
        var end = Data()
        end.le32(0x0605_4B50)
        end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(cd.count))
        end.le32(UInt32(offset))
        end.le16(0)
        try handle.write(contentsOf: cd + end)
        try handle.close()
    }

    static func dos(_ date: Date) -> (time: UInt16, date: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, c.year ?? 1980)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        let d: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: t), UInt16(truncatingIfNeeded: d))
    }
}

/// One file in a ZIP archive's central directory.
public struct ZipEntry: Sendable, Hashable {
    public let path: String
    public let method: UInt16
    public let flags: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int

    public var isDirectory: Bool { path.hasSuffix("/") }
}

/// Reads ZIP archives (stored and deflated entries, no ZIP64, no encryption).
/// The file is memory-mapped, so only the entries actually read are paged in.
public final class ZipReader {
    public let entries: [ZipEntry]
    private let data: Data

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    public func entry(_ path: String) -> ZipEntry? { entries.first { $0.path == path } }

    public func contents(of e: ZipEntry) throws -> Data {
        guard e.flags & 0x1 == 0 else { throw ZipError.encrypted(path: e.path) }
        let lh = e.localHeaderOffset
        guard lh + 30 <= data.count, data.le32(at: lh) == 0x0403_4B50 else {
            throw ZipError.corrupt("missing local header for \(e.path)")
        }
        let start = lh + 30 + Int(data.le16(at: lh + 26)) + Int(data.le16(at: lh + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("\(e.path) runs past the end") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        let out: Data
        switch e.method {
        case 0: out = raw
        case 8:
            do { out = try Inflate.decompress(raw, expectedSize: e.uncompressedSize) } catch {
                throw ZipError.corrupt("\(e.path) could not be decompressed")
            }
        default: throw ZipError.unsupportedMethod(e.method, path: e.path)
        }
        guard out.count == e.uncompressedSize, CRC32.checksum(out) == e.crc32 else {
            throw ZipError.checksumMismatch(path: e.path)
        }
        return out
    }

    private static func readCentralDirectory(_ d: Data) throws -> [ZipEntry] {
        guard d.count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record sits in the last 64 KiB + 22 bytes.
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 0xFFFF)
        while i >= floor {
            if d.le32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(d.le16(at: eocd + 10))
        let cdSize = Int(d.le32(at: eocd + 12))
        let cdOffset = Int(d.le32(at: eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
        guard cdOffset + cdSize <= eocd else { throw ZipError.corrupt("central directory out of range") }

        var out: [ZipEntry] = []
        out.reserveCapacity(count)
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= d.count, d.le32(at: p) == 0x0201_4B50 else {
                throw ZipError.corrupt("bad central directory entry")
            }
            let flags = d.le16(at: p + 8)
            let method = d.le16(at: p + 10)
            let crc = d.le32(at: p + 16)
            let csize = d.le32(at: p + 20)
            let usize = d.le32(at: p + 24)
            let nameLen = Int(d.le16(at: p + 28))
            let extraLen = Int(d.le16(at: p + 30))
            let commentLen = Int(d.le16(at: p + 32))
            let offset = d.le32(at: p + 42)
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                throw ZipError.zip64Unsupported
            }
            guard p + 46 + nameLen <= d.count else { throw ZipError.corrupt("name runs past the end") }
            let nameData = d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            out.append(ZipEntry(path: name, method: method, flags: flags, crc32: crc,
                                compressedSize: Int(csize), uncompressedSize: Int(usize),
                                localHeaderOffset: Int(offset)))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }
}
