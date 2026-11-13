import Foundation
import Security
import CoreFoundation
import Darwin

struct IOSSecretHandleFailure: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

// 运行时密钥不是存档密钥。只在 native 内存里保留；网页只能拿不可读的随机句柄。
// scope.generation 来自 Bridge 的 credential epoch，而不是前后台/导航 generation。
final class IOSSecretHandleService: IOSBridgeService {
    enum Purpose: String { case signer, token, baseline }
    enum ValueType: String { case bytes, string }
    static let maxBytes = 32_768
    static let maxHandles = 12
    // 网页导入仍限 12；native 换材期间最多 8 个保留槽，避免先删旧 baseline 才能认证新材料。
    static let maxRecordingHandles = 20
    static let maxTotalBytes = 262_144
    static let importTTL: Double = 300
    static let recordingTTL: Double = 7_200
    let methods = ["secret.import", "secret.release"]

    private final class Entry {
        let scope: IOSRideScope
        let purpose: Purpose
        let type: ValueType
        let bytes: UnsafeMutableRawPointer
        let count: Int
        var expires: Double
        var recordingID: UUID?
        init(scope: IOSRideScope, purpose: Purpose, type: ValueType, data: Data, expires: Double) {
            self.scope = scope; self.purpose = purpose; self.type = type
            count = data.count; self.expires = expires
            bytes = .allocate(byteCount: data.count, alignment: 1)
            data.withUnsafeBytes { source in bytes.copyMemory(from: source.baseAddress!, byteCount: count) }
        }
        deinit {
            // 独立 allocation 避免 Data 的写时复制把待擦除内存留在另一份共享副本里。
            _ = memset_s(bytes, count, 0, count)
            bytes.deallocate()
        }
    }

    private struct Reservation { let scope: IOSRideScope; var slots: Int; var bytes: Int }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var reservations: [UUID: Reservation] = [:]
    private var scopeProvider: (() -> IOSRideScope?)?
    private var metadataProvider: (() -> [String: Any]?)?

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread); scopeProvider = provider
    }
    func configureSessionMetadataProvider(_ provider: @escaping () -> [String: Any]?) {
        precondition(Thread.isMainThread); metadataProvider = provider
    }

    static func accepts(_ options: [String: Any], metadata: [String: Any], scope: IOSRideScope) -> Bool {
        guard scope.valid, let epoch = integer(options["epoch"]),
              epoch == integer(metadata["epoch"]), String(epoch) == scope.generation,
              options["navigationId"] as? String == metadata["navId"] as? String,
              options["frame"] as? String == metadata["frame"] as? String,
              let nav = metadata["navId"] as? String, !nav.isEmpty,
              let frame = metadata["frame"] as? String, !frame.isEmpty,
              metadata["accountId"] as? String == scope.accountID,
              metadata["vin"] as? String == scope.vin else { return false }
        return true
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              abs(n.doubleValue) <= 9_007_199_254_740_991 else { return nil }
        return n.intValue
    }
    static func text(_ value: Any?, max: Int, empty: Bool = false) -> String? {
        guard let s = value as? String, (empty || !s.isEmpty), s.utf8.count <= max,
              !s.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return s
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count == 1, let options = args.first as? [String: Any],
              let scope = scopeProvider?(), let metadata = metadataProvider?(),
              Self.accepts(options, metadata: metadata, scope: scope) else { reply(nil, "stale_session"); return }
        let common: Set<String> = ["navigationId", "epoch", "frame"]
        do {
            if method == "secret.import" {
                guard Set(options.keys).isSubset(of: common.union(["importBase64", "type", "purpose", "ttlMs"])),
                      let type = ValueType(rawValue: options["type"] as? String ?? ""),
                      let purpose = Purpose(rawValue: options["purpose"] as? String ?? ""),
                      let text = options["importBase64"] as? String,
                      !text.isEmpty, text.utf8.count <= ((Self.maxBytes + 2) / 3) * 4,
                      var data = Data(base64Encoded: text), !data.isEmpty, data.count <= Self.maxBytes,
                      data.base64EncodedString() == text else { throw IOSSecretHandleFailure("invalid_secret_import") }
                defer { data.resetBytes(in: 0..<data.count) }
                if type == .string {
                    guard String(data: data, encoding: .utf8) != nil else { throw IOSSecretHandleFailure("invalid_secret_string") }
                }
                if purpose == .token {
                    guard type == .string, let token = String(data: data, encoding: .utf8),
                          Self.text(token, max: Self.maxBytes) != nil else { throw IOSSecretHandleFailure("invalid_token") }
                }
                let ttl: Int
                if let requested = options["ttlMs"] {
                    guard let parsed = Self.integer(requested), parsed > 0, parsed <= Int(Self.importTTL * 1000) else {
                        throw IOSSecretHandleFailure("invalid_secret_ttl")
                    }
                    ttl = parsed
                } else { ttl = Int(Self.importTTL * 1000) }
                let handle = try importOpaque(data, scope: scope, purpose: purpose, type: type,
                                              expires: ProcessInfo.processInfo.systemUptime + Double(ttl) / 1000)
                reply(["ok": true, "handle": handle, "grantScope": ["epoch": scope.generation]], nil)
            } else if method == "secret.release" {
                guard Set(options.keys).isSubset(of: common.union(["handle"])),
                      let handle = options["handle"] as? String, UUID(uuidString: handle) != nil else {
                    throw IOSSecretHandleFailure("invalid_secret_handle")
                }
                try release(handle: handle, scope: scope)
                reply(["ok": true], nil)
            } else { reply(nil, "unsupported_method") }
        } catch { reply(nil, (error as? IOSSecretHandleFailure)?.code ?? "secret_failed") }
    }

    // 以下均是 native-only API；methods 没有 read/export，回执不会序列化 bytes 或新材料。
    func importOpaque(_ data: Data, scope: IOSRideScope, purpose: Purpose = .baseline,
                      type: ValueType = .string, expires: Double, recordingID: UUID? = nil) throws -> String {
        guard scope.valid, !data.isEmpty, data.count <= Self.maxBytes, expires.isFinite,
              expires > ProcessInfo.processInfo.systemUptime,
              expires <= ProcessInfo.processInfo.systemUptime + Self.recordingTTL else { throw IOSSecretHandleFailure("invalid_secret_import") }
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        let ownReservation = recordingID.flatMap { reservations[$0] }
        let otherSlots = reservations.reduce(0) { $0 + ($1.key == recordingID ? 0 : $1.value.slots) }
        let otherBytes = reservations.reduce(0) { $0 + ($1.key == recordingID ? 0 : $1.value.bytes) }
        let limit = recordingID == nil ? Self.maxHandles : Self.maxRecordingHandles
        guard entries.count + otherSlots < limit else { throw IOSSecretHandleFailure("secret_handle_limit") }
        guard entries.values.reduce(0, { $0 + $1.count }) + otherBytes <= Self.maxTotalBytes - data.count,
              ownReservation == nil || entries.values.reduce(0, { $0 + $1.count }) + otherBytes + (ownReservation?.bytes ?? 0) <= Self.maxTotalBytes else {
            throw IOSSecretHandleFailure("secret_bytes_limit")
        }
        if let reserve = ownReservation {
            // 预留按实际材料字节核销：entries 增加多少，reservation 就减少多少，
            // 二者之和保持不变。若固定扣 4096，1 字节材料会白放出 4095 字节被其它
            // import 抢走，导致换材 ACK 后补预算失败、整次录制授权被迫停止。
            guard reserve.scope == scope, reserve.slots > 0, reserve.bytes >= data.count,
                  purpose == .baseline, data.count <= 4096, let recordingID = recordingID else {
                throw IOSSecretHandleFailure("secret_reservation_limit")
            }
            reservations[recordingID] = Reservation(scope: scope, slots: reserve.slots - 1, bytes: reserve.bytes - data.count)
        }
        let handle = UUID().uuidString.lowercased()
        let entry = Entry(scope: scope, purpose: purpose, type: type, data: data, expires: expires)
        entry.recordingID = recordingID; entries[handle] = entry
        return handle
    }

    // callback 在锁内只做有界 crypto/compare；不得重入本服务、做 IO 或保留 pointer。
    func withSecret<T>(handle: String, scope: IOSRideScope, purpose: Purpose,
                       recordingID: UUID? = nil, body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard let entry = entries[handle], entry.scope == scope, entry.purpose == purpose,
              entry.recordingID == recordingID else { throw IOSSecretHandleFailure("secret_handle_unavailable") }
        return try body(UnsafeRawBufferPointer(start: entry.bytes, count: entry.count))
    }
    func valueType(handle: String, scope: IOSRideScope, purpose: Purpose, recordingID: UUID? = nil) throws -> ValueType {
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        guard let entry = entries[handle], entry.scope == scope, entry.purpose == purpose,
              entry.recordingID == recordingID else { throw IOSSecretHandleFailure("secret_handle_unavailable") }
        return entry.type
    }
    func matches(handle: String, data: Data, scope: IOSRideScope, recordingID: UUID?) throws -> Bool {
        try withSecret(handle: handle, scope: scope, purpose: .baseline, recordingID: recordingID) { bytes in
            guard bytes.count == data.count else { return false }
            return data.withUnsafeBytes { (other: UnsafeRawBufferPointer) in
                var diff: UInt8 = 0
                for index in 0..<bytes.count { diff |= bytes[index] ^ other[index] }
                return diff == 0
            }
        }
    }

    // 只有 native UI 已批准、真实 run 已存在时，由 renewal service 原子接管这些句柄。
    // 此处延的是内存保留时长，不是车辆授权时长，绝不据此产生 authenticated=true。
    func bindRecording(handles: Set<String>, scope: IOSRideScope, recordingID: UUID, consentUntil: Double,
                       replacementMaterials: Set<String> = []) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard consentUntil > now, consentUntil <= now + Self.recordingTTL else { throw IOSSecretHandleFailure("invalid_recording_grant") }
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        for handle in handles {
            guard let entry = entries[handle], entry.scope == scope,
                  entry.recordingID == nil || entry.recordingID == recordingID else { throw IOSSecretHandleFailure("secret_handle_unavailable") }
        }
        guard replacementMaterials.isSubset(of: handles) else { throw IOSSecretHandleFailure("secret_reservation_limit") }
        reservations[recordingID] = try replacementBudgetLocked(scope: scope, recordingID: recordingID, materials: replacementMaterials)
        for handle in handles { entries[handle]?.recordingID = recordingID; entries[handle]?.expires = consentUntil }
    }
    // 只读 preflight 在 native consent / fresh IO 之前执行；bind 时再同锁提交预留防竞争。
    func checkReplacementBudget(scope: IOSRideScope, recordingID: UUID, materials: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        _ = try replacementBudgetLocked(scope: scope, recordingID: recordingID, materials: materials)
    }
    func reserveReplacements(scope: IOSRideScope, recordingID: UUID, materials: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        guard entries.values.contains(where: { $0.scope == scope && $0.recordingID == recordingID }) else {
            throw IOSSecretHandleFailure("secret_handle_unavailable")
        }
        reservations[recordingID] = try replacementBudgetLocked(scope: scope, recordingID: recordingID, materials: materials)
    }
    private func replacementBudgetLocked(scope: IOSRideScope, recordingID: UUID, materials: Set<String>) throws -> Reservation {
        let slots = materials.count
        guard slots <= 8 else { throw IOSSecretHandleFailure("secret_reservation_limit") }
        var currentMaterialBytes = 0
        for handle in materials {
            guard let entry = entries[handle], entry.scope == scope, entry.purpose == .baseline, entry.count <= 4096,
                  entry.recordingID == nil || entry.recordingID == recordingID else { throw IOSSecretHandleFailure("secret_handle_unavailable") }
            currentMaterialBytes += entry.count
        }
        // 预留 = 本轮小材料长到 4KiB 的差额 + 下一轮完整新材料。
        // 不能只按当前尺寸加一轮：否则成功换大材料后补下一轮预算会才发现超限。
        let reservedBytes = slots * 4096 * 2 - currentMaterialBytes
        let others = reservations.filter { $0.key != recordingID }
        guard entries.count + others.values.reduce(0, { $0 + $1.slots }) + slots <= Self.maxRecordingHandles,
              entries.values.reduce(0, { $0 + $1.count }) + others.values.reduce(0, { $0 + $1.bytes }) + reservedBytes <= Self.maxTotalBytes else {
            throw IOSSecretHandleFailure("secret_reservation_limit")
        }
        return Reservation(scope: scope, slots: slots, bytes: reservedBytes)
    }
    func release(handle: String, scope: IOSRideScope) throws {
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        guard let entry = entries[handle], entry.scope == scope else { throw IOSSecretHandleFailure("secret_handle_unavailable") }
        entries.removeValue(forKey: handle)
    }
    func recordingEnded(recordingId: UUID) {
        lock.lock(); defer { lock.unlock() }
        for handle in Array(entries.keys) where entries[handle]?.recordingID == recordingId { entries.removeValue(forKey: handle) }
        reservations.removeValue(forKey: recordingId)
    }
    func scopeChanged() {
        precondition(Thread.isMainThread)
        let scope = scopeProvider?()
        lock.lock(); defer { lock.unlock() }
        for handle in Array(entries.keys) where entries[handle]?.scope != scope { entries.removeValue(forKey: handle) }
        for id in Array(reservations.keys) where reservations[id]?.scope != scope { reservations.removeValue(forKey: id) }
    }
    func navigationChanged() {
        precondition(Thread.isMainThread)
        scopeChanged()
        lock.lock(); defer { lock.unlock() }; pruneLocked()
        for handle in Array(entries.keys) where entries[handle]?.recordingID == nil { entries.removeValue(forKey: handle) }
    }
    func applicationBackgrounded() { navigationChanged() }
    private func pruneLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        for handle in Array(entries.keys) where (entries[handle]?.expires ?? 0) <= now { entries.removeValue(forKey: handle) }
        for id in Array(reservations.keys) where !entries.values.contains(where: { $0.recordingID == id }) { reservations.removeValue(forKey: id) }
    }
}
