import Foundation
import CryptoKit
import ImageIO
import CoreFoundation
import zlib

struct IOSWallpaperError: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

// Foundation 的 JSONSerialization 会折叠重复键；线上 ACK 和元数据先走严格语法闸门。
enum IOSWallpaperJSON {
    static func object(_ data: Data, limit: Int = 16384) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil else {
            throw IOSWallpaperError("invalid_json")
        }
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0); parser.space()
        guard parser.at == parser.bytes.count,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSWallpaperError("invalid_json")
        }
        return value
    }
    static func integer(_ value: Any?, min: Int = 0, max: Int) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= Double(min), number.doubleValue <= Double(max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue < Double(Int.max) else {
            throw IOSWallpaperError("invalid_integer")
        }
        return number.intValue
    }
    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        var peek: UInt8 { at < bytes.count ? bytes[at] : 0 }
        mutating func space() { while [9, 10, 13, 32].contains(peek) { at += 1 } }
        mutating func take(_ value: UInt8) -> Bool {
            guard at < bytes.count, peek == value else { return false }; at += 1; return true
        }
        mutating func require(_ value: UInt8) throws {
            guard take(value) else { throw IOSWallpaperError("invalid_json") }
        }
        mutating func string() throws -> String {
            let start = at; try require(34)
            while at < bytes.count {
                let c = peek; at += 1
                if c == 34 {
                    let part = Data(bytes[start..<at])
                    guard let text = try JSONSerialization.jsonObject(with: part, options: .fragmentsAllowed) as? String else {
                        throw IOSWallpaperError("invalid_json_string")
                    }
                    return text
                }
                guard c >= 32 else { throw IOSWallpaperError("invalid_json_string") }
                if c == 92 {
                    let escape = peek; at += 1
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard at < bytes.count, (48...57).contains(peek) || (65...70).contains(peek) || (97...102).contains(peek) else {
                                throw IOSWallpaperError("invalid_json_escape")
                            }
                            at += 1
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) {
                        throw IOSWallpaperError("invalid_json_escape")
                    }
                }
            }
            throw IOSWallpaperError("invalid_json_string")
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw IOSWallpaperError("json_depth") }
            space()
            if peek == 34 { _ = try string(); return }
            if peek == 123 || peek == 91 {
                let object = take(123)
                if !object { try require(91) }
                let end: UInt8 = object ? 125 : 93
                var keys = Set<String>()
                space(); if take(end) { return }
                while true {
                    space()
                    if object {
                        let key = try string()
                        guard keys.insert(key).inserted else { throw IOSWallpaperError("duplicate_json_key") }
                        space(); try require(58)
                    }
                    try value(depth: depth + 1); space()
                    if take(end) { return }; try require(44)
                }
            }
            for literal in ["true", "false", "null"] {
                let part = Array(literal.utf8)
                if bytes.count - at >= part.count, Array(bytes[at..<(at + part.count)]) == part {
                    at += part.count; return
                }
            }
            _ = take(45)
            if !take(48) {
                guard (49...57).contains(peek) else { throw IOSWallpaperError("invalid_json_number") }
                while (48...57).contains(peek) { at += 1 }
            }
            if take(46) {
                guard (48...57).contains(peek) else { throw IOSWallpaperError("invalid_json_number") }
                while (48...57).contains(peek) { at += 1 }
            }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                guard (48...57).contains(peek) else { throw IOSWallpaperError("invalid_json_number") }
                while (48...57).contains(peek) { at += 1 }
            }
        }
    }
}

// 只处理二进制资产，不接 VIN、配对二维码、审核状态或车辆选择编号。
struct IOSWallpaperSpec {
    let url: URL?
    let fileName: String
    let fileSize: Int?
    let md5: String
    let local: Bool
    let mainWidth: Int
    let mainHeight: Int
    let speedWidth: Int
    let speedHeight: Int

    static func parse(_ text: String, local: Bool) throws -> IOSWallpaperSpec {
        guard text.utf8.count <= 16384 else { throw IOSWallpaperError("metadata_too_large") }
        let object = try IOSWallpaperJSON.object(Data(text.utf8))
        let allowed: Set<String> = local
            ? ["fileName", "mainWidth", "mainHeight", "speedWidth", "speedHeight"]
            : ["url", "fileName", "fileSize", "md5"]
        guard Set(object.keys).isSubset(of: allowed) else { throw IOSWallpaperError("unexpected_asset_metadata") }
        func string(_ key: String) throws -> String {
            guard let value = object[key], !(value is NSNull) else { return "" }
            guard let text = value as? String else { throw IOSWallpaperError("invalid_metadata") }
            return text
        }
        let rawURL = try string("url"), rawName = try string("fileName"), hash = try string("md5").lowercased()
        guard rawName.isEmpty || IOSWallpaperPackage.safeName(rawName),
              hash.isEmpty || hash.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw IOSWallpaperError("invalid_metadata")
        }
        let url: URL? = rawURL.isEmpty ? nil : try IOSWallpaperPackage.allowedURL(rawURL)
        let size: Int?
        if let value = object["fileSize"], !(value is NSNull) {
            size = try IOSWallpaperJSON.integer(value, min: 1, max: IOSWallpaperPackage.maxFile)
        } else { size = nil }
        var mw = 0, mh = 0, sw = 0, sh = 0
        if local {
            guard IOSWallpaperPackage.safeName(rawName) else { throw IOSWallpaperError("invalid_local_metadata") }
            mw = try IOSWallpaperJSON.integer(object["mainWidth"], max: 8192)
            mh = try IOSWallpaperJSON.integer(object["mainHeight"], max: 8192)
            sw = try IOSWallpaperJSON.integer(object["speedWidth"], max: 8192)
            sh = try IOSWallpaperJSON.integer(object["speedHeight"], max: 8192)
            guard (mw == 0) == (mh == 0), (sw == 0) == (sh == 0), mw > 0 || sw > 0,
                  mw * mh <= 16777216, sw * sh <= 16777216 else { throw IOSWallpaperError("invalid_local_slots") }
        } else {
            guard url != nil else { throw IOSWallpaperError("download_url_required") }
        }
        let derived = url?.lastPathComponent ?? ""
        let name = !rawName.isEmpty ? rawName : IOSWallpaperPackage.safeName(derived) ? derived : "asset.zip"
        return IOSWallpaperSpec(url: url, fileName: name, fileSize: size, md5: hash, local: local,
                                mainWidth: mw, mainHeight: mh, speedWidth: sw, speedHeight: sh)
    }
}

struct IOSWallpaperPreparedPackage {
    let file: URL
    let fileName: String
    let size: Int
    let md5: String
}

enum IOSWallpaperPackage {
    static let maxFile = 16 * 1024 * 1024
    static let maxImage = 8 * 1024 * 1024
    static let maxImages = maxFile - 4096
    static let pngPrefix = "data:image/png;base64,"
    static let allowedHosts: Set<String> = ["oss-cfmoto-private.zeehoev.com", "zeeho-user.oss-cn-hangzhou.aliyuncs.com"]

    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name.lowercased().hasSuffix(".zip")
            && !name.hasPrefix(".") && !name.hasSuffix(" ")
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func allowedURL(_ text: String) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 8192, !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), allowedHosts.contains(host),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, !parts.percentEncodedPath.isEmpty,
              !parts.percentEncodedPath.hasPrefix("//"),
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              let url = parts.url else { throw IOSWallpaperError("url_not_allowed") }
        return url
    }

    static func boundedLocal(_ main: String, _ speed: String) -> Bool {
        func estimate(_ value: String) -> Int? {
            if value.isEmpty { return 0 }
            let n = value.utf8.count - pngPrefix.utf8.count
            guard value.hasPrefix(pngPrefix), n > 0, n <= ((maxImage + 2) / 3) * 4, n % 4 == 0 else { return nil }
            let padding = value.hasSuffix("==") ? 2 : value.hasSuffix("=") ? 1 : 0
            let size = n / 4 * 3 - padding
            return size > 0 && size <= maxImage ? size : nil
        }
        guard let a = estimate(main), let b = estimate(speed), a + b > 0, a + b <= maxImages else { return false }
        return true
    }

    static func buildLocal(directory: URL, spec: IOSWallpaperSpec, main: String, speed: String,
                           check: () throws -> Void) throws -> IOSWallpaperPreparedPackage {
        try check()
        guard spec.local, boundedLocal(main, speed), main.isEmpty == (spec.mainWidth == 0),
              speed.isEmpty == (spec.speedWidth == 0) else { throw IOSWallpaperError("invalid_local_slots") }
        func decode(_ text: String, width: Int, height: Int) throws -> Data {
            try check()
            let base64 = String(text.dropFirst(pngPrefix.count))
            guard let image = Data(base64Encoded: base64), !image.isEmpty, image.count <= maxImage,
                  image.base64EncodedString() == base64 else { throw IOSWallpaperError("invalid_base64") }
            let dimensions = try validatePNG(image, check: check)
            guard dimensions.0 == width, dimensions.1 == height else { throw IOSWallpaperError("local_dimensions_mismatch") }
            try validateDecodedImage(image, png: true, check: check)
            return image
        }
        var entries: [(String, Data)] = []
        if !main.isEmpty { entries.append(("2.png", try decode(main, width: spec.mainWidth, height: spec.mainHeight))) }
        if !speed.isEmpty { entries.append(("1.png", try decode(speed, width: spec.speedWidth, height: spec.speedHeight))) }
        guard entries.reduce(0, { $0 + $1.1.count }) <= maxImages else { throw IOSWallpaperError("local_size") }
        let zip = try storedZIP(entries, check: check)
        let file = directory.appendingPathComponent(spec.fileName)
        try check(); try zip.write(to: file, options: .atomic)
        return try validate(file: file, spec: spec, check: check)
    }

    // 只读自己的已封存文件；ZIP/图片不落解压目录，也不执行任何文件内容。
    static func validate(file: URL, spec: IOSWallpaperSpec, check: () throws -> Void) throws -> IOSWallpaperPreparedPackage {
        try check()
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= maxFile, spec.fileSize == nil || spec.fileSize == size else { throw IOSWallpaperError("file_size") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size else { throw IOSWallpaperError("file_changed") }
        var digest = Insecure.MD5()
        var at = 0
        while at < data.count {
            try check(); let end = min(data.count, at + 32768)
            digest.update(data: data.subdata(in: at..<end)); at = end
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard spec.md5.isEmpty || hash == spec.md5 else { throw IOSWallpaperError("md5_mismatch") }
        try validateZIP(data, check: check); try check()
        return IOSWallpaperPreparedPackage(file: file, fileName: spec.fileName, size: size, md5: hash)
    }

    private struct ZIPEntry {
        let name: String, version: Int, flags: Int, method: Int, crc: UInt32, compressed: Int, size: Int, offset: Int
        var body = 0
    }
    private struct Reader {
        let data: Data
        var at: Int
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, at >= 0, at <= data.count, n <= data.count - at else { throw IOSWallpaperError("truncated_container") }
            let result = data.subdata(in: at..<(at + n)); at += n; return result
        }
        mutating func u8() throws -> Int {
            guard at >= 0, at < data.count else { throw IOSWallpaperError("truncated_container") }
            let value = Int(data[at]); at += 1; return value
        }
        mutating func le16() throws -> Int { let b = try bytes(2); return Int(b[0]) | Int(b[1]) << 8 }
        mutating func le32() throws -> UInt32 { let b = try bytes(4); return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24 }
        mutating func be16() throws -> Int { let b = try bytes(2); return Int(b[0]) << 8 | Int(b[1]) }
        mutating func be32() throws -> UInt32 { let b = try bytes(4); return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
        mutating func skip(_ n: Int) throws {
            guard n >= 0, at >= 0, n <= data.count - at else { throw IOSWallpaperError("truncated_container") }; at += n
        }
    }
    private static func slot(_ name: String) -> Int {
        ["1.png", "1.jpg", "1.jpeg"].contains(name) ? 1 : ["2.png", "2.jpg", "2.jpeg"].contains(name) ? 2 : 0
    }
    private static func extra(_ data: Data) throws {
        var r = Reader(data: data, at: 0)
        while r.at < data.count {
            let kind = try r.le16(), n = try r.le16()
            guard kind != 1, kind != 0x7075 else { throw IOSWallpaperError("zip64_or_unicode_extra") }
            try r.skip(n)
        }
    }
    private static func validateZIP(_ data: Data, check: () throws -> Void) throws {
        guard data.count >= 22, data.count <= maxFile else { throw IOSWallpaperError("zip_size") }
        var end: Int?
        for at in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if at & 32767 == 0 { try check() }
            var r = Reader(data: data, at: at)
            if try r.le32() != 0x06054b50 { continue }
            r.at = at + 20
            if at + 22 + (try r.le16()) == data.count { end = at; break }
        }
        guard let eocd = end else { throw IOSWallpaperError("zip_end") }
        var r = Reader(data: data, at: eocd + 4)
        guard try r.le16() == 0, try r.le16() == 0 else { throw IOSWallpaperError("zip_multidisk") }
        let count = try r.le16(), total = try r.le16(), directorySize = Int(try r.le32()), directory = Int(try r.le32())
        guard count >= 1, count <= 2, count == total, directorySize >= 46 * count,
              directory + directorySize == eocd, directory < eocd else { throw IOSWallpaperError("zip_directory") }
        r.at = directory
        var entries: [ZIPEntry] = [], slots = Set<Int>(), totalInflated = 0
        for _ in 0..<count {
            try check()
            guard eocd - r.at >= 46, try r.le32() == 0x02014b50 else { throw IOSWallpaperError("zip_central_header") }
            _ = try r.le16()
            let version = try r.le16(), flags = try r.le16(), method = try r.le16()
            _ = try r.le32()
            let crc = try r.le32(), compressed = Int(try r.le32()), size = Int(try r.le32())
            let nameLength = try r.le16(), extraLength = try r.le16(), commentLength = try r.le16()
            guard try r.le16() == 0 else { throw IOSWallpaperError("zip_disk") }
            _ = try r.le16(); let attributes = try r.le32(), offset = Int(try r.le32())
            let mode = attributes >> 16 & 0xf000
            guard attributes & 0x10 == 0, mode == 0 || mode == 0x8000,
                  version <= 20, flags & ~0x080e == 0, method == 0 || method == 8,
                  method != 0 || flags & 6 == 0,
                  size > 0, size <= maxFile, compressed > 0, compressed <= maxFile,
                  method != 0 || size == compressed, size <= compressed * 200,
                  nameLength + extraLength + commentLength <= eocd - r.at else { throw IOSWallpaperError("zip_metadata") }
            let nameData = try r.bytes(nameLength)
            guard let name = String(data: nameData, encoding: .ascii), slot(name) != 0,
                  slots.insert(slot(name)).inserted else { throw IOSWallpaperError("zip_slot_or_path") }
            try extra(r.bytes(extraLength)); try r.skip(commentLength)
            totalInflated += size
            guard totalInflated <= maxFile * 2 else { throw IOSWallpaperError("zip_expansion") }
            entries.append(ZIPEntry(name: name, version: version, flags: flags, method: method, crc: crc,
                                    compressed: compressed, size: size, offset: offset))
        }
        guard r.at == eocd else { throw IOSWallpaperError("zip_central_tail") }
        entries.sort { $0.offset < $1.offset }
        var expected = 0
        for index in entries.indices {
            try check(); var entry = entries[index]
            let next = index + 1 < entries.count ? entries[index + 1].offset : directory
            guard entry.offset == expected, next <= directory, next - entry.offset >= 30 else { throw IOSWallpaperError("zip_overlap_or_gap") }
            r.at = entry.offset
            guard try r.le32() == 0x04034b50, try r.le16() == entry.version,
                  try r.le16() == entry.flags, try r.le16() == entry.method else { throw IOSWallpaperError("zip_local_header") }
            _ = try r.le32(); let crc = try r.le32(), compressed = Int(try r.le32()), size = Int(try r.le32())
            let nameLength = try r.le16(), extraLength = try r.le16()
            guard nameLength + extraLength <= next - r.at,
                  String(data: try r.bytes(nameLength), encoding: .ascii) == entry.name else { throw IOSWallpaperError("zip_local_name") }
            try extra(r.bytes(extraLength)); entry.body = r.at
            let dataEnd = entry.body + entry.compressed
            guard dataEnd <= next else { throw IOSWallpaperError("zip_data_overlap") }
            if entry.flags & 8 == 0 {
                guard crc == entry.crc, compressed == entry.compressed, size == entry.size, dataEnd == next else {
                    throw IOSWallpaperError("zip_local_metadata")
                }
            } else {
                guard crc == 0 || crc == entry.crc, compressed == 0 || compressed == entry.compressed,
                      size == 0 || size == entry.size, next - dataEnd == 12 || next - dataEnd == 16 else {
                    throw IOSWallpaperError("zip_descriptor_range")
                }
                r.at = dataEnd
                if next - dataEnd == 16, try r.le32() != 0x08074b50 { throw IOSWallpaperError("zip_descriptor_signature") }
                guard try r.le32() == entry.crc, Int(try r.le32()) == entry.compressed,
                      Int(try r.le32()) == entry.size else { throw IOSWallpaperError("zip_descriptor_metadata") }
            }
            let compressedData = data.subdata(in: entry.body..<dataEnd)
            let image = entry.method == 0 ? compressedData : try inflateRaw(compressedData, size: entry.size, check: check)
            guard image.count == entry.size, crc32Of(image) == entry.crc else { throw IOSWallpaperError("zip_crc") }
            if entry.name.hasSuffix(".png") { _ = try validatePNG(image, check: check) }
            else { try validateJPEG(image, check: check) }
            try validateDecodedImage(image, png: entry.name.hasSuffix(".png"), check: check)
            expected = next
        }
    }

    private static func inflateRaw(_ data: Data, size: Int, check: () throws -> Void) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw IOSWallpaperError("inflate_init")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: size + 1)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            try output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                while true {
                    try check()
                    let beforeIn = stream.total_in, beforeOut = stream.total_out
                    let result = inflate(&stream, Z_NO_FLUSH)
                    if result == Z_STREAM_END { break }
                    guard result == Z_OK, stream.avail_out > 0,
                          beforeIn != stream.total_in || beforeOut != stream.total_out else { throw IOSWallpaperError("deflate_stream") }
                }
                guard stream.total_out == uLong(size), stream.total_in == uLong(data.count), stream.avail_in == 0 else {
                    throw IOSWallpaperError("deflate_size_or_trailing")
                }
            }
        }
        output.removeLast(); return output
    }

    static func crc32Of(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    @discardableResult
    static func validatePNG(_ data: Data, check: () throws -> Void) throws -> (Int, Int) {
        var r = Reader(data: data, at: 0)
        guard try r.bytes(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw IOSWallpaperError("png_signature") }
        var ihdr = false, palette = false, idat = false, endedIDAT = false
        var chunks = 0, idatBytes = 0, width = 0, height = 0, color = -1
        while r.at < data.count {
            try check(); chunks += 1
            guard chunks <= 4096, data.count - r.at >= 12 else { throw IOSWallpaperError("png_chunk_range") }
            let n = Int(try r.be32()), type = try r.bytes(4)
            guard n <= maxFile, n <= data.count - r.at - 4,
                  type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(type[2]), let name = String(data: type, encoding: .ascii) else { throw IOSWallpaperError("png_chunk") }
            guard ihdr || name == "IHDR" else { throw IOSWallpaperError("png_first_chunk") }
            if idat && name != "IDAT" { endedIDAT = true }
            let body = try r.bytes(n); var crcData = type; crcData.append(body)
            guard try r.be32() == crc32Of(crcData) else { throw IOSWallpaperError("png_crc") }
            if name == "IHDR" {
                guard !ihdr, n == 13 else { throw IOSWallpaperError("png_ihdr") }
                var header = Reader(data: body, at: 0)
                width = Int(try header.be32()); height = Int(try header.be32())
                let depth = Int(body[8]); color = Int(body[9])
                let depthOK = color == 0 ? [1, 2, 4, 8, 16].contains(depth)
                    : color == 3 ? [1, 2, 4, 8].contains(depth) : [2, 4, 6].contains(color) && [8, 16].contains(depth)
                guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16777216,
                      depthOK, body[10] == 0, body[11] == 0, body[12] <= 1 else { throw IOSWallpaperError("png_dimensions_or_format") }
                ihdr = true
            } else if name == "PLTE" {
                guard !palette, !idat, color != 0, color != 4, n > 0, n <= 768, n % 3 == 0 else { throw IOSWallpaperError("png_palette") }
                palette = true
            } else if name == "IDAT" {
                guard !endedIDAT, color != 3 || palette else { throw IOSWallpaperError("png_idat_order") }
                idat = true; idatBytes += n
            } else if name == "IEND" {
                guard n == 0, idat, idatBytes > 0, r.at == data.count else { throw IOSWallpaperError("png_iend_or_trailing") }
                return (width, height)
            } else if ["acTL", "fcTL", "fdAT"].contains(name) || (65...90).contains(type[0]) {
                throw IOSWallpaperError("png_animation_or_critical_chunk")
            }
        }
        throw IOSWallpaperError("png_missing_iend")
    }

    static func validateJPEG(_ data: Data, check: () throws -> Void) throws {
        var r = Reader(data: data, at: 0)
        guard data.count <= maxFile, try r.be16() == 0xffd8 else { throw IOSWallpaperError("jpeg_signature") }
        var marker = -1, segments = 0, frame = 0, restartInterval = 0
        var components = Set<Int>(), scanned = Set<Int>(), hasScan = false
        while true {
            try check()
            if marker < 0 {
                guard try r.u8() == 255 else { throw IOSWallpaperError("jpeg_marker") }
                repeat { marker = try r.u8() } while marker == 255
            }
            if marker == 0xd9 {
                guard hasScan, scanned.isSuperset(of: components), r.at == data.count else { throw IOSWallpaperError("jpeg_eoi_or_trailing") }
                return
            }
            segments += 1
            guard segments <= 4096, marker != 0, marker != 0xd8, marker != 1,
                  !(0xd0...0xd7).contains(marker) else { throw IOSWallpaperError("jpeg_marker_order") }
            let length = try r.be16() - 2
            guard length >= 0, length <= data.count - r.at else { throw IOSWallpaperError("jpeg_segment_range") }
            if [0xc0, 0xc1, 0xc2].contains(marker) {
                guard frame == 0, length >= 9 else { throw IOSWallpaperError("jpeg_sof") }
                let precision = try r.u8(), height = try r.be16(), width = try r.be16(), count = try r.u8()
                guard precision == 8, height > 0, width > 0, width <= 8192, height <= 8192,
                      width * height <= 16777216, count >= 1, count <= 4, length == 6 + 3 * count else { throw IOSWallpaperError("jpeg_dimensions") }
                for _ in 0..<count {
                    let id = try r.u8(), sampling = try r.u8(), table = try r.u8()
                    guard components.insert(id).inserted, (1...4).contains(sampling >> 4),
                          (1...4).contains(sampling & 15), table <= 3 else { throw IOSWallpaperError("jpeg_components") }
                }
                frame = marker
            } else if marker == 0xda {
                guard frame != 0, length >= 6 else { throw IOSWallpaperError("jpeg_sos") }
                let count = try r.u8(); var ids = Set<Int>()
                guard count >= 1, count <= components.count, length == 4 + 2 * count else { throw IOSWallpaperError("jpeg_scan_components") }
                for _ in 0..<count {
                    let id = try r.u8(), table = try r.u8()
                    guard components.contains(id), ids.insert(id).inserted, table >> 4 <= 3, table & 15 <= 3 else { throw IOSWallpaperError("jpeg_scan_tables") }
                }
                let first = try r.u8(), last = try r.u8(), approximation = try r.u8()
                guard first <= last, last <= 63, approximation >> 4 <= 13, approximation & 15 <= 13,
                      frame == 0xc2 || (first == 0 && last == 63 && approximation == 0),
                      frame != 0xc2 || (first == 0 ? last == 0 : count == 1) else { throw IOSWallpaperError("jpeg_scan_format") }
                scanned.formUnion(ids); hasScan = true
                var entropy = 0, restarts = 0
                while true {
                    if r.at & 32767 == 0 { try check() }
                    let value = try r.u8()
                    if value != 255 { entropy += 1; continue }
                    var fill = 0, next: Int
                    repeat { next = try r.u8(); fill += 1 } while next == 255 && fill <= 65536
                    guard fill <= 65536 else { throw IOSWallpaperError("jpeg_fill") }
                    if next == 0 {
                        guard fill == 1 else { throw IOSWallpaperError("jpeg_stuffing") }; entropy += 1; continue
                    }
                    if (0xd0...0xd7).contains(next) {
                        guard restartInterval > 0, entropy > 0, next == 0xd0 + (restarts & 7), restarts < 65536 else {
                            throw IOSWallpaperError("jpeg_restart")
                        }
                        restarts += 1; entropy = 0; continue
                    }
                    guard entropy > 0 else { throw IOSWallpaperError("jpeg_empty_scan") }; marker = next; break
                }
                continue
            } else if marker == 0xdd {
                guard length == 2 else { throw IOSWallpaperError("jpeg_dri") }; restartInterval = try r.be16()
            } else if [0xc4, 0xdb, 0xfe].contains(marker) || (0xe0...0xef).contains(marker) {
                guard ![0xc4, 0xdb].contains(marker) || length > 0 else { throw IOSWallpaperError("jpeg_tables") }
                try r.skip(length)
            } else { throw IOSWallpaperError("jpeg_unsupported_marker") }
            marker = -1
        }
    }

    private static func validateDecodedImage(_ data: Data, png: Bool, check: () throws -> Void) throws {
        try check()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetType(source) as String? == (png ? "public.png" : "public.jpeg"),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              image.width * image.height <= 16777216 else { throw IOSWallpaperError("invalid_single_image") }
        try check()
    }

    private static func storedZIP(_ entries: [(String, Data)], check: () throws -> Void) throws -> Data {
        var output = Data(), central = Data()
        for (name, image) in entries {
            try check()
            let bytes = Data(name.utf8), crc = crc32Of(image), offset = output.count
            output.le32(0x04034b50); output.le16(20); output.le16(0); output.le16(0)
            output.le16(0); output.le16(0x2821) // 2000-01-01：确定性时间，不泄露选图时间。
            output.le32(crc); output.le32(UInt32(image.count)); output.le32(UInt32(image.count))
            output.le16(bytes.count); output.le16(0); output.append(bytes); output.append(image)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0x2821); central.le32(crc)
            central.le32(UInt32(image.count)); central.le32(UInt32(image.count)); central.le16(bytes.count)
            central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset)); central.append(bytes)
        }
        let directory = output.count
        output.append(central); output.le32(0x06054b50); output.le16(0); output.le16(0)
        output.le16(entries.count); output.le16(entries.count); output.le32(UInt32(central.count)); output.le32(UInt32(directory)); output.le16(0)
        guard output.count <= maxFile else { throw IOSWallpaperError("local_zip_size") }; return output
    }
}

private extension Data {
    mutating func le16(_ n: Int) { append(UInt8(truncatingIfNeeded: n)); append(UInt8(truncatingIfNeeded: n >> 8)) }
    mutating func le32(_ n: UInt32) {
        for shift in [0, 8, 16, 24] { append(UInt8(truncatingIfNeeded: n >> shift)) }
    }
}
