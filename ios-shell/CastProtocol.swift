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
        if case let .posix(code) = error {
            if code == .EACCES || code == .EPERM { return "local_network_permission_denied" }
            if [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENODEV, .EADDRNOTAVAIL].contains(code) { return "cast_route_lost" }
        }
        return "cast_socket_failed"
    }
    // 路由/权限错误不是接收端解码兼容性，不能通过降档或重建另一条出口重试。
    static func routeFailure(_ code: String) -> Bool {
        code.hasPrefix("cast_route_") || code.hasPrefix("cast_source_") || code.hasPrefix("cast_interface_")
            || ["wifi_path_unavailable", "wifi_route_not_exclusive", "ambiguous_wifi_path",
                "wifi_permission_denied", "local_network_permission_denied"].contains(code)
    }
}

// 只读公开的路径/接口证据。utun 的存在不证明这条连接用了 VPN；连接仍须精确绑定并核对源地址。
// Host/Broadcast 共用这些检查，不向扩展引入账号、SSID、桥或新的系统权限。
enum IOSWiFiRouteChecks {
    struct Source {
        let state: String
        let address: String?
    }
    static func pathStatus(_ path: Network.NWPath) -> String {
        switch path.status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requires_connection"
        @unknown default: return "unknown"
        }
    }
    static func pathError(_ path: Network.NWPath) -> String? {
        guard path.status == .satisfied else {
            if path.unsatisfiedReason == .localNetworkDenied { return "local_network_permission_denied" }
            if path.unsatisfiedReason == .wifiDenied { return "wifi_permission_denied" }
            return "wifi_path_unavailable"
        }
        guard path.usesInterfaceType(.wifi) else { return "wifi_path_unavailable" }
        guard !path.usesInterfaceType(.cellular), !path.usesInterfaceType(.other),
              !path.usesInterfaceType(.wiredEthernet), !path.usesInterfaceType(.loopback) else {
            return "wifi_route_not_exclusive"
        }
        guard path.availableInterfaces.filter({ $0.type == .wifi }).count == 1 else { return "ambiguous_wifi_path" }
        return nil
    }
    static func localSource(_ path: Network.NWPath, matches sourceIP: String) -> Bool {
        guard let endpoint = path.localEndpoint, case let .hostPort(host, port) = endpoint, port != .any,
              case let .ipv4(address) = host else { return false }
        return address == IPv4Address(sourceIP)
    }
    static func source(interface: String, target: String) -> Source {
        var targetAddress = in_addr()
        guard inet_pton(AF_INET, target, &targetAddress) == 1 else { return Source(state: "invalid_target", address: nil) }
        let targetBits = UInt32(bigEndian: targetAddress.s_addr)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return Source(state: "interfaces_unreadable", address: nil) }
        defer { freeifaddrs(list) }
        var pointer = list, candidates: Set<String> = []
        var available = false
        while let node = pointer {
            let item = node.pointee; pointer = item.ifa_next
            guard String(cString: item.ifa_name) == interface, item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            available = true
            guard let address = item.ifa_addr, let netmask = item.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET, Int32(netmask.pointee.sa_family) == AF_INET else { continue }
            let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let maskAddr = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let bits = UInt32(bigEndian: addr.s_addr), mask = UInt32(bigEndian: maskAddr.s_addr)
            let prefix = mask.nonzeroBitCount
            // 只接受唯一、同一直连子网的主机地址；不猜 gateway，不接受自身/网络/广播地址。
            guard prefix >= 16, prefix <= 30, mask == UInt32.max << (32 - prefix),
                  bits != targetBits, bits & mask == targetBits & mask,
                  bits & ~mask != 0, bits & ~mask != ~mask,
                  targetBits & ~mask != 0, targetBits & ~mask != ~mask else { continue }
            var copy = addr, chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &copy, &chars, socklen_t(INET_ADDRSTRLEN)) != nil { candidates.insert(String(cString: chars)) }
        }
        guard available else { return Source(state: "interface_unavailable", address: nil) }
        guard candidates.count == 1 else { return Source(state: candidates.isEmpty ? "unavailable" : "ambiguous", address: nil) }
        return Source(state: "verified", address: candidates.first)
    }
}

// 匿名会话的不可换出口约束。NWInterface 不能跨进程编码，扩展必须按 name+index 重新解析真实接口。
struct IOSCastRoute: Codable, Equatable {
    let interfaceName: String
    let interfaceIndex: Int
    let sourceIP: String
    let targetIP: String

    var valid: Bool {
        interfaceIndex > 0 && interfaceIndex <= Int(UInt32.max) && !interfaceName.isEmpty && interfaceName.utf8.count <= 64
            && interfaceName.utf8.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                    || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
            }
            && IPv4Address(sourceIP) != nil && sourceIP != targetIP && (try? IOSCastTarget.validate(targetIP)) != nil
    }
    static func capture(_ path: Network.NWPath, targetIP: String) throws -> IOSCastRoute {
        if let error = IOSWiFiRouteChecks.pathError(path) { throw IOSCastError.reason(error) }
        guard let interface = path.availableInterfaces.first(where: { $0.type == .wifi }),
              let source = IOSWiFiRouteChecks.source(interface: interface.name, target: targetIP).address else {
            throw IOSCastError.reason("cast_source_unverified")
        }
        let route = IOSCastRoute(interfaceName: interface.name, interfaceIndex: interface.index, sourceIP: source, targetIP: targetIP)
        guard route.valid, route.sourceError() == nil else { throw IOSCastError.reason("cast_route_unverified") }
        return route
    }
    func interface(in path: Network.NWPath) -> Network.NWInterface? {
        path.availableInterfaces.first { $0.type == .wifi && $0.name == interfaceName && $0.index == interfaceIndex }
    }
    func sourceError() -> String? {
        guard valid else { return "cast_route_invalid" }
        guard if_nametoindex(interfaceName) == UInt32(interfaceIndex) else { return "cast_interface_changed" }
        let source = IOSWiFiRouteChecks.source(interface: interfaceName, target: targetIP)
        guard let address = source.address else { return "cast_source_unverified" }
        return address == sourceIP ? nil : "cast_source_changed"
    }
    func pathError(_ path: Network.NWPath, connection: Bool = false) -> String? {
        if let error = IOSWiFiRouteChecks.pathError(path) { return error }
        guard interface(in: path) != nil else { return "cast_interface_changed" }
        if let error = sourceError() { return error }
        if connection && !IOSWiFiRouteChecks.localSource(path, matches: sourceIP) { return "cast_route_local_endpoint_unverified" }
        return nil
    }
    func parameters(interface: Network.NWInterface, port: Network.NWEndpoint.Port = .any) throws -> Network.NWParameters {
        guard interface.type == .wifi, interface.name == interfaceName, interface.index == interfaceIndex else {
            throw IOSCastError.reason("cast_interface_changed")
        }
        if let error = sourceError() { throw IOSCastError.reason(error) }
        let tcp = Network.NWProtocolTCP.Options(); tcp.noDelay = true
        let params = Network.NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi; params.requiredInterface = interface
        params.prohibitedInterfaceTypes = [.cellular, .wiredEthernet, .loopback, .other]
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address(sourceIP)!), port: port)
        params.includePeerToPeer = false
        params.allowLocalEndpointReuse = true
        return params
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
        var payload = data
        while payload.last == 0 { payload.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw IOSCastError.reason("cast_bad_json")
        }
        return object
    }

    struct Control {
        let type: UInt32
        let identifier: UInt32
        let body: Data
    }
    struct Media {
        let command: UInt16
        let serial: UInt32 // 按位回填，不能把负序号截成 0。
        let body: Data
    }
    static func control(_ type: UInt32, identifier: UInt32 = 0, body: Data = Data()) throws -> Data {
        let length = body.count + 16
        guard length <= controlMax else { throw IOSCastError.reason("control_frame_invalid") }
        var out = Data()
        append32(type, to: &out); append32(UInt32(length), to: &out)
        append32(type ^ UInt32(length), to: &out); append32(identifier, to: &out)
        out.append(body)
        return out
    }
    static func controlLength(_ header: Data) throws -> Int {
        guard header.count == 16 else { throw IOSCastError.reason("control_frame_truncated") }
        let length = Int(u32(header, 4))
        guard (16...controlMax).contains(length), u32(header, 8) == (u32(header, 0) ^ UInt32(length)) else {
            throw IOSCastError.reason("control_frame_invalid")
        }
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
        let dimensionsOnly: Bool?
        let signatureOffset: Int?
        let dimensionAliases: [DimensionAlias]?
    }
    struct DimensionAlias: Codable {
        let width: Int; let height: Int; let outputHeight: Int
    }
    struct Ack: Codable {
        let size: Int
        let codecOffset: Int; let widthOffset: Int; let heightOffset: Int; let extendedOffset: Int
    }
    struct Session: Codable {
        let request: UInt32
        let start: [Reply]
        let stop: Reply
        let heartbeat: Reply
        let heartbeatMilliseconds: Int
        let firstFrameZeroBytes: Int
        let waitForFrame: Bool
        let rsaBits: Int
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
    let session: Session?

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
        if let session = session {
            try require(control.contains { $0.request == session.request && $0.action == "reply" } && session.start.count <= 8 && !session.start.isEmpty)
            try require((1000...10000).contains(session.heartbeatMilliseconds) && (0...16).contains(session.firstFrameZeroBytes)
                        && [1024, 2048].contains(session.rsaBits))
            for reply in session.start + [session.stop, session.heartbeat] { if let json = reply.json { try require(template(json)) } }
        }
        func fits(_ offset: Int, _ bytes: Int, _ total: Int) -> Bool { offset >= 0 && offset <= total - bytes }
        try require((4...256).contains(capture.minBytes) && fits(capture.widthOffset, 2, capture.minBytes) &&
                    fits(capture.heightOffset, 2, capture.minBytes))
        if capture.dimensionsOnly != true {
            try require(fits(capture.fpsOffset, 4, capture.minBytes) && fits(capture.codecOffset, 4, capture.minBytes) &&
                        fits(capture.bitrateOffset, 4, capture.minBytes) && fits(capture.extendedOffset, 1, capture.minBytes))
        }
        if let offset = capture.signatureOffset { try require(offset >= capture.minBytes && offset <= 256) }
        let aliases = capture.dimensionAliases ?? []
        try require(aliases.count <= 4 && Set(aliases.map { "\($0.width)x\($0.height)" }).count == aliases.count)
        for alias in aliases {
            try require((16...1920).contains(alias.width) && (16...1088).contains(alias.height) &&
                        (16...alias.height).contains(alias.outputHeight) && alias.outputHeight % 2 == 0)
        }
        try require((8...256).contains(captureAck.size) && fits(captureAck.widthOffset, 2, captureAck.size) &&
                    fits(captureAck.heightOffset, 2, captureAck.size) && fits(captureAck.codecOffset, 4, captureAck.size) &&
                    (captureAck.extendedOffset == -1 || fits(captureAck.extendedOffset, 1, captureAck.size)))
        var ackRanges = [captureAck.codecOffset..<(captureAck.codecOffset + 4), captureAck.widthOffset..<(captureAck.widthOffset + 2),
                         captureAck.heightOffset..<(captureAck.heightOffset + 2)]
        if captureAck.extendedOffset >= 0 { ackRanges.append(captureAck.extendedOffset..<(captureAck.extendedOffset + 1)) }
        try require(Set(ackRanges.flatMap { Array($0) }).count == (captureAck.extendedOffset >= 0 ? 9 : 8))
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
        let width = Int(IOSCastWire.u16(data, capture.widthOffset)), reportedHeight = Int(IOSCastWire.u16(data, capture.heightOffset))
        let height = capture.dimensionAliases?.first { $0.width == width && $0.height == reportedHeight }?.outputHeight ?? reportedHeight
        guard (16...4096).contains(width), (16...4096).contains(height) else { throw IOSCastError.reason("media_config_invalid") }
        if capture.dimensionsOnly == true {
            return IOSCastCapture(width: width, height: height, fps: fallback.fps, codec: capture.zeroCodec,
                                  bitrate: fallback.bitrate, extended: false)
        }
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
        if captureAck.extendedOffset >= 0 { out[captureAck.extendedOffset] = plan.extended ? 1 : 0 }
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
                signature: String = "", screen: [String: Int] = [:]) throws -> Data {
        let object = try IOSCastWire.object(Data(template.utf8))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let builtins: [String: Any] = ["os": "iOS", "package": "io.github.lswlc33.dashboard.ios", "brand": "Apple",
            "model": "iOS ReplayKit", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "uuid": identity?.uuid ?? "", "publicKey": identity?.publicKey ?? "", "signature": signature,
            "screenWidth": screen["width"] ?? 0, "screenHeight": screen["height"] ?? 0, "screenRotation": screen["rotation"] ?? 0,
            "time": now, "localTime": now + Int64(TimeZone.current.secondsFromGMT()) * 1000, "timeZone": TimeZone.current.identifier]
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
}

// 随机会话 RSA，未抄 Android 内置秘密。RawSign 的 PKCS1 type-1 padding 对应 Java
// Cipher(ENCRYPT_MODE, privateKey)，不能换成 SHA256WithRSA（那会多一层 DigestInfo）。
final class IOSCastIdentity {
    private let privateKey: SecKey
    private let publicDER: Data
    let uuid = UUID().uuidString
    var publicKey: String { publicDER.base64EncodedString() }
    init(bits: Int = 1024) throws {
        guard [1024, 2048].contains(bits) else { throw IOSCastError.reason("cast_recipe_invalid") }
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits,
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
        guard !input.isEmpty, input.utf8.count <= SecKeyGetBlockSize(privateKey) - 11 else { throw IOSCastError.reason("cast_sign_input_invalid") }
        let input = Data(input.utf8)
        var signature = [UInt8](repeating: 0, count: SecKeyGetBlockSize(privateKey))
        var size = signature.count
        let status = input.withUnsafeBytes { bytes in
            SecKeyRawSign(privateKey, .PKCS1, bytes.bindMemory(to: UInt8.self).baseAddress!, input.count, &signature, &size)
        }
        guard status == errSecSuccess, size == SecKeyGetBlockSize(privateKey) else { throw IOSCastError.reason("cast_sign_failed") }
        return Data(signature.prefix(size)).base64EncodedString()
    }
}

// App Group 只存匿名短期会话、目标与编码设置；不存账号、VIN、二维码、Wi-Fi 密码或授权 token。
struct IOSCastGrant: Codable {
    let version: Int
    let id: String
    let extensionID: String? // 旧票据缺此键仍可被 host 撤销；新扩展启动时必须精确匹配。
    let targetIP: String
    let route: IOSCastRoute? // 旧票据仍可撤销，但扩展不再消费缺少路由约束的票据。
    let issuedAt: TimeInterval
    let selectBefore: TimeInterval
    let endBefore: TimeInterval
    var revoked: Bool
    var reason: String
    var settings: IOSCastSettings
    let recipe: IOSCastRecipe
    var valid: Bool {
        version == 1 && UUID(uuidString: id) != nil && (extensionID.map { IOSCastMailbox.validExtensionID($0) } ?? true)
            && (try? IOSCastTarget.validate(targetIP)) != nil && settings.valid
            && (route.map { $0.valid && $0.targetIP == targetIP } ?? true)
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
    // 与 Shared/AppGroup.swift 同一契约（test.py 逐键断言）：未签名 IPA 交用户自签后，
    // 描述文件里的 App Group 会被换成签名团队的组；AltStore/SideStore 重签时会把
    // profile 的 app groups 回写进每个 bundle 的 Info.plist 的 ALTAppGroups。
    // 本文件同时编进 Host 与 Broadcast 两个 module，不能 import ZeehoSystemShared，
    // 所以这里自带同一套解析；三处进程必须解析出同一个组名。
    static var groupID: String { resolvedGroupID() }
    private static func resolvedGroupID() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let explicit = info["ZeehoAppGroupID"] as? String, isValidGroup(explicit) { return explicit }
        if let groups = info["ALTAppGroups"] as? [String], let first = groups.first(where: { isValidGroup($0) }) { return first }
        if let single = info["ALTAppGroups"] as? String, isValidGroup(single) { return single }
        // 全能签/eSign/zsign 等 P12 工具只把证书团队的组签进 entitlements，不写 Info.plist；
        // 从 CMS 包裹的 embedded.mobileprovision 抽内嵌 plist 取 application-groups。
        // appex 常被单-profile 工具漏放，所以回退读宿主 bundle 的那份。
        for url in profileCandidates() {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data.subdata(in: start.lowerBound..<end.upperBound),
                      options: [], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String],
                  let first = groups.first(where: { isValidGroup($0) }) else { continue }
            return first
        }
        return "group.io.github.lswlc33.dashboard.ios"
    }
    private static func profileCandidates() -> [URL] {
        var urls: [URL] = []
        if let own = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") {
            urls.append(URL(fileURLWithPath: own))
        }
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let hostProfile = host.appendingPathComponent("embedded.mobileprovision")
        if hostProfile.path != urls.first?.path, FileManager.default.fileExists(atPath: hostProfile.path) {
            urls.append(hostProfile)
        }
        return urls
    }
    private static func isValidGroup(_ value: String) -> Bool {
        guard value.hasPrefix("group."), value.utf8.count <= 256,
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return false }
        let name = String(value.dropFirst("group.".count))
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
            }
        }
    }
    static func validExtensionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.contains(".")
            && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { byte in
                    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                        || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
                }
            }
    }
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
    private(set) var signedIdentity: Data?
    private var receivedEOF = false
    private let route: IOSCastRoute
    private var ready = false
    private var deferredWrites: [(Data, () -> Void)] = []
    private var deferredBytes = 0

    init(_ connection: NWConnection, queue: DispatchQueue, control: Bool, route: IOSCastRoute) {
        self.connection = connection; self.queue = queue; self.control = control; self.route = route
    }
    @discardableResult private func verifyRoute() -> Bool {
        guard !closed, let path = connection.currentPath else { close("cast_route_lost"); return false }
        if let error = route.pathError(path, connection: true) { close(error); return false }
        return true
    }
    func replies(_ rule: IOSCastRecipe.Rule, frame: IOSCastWire.Control, recipe: IOSCastRecipe) throws -> [Data] {
        let input: [String: Any]
        if rule.action == "rsa" || rule.action == "echo" { input = try IOSCastWire.object(frame.body) }
        else { input = [:] }
        var signature = ""
        if rule.action == "rsa" {
            if identity == nil { identity = try IOSCastIdentity(bits: recipe.session?.rsaBits ?? 1024) }
            guard let value = (rule.inputKeys ?? []).compactMap({ input[$0] as? String }).first, !value.isEmpty else {
                throw IOSCastError.reason("cast_sign_input_invalid")
            }
            signature = try identity!.sign(value)
            signedIdentity = Data(base64Encoded: signature)
        }
        return try rule.replies.map { reply in
            let data = try reply.json.map { try recipe.render($0, input: input, defaults: rule.defaults ?? [:], identity: identity, signature: signature) } ?? Data()
            return try IOSCastWire.control(reply.type, identifier: frame.identifier, body: data)
        }
    }
    func start(expectedIP: String, ready: @escaping () -> Void) {
        connection.pathUpdateHandler = { [weak self] path in
            guard let self = self, !self.closed else { return }
            if let error = self.route.pathError(path, connection: self.ready) { self.close(error) }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            if !viable { self?.close("cast_route_lost") }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                guard expectedIP == self.route.targetIP,
                      case let .hostPort(host, _) = self.connection.endpoint,
                      case let .ipv4(address) = host, address == IPv4Address(expectedIP) else {
                    self.close("cast_peer_rejected"); return
                }
                guard self.verifyRoute() else { return }
                self.ready = true; ready(); self.readFrame()
            case let .failed(error): self.close(IOSCastError.network(error))
            case let .waiting(error):
                let code = IOSCastError.network(error)
                self.close(IOSCastError.routeFailure(code) ? code : "cast_route_lost")
            case .cancelled: self.close("cast_socket_cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func readExactly(_ count: Int, frameBoundary: Bool = false, collected: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !closed, verifyRoute() else { return }
        if count == 0 { completion(collected); return }
        if receivedEOF { close(frameBoundary && collected.isEmpty ? "peer_closed" : "cast_frame_truncated"); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed, self.verifyRoute() else { return }
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
                    if self.control { self.onControl?(IOSCastWire.Control(type: IOSCastWire.u32(header, 0), identifier: IOSCastWire.u32(header, 12), body: body), next) }
                    else { self.onMedia?(IOSCastWire.Media(command: IOSCastWire.u16(header, 0), serial: IOSCastWire.u32(header, 4), body: body), next) }
                }
            } catch { self.close(IOSCastError.code(error)) }
        }
    }
    func send(_ bytes: Data, completion: @escaping () -> Void) {
        guard !closed, verifyRoute() else { return }
        if writeSince != nil {
            guard control, deferredWrites.count < 8, deferredBytes + bytes.count <= IOSCastWire.controlMax else {
                close("cast_backpressure_violation"); return
            }
            deferredWrites.append((bytes, completion)); deferredBytes += bytes.count
            return
        }
        writeSince = ProcessInfo.processInfo.systemUptime
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            self.writeSince = nil
            if let error = error { self.close(IOSCastError.network(error)); return }
            completion()
            if !self.closed, self.writeSince == nil, !self.deferredWrites.isEmpty {
                let pending = self.deferredWrites.removeFirst(); self.deferredBytes -= pending.0.count
                self.send(pending.0, completion: pending.1)
            }
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
        closed = true; connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil
        connection.viabilityUpdateHandler = nil; connection.cancel(); identity = nil; signedIdentity = nil
        deferredWrites.removeAll(); deferredBytes = 0
        let callback = onClosed
        onClosed = nil; onControl = nil; onMedia = nil
        callback?(reason)
    }
}
