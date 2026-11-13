import Foundation
import Network
import Security
import CoreFoundation
import Darwin

// 通用有界帧配方执行器；私有接收端端口、opcode、握手字段与档位由可信网页提交。
// 本文件同时编入 App 与 Broadcast target；不依赖桥、账号、VIN 或 KMP 模块。
enum IOSCastError: Error, LocalizedError {
    case reason(String)
    var code: String { switch self { case let .reason(code): return code } }
    var errorDescription: String? { code }
    static func code(_ error: Error) -> String { (error as? IOSCastError)?.code ?? "cast_internal_error" }
    static func network(_ error: NWError) -> String {
        if case let .posix(code) = error, code == .EACCES || code == .EPERM { return "local_network_permission_denied" }
        return "cast_socket_failed"
    }
}

enum IOSCastWire {
    static let controlMax = 262144
    // ReplayKit extension 的内存预算比 Android 小；编码输出和队列另有总字节上限。
    static let frameMax = 2 * 1024 * 1024
    static let aud = Data([0, 0, 0, 1, 9, 0x10])
    static let startCode = Data([0, 0, 0, 1])

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func json(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw IOSCastError.reason("cast_bad_json") }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSCastError.reason("cast_bad_json")
        }
        return object
    }

    struct Control {
        let type: UInt32
        let body: Data
    }
    struct Media {
        let command: UInt16
        let serial: UInt32 // 按位回填，不能把负序号截成 0。
        let body: Data
    }
    static func control(_ type: UInt32, body: Data = Data()) throws -> Data {
        let length = body.count + 16
        guard length <= controlMax else { throw IOSCastError.reason("control_frame_invalid") }
        var out = Data()
        append32(type, to: &out); append32(UInt32(length), to: &out)
        append32(type ^ UInt32(length), to: &out); append32(0, to: &out)
        out.append(body)
        return out
    }
    static func controlLength(_ header: Data) throws -> Int {
        guard header.count == 16 else { throw IOSCastError.reason("control_frame_truncated") }
        let length = Int(u32(header, 4))
        guard (16...controlMax).contains(length), u32(header, 8) == (u32(header, 0) ^ UInt32(length)),
              u32(header, 12) == 0 else { throw IOSCastError.reason("control_frame_invalid") }
        return length - 16
    }
    static func media(_ command: UInt16, serial: UInt32, body: Data = Data()) throws -> Data {
        guard body.count <= 65535 else { throw IOSCastError.reason("media_frame_invalid") }
        var out = Data()
        append16(command, to: &out); append16(UInt16(body.count), to: &out)
        append32(serial, to: &out); out.append(body)
        return out
    }
    static func packet(_ frame: Data?, index: UInt32, extended: Bool) throws -> Data {
        guard let frame = frame, !frame.isEmpty else { return Data([0, 0, 0, 0]) }
        guard frame.count <= frameMax else { throw IOSCastError.reason("encoded_frame_too_large") }
        var out = Data()
        append32(UInt32(frame.count + (extended ? 4 : 0)), to: &out)
        if extended { append32(index, to: &out) }
        out.append(frame)
        return out
    }

    // 优先完整验证 AVCC，避免把 256..511 字节的 NAL 长度误当三字节起始码。
    static func annexB(_ input: Data, lengthBytes: Int = 4, allowAnnexB: Bool = true) throws -> Data {
        guard !input.isEmpty, input.count <= frameMax, (1...4).contains(lengthBytes) else {
            throw IOSCastError.reason("h264_frame_invalid")
        }
        var parts: [Range<Int>] = []
        var offset = 0
        while offset + lengthBytes <= input.count {
            var length = 0
            for i in 0..<lengthBytes { length = (length << 8) | Int(input[input.startIndex + offset + i]) }
            offset += lengthBytes
            guard length > 0, length <= input.count - offset else { break }
            parts.append(offset..<(offset + length)); offset += length
        }
        if offset == input.count, !parts.isEmpty,
           parts.reduce(0, { $0 + $1.count + lengthBytes }) == input.count {
            var out = Data()
            for part in parts { out.append(startCode); out.append(input.subdata(in: part)) }
            guard out.count <= frameMax else { throw IOSCastError.reason("encoded_frame_too_large") }
            return out
        }
        if allowAnnexB, startsAnnexB(input), !nalTypes(input).isEmpty { return input }
        throw IOSCastError.reason("h264_frame_invalid")
    }
    static func startsAnnexB(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0 && data[data.startIndex + 1] == 0 &&
            (data[data.startIndex + 2] == 1 || (data[data.startIndex + 2] == 0 && data[data.startIndex + 3] == 1))
    }
    static func nalTypes(_ data: Data) -> Set<UInt8> {
        var types: Set<UInt8> = []
        var i = 0
        while i + 3 < data.count {
            let base = data.startIndex
            if data[base + i] == 0, data[base + i + 1] == 0 {
                var header = 0
                if data[base + i + 2] == 1 { header = 3 }
                else if i + 4 < data.count, data[base + i + 2] == 0, data[base + i + 3] == 1 { header = 4 }
                if header > 0, i + header < data.count {
                    types.insert(data[base + i + header] & 0x1f); i += header; continue
                }
            }
            i += 1
        }
        return types
    }
    static func accessUnit(_ bytes: Data, sps: Data, pps: Data) throws -> (Data, Bool) {
        let types = nalTypes(bytes)
        guard !types.isEmpty else { throw IOSCastError.reason("h264_frame_invalid") }
        let idr = types.contains(5)
        var out = types.contains(9) ? Data() : aud
        if idr {
            guard (types.contains(7) || !sps.isEmpty), (types.contains(8) || !pps.isEmpty) else {
                throw IOSCastError.reason("h264_parameter_sets_missing")
            }
            if !types.contains(7) { out.append(sps) }
            if !types.contains(8) { out.append(pps) }
        }
        out.append(bytes)
        guard out.count <= frameMax else { throw IOSCastError.reason("encoded_frame_too_large") }
        return (out, idr)
    }
}

struct IOSCastSettings: Codable {
    var tier = ""
    var extended = false
    // 硬件输入/输出按 extension 的有限内存限制；不让网页抬高负载。
    var maxWidth = 1920
    var maxHeight = 1088
    var maxFPS = 60
    var maxBitrate = 8000000

    var valid: Bool {
        tier.utf8.count <= 64 && (16...1920).contains(maxWidth) && (16...1088).contains(maxHeight)
            && (1...60).contains(maxFPS) && (256000...8000000).contains(maxBitrate)
    }
    static func from(_ object: [String: Any]) throws -> IOSCastSettings {
        var settings = IOSCastSettings()
        if let source = object["captureSource"] as? String, source != "screen" {
            throw IOSCastError.reason("capture_source_unsupported")
        }
        if let format = object["frameFormat"] as? String {
            guard ["traditional", "extended"].contains(format) else { throw IOSCastError.reason("unsupported_frame_format") }
            settings.extended = format == "extended"
        }
        if let tier = object["tier"] as? String {
            guard !tier.isEmpty, tier.utf8.count <= 64 else { throw IOSCastError.reason("cast_tier_invalid") }
            settings.tier = tier
        }
        for key in ["width", "height", "fps", "bitrate"] {
            guard let value = object[key] else { continue }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue == Double(n.intValue), n.intValue > 0 else {
                throw IOSCastError.reason("cast_settings_invalid")
            }
            switch key {
            case "width": guard n.intValue >= 16 else { throw IOSCastError.reason("cast_settings_invalid") }; settings.maxWidth = min(1920, n.intValue)
            case "height": guard n.intValue >= 16 else { throw IOSCastError.reason("cast_settings_invalid") }; settings.maxHeight = min(1088, n.intValue)
            case "fps": settings.maxFPS = min(60, n.intValue)
            default: guard n.intValue >= 256000 else { throw IOSCastError.reason("cast_settings_invalid") }; settings.maxBitrate = min(8000000, n.intValue)
            }
        }
        return settings
    }
}

struct IOSCastCapture: Codable {
    var width: Int
    var height: Int
    var fps: Int
    var codec: UInt32
    var bitrate: Int
    var extended: Bool
}

// 配方只描述固定的帧读写/JSON echo/RSA raw-sign/编码配置动作，不执行代码、URL或无限循环。
// 三个 listener role 唯一；probe 与 listener 总共至多四个私网端口；全部输入解码再验证。
struct IOSCastRecipe: Codable {
    struct Ports: Codable { let data: UInt16; let media: UInt16; let control: UInt16; let probe: UInt16
        var listeners: [UInt16] { [data, media, control] }
    }
    struct Probe: Codable { let requestType: UInt32; let responseType: UInt32; let requestJSON: String; let statusKey: String }
    struct Reply: Codable { let type: UInt32; let json: String? }
    struct Rule: Codable {
        let request: UInt32
        let action: String
        let inputKeys: [String]?
        let defaults: [String: String]?
        let replies: [Reply]
    }
    struct MediaRule: Codable {
        let request: UInt16
        let action: String
        let reply: UInt16?
        let bodyBase64: String?
    }
    struct Capture: Codable {
        let minBytes: Int
        let widthOffset: Int; let heightOffset: Int; let fpsOffset: Int
        let codecOffset: Int; let bitrateOffset: Int; let extendedOffset: Int
        let zeroCodec: UInt32
    }
    struct Ack: Codable {
        let size: Int
        let codecOffset: Int; let widthOffset: Int; let heightOffset: Int; let extendedOffset: Int
    }
    struct Tier: Codable {
        let id: String
        let fps: Int
        let bitrate: Int
        let requestedBitrate: Bool
        let widthLimit: Int
        let heightLimit: Int
        let maxMacroblocks: Int
        let compatibilityFPS: Bool
        let level: String
    }
    let version: Int
    let ports: Ports
    let probe: Probe
    let control: [Rule]
    let media: [MediaRule]
    let capture: Capture
    let captureAck: Ack
    let fallback: IOSCastCapture
    let tiers: [Tier]
    let pullCommand: UInt16

    static func from(_ value: Any?) throws -> IOSCastRecipe {
        guard let value = value, JSONSerialization.isValidJSONObject(value) else { throw IOSCastError.reason("cast_recipe_required") }
        let bytes = try JSONSerialization.data(withJSONObject: value)
        guard bytes.count <= 32768 else { throw IOSCastError.reason("cast_recipe_too_large") }
        let recipe = try JSONDecoder().decode(Self.self, from: bytes)
        try recipe.validate()
        return recipe
    }
    func validate() throws {
        func require(_ value: Bool) throws { if !value { throw IOSCastError.reason("cast_recipe_invalid") } }
        func key(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        func template(_ text: String) -> Bool {
            guard text.utf8.count <= 4096, let bytes = text.data(using: .utf8),
                  let object = try? IOSCastWire.object(bytes) else { return false }
            func scan(_ value: Any, depth: Int) -> Bool {
                guard depth <= 4 else { return false }
                if let dict = value as? [String: Any] {
                    let sensitive = ["vin", "account", "accountid", "credential", "password", "pwd", "accesstoken", "refreshtoken", "authorization"]
                    return dict.count <= 32 && dict.allSatisfy { field, value in
                        guard key(field), !sensitive.contains(field.lowercased()) else { return false }
                        if field.lowercased() == "token" { return (value as? NSNumber)?.intValue == 0 }
                        return scan(value, depth: depth + 1)
                    }
                }
                if let text = value as? String { return text.utf8.count <= 512 && !text.contains("://") }
                return value is NSNumber || value is NSNull
            }
            return scan(object, depth: 0)
        }
        try require(version == 1 && Set(ports.listeners + [ports.probe]).count == 4 &&
                    (ports.listeners + [ports.probe]).allSatisfy { $0 >= 1024 })
        try require(control.count <= 32 && media.count <= 32 && Set(control.map { $0.request }).count == control.count &&
                    Set(media.map { $0.request }).count == media.count)
        try require(template(probe.requestJSON) && key(probe.statusKey))
        for rule in control {
            try require(["reply", "rsa", "echo", "ignore"].contains(rule.action) && rule.replies.count <= 2)
            try require(rule.action == "ignore" ? rule.replies.isEmpty : !rule.replies.isEmpty)
            try require((rule.inputKeys ?? []).count <= 4 && (rule.inputKeys ?? []).allSatisfy(key))
            try require((rule.defaults ?? [:]).count <= 8 && (rule.defaults ?? [:]).allSatisfy { key($0.key) && $0.value.utf8.count <= 128 })
            if rule.action == "rsa" { try require(!(rule.inputKeys ?? []).isEmpty) }
            for reply in rule.replies { if let json = reply.json { try require(template(json)) } }
        }
        for rule in media {
            try require(["configure", "start", "reply", "keyframe", "ignore"].contains(rule.action))
            if rule.action != "ignore" { try require(rule.reply != nil) }
            if let base64 = rule.bodyBase64 { try require(base64.utf8.count <= 8192 && (Data(base64Encoded: base64)?.count ?? 65536) <= 4096) }
        }
        try require(media.filter { $0.action == "configure" }.count == 1 && media.filter { $0.action == "start" }.count == 1)
        func fits(_ offset: Int, _ bytes: Int, _ total: Int) -> Bool { offset >= 0 && offset <= total - bytes }
        try require((1...256).contains(capture.minBytes) && fits(capture.widthOffset, 2, capture.minBytes) &&
                    fits(capture.heightOffset, 2, capture.minBytes) && fits(capture.fpsOffset, 4, capture.minBytes) &&
                    fits(capture.codecOffset, 4, capture.minBytes) && fits(capture.bitrateOffset, 4, capture.minBytes) &&
                    fits(capture.extendedOffset, 1, capture.minBytes))
        try require((1...256).contains(captureAck.size) && fits(captureAck.widthOffset, 2, captureAck.size) &&
                    fits(captureAck.heightOffset, 2, captureAck.size) && fits(captureAck.codecOffset, 4, captureAck.size) &&
                    fits(captureAck.extendedOffset, 1, captureAck.size))
        let ackRanges = [captureAck.codecOffset..<(captureAck.codecOffset + 4), captureAck.widthOffset..<(captureAck.widthOffset + 2),
                         captureAck.heightOffset..<(captureAck.heightOffset + 2), captureAck.extendedOffset..<(captureAck.extendedOffset + 1)]
        try require(Set(ackRanges.flatMap { Array($0) }).count == 9)
        try require((16...4096).contains(fallback.width) && (16...4096).contains(fallback.height) &&
                    (0...60).contains(fallback.fps) && (256000...8000000).contains(fallback.bitrate))
        try require(!tiers.isEmpty && tiers.count <= 6 && Set(tiers.map { $0.id }).count == tiers.count)
        for tier in tiers {
            try require(key(tier.id.replacingOccurrences(of: "-", with: "_")) && (1...60).contains(tier.fps) &&
                        (256000...8000000).contains(tier.bitrate) && (16...1920).contains(tier.widthLimit) &&
                        (16...1088).contains(tier.heightLimit) && (1...8160).contains(tier.maxMacroblocks) &&
                        ["auto", "1.0", "1.1", "1.2", "1.3", "2.1", "2.2", "3.0", "3.1", "3.2", "4.0", "4.2", "5.0", "5.1", "5.2"].contains(tier.level))
        }
    }
    func parseCapture(_ data: Data) throws -> IOSCastCapture {
        guard data.count >= capture.minBytes else { throw IOSCastError.reason("media_config_invalid") }
        let width = Int(IOSCastWire.u16(data, capture.widthOffset)), height = Int(IOSCastWire.u16(data, capture.heightOffset))
        guard width >= 16, height >= 16 else { throw IOSCastError.reason("media_config_invalid") }
        let codec = IOSCastWire.u32(data, capture.codecOffset)
        return IOSCastCapture(width: width, height: height, fps: Int(Int32(bitPattern: IOSCastWire.u32(data, capture.fpsOffset))),
            codec: codec == 0 ? capture.zeroCodec : codec, bitrate: Int(Int32(bitPattern: IOSCastWire.u32(data, capture.bitrateOffset))),
            extended: data[data.startIndex + capture.extendedOffset] != 0)
    }
    func acknowledgement(_ plan: IOSCastPlan) -> Data {
        var out = Data(repeating: 0, count: captureAck.size)
        var codec = Data(); IOSCastWire.append32(plan.codec, to: &codec)
        var width = Data(); IOSCastWire.append16(UInt16(plan.width), to: &width)
        var height = Data(); IOSCastWire.append16(UInt16(plan.height), to: &height)
        out.replaceSubrange(captureAck.codecOffset..<(captureAck.codecOffset + 4), with: codec)
        out.replaceSubrange(captureAck.widthOffset..<(captureAck.widthOffset + 2), with: width)
        out.replaceSubrange(captureAck.heightOffset..<(captureAck.heightOffset + 2), with: height)
        out[captureAck.extendedOffset] = plan.extended ? 1 : 0
        return out
    }
    func plan(_ config: IOSCastCapture, _ settings: IOSCastSettings) throws -> IOSCastPlan {
        guard let tier = tiers.first(where: { $0.id == settings.tier }) else { throw IOSCastError.reason("cast_tier_invalid") }
        var w = IOSCastPlan.align(min(config.width, settings.maxWidth)), h = IOSCastPlan.align(min(config.height, settings.maxHeight))
        let scale = min(1, min(Double(tier.widthLimit) / Double(w), Double(tier.heightLimit) / Double(h)))
        w = IOSCastPlan.align(Int(Double(w) * scale)); h = IOSCastPlan.align(Int(Double(h) * scale))
        while (w / 16) * (h / 16) > tier.maxMacroblocks, w > 16, h > 16 { if w >= h { w -= 16 } else { h -= 16 } }
        let requestedFPS = config.fps > 0 ? min(config.fps, settings.maxFPS) : 30
        let fps = tier.compatibilityFPS ? (requestedFPS >= 15 ? min(tier.fps, requestedFPS) : tier.fps) : tier.fps
        let requestedBPS = (256000...8000000).contains(config.bitrate) ? min(tier.bitrate, config.bitrate) : tier.bitrate
        let effectiveFPS = max(1, min(fps, settings.maxFPS))
        try IOSCastPlan.validateLevel(tier.level, width: w, height: h, fps: effectiveFPS)
        return IOSCastPlan(tier: tier.id, width: w, height: h, fps: effectiveFPS,
            bitrate: max(256000, min(tier.requestedBitrate ? requestedBPS : tier.bitrate, settings.maxBitrate)), codec: config.codec,
            extended: settings.extended && config.extended, level: tier.level)
    }
    // 替换解析后的 JSON 值，禁止手工字符串插入 HUID/SN（引号会破坏 JSON）。
    func render(_ template: String, input: [String: Any] = [:], defaults: [String: String] = [:], identity: IOSCastIdentity? = nil,
                signature: String = "") throws -> Data {
        let object = try IOSCastWire.object(Data(template.utf8))
        let builtins: [String: String] = ["os": "iOS", "package": "io.github.lswlc33.dashboard.ios", "brand": "Apple",
            "model": "iOS ReplayKit", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "uuid": identity?.uuid ?? "", "publicKey": identity?.publicKey ?? "", "signature": signature]
        func replace(_ value: Any) throws -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, value) in dict { out[key] = try replace(value) }
                return out
            }
            guard let text = value as? String, text.hasPrefix("${"), text.hasSuffix("}") else { return value }
            let key = String(text.dropFirst(2).dropLast())
            if key.hasPrefix("input:") {
                let field = String(key.dropFirst(6))
                guard let text = (input[field] as? String) ?? defaults[field], text.utf8.count <= 128 else {
                    throw IOSCastError.reason("cast_echo_invalid")
                }
                return text
            }
            guard let result = builtins[key] else { throw IOSCastError.reason("cast_template_invalid") }
            return result
        }
        guard let out = try replace(object) as? [String: Any] else { throw IOSCastError.reason("cast_template_invalid") }
        // 原生真实系统身份：模板不得声称Android或其他OS。
        for key in ["phoneOs", "phoneType"] { if let value = out[key] as? String, value != "iOS" { throw IOSCastError.reason("cast_identity_invalid") } }
        return try IOSCastWire.json(out)
    }
}

struct IOSCastPlan {
    let tier: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let codec: UInt32
    let extended: Bool
    let level: String
    static func align(_ n: Int) -> Int { max(16, n & ~15) }
    static func validateLevel(_ level: String, width: Int, height: Int, fps: Int) throws {
        if level == "auto" { return }
        // 标准 H.264 Annex A 宏块与宏块/秒上限；不是接收端私有协议值。
        let limits: [String: (Int, Int)] = ["1.0": (99, 1485), "1.1": (396, 3000), "1.2": (396, 6000),
            "1.3": (396, 11880), "2.1": (792, 19800), "2.2": (1620, 20250), "3.0": (1620, 40500),
            "3.1": (3600, 108000), "3.2": (5120, 216000), "4.0": (8192, 245760),
            "4.2": (8704, 522240), "5.0": (22080, 589824), "5.1": (36864, 983040), "5.2": (36864, 2073600)]
        let blocks = ((width + 15) / 16) * ((height + 15) / 16)
        guard let limit = limits[level], blocks <= limit.0, blocks * fps <= limit.1 else {
            throw IOSCastError.reason("h264_level_load_invalid")
        }
    }
}

enum IOSCastTarget {
    // 只接受规范的 RFC1918 IPv4 字面量：禁 URL、DNS、IPv6、环回、组播及公网上传目标。
    static func validate(_ text: String) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw IOSCastError.reason("cast_target_invalid") }
        var bytes: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(part),
                  (0...255).contains(n), String(n) == part else { throw IOSCastError.reason("cast_target_invalid") }
            bytes.append(n)
        }
        guard bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168),
              bytes[3] != 0, bytes[3] != 255, IPv4Address(text) != nil else { throw IOSCastError.reason("cast_target_invalid") }
        return text
    }
    static func wifiParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi
        params.prohibitedInterfaceTypes = [.cellular, .loopback]
        params.includePeerToPeer = false // 不把 AWDL / AirPlay 当 EasyConn，也不假装有 WifiP2pManager。
        params.allowLocalEndpointReuse = true
        return params
    }
}

// 随机会话 RSA，未抄 Android 内置秘密。RawSign 的 PKCS1 type-1 padding 对应 Java
// Cipher(ENCRYPT_MODE, privateKey)，不能换成 SHA256WithRSA（那会多一层 DigestInfo）。
final class IOSCastIdentity {
    private let privateKey: SecKey
    private let publicDER: Data
    let uuid = UUID().uuidString
    var publicKey: String { publicDER.base64EncodedString() }
    init() throws {
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024,
                                     kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key), let external = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw IOSCastError.reason("huid_key_unavailable")
        }
        privateKey = key
        // Security 导出的是 PKCS#1 RSAPublicKey；Android getEncoded() 是 X.509 SPKI。
        let algorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        publicDER = Self.der(0x30, algorithm + Self.der(0x03, Data([0]) + external))
    }
    private static func der(_ tag: UInt8, _ body: Data) -> Data {
        var data = Data([tag])
        if body.count < 128 { data.append(UInt8(body.count)) }
        else if body.count < 256 { data.append(contentsOf: [0x81, UInt8(body.count)]) }
        else { data.append(contentsOf: [0x82, UInt8(body.count >> 8), UInt8(body.count & 255)]) }
        data.append(body); return data
    }
    func sign(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 117 else { throw IOSCastError.reason("cast_sign_input_invalid") }
        let input = Data(input.utf8)
        var signature = [UInt8](repeating: 0, count: SecKeyGetBlockSize(privateKey))
        var size = signature.count
        let status = input.withUnsafeBytes { bytes in
            SecKeyRawSign(privateKey, .PKCS1, bytes.bindMemory(to: UInt8.self).baseAddress!, input.count, &signature, &size)
        }
        guard status == errSecSuccess, size == 128 else { throw IOSCastError.reason("cast_sign_failed") }
        return Data(signature.prefix(size)).base64EncodedString()
    }
}

// App Group 只存匿名短期会话、目标与编码设置；不存账号、VIN、二维码、Wi-Fi 密码或授权 token。
struct IOSCastGrant: Codable {
    let version: Int
    let id: String
    let targetIP: String
    let issuedAt: TimeInterval
    let selectBefore: TimeInterval
    let endBefore: TimeInterval
    var revoked: Bool
    var reason: String
    var settings: IOSCastSettings
    let recipe: IOSCastRecipe
    var valid: Bool {
        version == 1 && UUID(uuidString: id) != nil && (try? IOSCastTarget.validate(targetIP)) != nil && settings.valid
            && (try? recipe.validate()) != nil && recipe.tiers.contains(where: { $0.id == settings.tier })
            && issuedAt.isFinite && selectBefore.isFinite && endBefore.isFinite
            && selectBefore >= issuedAt && selectBefore - issuedAt <= 120
            && endBefore > selectBefore && endBefore - issuedAt <= 7200
    }
}

struct IOSCastHeartbeat: Codable {
    let version: Int
    let id: String
    let updatedAt: TimeInterval
    let phase: String
    let reason: String
    let broadcastActive: Bool
    let probeAccepted: Bool
    let listenersReady: [UInt16]
    let connectedPorts: [UInt16]
    let expectedPorts: [UInt16]
    let encoderReady: Bool
    let sentFrames: UInt64
    let sentBytes: UInt64
    let keyframes: UInt64
    let emptyPulls: UInt64
    let droppedFrames: UInt64
    let tier: String
    let retries: Int
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    var fresh: Bool { updatedAt.isFinite && Date().timeIntervalSince1970 - updatedAt >= -2 && Date().timeIntervalSince1970 - updatedAt < 5 }
    var streaming: Bool {
        fresh && broadcastActive && probeAccepted && encoderReady && sentFrames > 0
            && expectedPorts.count == 3 && Set(expectedPorts).count == 3 && Set(connectedPorts) == Set(expectedPorts) && phase == "casting"
    }
}

final class IOSCastMailbox {
    static let groupID = "group.io.github.lswlc33.dashboard.ios"
    static let extensionID = "io.github.lswlc33.dashboard.ios.broadcast"
    static let changedNotification = "io.github.lswlc33.dashboard.ios.cast-grant-changed"
    private let directory: URL
    init(groupID: String = IOSCastMailbox.groupID) throws {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw IOSCastError.reason("cast_app_group_unavailable")
        }
        directory = root.appendingPathComponent("Cast", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    private func read<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
        let url = directory.appendingPathComponent(name)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 49152 else { throw IOSCastError.reason("cast_mailbox_invalid") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 49152 else { throw IOSCastError.reason("cast_mailbox_invalid") }
        try bytes.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func grant() throws -> IOSCastGrant { let value = try read("grant.json", IOSCastGrant.self); guard value.valid else { throw IOSCastError.reason("cast_grant_invalid") }; return value }
    func heartbeat() throws -> IOSCastHeartbeat { try read("heartbeat.json", IOSCastHeartbeat.self) }
    // atomic rename 只保证单次写完整，不能保证 read-ID-check-write 是 CAS。
    // App 和 extension 的所有 grant 修改共用同一个跨进程锁，锁内完成核对与写入。
    private func withGrantLock<T>(_ action: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent("grant.lock").path
        let fd = path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw IOSCastError.reason("cast_grant_lock_unavailable") }
        defer { _ = Darwin.close(fd) }
        // Darwin 的 C 函数 flock() 与 struct flock 同名，Swift 里 Darwin.flock(...)
        // 会被解析成结构体默认初始化（argument passed to call that takes no arguments）。
        // 改用 fcntl + F_SETLK 表达同一把跨进程排它锁，语义与阻塞/非阻塞行为保持一致。
        func setLock(_ type: Int32) -> Bool {
            var entry = Darwin.flock()
            entry.l_type = Int16(type)
            entry.l_whence = Int16(SEEK_SET)
            entry.l_start = 0
            entry.l_len = 0
            return fcntl(fd, F_SETLK, &entry) == 0
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while !setLock(F_WRLCK) {
            guard errno == EWOULDBLOCK || errno == EACCES || errno == EINTR else {
                throw IOSCastError.reason("cast_grant_lock_failed")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw IOSCastError.reason("cast_grant_lock_timeout") }
            usleep(1000)
        }
        defer { _ = setLock(F_UNLCK) }
        return try action()
    }
    private func notifyGrantChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.changedNotification as CFString), nil, nil, true)
    }
    func setGrant(_ grant: IOSCastGrant) throws {
        guard grant.valid else { throw IOSCastError.reason("cast_grant_invalid") }
        try withGrantLock { try write(grant, "grant.json") }
        notifyGrantChanged()
    }
    func setHeartbeat(_ heartbeat: IOSCastHeartbeat) throws { try write(heartbeat, "heartbeat.json") }
    func revoke(_ id: String, reason: String) throws {
        let changed = try withGrantLock { () throws -> Bool in
            var grant = try self.grant()
            guard grant.id == id else { return false }
            if grant.revoked { return false }
            grant.revoked = true; grant.reason = reason
            try write(grant, "grant.json")
            return true
        }
        if changed { notifyGrantChanged() }
    }
}

// 一次只读一整帧、处理并发送后才接下一帧。不维护无限 NWConnection send 队列。
// readExactly 区分帧边界正常 EOF 与半包 EOF；partial timeout 一律断链。
final class IOSCastSocket {
    let connection: NWConnection
    let queue: DispatchQueue
    let control: Bool
    var closed = false
    var lastFrameAt = ProcessInfo.processInfo.systemUptime
    var partialSince: TimeInterval?
    var writeSince: TimeInterval?
    var onClosed: ((String) -> Void)?
    var onControl: ((IOSCastWire.Control, @escaping () -> Void) -> Void)?
    var onMedia: ((IOSCastWire.Media, @escaping () -> Void) -> Void)?
    private var identity: IOSCastIdentity?
    private var receivedEOF = false

    init(_ connection: NWConnection, queue: DispatchQueue, control: Bool) {
        self.connection = connection; self.queue = queue; self.control = control
    }
    func replies(_ rule: IOSCastRecipe.Rule, body: Data, recipe: IOSCastRecipe) throws -> [Data] {
        let input: [String: Any]
        if rule.action == "rsa" || rule.action == "echo" { input = try IOSCastWire.object(body) }
        else { input = [:] }
        var signature = ""
        if rule.action == "rsa" {
            if identity == nil { identity = try IOSCastIdentity() }
            guard let value = (rule.inputKeys ?? []).compactMap({ input[$0] as? String }).first, !value.isEmpty else {
                throw IOSCastError.reason("cast_sign_input_invalid")
            }
            signature = try identity!.sign(value)
        }
        return try rule.replies.map { reply in
            let data = try reply.json.map { try recipe.render($0, input: input, defaults: rule.defaults ?? [:], identity: identity, signature: signature) } ?? Data()
            return try IOSCastWire.control(reply.type, body: data)
        }
    }
    func start(expectedIP: String, ready: @escaping () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                guard self.connection.currentPath?.usesInterfaceType(.wifi) == true,
                      case let .hostPort(host, _) = self.connection.endpoint,
                      case let .ipv4(address) = host, address == IPv4Address(expectedIP) else {
                    self.close("cast_peer_rejected"); return
                }
                ready(); self.readFrame()
            case let .failed(error): self.close(IOSCastError.network(error))
            case let .waiting(error):
                if IOSCastError.network(error) == "local_network_permission_denied" { self.close("local_network_permission_denied") }
            case .cancelled: self.close("cast_socket_cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func readExactly(_ count: Int, frameBoundary: Bool = false, collected: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        if count == 0 { completion(collected); return }
        if receivedEOF { close(frameBoundary && collected.isEmpty ? "peer_closed" : "cast_frame_truncated"); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            let data = data ?? Data()
            var joined = collected; joined.append(data)
            // Network 可把有效末包与 FIN 同一次交付；先消费 bytes，再判断不足 EOF。
            if complete { self.receivedEOF = true }
            if data.count == count { completion(joined); return }
            if error != nil || complete {
                self.close(frameBoundary && joined.isEmpty ? "peer_closed" : "cast_frame_truncated"); return
            }
            guard !data.isEmpty else { self.close("cast_frame_truncated"); return }
            self.partialSince = self.partialSince ?? ProcessInfo.processInfo.systemUptime
            self.readExactly(count - data.count, collected: joined, completion: completion)
        }
    }
    private func readFrame() {
        guard !closed else { return }
        readExactly(control ? 16 : 8, frameBoundary: true) { [weak self] header in
            guard let self = self, !self.closed else { return }
            self.partialSince = self.partialSince ?? ProcessInfo.processInfo.systemUptime
            do {
                let length: Int
                if self.control { length = try IOSCastWire.controlLength(header) }
                else { length = Int(IOSCastWire.u16(header, 2)) }
                self.readExactly(length) { [weak self] body in
                    guard let self = self, !self.closed else { return }
                    self.partialSince = nil; self.lastFrameAt = ProcessInfo.processInfo.systemUptime
                    let next: () -> Void = { [weak self] in self?.readFrame() }
                    if self.control { self.onControl?(IOSCastWire.Control(type: IOSCastWire.u32(header, 0), body: body), next) }
                    else { self.onMedia?(IOSCastWire.Media(command: IOSCastWire.u16(header, 0), serial: IOSCastWire.u32(header, 4), body: body), next) }
                }
            } catch { self.close(IOSCastError.code(error)) }
        }
    }
    func send(_ bytes: Data, completion: @escaping () -> Void) {
        guard !closed else { return }
        guard writeSince == nil else { close("cast_backpressure_violation"); return }
        writeSince = ProcessInfo.processInfo.systemUptime
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            self.writeSince = nil
            if error != nil { self.close("cast_write_failed"); return }
            completion()
        })
    }
    func tick(idleLimit: TimeInterval?, ioLimit: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        if let partial = partialSince, now - partial > ioLimit { close("cast_frame_timeout") }
        else if let write = writeSince, now - write > ioLimit { close("cast_write_timeout") }
        else if let limit = idleLimit, now - lastFrameAt > limit { close("vehicle_idle") }
    }
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true; connection.stateUpdateHandler = nil; connection.cancel(); identity = nil
        let callback = onClosed
        onClosed = nil; onControl = nil; onMedia = nil
        callback?(reason)
    }
}
