import Compression
import Foundation

/**
 * Just enough zip for the backup files: writes stored (uncompressed) entries,
 * reads stored and deflated ones through the central directory, so backups
 * made by the Android app (which deflates and uses data descriptors) import too.
 */
public enum Zip {
    public static func write(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            out.append(le32: 0x0403_4b50)
            out.append(le16: 20); out.append(le16: 0x0800); out.append(le16: 0)  // version, flags (UTF-8), stored
            out.append(le16: 0); out.append(le16: 0x21)                          // time, date (1980-01-01)
            out.append(le32: crc); out.append(le32: UInt32(data.count)); out.append(le32: UInt32(data.count))
            out.append(le16: UInt16(nameBytes.count)); out.append(le16: 0)
            out.append(nameBytes); out.append(data)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 20); central.append(le16: 20); central.append(le16: 0x0800); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0x21)
            central.append(le32: crc); central.append(le32: UInt32(data.count)); central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(nameBytes.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0); central.append(le32: 0)
            central.append(le32: offset)
            central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0); out.append(le16: 0)
        out.append(le16: UInt16(files.count)); out.append(le16: UInt16(files.count))
        out.append(le32: UInt32(central.count)); out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    /** Entry name -> contents. Returns nil when [data] isn't a zip. */
    public static func read(_ data: Data) throws -> [String: Data]? {
        let d = [UInt8](data)
        guard d.count >= 22, d.u32(0) == 0x0403_4b50 || d.u32(0) == 0x0605_4b50 else { return nil }
        guard let eocd = stride(from: d.count - 22, through: max(0, d.count - 22 - 65_535), by: -1)
            .first(where: { d.u32($0) == 0x0605_4b50 }) else { throw LoadError("zip has no directory") }
        let entries = Int(d.u16(eocd + 10))
        var p = Int(d.u32(eocd + 16))
        var files: [String: Data] = [:]
        for _ in 0..<entries {
            guard p + 46 <= d.count, d.u32(p) == 0x0201_4b50 else { throw LoadError("bad zip directory") }
            let method = d.u16(p + 10)
            let csize = Int(d.u32(p + 20)), usize = Int(d.u32(p + 24))
            let nlen = Int(d.u16(p + 28)), elen = Int(d.u16(p + 30)), clen = Int(d.u16(p + 32))
            let local = Int(d.u32(p + 42))
            let name = String(decoding: d[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + elen + clen

            guard local + 30 <= d.count else { throw LoadError("bad zip entry \(name)") }
            let start = local + 30 + Int(d.u16(local + 26)) + Int(d.u16(local + 28))
            guard start + csize <= d.count else { throw LoadError("truncated zip entry \(name)") }
            let raw = Data(d[start..<(start + csize)])
            if name.hasSuffix("/") { continue }
            switch method {
            case 0: files[name] = raw
            case 8: files[name] = try inflate(raw, size: usize)
            default: throw LoadError("unsupported zip compression in \(name)")
            }
        }
        return files
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)  // raw deflate, as in zip
            }
        }
        guard n == size else { throw LoadError("could not decompress zip entry") }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

private extension [UInt8] {
    func u16(_ i: Int) -> UInt16 { i + 2 <= count ? UInt16(self[i]) | UInt16(self[i + 1]) << 8 : 0 }
    func u32(_ i: Int) -> UInt32 { i + 4 <= count ? UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 : 0 }
}
