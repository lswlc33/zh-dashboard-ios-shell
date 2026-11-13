import Foundation
import CommonCrypto

// 仅解释私有网页交来的受限字节配方；这里没有厂商命令、字段映射、云路径或密钥。
// 所有回调在主线程，IO 仍由 Bluetooth 的单飞 GATT 队列执行。
struct IOSBLERecipe {
    static let maxBytes = 240
    struct Material { let slot: String; let requestIndex: Int; let path: [String]; let type: String }
    struct Frame {
        let magic: Data
        let tail: Data
        let command: UInt8
        let maxPayload: Int
        // 只接受已经实现的有界布局，绝不猜测其他格式或给实车增加不存在的序列字节。
        init?(_ value: Any?, command: Any?) {
            guard let v = value as? [String: Any], let magic = Self.hex(v["magicHex"], max: 8), !magic.isEmpty,
                  let tail = Self.hex(v["tailHex"], max: 8),
                  let command = IOSRideJSON.integer(command, maximum: 255),
                  IOSRideJSON.integer(v["commandOffset"]) == Int64(magic.count),
                  IOSRideJSON.integer(v["lengthOffset"]) == Int64(magic.count + 1),
                  IOSRideJSON.integer(v["lengthBytes"]) == 2, v["lengthEndian"] as? String == "little",
                  IOSRideJSON.integer(v["payloadOffset"]) == Int64(magic.count + 3),
                  v["checksum"] as? String == "sum8",
                  v["checksumInput"] as? [String] == ["command", "lengthLow", "lengthHigh", "payload"],
                  let limit = IOSRideJSON.integer(v["maxPayload"], minimum: 1, maximum: 240) else { return nil }
            self.magic = magic; self.tail = tail; self.command = UInt8(command); maxPayload = Int(limit)
        }
        static func hex(_ value: Any?, max: Int = 240) -> Data? {
            guard let text = value as? String, text.utf8.count <= max * 2, text.utf8.count % 2 == 0 else { return nil }
            if text.isEmpty { return Data() }
            return Data(strictHex: text)
        }
        func encode(_ payload: Data) -> Data? {
            guard payload.count <= maxPayload else { return nil }
            var result = magic
            result.append(command); result.append(UInt8(payload.count & 255)); result.append(UInt8(payload.count >> 8))
            result.append(payload)
            let sum = payload.reduce(Int(command) + (payload.count & 255) + (payload.count >> 8)) { $0 + Int($1) }
            result.append(UInt8(sum & 255)); result.append(tail)
            return result
        }
        // 返回完整载荷和消耗字节；半包留在有界缓冲中，坏帧由调用方安全失败。
        func decode(_ data: Data, acceptingAnyCommand: Bool = false) -> (payload: Data, consumed: Int)? {
            let header = magic.count + 3
            guard data.count >= header, data.prefix(magic.count) == magic,
                  acceptingAnyCommand || data[magic.count] == command else { return nil }
            let length = Int(data[magic.count + 1]) | (Int(data[magic.count + 2]) << 8)
            let total = header + length + 1 + tail.count
            guard length <= maxPayload, data.count >= total,
                  data.subdata(in: (total - tail.count)..<total) == tail else { return nil }
            let payload = data.subdata(in: header..<(header + length))
            let sum = payload.reduce(Int(data[magic.count]) + (length & 255) + (length >> 8)) { $0 + Int($1) }
            guard data[header + length] == UInt8(sum & 255) else { return nil }
            return (payload, total)
        }
    }
    enum Operand { case literal(Data), slot(String) }
    struct WaitRule {
        let frame: Frame; let slot: String; let timeout: TimeInterval; let optional: Bool
        let validation: String; let field: Int?; let values: Set<UInt64>
    }
    enum Step {
        case write(String, Frame, [Operand])
        case wait(WaitRule)
        case extract(String, Int, String, Bool)
        case aes(String, String, String, Int, Int, Bool)
        case bytesPB(String, Int, String)
        case hexUTF8(String, String)
        case equal(Operand, Operand)
    }
    let steps: [Step]
    let materials: [Material]
    let timeout: TimeInterval

    static func name(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
        return value
    }
    static func operand(_ value: Any?, available: Set<String>) -> Operand? {
        guard let v = value as? [String: Any], v.count == 1 else { return nil }
        if let hex = Frame.hex(v["hex"]) { return .literal(hex) }
        if let slot = name(v["slot"]), available.contains(slot) { return .slot(slot) }
        return nil
    }
    init?(_ value: Any?) {
        guard let v = value as? [String: Any], IOSRideJSON.integer(v["version"]) == 1,
              IOSRideJSON.integer(v["retries"]) == 0,
              let timeout = IOSRideJSON.integer(v["timeoutMs"], minimum: 1000, maximum: 15000),
              let raw = v["steps"] as? [[String: Any]], (1...16).contains(raw.count),
              let rawMaterials = v["materials"] as? [[String: Any]], rawMaterials.count <= 16 else { return nil }
        var materials: [Material] = []; var available = Set<String>()
        for m in rawMaterials {
            guard let slot = Self.name(m["slot"]), available.insert(slot).inserted,
                  let index = IOSRideJSON.integer(m["requestIndex"], maximum: 1),
                  let path = m["path"] as? [String], (1...8).contains(path.count),
                  path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
                  let type = m["type"] as? String, ["string", "bytes", "base64", "hex"].contains(type) else { return nil }
            materials.append(Material(slot: slot, requestIndex: Int(index), path: path, type: type))
        }
        var steps: [Step] = []; var writePending = false; var waited = false; var writes = 0; var proofChecked = false
        var responseSlots = Set<String>(); var derivedResponse = Set<String>()
        var latestResponses = Set<String>()
        for s in raw {
            guard let op = s["op"] as? String else { return nil }
            switch op {
            case "write":
                guard !writePending, let id = Self.name(s["operationId"]), let frame = Frame(s["frame"], command: s["command"]),
                      let rawParts = s["parts"] as? [Any], rawParts.count <= 16 else { return nil }
                let parts = rawParts.compactMap { Self.operand($0, available: available) }
                guard parts.count == rawParts.count else { return nil }
                latestResponses.removeAll()
                steps.append(.write(id, frame, parts)); writePending = true; waited = false; writes += 1
            case "wait":
                guard writePending, let frame = Frame(s["frame"], command: s["command"]), let slot = Self.name(s["slot"]),
                      !available.contains(slot), let ms = IOSRideJSON.integer(s["timeoutMs"], minimum: 1, maximum: timeout) else { return nil }
                let optional = s["optional"] as? Bool ?? false
                guard !optional || proofChecked else { return nil }
                let validation = s["payloadValidation"] as? [String: Any]
                let kind = validation?["kind"] as? String ?? "any"
                guard ["any", "empty", "emptyOrVarint"].contains(kind), !optional || kind != "any" else { return nil }
                var field: Int?; var accepted = Set<UInt64>()
                if kind == "emptyOrVarint" {
                    guard let f = IOSRideJSON.integer(validation?["field"], minimum: 1, maximum: 2047),
                          let vals = validation?["values"] as? [Any], (1...8).contains(vals.count) else { return nil }
                    for v in vals { guard let n = IOSRideJSON.integer(v, maximum: 65535) else { return nil }; accepted.insert(UInt64(n)) }
                    field = Int(f)
                }
                steps.append(.wait(WaitRule(frame: frame, slot: slot, timeout: Double(ms) / 1000,
                    optional: optional, validation: kind, field: field, values: accepted)))
                available.insert(slot); responseSlots.insert(slot); latestResponses.insert(slot)
                writePending = false; waited = !optional
            case "protobufExtract":
                guard let from = Self.name(s["from"]), available.contains(from), let to = Self.name(s["to"]), !available.contains(to),
                      let field = IOSRideJSON.integer(s["field"], minimum: 1, maximum: 2047),
                      s["requirePresent"] as? Bool == true,
                      let kind = s["kind"] as? String, ["bytes", "varint"].contains(kind) else { return nil }
                steps.append(.extract(from, Int(field), to, kind == "bytes")); available.insert(to)
                if responseSlots.contains(from) || derivedResponse.contains(from) { derivedResponse.insert(to) }
                if latestResponses.contains(from) { latestResponses.insert(to) }
            case "aes", "bytesPB", "hexUTF8":
                guard let from = Self.name(s["from"]), available.contains(from), let to = Self.name(s["to"]), !available.contains(to) else { return nil }
                if op == "aes" {
                    guard s["mode"] as? String == "decrypt_ecb_pkcs7", let key = Self.name(s["keySlot"]),
                          materials.contains(where: { $0.slot == key }) else { return nil }
                    let validation = s["outputUTF8"] as? [String: Any]
                    guard let minimum = IOSRideJSON.integer(validation?["minBytes"], minimum: 1, maximum: 240),
                          let maximum = IOSRideJSON.integer(validation?["maxBytes"], minimum: minimum, maximum: 240),
                          validation?["noControls"] as? Bool == true else { return nil }
                    steps.append(.aes(from, key, to, Int(minimum), Int(maximum), true))
                } else if op == "bytesPB" {
                    guard let field = IOSRideJSON.integer(s["field"], minimum: 1, maximum: 2047) else { return nil }
                    steps.append(.bytesPB(from, Int(field), to))
                } else { steps.append(.hexUTF8(from, to)) }
                available.insert(to)
                if responseSlots.contains(from) || derivedResponse.contains(from) { derivedResponse.insert(to) }
                if latestResponses.contains(from) { latestResponses.insert(to) }
            case "checkEqual":
                guard waited, !writePending, let left = Self.operand(s["left"], available: available),
                      let right = Self.operand(s["right"], available: available) else { return nil }
                // 不能用 literal == literal 或只比较云材料伪造握手成功；必须包含车端最新响应。
                func isResponse(_ value: Operand) -> Bool {
                    if case .slot(let key) = value { return latestResponses.contains(key) }
                    return false
                }
                guard isResponse(left) || isResponse(right) else { return nil }
                if case .slot(let a) = left, case .slot(let b) = right, a == b { return nil }
                if case .literal(let literal) = left, literal.isEmpty { return nil }
                if case .literal(let literal) = right, literal.isEmpty { return nil }
                steps.append(.equal(left, right)); proofChecked = true
            default: return nil
            }
        }
        guard writes > 0, !writePending, proofChecked else { return nil }
        self.steps = steps; self.materials = materials; self.timeout = Double(timeout) / 1000
    }
}

final class IOSBLERecipeExecutor {
    struct Receipt {
        let operationID: String
        let startSequence: Int64
        let startedUptime: TimeInterval
        let generation: String
    }
    typealias Writer = (Data, String, @escaping (Receipt) -> Void, @escaping (Bool) -> Void) -> Void
    private let recipe: IOSBLERecipe
    private let generation: String
    private let isCurrent: () -> Bool
    private let writer: Writer
    private let secret: (String) -> Data?
    private var completion: ((Bool) -> Void)?
    private var slots: [String: Data] = [:]
    private let handles: [String: String]
    private var index = 0
    private var receipt: Receipt?
    private var wrote = false
    private var acceptedWait = false
    private var wait: IOSBLERecipe.WaitRule?
    private var proofChecked = false
    private var buffer = Data()
    private var fragments: [(Data, Int64, TimeInterval, String)] = []
    private var timeout: DispatchWorkItem?
    private var stepTimeout: DispatchWorkItem?
    private var lastSequence: Int64 = 0
    private var deadline: TimeInterval = 0

    init(recipe: IOSBLERecipe, generation: String, handles: [String: String], isCurrent: @escaping () -> Bool,
         secret: @escaping (String) -> Data?, writer: @escaping Writer, completion: @escaping (Bool) -> Void) {
        self.recipe = recipe; self.generation = generation; self.handles = handles
        self.isCurrent = isCurrent; self.secret = secret; self.writer = writer; self.completion = completion
    }
    func start() {
        precondition(Thread.isMainThread)
        guard completion != nil, deadline == 0 else { return }
        deadline = ProcessInfo.processInfo.systemUptime + recipe.timeout
        let work = DispatchWorkItem { [weak self] in self?.finish(false) }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + recipe.timeout, execute: work)
        advance()
    }
    func cancel() { precondition(Thread.isMainThread); finish(false) }
    private var current: Bool { completion != nil && isCurrent() && ProcessInfo.processInfo.systemUptime < deadline }
    private func value(_ op: IOSBLERecipe.Operand) -> Data? {
        switch op {
        case .literal(let data): return data
        case .slot(let key):
            if let handle = handles[key] { return secret(handle).flatMap { $0.count <= IOSBLERecipe.maxBytes ? $0 : nil } }
            return slots[key]
        }
    }
    private func put(_ key: String, _ data: Data?) -> Bool {
        guard let data = data, data.count <= IOSBLERecipe.maxBytes, slots.count < 16 else { return false }
        slots[key] = data; return true
    }
    private func advance() {
        guard current else { finish(false); return }
        while index < recipe.steps.count {
            let step = recipe.steps[index]; index += 1
            switch step {
            case .write(let id, let frame, let parts):
                var payload = Data()
                for part in parts {
                    guard let bytes = value(part), payload.count + bytes.count <= frame.maxPayload else { finish(false); return }
                    payload.append(bytes)
                }
                guard let bytes = frame.encode(payload) else { finish(false); return }
                wipeBuffer(); fragments.removeAll(); receipt = nil; wrote = false; acceptedWait = false
                writer(bytes, id, { [weak self] proof in
                    guard let self = self, self.current, proof.operationID == id, proof.generation == self.generation else { self?.finish(false); return }
                    self.receipt = proof; self.lastSequence = proof.startSequence
                }, { [weak self] success in
                    guard let self = self, self.current, success, self.receipt != nil else { self?.finish(false); return }
                    self.wrote = true; self.advance()
                })
                payload.resetBytes(in: 0..<payload.count)
                return
            case .wait(let rule):
                guard wrote, receipt != nil, !rule.optional || proofChecked else { finish(false); return }
                wait = rule
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.current else { self?.finish(false); return }
                    guard rule.optional, self.buffer.isEmpty, self.proofChecked else { self.finish(false); return }
                    self.wait = nil; self.stepTimeout = nil; self.advance()
                }
                stepTimeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + rule.timeout, execute: work)
                let early = fragments; fragments.removeAll()
                for f in early { consume(f.0, sequence: f.1, uptime: f.2, generation: f.3) }
                return
            case .extract(let from, let field, let to, let bytes):
                guard let input = value(.slot(from)), put(to, Self.extract(input, field: field, bytes: bytes)) else { finish(false); return }
            case .aes(let from, let key, let to, let minimum, let maximum, let noControls):
                guard let input = value(.slot(from)), var material = value(.slot(key)),
                      let plain = Self.decrypt(input, key: material), (minimum...maximum).contains(plain.count),
                      let text = String(data: plain, encoding: .utf8),
                      !noControls || !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      put(to, plain) else { finish(false); return }
                material.resetBytes(in: 0..<material.count)
            case .bytesPB(let from, let field, let to):
                guard let input = value(.slot(from)) else { finish(false); return }
                let data = Self.varint(UInt64(field << 3 | 2)) + Self.varint(UInt64(input.count)) + input
                guard put(to, data) else { finish(false); return }
            case .hexUTF8(let from, let to):
                guard let input = value(.slot(from)), let text = String(data: input, encoding: .utf8),
                      text.utf8.count == input.count, put(to, IOSBLERecipe.Frame.hex(text)) else { finish(false); return }
            case .equal(let left, let right):
                guard acceptedWait, let a = value(left), let b = value(right), Self.equal(a, b) else { finish(false); return }
                proofChecked = true
            }
            guard current else { finish(false); return }
        }
        finish(proofChecked)
    }
    // 此方法只由真实 CoreBluetooth notify 调用；网页 poll/标记不能构造 receipt。
    func consume(_ data: Data, sequence: Int64, uptime: TimeInterval, generation: String) {
        precondition(Thread.isMainThread)
        guard current, let proof = receipt, proof.generation == generation, generation == self.generation,
              sequence > proof.startSequence, uptime >= proof.startedUptime else { return }
        guard data.count <= 512 else { finish(false); return }
        if wait == nil {
            guard !wrote, fragments.count < 16, fragments.reduce(0, { $0 + $1.0.count }) + data.count <= 512 else { return }
            fragments.append((data, sequence, uptime, generation)); return
        }
        guard sequence > lastSequence, let waiting = wait else { return }
        lastSequence = sequence
        guard buffer.count + data.count <= 512 else { finish(false); return }
        buffer.append(data)
        let frame = waiting.frame
        // 跳过无关完整/分片帧，但不无限积攒。匹配帧必须从本次 write 的新通知窗口开始。
        while !buffer.isEmpty {
            if buffer.count < frame.magic.count {
                if frame.magic.starts(with: buffer) { return }
                buffer.removeFirst(); buffer = Data(buffer); continue
            }
            if buffer.prefix(frame.magic.count) != frame.magic {
                buffer.removeFirst(); buffer = Data(buffer); continue
            }
            let header = frame.magic.count + 3
            if buffer.count < header { return } // 仅保留真正 magic/header 半包。
            let expected = buffer[frame.magic.count] == frame.command
            let length = Int(buffer[frame.magic.count + 1]) | Int(buffer[frame.magic.count + 2]) << 8
            if length > frame.maxPayload {
                if expected { finish(false); return }
                buffer.removeFirst(); buffer = Data(buffer); continue
            }
            let total = header + length + 1 + frame.tail.count
            if buffer.count < total { return }
            guard let result = frame.decode(buffer, acceptingAnyCommand: true) else {
                if expected { finish(false); return }
                buffer.removeFirst(); buffer = Data(buffer); continue
            }
            if !expected {
                // 真实 F3/FD 等无关完整帧整包消耗，不能给 optional ACK 留下伪半包尾。
                buffer.removeFirst(result.consumed); buffer = Data(buffer); continue
            }
            if waiting.validation == "empty", !result.payload.isEmpty { finish(false); return }
            if waiting.validation == "emptyOrVarint", !result.payload.isEmpty {
                guard let field = waiting.field, let value = Self.extract(result.payload, field: field, bytes: false),
                      waiting.values.contains(where: { Self.varint($0) == value }) else { finish(false); return }
            }
            guard put(waiting.slot, result.payload) else { finish(false); return }
            wait = nil; stepTimeout?.cancel(); stepTimeout = nil; acceptedWait = true
            wipeBuffer(); advance(); return
        }
    }
    private func wipeBuffer() { buffer.resetBytes(in: 0..<buffer.count); buffer.removeAll() }
    private func finish(_ success: Bool) {
        guard let callback = completion else { return }
        completion = nil; timeout?.cancel(); stepTimeout?.cancel(); timeout = nil; stepTimeout = nil
        wipeBuffer(); fragments.removeAll(); wait = nil; receipt = nil
        for key in Array(slots.keys) {
            if var data = slots.removeValue(forKey: key) { data.resetBytes(in: 0..<data.count) }
        }
        slots.removeAll(); callback(success)
    }
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) { result |= x ^ y }
        return result == 0
    }
    static func varint(_ n: UInt64) -> Data {
        var n = n; var out = Data()
        repeat { out.append(UInt8(n & 127) | (n > 127 ? 128 : 0)); n >>= 7 } while n != 0
        return out
    }
    static func extract(_ data: Data, field: Int, bytes: Bool) -> Data? {
        guard data.count <= 240 else { return nil }
        var at = 0; var seen = Set<Int>(); var result: Data?
        func read() -> UInt64? {
            var value: UInt64 = 0
            for i in 0..<10 {
                guard at < data.count else { return nil }
                let b = data[at]; at += 1
                guard i != 9 || b & 254 == 0 else { return nil }
                value |= UInt64(b & 127) << (i * 7)
                if b & 128 == 0 { return value }
            }
            return nil
        }
        while at < data.count {
            guard let tag = read(), tag > 0, tag <= UInt64(Int32.max), seen.count < 64 else { return nil }
            let number = Int(tag >> 3), wire = Int(tag & 7)
            guard number > 0, seen.insert(number).inserted else { return nil }
            var value: Data
            switch wire {
            case 0: guard let n = read() else { return nil }; value = varint(n)
            case 1, 5:
                let length = wire == 1 ? 8 : 4
                guard at + length <= data.count else { return nil }
                value = data.subdata(in: at..<(at + length)); at += length
            case 2:
                guard let n = read(), n <= 240, at + Int(n) <= data.count else { return nil }
                value = data.subdata(in: at..<(at + Int(n))); at += Int(n)
            default: return nil
            }
            if number == field {
                guard wire == (bytes ? 2 : 0) else { return nil }
                result = value
            }
        }
        return result
    }
    static func decrypt(_ data: Data, key: Data) -> Data? {
        guard !data.isEmpty, data.count <= 240, data.count % 16 == 0, [16, 24, 32].contains(key.count) else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128); var used = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, nil, input.baseAddress, input.count, out.baseAddress, capacity, &used)
                }
            }
        }
        guard status == kCCSuccess, used <= 240 else { output.resetBytes(in: 0..<output.count); return nil }
        output.count = used; return output
    }
}
