import Foundation
import UIKit
import CoreLocation
import UserNotifications
import CryptoKit
import CoreFoundation
import Darwin
import ZeehoSystemShared

// 长期归属是稳定账号 + VIN；generation 只撤销在途采样，不让重登/重启隐藏旧记录。
// 只接核心桥的原生会话 provider，从不接收网页 token 或用网页布尔值证明车辆所有权。
struct IOSRideScope: Equatable {
    let accountID: String
    let vin: String
    let generation: String

    var valid: Bool {
        [accountID, vin, generation].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }

    var ownerHash: String {
        var data = Data()
        for value in [accountID, vin] {
            let part = Data(value.utf8)
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(part)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum IOSRideJSON {
    static func object(_ text: String) -> [String: Any]? {
        guard text.utf8.count <= 8 * 1024 * 1024, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func integer(_ value: Any?, minimum: Int64 = 0, maximum: Int64 = Int64.max) -> Int64? {
        guard let n = number(value), n.rounded(.towardZero) == n, n >= Double(minimum), n < Double(Int64.max) else { return nil }
        let result = Int64(n)
        return result <= maximum ? result : nil
    }

    static func telemetry(_ source: [String: Any]) -> [String: Any] {
        let bounds: [String: ClosedRange<Double>] = [
            "speedKph": 0...400, "socPercent": 0...100, "voltageV": 0...200,
            "tempC": -50...150, "headLockState": 0...2,
            "socRaw": 0...4294967295, "powerRaw": 0...100000,
            "powerDeltaRaw": -1500...98500, "odometerRaw": 0...4294967295,
            "modeRaw": 0...4294967295, "lightRaw": 0...4294967295
        ]
        var result: [String: Any] = [:]
        for (key, range) in bounds {
            if let value = number(source[key]), range.contains(value) { result[key] = value }
        }
        return result
    }

    // 这是公共读数投影，不解析认证/订阅状态机；档位只解释用户确认的低四位。
    // 每个字段独立用原生接收时刻过期，FD 电量包绝不能给 F3 旧速度续命。
    static func visibleTelemetry(_ source: [String: Any], times: [String: Int64],
                                 uptimes: [String: TimeInterval], now: TimeInterval) -> [String: Any] {
        var values: [String: Any] = [:]
        var stamps: [String: Int64] = [:]
        for (key, value) in telemetry(source) {
            guard let at = times[key], at > 0, let uptime = uptimes[key],
                  now >= uptime, now - uptime < 10 else { continue }
            values[key] = value; stamps[key] = at
        }
        if let mode = integer(values["modeRaw"], maximum: 4294967295), let at = stamps["modeRaw"] {
            let gear = mode & 0x0f
            values["gearCode"] = gear <= 3 ? gear as Any : NSNull()
            stamps["gearCode"] = at
        }
        return ["telemetry": values, "telemetryTimes": stamps]
    }

    static func publicRecordState(_ state: String) -> String {
        switch state {
        case "saving": return "ending"
        case "paused", "stale", "unavailable", "gap": return "gap"
        case "permission_required", "waiting", "disabled": return "waiting"
        case "not_recorded": return "completed"
        case "recording", "ending", "completed", "interrupted", "save_failed", "error": return state
        default: return "error"
        }
    }

    static func fields(_ source: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        let statuses: Set<String> = ["captured_small_frame", "static_schema_unverified", "unsupported_command"]
        let reasons: Set<String> = ["wrong_wire", "out_of_range", "half_step_unverified", "unit_unverified",
                                   "field_unverified", "static_schema_unverified", "proto3_default", "non_finite", "duplicate_field"]
        if let status = source["status"] as? String, statuses.contains(status) { result["status"] = status }
        if let verified = source["unitsVerified"] as? Bool { result["unitsVerified"] = verified }
        if let command = integer(source["command"], maximum: 255) { result["command"] = command }
        if let length = integer(source["payloadLength"], maximum: 240) { result["payloadLength"] = length }
        if let unsupported = source["unsupported"] as? [String: Any] {
            result["unsupported"] = unsupported.filter { _, value in
                if let reason = value as? String { return reasons.contains(reason) }
                return false
            }
        }
        for index in 1...64 {
            guard let raw = source["field\(index)"] as? [String: Any] else { continue }
            var field: [String: Any] = [:]
            if let wire = integer(raw["wire"], maximum: 5) { field["wire"] = wire }
            if let numeric = number(raw["numeric"]) { field["numeric"] = numeric }
            if let present = raw["present"] as? Bool { field["present"] = present }
            if let reason = raw["reason"] as? String, reasons.contains(reason) { field["reason"] = reason }
            // 未知 bytes 可能含身份/认证物料，不复制 bytes/digest/summary。
            if !field.isEmpty { result["field\(index)"] = field }
        }
        return result
    }
}

// 骑行桥回执里要用的人读文案。IOSStrings 是独立文件，本次修复限定只改 Ride.swift，
// 先就近定义；后续统一迁到 IOSStrings 时删掉这里。
private enum IOSRideText {
    static let notRecorded = "本次没有采集到数据"
}

private enum IOSRideDisk {
    static let maxSamples = 20000
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxOwnerBytes = 64 * 1024 * 1024
    static let maxTotalBytes = 256 * 1024 * 1024
    static let maxFiles = 100
    static let maxOwners = 64
    static let parseBudget = 16 * 1024 * 1024
    /// 全库用量缓存的有效期。checkpoint 每 15 秒一轮，每次都遍历最多 64 个 owner 目录
    /// × 100 个文件，会在串行落盘队列上堆出明显延迟；60 秒内的旧值足够当提前拒绝的依据。
    static let usageTTL: TimeInterval = 60

    struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    struct Orphan {
        let id: String
        let at: Int64?
    }

    // save 既跑在串行 worker 上，也可能被 deinit 的独立队列调用，缓存必须自己加锁。
    private static let usageLock = NSLock()
    private static var usageCache: [String: (bytes: Int, at: Date)] = [:]

    private static func cachedUsage(_ key: String, now: Date) -> Int? {
        usageLock.lock(); defer { usageLock.unlock() }
        guard let entry = usageCache[key], now.timeIntervalSince(entry.at) < usageTTL else { return nil }
        return entry.bytes
    }

    private static func storeUsage(_ key: String, bytes: Int, now: Date) {
        usageLock.lock(); usageCache[key] = (bytes, now); usageLock.unlock()
    }

    private static func usagesInvalidate(_ key: String) {
        usageLock.lock(); usageCache.removeValue(forKey: key); usageLock.unlock()
    }

    private static func directory(owner: String, create: Bool) throws -> URL {
        guard owner.count == 64, owner.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure("invalid_scope") }
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure("storage_unavailable")
        }
        let root = support.appendingPathComponent("zeeho-rides-v1", isDirectory: true)
        let target = root.appendingPathComponent(owner, isDirectory: true)
        if create {
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: root.path) { try manager.createDirectory(at: root, withIntermediateDirectories: false) }
            let owners = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            if !manager.fileExists(atPath: target.path) {
                guard owners.count < maxOwners else { throw Failure("storage_limit_reached") }
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
            }
            try manager.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            var protected = target
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try protected.setResourceValues(resources)
        }
        for url in [root, target] where manager.fileExists(atPath: url.path) {
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        }
        return target
    }

    static func url(owner: String, id: UUID, create: Bool = false) throws -> URL {
        try directory(owner: owner, create: create).appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private static func files(owner: String) throws -> [URL] {
        let target = try directory(owner: owner, create: false)
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: target,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        guard entries.count <= maxFiles + 1 else { throw Failure("storage_limit_reached") }
        return try entries.filter { item in
            guard item.pathExtension == "json", let uuid = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  item.lastPathComponent == uuid.uuidString.lowercased() + ".json" else { return false }
            let attributes = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else { throw Failure("unsafe_storage_path") }
            return true
        }
    }

    static func save(_ record: [String: Any], owner: String, id: UUID) throws -> Int {
        guard JSONSerialization.isValidJSONObject(record) else { throw Failure("invalid_record") }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard data.count <= maxFileBytes else { throw Failure("record_limit_reached") }
        let target = try url(owner: owner, id: id, create: true)
        let siblings = try files(owner: owner)
        // 分档错误码：只有「删掉本 owner 的旧记录就能腾出空间」的那几种才允许回收。
        // 原来它们都叫 storage_limit_reached，回收器不分青红皂白删 8 条，
        // 撞到 owner 数上限（64 个目录）时删再多也修不好，白删真实历史。
        guard siblings.contains(target) || siblings.count < maxFiles else { throw Failure("owner_storage_full") }
        var bytes = 0
        for item in siblings where item != target {
            bytes += try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        guard bytes + data.count <= maxOwnerBytes else { throw Failure("owner_storage_full") }
        let root = target.deletingLastPathComponent().deletingLastPathComponent()
        let targetDirectory = target.deletingLastPathComponent().path
        let targetSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let stamp = Date()
        var total = 0
        let scopes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        // 目录数触顶：这是全局身份数量上限，删本 owner 的记录毫无帮助。
        guard scopes.count <= maxOwners else { throw Failure("storage_limit_reached") }
        for scope in scopes {
            let attributes = try scope.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
            // 每次 checkpoint 都全库重扫会在落盘队列上堆出明显延迟；60 秒内的目录用量直接复用。
            // 目标文件自身的旧大小要扣掉：这次写入会原子替换它，不能重复计入。
            let key = scope.path
            let scopeBytes: Int
            if let cached = cachedUsage(key, now: stamp) {
                scopeBytes = cached
            } else {
                let entries = try FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                // 别的 owner 目录塞满文件：删本 owner 的记录也修不好。
                guard entries.count <= maxFiles + 1 else { throw Failure("storage_limit_reached") }
                var sum = 0
                for item in entries { sum += try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
                storeUsage(key, bytes: sum, now: stamp)
                scopeBytes = sum
            }
            total += max(0, scopeBytes - (key == targetDirectory ? targetSize : 0))
        }
        // 之前是边加边判，现在按目录聚合后再判：同等拒绝能力，但少了一堆 syscall。
        // 全库总量触顶同样是「删本 owner 的旧记录可以缓解」，所以也归 owner_storage_full。
        guard total + data.count <= maxTotalBytes else { throw Failure("owner_storage_full") }
        if FileManager.default.fileExists(atPath: target.path) {
            let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        }
        // 非凭据文件不用 Keychain；原子替换 + 首次解锁后的文件保护允许获准的锁屏录制落盘。
        // .atomic 不代表最后 fsync 必然成功，末次 synchronize/close 都成功后才报告 completed。
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        let handle = try FileHandle(forUpdating: target)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw Failure("save_sync_failed") }
        let descriptor = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure("save_sync_failed") }
        let synced = fsync(descriptor)
        let closed = Darwin.close(descriptor)
        guard synced == 0, closed == 0 else { throw Failure("save_sync_failed") }
        // 本目录用量已变，缓存作废；其他目录的旧值仍然有效。
        usagesInvalidate(targetDirectory)
        return data.count
    }

    /// 8 MiB 单文件上限兜底：保留最早的样本，按比例丢尾部。
    /// 整条记录因为超限永远写不进去时，宁可少存尾部也不能让用户整趟骑行丢失；
    /// 每次尝试都重新序列化确认真的落到上限内，避免凭估算再次超限。
    static func trimmed(_ record: [String: Any]) -> [String: Any]? {
        guard let gps = record["rawGPS"] as? [[String: Any]],
              let telemetry = record["telemetry"] as? [[String: Any]] else { return nil }
        let total = gps.count + telemetry.count
        guard total > 1 else { return nil }
        var ratio = 0.9
        while ratio >= 0.05 {
            let keep = max(1, Int(Double(total) * ratio))
            // 按各自占比等比例保留，避免只砍掉 GPS 或只砍掉 BLE 导致某一类样本全缺。
            let keepGPS = min(gps.count, Int((Double(keep) * Double(gps.count) / Double(total)).rounded(.down)))
            let keepBLE = min(telemetry.count, keep - keepGPS)
            guard keepGPS + keepBLE < total else { ratio -= 0.1; continue }
            var value = record
            value["rawGPS"] = Array(gps.prefix(keepGPS))
            value["telemetry"] = Array(telemetry.prefix(keepBLE))
            // read() 要求 samples 与两类样本总数严格一致，截断后必须同步。
            value["samples"] = keepGPS + keepBLE
            if var report = value["report"] as? [String: Any] {
                report["gpsSamples"] = keepGPS
                report["bleSamples"] = keepBLE
                value["report"] = report
            }
            var gaps = value["gaps"] as? [[String: Any]] ?? []
            if gaps.count < 1024 {
                gaps.append(["at": Int64(Date().timeIntervalSince1970 * 1000),
                             "elapsedMs": IOSRideJSON.integer(record["elapsedMs"]) ?? 0,
                             "source": "storage", "reason": "trimmed_for_size"])
                value["gaps"] = gaps
            }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               data.count <= maxFileBytes { return value }
            ratio -= 0.2
        }
        return nil
    }

    static func read(owner: String, id: UUID) throws -> [String: Any] {
        let target = try url(owner: owner, id: id)
        let attributes = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maxFileBytes else { throw Failure("invalid_record") }
        let data = try Data(contentsOf: target)
        guard data.count <= maxFileBytes,
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              IOSRideJSON.integer(record["version"]) == 1, record["owner"] as? String == owner,
              record["id"] as? String == id.uuidString.lowercased(),
              let gps = record["rawGPS"] as? [[String: Any]], let telemetry = record["telemetry"] as? [[String: Any]],
              let gaps = record["gaps"] as? [[String: Any]], gps.count + telemetry.count <= maxSamples, gaps.count <= 1024,
              IOSRideJSON.integer(record["samples"]) == Int64(gps.count + telemetry.count),
              IOSRideJSON.integer(record["startedAt"], minimum: 1) != nil else { throw Failure("invalid_record") }
        var lastGPSAt: Int64 = 0
        var lastGPSSeq: Int64 = 0
        var lastBLEAt: Int64 = 0
        var lastBLESeq: Int64 = 0
        for sample in gps {
            guard sample["provider"] as? String == "corelocation",
                  IOSRideJSON.integer(sample["at"], minimum: 1) != nil,
                  IOSRideJSON.integer(sample["seq"], minimum: 1) != nil,
                  IOSRideJSON.integer(sample["elapsedMs"]) != nil else { throw Failure("invalid_record") }
            // lat/lng 只在定位成功时成对写入；单边存在说明文件被截断或改写过，
            // 放行会让详情页画出半个坐标（之前 lat 有值、lng 缺失就直接跳过校验）。
            let lat = IOSRideJSON.number(sample["lat"])
            let lng = IOSRideJSON.number(sample["lng"])
            guard (lat == nil) == (lng == nil) else { throw Failure("invalid_record") }
            if let lat = lat, let lng = lng {
                guard (-90...90).contains(lat), (-180...180).contains(lng) else { throw Failure("invalid_record") }
            }
            if let accuracy = IOSRideJSON.number(sample["accuracy"]), accuracy < 0 { throw Failure("invalid_record") }
            if let speed = IOSRideJSON.number(sample["speedKph"]), !(0...400).contains(speed) { throw Failure("invalid_record") }
            // at/seq 是时间线与去重的基础；不是严格递增就意味着乱序样本，读完会污染统计。
            if let at = IOSRideJSON.integer(sample["at"], minimum: 1) {
                guard at >= lastGPSAt else { throw Failure("invalid_record") }
                lastGPSAt = at
            }
            if let seq = IOSRideJSON.integer(sample["seq"], minimum: 1) {
                guard seq >= lastGPSSeq else { throw Failure("invalid_record") }
                lastGPSSeq = seq
            }
        }
        for sample in telemetry {
            guard let values = sample["values"] as? [String: Any], !values.isEmpty,
                  IOSRideJSON.telemetry(values).count == values.count,
                  let times = sample["times"] as? [String: Any], times.count == values.count,
                  times.values.allSatisfy({ IOSRideJSON.integer($0, minimum: 1) != nil }),
                  ["ble_period", "ble_dash"].contains(sample["source"] as? String ?? ""),
                  let at = IOSRideJSON.integer(sample["at"], minimum: 1) else { throw Failure("invalid_record") }
            guard at >= lastBLEAt else { throw Failure("invalid_record") }
            lastBLEAt = at
            if let seq = IOSRideJSON.integer(sample["seq"], minimum: 1) {
                guard seq >= lastBLESeq else { throw Failure("invalid_record") }
                lastBLESeq = seq
            }
        }
        return record
    }

    static func summary(_ record: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["id", "startedAt", "endedAt", "state", "reason", "durationMs", "elapsedMs", "samples", "report"] {
            result[key] = record[key] ?? NSNull()
        }
        if record["endedAt"] is NSNull || record["endedAt"] == nil {
            result["state"] = "interrupted"
            result["reason"] = "unfinished_record"
            result["incomplete"] = true
        } else { result["incomplete"] = false }
        result["recordingId"] = record["id"] ?? NSNull()
        result["recordedSamples"] = record["samples"] ?? NSNull()
        result["countIsPartial"] = result["incomplete"] as? Bool == true
        return result
    }

    static func list(owner: String) throws -> [String: Any] {
        let allFiles = try files(owner: owner)
        let entries = allFiles.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        var remaining = parseBudget
        var summaries: [[String: Any]] = []
        var error = ""
        var used = 0
        var failed = 0
        // 列表上限（30 条）曾完全不对外标注：第 31 条及更旧的记录在 App 内既看不见也删不掉，
        // 却继续占预算；`storage.files` 报真实文件数，用户会看到「50 files 却只列出 30 条」。
        // 现在显式回报被截断的条数与总数，网页才能提示「还有 N 条更旧记录」并给删除入口。
        let listLimit = 30
        var truncated = 0
        for item in entries {
            let size = try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            used += size
            guard summaries.count < listLimit else { truncated += 1; continue }
            guard size <= remaining else { if error.isEmpty { error = "records_parse_limit" }; failed += 1; continue }
            remaining -= size
            guard let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent) else { continue }
            do { summaries.append(summary(try read(owner: owner, id: id))) }
            // catch 的隐式变量名是 error，会遮蔽外层同名的 String 变量；显式命名避免歧义。
            catch let failure { failed += 1; if error.isEmpty { error = (failure as? Failure)?.code ?? "records_read_failed" } }
        }
        // ok 只表示「这次调用本身成功」：坏一条不该让整页列表拿不到。
        // 只有目录里确实有文件、却一条都读不出来时才判失败——否则网页会当成「记录被清空」。
        let nothingReadable = used > 0 && summaries.isEmpty && failed > 0
        return ["ok": !nothingReadable, "records": summaries, "recordsReady": true, "recordsError": error,
                // truncated：因为 30 条展示上限而没出现在 records 里的条数。
                "truncated": truncated, "totalRecords": entries.count, "listLimit": listLimit,
                "storage": ["files": allFiles.count, "bytes": used, "maxFiles": maxFiles,
                            "maxOwnerBytes": maxOwnerBytes, "maxTotalBytes": maxTotalBytes,
                            "maxFileBytes": maxFileBytes, "maxSamples": maxSamples],
                "partial": !nothingReadable && !error.isEmpty]
    }

    /// 启动扫盘：找出本 owner 目录里 endedAt 为空的历史文件（上次录制被系统杀掉/崩溃）。
    /// 只做提示，不自动续记——没有活跃的 Location/Bluetooth 上下文，续记会写出假样本。
    /// 这里刻意只做浅解析：init 阶段不该为几十个文件跑完整样本校验。
    ///
    /// 限制用「条数」而不是按字节 break：`files()` 是目录原始顺序，按字节 break 时
    /// 每次都在同一批文件上耗尽预算，后面的孤儿永远看不到，「剩下的下次再扫」也就不成立。
    /// 现在只扫最近修改的 scanEntries 条——录制中被杀留下的孤儿通常就是最近这几条。
    static func orphans(owner: String) throws -> [Orphan] {
        var result: [Orphan] = []
        let scanEntries = 40
        let sorted = try files(owner: owner).sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        for item in sorted.prefix(scanEntries) {
            guard result.count < maxFiles else { break }
            guard let size = try item.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maxFileBytes,
                  let data = try? Data(contentsOf: item),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard record["endedAt"] == nil || record["endedAt"] is NSNull else { continue }
            guard let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent) else { continue }
            let at = IOSRideJSON.integer(record["startedAt"], minimum: 1)
            result.append(Orphan(id: id.uuidString.lowercased(), at: at))
        }
        return result
    }

    static func delete(owner: String, id: UUID) throws {
        let target = try url(owner: owner, id: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return } // 幂等，不写另一份墓碑/假记录。
        let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        try FileManager.default.removeItem(at: target)
        // 删完立刻作废用量缓存：否则 60 秒内的旧值仍按「删之前」的偏大体积拒绝下一次写入。
        usagesInvalidate(target.deletingLastPathComponent().path)
    }

    /// 预算/文件数触顶时的回收：删本 owner 目录里最旧的「已完成」记录，给当前这趟腾地方。
    ///
    /// 为什么需要它：这批上限（64MB/owner、256MB/全库、100 文件）都是硬墙，而原来全库
    /// 唯一删除入口只有用户手动 `ride.delete`。按 1 小时 ≈ 3MB 算，同一账号累计约 20 小时
    /// 骑行就撞到 64MB，此后每一趟都从第一条 checkpoint 就写不进去，
    /// 整趟只活在内存里、进程一死全丢。自动回收最旧的已完成记录是唯一能保住当前这趟的做法。
    ///
    /// 只删 `endedAt` 非空的文件（真正收尾过）。`endedAt` 为空的是崩溃/被杀留下的，
    /// 还要靠 `orphans()` 提示用户处理，绝不能在这里悄悄删掉。
    /// 目标文件自身永远不动（那就是正在录的这趟）。单次最多删 8 条，避免一次失败把历史清空。
    @discardableResult
    static func evictOldestFinished(owner: String, protecting id: UUID) -> Int {
        let manager = FileManager.default
        guard let target = try? directory(owner: owner, create: false),
              manager.fileExists(atPath: target.path),
              // files() 在条目超上限时会自己抛错，回收本身必须绕过那道闸，所以这里单独列目录。
              let entries = try? manager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return 0 }
        let protectedName = id.uuidString.lowercased() + ".json"
        // 函数内声明无捕获的局部结构：不走命名空间，也不会影响文件里其他类型。
        var candidates: [(url: URL, modified: Date)] = []
        for item in entries {
            guard item.lastPathComponent != protectedName, item.pathExtension == "json",
                  let uuid = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  item.lastPathComponent == uuid.uuidString.lowercased() + ".json",
                  let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // 浅解析只为确认「这趟确实收尾过」，与 orphans() 同口径；不为几十个文件跑完整校验。
            guard let data = try? Data(contentsOf: item),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["endedAt"] != nil, !(record["endedAt"] is NSNull) else { continue }
            candidates.append((url: item, modified: values.contentModificationDate ?? .distantPast))
        }
        // 最旧的先删：用户最先忘掉的那趟，损失最小。
        candidates.sort { $0.modified < $1.modified }
        var removed = 0
        for candidate in candidates {
            guard (try? manager.removeItem(at: candidate.url)) != nil else { continue }
            removed += 1
            if removed >= 8 { break }
        }
        if removed > 0 {
            // 删完统一作废一次：回收后仍按旧的偏大值拒绝下一趟就白删了。
            usagesInvalidate(target.path)
        }
        return removed
    }
}

final class IOSRideService: NSObject, IOSBridgeService, IOSBridgeCancellableService {
    let methods = ["ride.begin", "ride.poll", "ride.end", "ride.action", "ride.list", "ride.detail", "ride.delete", "ride.share"]
    private static weak var leaseOwner: IOSRideService?
    private let gps = IOSLocationService.shared
    private let bluetooth = IOSBluetoothService.shared
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.rides.io", qos: .utility)
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private weak var optionalSystemSurfacePublisher: IOSSystemSurfacePublisher?
    private var page: UInt64 = 0
    private var active: Run?
    private var finals: [UUID: Run] = [:]
    private var gpsObserver: UUID?
    private var bleObserver: UUID?
    private var foregroundObserver: NSObjectProtocol?
    private var clock: Timer?
    private var pendingIO = 0
    private var confirmation: Consent?
    private weak var confirmationAlert: UIAlertController?
    private var sharing: Consent?
    private weak var activity: UIActivityViewController?
    /// 上次扫盘发现的未结束记录（被系统杀掉/崩溃留下）。只有最新一份对外提示，不做自动续记。
    private var orphanCount = 0
    private var orphanLatestAt: Int64?
    /// 扫盘并入同一个 worker 串行执行，避免和 checkpoint 抢磁盘；结果回主线程才写状态。
    private var scanInFlight = false
    private var scannedScope: String?
    /// 已销毁的 0 采样记录（只用于让 end/poll 幂等回终态）。带 owner，避免提示泄漏给别的账号。
    private var emptyFinals: [(id: UUID, owner: String, at: Int64)] = []
    // 只保存非敏感显示偏好，按原生 owner 隔离；不是网页认证或后台授权。
    private let preferences = UserDefaults.standard
    private var notificationPermissionGranted: Bool?
    private var notificationReadInFlight = false
    private var permissionBusy = false

    private func gpsAutoKey(_ scope: IOSRideScope) -> String {
        "dashboard.ride.gps-over-50." + scope.ownerHash
    }

    private func readNotificationPermission() {
        guard !notificationReadInFlight else { return }
        notificationReadInFlight = true
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted: Bool?
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: granted = true
            case .denied, .notDetermined: granted = false
            @unknown default: granted = nil
            }
            DispatchQueue.main.async {
                self?.notificationReadInFlight = false
                self?.notificationPermissionGranted = granted
            }
        }
    }

    private final class Consent {
        let page: UInt64
        let scope: IOSRideScope
        let method: String
        let id: UUID?
        var reply: ((Any?, String?) -> Void)?
        var timeout: DispatchWorkItem?
        init(page: UInt64, scope: IOSRideScope, method: String, id: UUID?, reply: @escaping (Any?, String?) -> Void) {
            self.page = page; self.scope = scope; self.method = method; self.id = id; self.reply = reply
        }
    }

    private final class Run {
        let id = UUID()
        let scope: IOSRideScope
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var gpsWanted: Bool
        var gpsOver50 = false
        var backgroundWanted: Bool
        // 文件保留完整历史；实时读数独立缓存，截断文件不能让仪表倒退回旧样本。
        var latestBLE: [String: Any] = [:]
        var latestBLETimes: [String: Int64] = [:]
        var latestBLEUptimes: [String: TimeInterval] = [:]
        var latestBLEFields: [String: Any] = [:]
        var latestBLEGeneration: UUID?
        var gaugeSource: SystemGaugeSource?
        var gaugeAt: Int64?
        var state = "waiting"
        var recordState = "waiting"
        var reason = "waiting_fix"
        var rawGPS: [[String: Any]] = []
        var telemetry: [[String: Any]] = []
        var gaps: [[String: Any]] = []
        var samples = 0
        var gpsSamples = 0
        var bleSamples = 0
        var lastGPSSequence: Int64 = 0
        var lastBLESequence: Int64 = 0
        /// 已接受样本的最大 at（GPS/BLE 各自一条）。写入侧把时间戳夹成不减：
        /// 读取侧 `read()` 要求每个数组内 `at` 单调不减，而墙钟被 NTP/手动回拨时新样本会带更小的 at，
        /// 一旦写进文件，这条记录就永远 `invalid_record`、被 list 静默跳过且 orphans 也不认它。
        /// 宁可把回拨期间的样本压到上一条的时间点，也不能让整份记录隐身。
        var lastGPSPointAt: Int64 = 0
        var lastBLEPointAt: Int64 = 0
        var lastGPSUptime: TimeInterval?
        var lastBLEUptime: TimeInterval?
        var gapReasons: [String: String] = [:]
        var activeSince: TimeInterval?
        var activeDuration: TimeInterval = 0
        var endedAt: Int64?
        var endedUptime: TimeInterval?
        var ending = false
        var completed = false
        var targetState = "completed"
        var targetReason = "user_stop"
        var estimatedBytes = 2048
        var checkpointing = false
        var checkpointDirty = false
        var lastCheckpoint: TimeInterval = 0
        var saveInFlight = false
        var userPaused = false
        var saveFailed = false
        /// 结束保存已经自动重试过一次；再失败才真正置 save_failed。
        var saveRetried = false
        /// checkpoint 连续失败次数。以前任意一次失败就永久置 saveFailed、之后所有 checkpoint 全跳过，
        /// 一次瞬时故障（磁盘压力、文件保护未就绪）就把「最多丢 15 秒」变成「从失败点起全部不落盘」。
        /// 现在按次数退避重试：失败后保留 dirty，下一次 tick 再试；只有连续失败到上限才真的放弃。
        var checkpointFailures = 0
        /// 下一次允许重试 checkpoint 的时刻（systemUptime）。退避 15s → 30s → 60s，封顶 60s。
        var checkpointRetryAt: TimeInterval = 0
        /// 本趟是否已经尝试过「回收最旧记录腾地方」。只允许一次：
        /// 撞的是 owner 数上限（64 个目录）或别的 owner 目录文件数墙时，删自己的记录根本修不好，
        /// 每 15s 删 8 条就会把真实历史删空而保存依旧失败。一次回收后仍失败就交给退避/判死。
        var evictionAttempted = false
        var savedBytes = 0
        /// 0 采样的终态标记：没有文件可写，但这条记录已经收尾（saved 必须为 true）。
        var empty = false
        /// 上次成功落盘的真实字节/样本数；0 表示还没测到，admit 先用调用方的粗估。
        var bytesPerSample = 0.0
        var saveWaiters: [(UInt64, IOSRideScope?, (Any?, String?) -> Void)] = []
        var lastRoute: IOSGPSFix?
        var distanceM = 0.0
        var distanceSegments = 0
        var maxGPSSpeed: Double?
        var systemUpdatedAt: Int64 = 0
        var systemElapsedSeconds: Double? = 0
        var systemBLEConnected = false

        init(scope: IOSRideScope, gps: Bool, background: Bool) {
            self.scope = scope; gpsWanted = gps; backgroundWanted = background
            systemUpdatedAt = startedAt
        }

        var elapsedMs: Int64 {
            Int64(max(0, (endedUptime ?? ProcessInfo.processInfo.systemUptime) - startedUptime) * 1000)
        }

        var durationMs: Int64 {
            let current = activeSince.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
            return Int64(max(0, activeDuration + current) * 1000)
        }
    }

    override init() {
        super.init()
        bluetooth.configureRecordingProvider { [weak self] in self?.currentNativeRecording() }
        readNotificationPermission()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.readNotificationPermission()
            guard let run = self.active, !run.ending, !run.userPaused else { return }
            self.checkScope()
            guard self.active === run else { return }
            if run.gpsWanted { _ = self.gps.resumeRecording(id: run.id, requestPermission: false) }
            self.updateBLEContext(run)
            self.tick()
        }
    }

    deinit {
        if let token = foregroundObserver { NotificationCenter.default.removeObserver(token) }
        clock?.invalidate()
        if let token = gpsObserver { gps.removeObserver(token) }
        if let token = bleObserver { bluetooth.removeObserver(token) }
        let run = active
        let location = gps
        let remote = bluetooth
        // 释放采样上下文必须回主线程：IOSLocationService.endRecording / setRecordingContext
        // 都带主线程 precondition，而 deinit 由最后一个强引用释放决定，可能在后台队列或
        // autorelease 池里发生（真机 swap WebView 时踩过崩溃）。这里只捕获具体服务对象，
        // 不捕获 self——deinit 里捕获 self 的逃逸闭包不合法。
        let detach = {
            guard let run = run else { return }
            location.endRecording(id: run.id)
            remote.setRecordingContext(id: nil, background: false, scope: nil)
        }
        if Thread.isMainThread { detach() } else { DispatchQueue.main.async(execute: detach) }
        // 走到 deinit 说明服务被替换（换 WebView/重启）。正在录制的 run 如果只靠 15 秒一轮
        // 的 checkpoint，进程退出就会丢掉尾巴；这里补一次最终 checkpoint。
        // 不能调 checkpoint()：它带 active === run / checkpointing 等实例状态判定，也会读
        // gps/bluetooth 的主线程快照；deinit 里只取 run 的纯值字段，交给独立队列落盘。
        // 用 final:false：这条记录并没有被用户结束，写成 endedAt 会让下次启动误判为已保存；
        // 留空则 list 会标 incomplete，正好对上启动扫盘的孤儿提示。
        if let run = run, run.samples > 0, !run.saveFailed, !run.ending, !run.completed {
            let value = record(run, final: false)
            let owner = run.scope.ownerHash
            let id = run.id
            Self.teardownQueue.async {
                // 失败也不抛：deinit 里没人能处理错误，写不进去就留给 list 兜底。
                _ = try? IOSRideDisk.save(value, owner: owner, id: id)
            }
        }
    }

    /// deinit 专用落盘队列：不能用 worker（它由实例持有，deinit 后即将失效），也不能同步等。
    private static let teardownQueue = DispatchQueue(label: "io.github.lswlc33.dashboard.rides.teardown", qos: .utility)

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread)
        scopeProvider = provider
        scopeChanged()
    }

    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }

    func configureSystemSurfacePublisher(_ publisher: IOSSystemSurfacePublisher?) {
        precondition(Thread.isMainThread)
        optionalSystemSurfacePublisher = publisher
        if let run = active, owns(run) { publishSystemSurface(run) }
    }

    func scopeChanged() {
        precondition(Thread.isMainThread)
        cancelConsent("stale_session")
        cancelShare("stale_session")
        checkScope()
        // 账号/车辆切换后，旧 owner 的 0 采样标记与孤儿提示都不该再对新会话可见。
        if let scope = scopeProvider?() {
            emptyFinals.removeAll { $0.owner != scope.ownerHash }
        } else { emptyFinals.removeAll() }
        scanOrphans()
    }

    /// 进前台/切账号后扫一次本 owner 目录，找出 `endedAt` 为空的记录（进程被杀、崩溃留下的）。
    /// 只提示不续记：没有活跃的 Location/Bluetooth 上下文，续记会凭空造出样本。
    /// 扫盘放在 worker 上，结果回主线程才改状态（否则 snapshot() 可能读到半更新的计数）。
    private func scanOrphans() {
        guard let scope = scopeProvider?(), scope.valid else {
            // 没身份就清掉旧提示，避免把上一个账号的孤儿数报给新账号。
            orphanCount = 0; orphanLatestAt = nil; scannedScope = nil
            return
        }
        let owner = scope.ownerHash
        guard !scanInFlight, scannedScope != owner else { return }
        scanInFlight = true
        worker.async { [weak self] in
            let found = (try? IOSRideDisk.orphans(owner: owner)) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanInFlight = false
                // 扫盘期间可能已经切账号；不是同一个 owner 就丢弃结果，等下一轮重扫。
                guard self.scopeProvider?().map({ $0.valid && $0.ownerHash == owner }) == true else { return }
                self.scannedScope = owner
                self.orphanCount = found.count
                self.orphanLatestAt = found.compactMap { $0.at }.max()
            }
        }
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        page &+= 1
        cancelConsent("stale_navigation")
        cancelShare("stale_navigation")
        // 没有 WK observer；已明确录制与页面生命周期分离，仍由 scope/系统权限守护。
        checkScope()
        // 每次重新进面板都补扫一次（scannedScope 去重，同一 owner 不会重复扫），
        // 否则上次会话留下的孤儿记录在切账号/重启前都不对用户可见。
        scannedScope = nil
        scanOrphans()
    }

    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        cancelConsent("foreground_required")
        cancelShare("foreground_required")
        guard let run = active, !run.ending else { return }
        if run.gpsWanted && !gps.backgroundAllowed {
            markGap(run, source: "gps", reason: gps.backgroundReason)
            pauseDuration(run)
            run.state = "interrupted"
            run.recordState = "interrupted"
            run.reason = gps.backgroundReason
        }
        updateBLEContext(run)
        checkpoint(run, force: true)
    }

    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        if confirmation?.method == method { cancelConsent("operation_cancelled") }
        if method == "ride.share" { cancelShare("operation_cancelled") }
        if method == "ride.action", permissionBusy { gps.cancel(method: "gps.begin", args: []) }
        // 已受理 stop/save 要继续安全落盘；取消的只是旧页面回执，不能再把 ending 复活为 recording。
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(method: method, args: args, reply: reply) }
            return
        }
        checkScope()
        let options = args.first as? [String: Any] ?? [:]
        guard let scope = scopeProvider?(), scope.valid else { reply(failure("authorized_vehicle_required"), nil); return }
        if let vin = options["vin"] as? String, vin != scope.vin { reply(failure("stale_session"), nil); return }
        switch method {
        case "ride.begin": begin(scope: scope, options: options, reply: reply)
        case "ride.poll":
            if let id = requestedID(options) {
                if let run = active?.id == id ? active : finals[id], run.scope.ownerHash == scope.ownerHash {
                    reply(snapshot(run), nil)
                } else if let empty = emptyFinals.first(where: { $0.id == id && $0.owner == scope.ownerHash }) {
                    // 网页轮询会一直跟到 saved===true；0 采样的终态也必须能被 poll 到，
                    // 否则它只会在 end 的回执里出现一次，刷新面板后又变成「等待数据」。
                    reply(emptySnapshot(id: id, at: empty.at, scope: scope), nil)
                } else { reply(failure("stale_ticket"), nil) }
            } else if let run = active, run.scope == scope { reply(snapshot(run), nil) }
            else { reply(idleSnapshot(scope: scope), nil) }
        case "ride.end": end(scope: scope, options: options, reply: reply)
        case "ride.action": action(scope: scope, options: options, reply: reply)
        case "ride.list": list(scope: scope, reply: reply)
        case "ride.detail": detail(scope: scope, options: options, reply: reply)
        case "ride.delete": delete(scope: scope, options: options, reply: reply)
        case "ride.share": share(scope: scope, options: options, reply: reply)
        default: reply(nil, "unsupported_method")
        }
    }

    private func begin(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
        if let run = active, !run.completed {
            if run.ending {
                // 正在保存的旧 run 不是「当前会话」：把它当幂等结果返回会让网页以为
                // 还有一条可继续记录的会话，并且拿到的快照缺 accepted。明确回 busy + 状态。
                reply(["ok": false, "reason": "recording_busy", "state": "saving",
                       "recordState": "ending", "nativeRecordState": "saving", "busy": true, "accepted": false], nil); return
            }
            guard run.scope == scope else { reply(failure("recording_busy"), nil); return }
            // 同一 run 的幂等 begin：网页重放（重连/重开面板）拿到的那条也要带 accepted，
            // 否则它无法区分「这次 begin 被受理」和「只是抖了个快照」。
            var value = snapshot(run)
            value["accepted"] = true
            reply(value, nil); return
        }
        if let owner = Self.leaseOwner, owner !== self { reply(failure("recording_busy"), nil); return }
        guard pendingSaveCapacity else { reply(failure("pending_save_limit"), nil); return }
        let wantedGPS = options["gps"] as? Bool ?? true
        guard wantedGPS || bluetooth.connected else { reply(failure("no_data_source"), nil); return }
        let background = options["backgroundRecording"] as? Bool == true
        confirm(method: "ride.begin", id: nil, scope: scope, title: IOSStrings.rideRecordTitle,
                message: IOSStrings.rideRecordMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            guard self.active == nil || self.active?.completed == true,
                  Self.leaseOwner == nil || Self.leaseOwner === self else {
                self.finish(consent, self.failure("recording_busy")); return
            }
            guard self.pendingSaveCapacity else { self.finish(consent, self.failure("pending_save_limit")); return }
            let run = Run(scope: scope, gps: wantedGPS, background: background)
            run.gpsOver50 = self.preferences.bool(forKey: self.gpsAutoKey(scope))
            run.systemBLEConnected = self.bluetooth.connected
            self.active = run
            Self.leaseOwner = self
            self.installObservers()
            self.startClock()
            let status = wantedGPS ? self.gps.beginRecording(id: run.id, background: background, requestPermission: true) : self.gps.snapshot()
            if wantedGPS && background {
                // 原生按钮确认了背景选项；已有 WhenInUse 时才请求 Always，否则等用户再次点背景授权。
                _ = self.gps.setBackgroundRecording(id: run.id, enabled: true, requestPermission: true)
            }
            self.updateBLEContext(run)
            if status["state"] as? String == "permission_required" {
                run.state = "permission_required"; run.recordState = "permission_required"
                run.reason = status["reason"] as? String ?? "permission_required"
            }
            var response = self.snapshot(run)
            response["accepted"] = true
            self.publishSystemSurface(run, eventAt: run.startedAt, elapsedSeconds: 0)
            self.finish(consent, response)
        }
    }

    private func installObservers() {
        if gpsObserver == nil {
            gpsObserver = gps.addObserver(onFix: { [weak self] fix in self?.recordGPS(fix) },
                onState: { [weak self] value in self?.gpsState(value) })
        }
        if bleObserver == nil {
            bleObserver = bluetooth.addObserver(onSample: { [weak self] sample in self?.recordBLE(sample) },
                onState: { [weak self] value in self?.bleState(value) })
        }
    }

    private func removeObservers() {
        if let id = gpsObserver { gps.removeObserver(id); gpsObserver = nil }
        if let id = bleObserver { bluetooth.removeObserver(id); bleObserver = nil }
    }

    private func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkScope() {
        guard let run = active, !run.ending else { return }
        guard scopeProvider?() == run.scope else {
            stop(run, state: "interrupted", reason: "stale_session", reply: nil); return
        }
    }

    private func owns(_ run: Run) -> Bool {
        active === run && !run.ending && !run.completed && scopeProvider?() == run.scope
    }

    func currentNativeRecording() -> IOSNativeRecording? {
        precondition(Thread.isMainThread)
        guard let run = active, owns(run), !run.userPaused else { return nil }
        return IOSNativeRecording(id: run.id, scope: run.scope, startedUptime: run.startedUptime, background: run.backgroundWanted)
    }

    private func recordGPS(_ fix: IOSGPSFix) {
        guard let run = active, owns(run), !run.userPaused, run.gpsWanted, fix.fresh,
              fix.sequence > run.lastGPSSequence,
              fix.at >= run.startedAt,
              UIApplication.shared.applicationState == .active || gps.backgroundAllowed else { return }
        bluetooth.observeRecordingEvent(id: run.id, scope: run.scope)
        guard admit(run, bytes: 480) else { return }
        run.lastGPSSequence = fix.sequence
        var point = fix.json(includeCoordinates: true)
        // 写入侧夹紧：读取侧要求数组内 at 单调不减，墙钟回拨时不能让更小的时间戳进文件。
        // 距离计算仍用原始 fix（accumulateDistance 读 run.lastRoute），不受夹紧影响。
        let gpsAt = max(fix.at, run.lastGPSPointAt)
        point["at"] = gpsAt
        run.lastGPSPointAt = gpsAt
        point["elapsedMs"] = Int64(max(0, fix.receivedUptime - run.startedUptime - fix.ageAtReceipt) * 1000)
        run.rawGPS.append(point)
        run.gpsSamples += 1
        run.lastGPSUptime = fix.receivedUptime - fix.ageAtReceipt
        run.gapReasons.removeValue(forKey: "gps")
        if let speed = fix.speedKph { run.maxGPSSpeed = max(run.maxGPSSpeed ?? speed, speed) }
        accumulateDistance(run, fix)
        run.lastRoute = fix
        sampleAccepted(run)
        if fix.speedKph != nil { publishGaugeSample(run) }
    }

    /// 距离只累加"可信段"。
    /// distanceFilter=3 意味着静止时 GPS 漂移 3 米就产生一个新点，全额累加会攒出幽灵里程。
    /// 两道闸：① 段长不小于 max(3, min(两侧精度)*0.5)——精度越好，可接受的最短段越短；
    /// ② 隐含速度不超过 100 km/h 的业务阈值（两轮车），超了就丢弃该段并记 gap，不失败整条记录。
    /// 存储层的 400 边界不动：老文件校验仍按它，这里只做业务过滤。
    private func accumulateDistance(_ run: Run, _ fix: IOSGPSFix) {
        guard let previous = run.lastRoute, let lat = fix.latitude, let lng = fix.longitude,
              let previousLat = previous.latitude, let previousLng = previous.longitude else { return }
        let seconds = Double(fix.at - previous.at) / 1000
        guard seconds > 0 && seconds <= 10 else { return }
        let distance = CLLocation(latitude: lat, longitude: lng)
            .distance(from: CLLocation(latitude: previousLat, longitude: previousLng))
        guard distance.isFinite, distance >= 0 else { return }
        // 精度已知但超过 50 米说明这一段本身不可信（老代码直接跳过）；未知时才退到 3 米下限。
        if let accuracy = fix.accuracy, accuracy > 50 { return }
        if let previousAccuracy = previous.accuracy, previousAccuracy > 50 { return }
        let floor: Double
        if let accuracy = fix.accuracy, let previousAccuracy = previous.accuracy {
            floor = max(3.0, min(accuracy, previousAccuracy) * 0.5)
        } else {
            floor = 3.0
        }
        // 抖动：低于最小段长视为同一位置的重复定位，不计入也不报错。
        guard distance >= floor else { return }
        guard distance / seconds * 3.6 <= 100 else {
            // 跳点（隧道后首个 fix、定位漂移）会让单段速度离谱；只丢这段并留痕，路程继续。
            // 参考点由调用方无条件推进，所以丢段不会让后面每一段都跟着被丢。
            markGap(run, source: "distance", reason: "stale_fix", force: true)
            return
        }
        run.distanceM += distance
        run.distanceSegments += 1
    }

    private func recordBLE(_ sample: IOSBLETelemetrySample) {
        guard let run = active, owns(run), !run.userPaused, sample.scope == run.scope, bluetooth.connected,
              sample.sequence > run.lastBLESequence, sample.at >= run.startedAt,
              sample.receivedUptime >= run.startedUptime,
              UIApplication.shared.applicationState == .active || run.backgroundWanted else { return }
        bluetooth.observeRecordingEvent(id: run.id, scope: run.scope)
        guard bluetooth.canObserveTelemetry(recordingId: run.id, scope: run.scope, connectionGeneration: sample.connectionGeneration) else {
            clearBLEDisplay(run); markGap(run, source: "ble", reason: "authorization_expired"); return
        }
        let clean = IOSRideJSON.telemetry(sample.values)
        guard !clean.isEmpty, admit(run, bytes: 1000) else { return }
        run.lastBLESequence = sample.sequence
        if run.latestBLEGeneration != sample.connectionGeneration {
            clearBLEDisplay(run)
            run.latestBLEGeneration = sample.connectionGeneration
        }
        for (key, value) in clean {
            run.latestBLE[key] = value
            run.latestBLETimes[key] = sample.at
            run.latestBLEUptimes[key] = sample.receivedUptime
        }
        run.latestBLEFields = IOSRideJSON.fields(sample.fields)
        // 与 GPS 同理：读取侧要求数组内 at 单调不减。实时读数仍用真实 sample.at 判新鲜度
        // （latestBLETimes 见上），只有落盘样本夹紧，避免墙钟回拨把整条记录写成 invalid_record。
        let bleAt = max(sample.at, run.lastBLEPointAt)
        run.lastBLEPointAt = bleAt
        let times = Dictionary(uniqueKeysWithValues: clean.keys.map { ($0, bleAt) })
        run.telemetry.append(["at": bleAt, "seq": sample.sequence,
            "elapsedMs": Int64(max(0, sample.receivedUptime - run.startedUptime) * 1000),
            "source": sample.source, "connectionGeneration": sample.connectionGeneration.uuidString.lowercased(),
            "values": clean, "times": times, "fields": IOSRideJSON.fields(sample.fields)])
        run.bleSamples += 1
        run.lastBLEUptime = sample.receivedUptime
        run.gapReasons.removeValue(forKey: "ble")
        sampleAccepted(run)
        if clean["speedKph"] != nil { publishGaugeSample(run) }
    }

    private func clearBLEDisplay(_ run: Run) {
        run.latestBLE.removeAll(); run.latestBLETimes.removeAll(); run.latestBLEUptimes.removeAll()
        run.latestBLEFields.removeAll(); run.latestBLEGeneration = nil
        invalidateGauge(run, source: .ble)
    }

    private func visibleBLE(_ run: Run) -> [String: Any] {
        guard active === run, !run.ending, !run.userPaused, bluetooth.connected, bluetooth.canObserveTelemetry else {
            return ["telemetry": [:], "telemetryTimes": [:]]
        }
        return IOSRideJSON.visibleTelemetry(run.latestBLE, times: run.latestBLETimes,
            uptimes: run.latestBLEUptimes, now: ProcessInfo.processInfo.systemUptime)
    }

    // 文案仍写高于 50，实际公共仪表按 BLE >45 切换；这里只选读数，不启动定位或私有认证。
    private func selectedGauge(_ run: Run) -> SystemGaugeSnapshot? {
        guard owns(run), !run.userPaused else { return nil }
        let ble = visibleBLE(run)
        let values = ble["telemetry"] as? [String: Any] ?? [:]
        let times = ble["telemetryTimes"] as? [String: Int64] ?? [:]
        let speed = IOSRideJSON.number(values["speedKph"])
        if run.gpsWanted, gpsFresh(run), !run.gpsOver50 || (speed.map { $0 > 45 } ?? false),
           let gpsSpeed = IOSRideJSON.number(run.rawGPS.last?["speedKph"]),
           let at = IOSRideJSON.integer(run.rawGPS.last?["at"], minimum: 1) {
            return SystemGaugeSnapshot(source: .gps, speedKph: gpsSpeed, updatedAt: at)
        }
        if let speed = speed, let at = times["speedKph"] {
            return SystemGaugeSnapshot(source: .ble, speedKph: speed, updatedAt: at)
        }
        return nil
    }

    private func publishGaugeSample(_ run: Run) {
        guard let publisher = optionalSystemSurfacePublisher, let value = selectedGauge(run),
              run.gaugeSource != value.source || run.gaugeAt != value.updatedAt else { return }
        run.gaugeSource = value.source; run.gaugeAt = value.updatedAt
        // publisher 只更新用户已经开启的显示；原生样本不自动新建实时活动。
        publisher.publishGauge(value, scope: run.scope)
    }

    private func invalidateGauge(_ run: Run, source: SystemGaugeSource? = nil) {
        guard run.gaugeSource != nil, source == nil || run.gaugeSource == source else { return }
        run.gaugeSource = nil; run.gaugeAt = nil
        optionalSystemSurfacePublisher?.systemGaugeDisconnected(scope: run.scope)
    }

    /// 接收闸门。字节估算优先用「上次真实序列化大小 / 样本数」× 1.1：
    /// 固定 480/1000 的粗估在字段多时偏低，会让 estimatedBytes 迟迟不靠近 8 MiB，
    /// 直到真正序列化时才超限；反过来在字段少时又白丢可写空间。
    /// 还没成功落过盘时（bytesPerSample == 0）仍退回调用方的粗估，行为与旧版一致。
    private func admit(_ run: Run, bytes: Int) -> Bool {
        let estimate = run.bytesPerSample > 0 ? Int((run.bytesPerSample * 1.1).rounded(.up)) : bytes
        guard run.samples < IOSRideDisk.maxSamples, run.estimatedBytes + estimate + 4096 <= IOSRideDisk.maxFileBytes else {
            stop(run, state: "interrupted", reason: "record_limit_reached", reply: nil)
            return false
        }
        run.samples += 1
        run.estimatedBytes += estimate
        return true
    }

    /// 每次真实落盘后更新「字节/样本」滑动值。
    /// 分母用落盘那一刻的样本数（不能读 run.samples：截断后主线程可能已经改过它）。
    /// 文件头（version/id/owner/report 等）是固定开销，estimatedBytes 初值 2048 已覆盖，
    /// 这里先扣掉再除，否则样本少的时候会把固定开销重复算成每样本成本。
    private func observeSaved(_ run: Run, _ saved: Saved) {
        run.savedBytes = saved.bytes
        guard saved.samples > 0, saved.bytes > 2048 else { return }
        let measured = Double(saved.bytes - 2048) / Double(saved.samples)
        guard measured.isFinite, measured > 0 else { return }
        // 0.5 的滑动系数：单次异常样本（带了很多 fields）不会立刻把预算抬到上限。
        run.bytesPerSample = run.bytesPerSample > 0 ? run.bytesPerSample * 0.5 + measured * 0.5 : measured
    }

    private func sampleAccepted(_ run: Run) {
        let now = ProcessInfo.processInfo.systemUptime
        if run.activeSince == nil { run.activeSince = now }
        run.state = "recording"
        run.recordState = run.saveFailed ? "save_failed" : "recording"
        if !run.saveFailed { run.reason = "" }
        run.checkpointDirty = true
        checkpoint(run, force: run.samples == 1)
        let timestamps = [IOSRideJSON.integer(run.rawGPS.last?["at"]), IOSRideJSON.integer(run.telemetry.last?["at"])]
        let elapsed = [IOSRideJSON.number(run.rawGPS.last?["elapsedMs"]), IOSRideJSON.number(run.telemetry.last?["elapsedMs"])]
            .compactMap { $0 }.max().map { $0 / 1000 }
        publishSystemSurface(run, eventAt: timestamps.compactMap { $0 }.max(), elapsedSeconds: elapsed)
    }

    private func gpsState(_ value: [String: Any]) {
        guard let run = active, owns(run), run.gpsWanted else { return }
        let state = value["state"] as? String ?? "unknown"
        if ["permission_required", "interrupted", "unavailable", "error", "stale"].contains(state) {
            markGap(run, source: "gps", reason: value["reason"] as? String ?? "gps_unavailable")
            run.lastRoute = nil
            invalidateGauge(run, source: .gps)
            if !bleFresh(run) {
                pauseDuration(run)
                run.state = state
                run.recordState = state
                run.reason = value["reason"] as? String ?? "gps_unavailable"
            }
        }
    }

    private func bleState(_ value: [String: Any]) {
        guard let run = active, owns(run) else { return }
        if value["canObserveTelemetry"] as? Bool != true {
            clearBLEDisplay(run)
            if run.bleSamples > 0 || bluetooth.currentRecordingLease() != nil {
                markGap(run, source: "ble", reason: value["renewReason"] as? String ?? "native_authorization_required")
            }
        }
        if value["connected"] as? Bool != true, run.bleSamples > 0 {
            markGap(run, source: "ble", reason: value["reason"] as? String ?? "connection_lost")
        }
        // GPS-only 与 BLE 分离；蓝牙断开不会伪造电池，也不会停止获准的 GPS 录制。
        let connected = value["connected"] as? Bool == true
        let disconnected = run.systemBLEConnected && !connected
        run.systemBLEConnected = connected
        if !connected { clearBLEDisplay(run) }
        // GPS-only 的 false 状态不是断连；真实 BLE 断连也不能结束独立获准的 GPS 活动。
        if disconnected && !run.gpsWanted {
            optionalSystemSurfacePublisher?.systemSurfacesDisconnected(scope: run.scope)
        }
        if disconnected { publishSystemSurface(run) }
    }

    private func tick() {
        checkScope()
        guard let run = active, owns(run), !run.userPaused else { return }
        if run.gpsWanted, !gpsFresh(run), run.gpsSamples > 0 {
            markGap(run, source: "gps", reason: "stale_fix")
            run.lastRoute = nil
        }
        if !bleFresh(run), run.bleSamples > 0 { markGap(run, source: "ble", reason: "sample_gap") }
        if !gpsFresh(run) && !bleFresh(run) && run.samples > 0 {
            pauseDuration(run)
            run.state = "interrupted"
            run.recordState = run.saveFailed ? "save_failed" : "gap"
            if !run.saveFailed { run.reason = "sample_gap" }
        }
        if let source = run.gaugeSource {
            if let current = selectedGauge(run) {
                // GPS 过期但 BLE 仍新鲜时只切来源，不能结束用户已开启且不能自动重开的活动。
                // 重用已接受样本的原始 at，tick 不把切换时刻伪装成一次新采样。
                if current.source != source || current.updatedAt != run.gaugeAt { publishGaugeSample(run) }
            } else { invalidateGauge(run) }
        }
        checkpoint(run, force: false)
        // tick 只撤销过期速度；最后更新时间和时长仍保留真实接受事件，不能用轮询伪造新观测。
        publishSystemSurface(run)
    }

    private func gpsFresh(_ run: Run) -> Bool {
        guard run.gpsWanted, let last = run.lastGPSUptime else { return false }
        let age = ProcessInfo.processInfo.systemUptime - last
        return age >= 0 && age < 10 && gps.snapshot()["updating"] as? Bool == true
    }

    private func bleFresh(_ run: Run) -> Bool {
        guard bluetooth.connected, bluetooth.canObserveTelemetry, let last = run.lastBLEUptime else { return false }
        let age = ProcessInfo.processInfo.systemUptime - last
        return age >= 0 && age < 10
    }

    /// force=true 用于"同一来源同一个 reason 也要留一条痕迹"的场景（例如距离段被丢弃），
    /// 默认 false 保持原有去重：同源的连续失联只记一次，避免 1024 条上限被同一条噪声吃满。
    private func markGap(_ run: Run, source: String, reason: String, force: Bool = false) {
        guard run.samples > 0, run.gaps.count < 1024 else { return }
        if !force, run.gapReasons[source] == reason { return }
        run.gapReasons[source] = reason
        run.gaps.append(["at": Int64(Date().timeIntervalSince1970 * 1000), "elapsedMs": run.elapsedMs,
                         "source": source, "reason": safeReason(reason)])
        run.estimatedBytes += 180
        run.checkpointDirty = true
        publishSystemSurface(run, eventAt: IOSRideJSON.integer(run.gaps.last?["at"]), elapsedSeconds: Double(run.elapsedMs) / 1000)
    }

    private func safeReason(_ value: String) -> String {
        let codes: Set<String> = ["waiting_fix", "permission_required", "permission_denied", "permission_restricted", "system_paused",
            "location_services_disabled", "stale_fix", "sample_gap", "connection_lost", "disconnected", "user_disconnect",
            "background_recording_disabled", "background_mode_missing", "always_permission_required", "background_interrupted",
            "stale_session", "record_limit_reached", "user_pause", "gps_disabled", "navigation_changed",
            "subscription_failed", "notification_failed", "services_invalidated", "powered_off", "not_authorised",
            "bluetooth_resetting", "write_timeout", "read_timeout", "discovery_timeout", "location_failed", "no_fix",
            "trimmed_for_size", "authorization_expired", "native_authorization_required", "material_changed",
            "initial_authorization", "native_authentication_failed", "lease_renewal_rejected", "stale_renewal"]
        return codes.contains(value) ? value : "source_unavailable"
    }

    private func pauseDuration(_ run: Run) {
        if let since = run.activeSince { run.activeDuration += max(0, ProcessInfo.processInfo.systemUptime - since) }
        run.activeSince = nil
    }

    private func updateBLEContext(_ run: Run) {
        if run.userPaused { bluetooth.setRecordingContext(id: nil, background: false, scope: nil) }
        else { bluetooth.setRecordingContext(id: run.id, background: run.backgroundWanted, scope: run.scope) }
    }

    private func publishSystemSurface(_ run: Run, eventAt: Int64? = nil, elapsedSeconds: Double? = nil) {
        guard let publisher = optionalSystemSurfacePublisher else { return }
        if let eventAt = eventAt, eventAt >= run.systemUpdatedAt {
            run.systemUpdatedAt = eventAt
            if let elapsedSeconds = elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0 {
                run.systemElapsedSeconds = elapsedSeconds
            }
        }
        let state: SystemRideState = run.ending ? .ended : (run.userPaused ? .paused :
            (run.state == "recording" ? .recording : (run.samples > 0 ? .interrupted : .waiting)))
        let gpsAt = IOSRideJSON.integer(run.rawGPS.last?["at"])
        let bleAt = IOSRideJSON.integer(run.telemetry.last?["at"])
        let speed = state == .recording && gpsFresh(run) ? IOSRideJSON.number(run.rawGPS.last?["speedKph"]) : nil
        let age = gpsAt.map { max(0, Double(run.systemUpdatedAt - $0) / 1000) }
        let value = SystemRideSnapshot(state: state, startedAt: run.startedAt, updatedAt: run.systemUpdatedAt,
            speedKph: speed, speedUpdatedAt: gpsAt, lastLocationAt: gpsAt,
            lastSignalAt: [gpsAt, bleAt].compactMap { $0 }.max(), locationAgeSeconds: age,
            elapsedSeconds: run.systemElapsedSeconds, gapCount: run.gaps.count)
        // 不复制 rawGPS/串号/owner 身份，也不由 GPS 推导充电；scope 是开始录制时原生捕获的那一份。
        publisher.publishRide(value, scope: run.scope)
    }

    private func permissionProjection(_ gpsValue: [String: Any], _ ble: [String: Any]) -> [String: Any] {
        let authorization = ble["authorization"] as? String ?? "unknown"
        let granted: Any = authorization == "unknown" ? NSNull() : (authorization == "allowed") as Any
        let power = ble["power"] as? String ?? "unknown"
        let enabled: Any = power == "unknown" || power == "resetting" ? NSNull() : (power == "powered_on") as Any
        return ["permissionGranted": granted, "bluetoothEnabled": enabled,
            "locationPermissionGranted": gpsValue["permissionGranted"] ?? NSNull(),
            "notificationPermissionGranted": notificationPermissionGranted as Any? ?? NSNull(),
            "permissionBusy": permissionBusy, "permissionReason": permissionBusy ? "permission_required" : "",
            "openRequested": false, "paired": false, "systemBondState": "unknown_os_managed",
            "authenticated": ble["nativeAuthenticated"] ?? false,
            "authenticationState": ble["nativeAuthenticated"] as? Bool == true ? "native_recipe_verified" : "native_authorization_required",
            "authorizationFresh": ble["authorizationFresh"] ?? false,
            "automaticUnlock": false, "renewing": ble["renewing"] ?? false, "renewReason": ble["renewReason"] ?? "",
            "nativeRenewAvailable": ble["backgroundAuthRenewalSupported"] ?? false,
            "backgroundAuthRenewalSupported": ble["backgroundAuthRenewalSupported"] ?? false, "privateDriverRequired": true,
            "records": [], "recordsReady": false, "recordsError": "", "vehicleName": ""]
    }

    private func idleSnapshot(scope: IOSRideScope) -> [String: Any] {
        let gpsValue = gps.snapshot(), ble = bluetooth.snapshot()
        var value = permissionProjection(gpsValue, ble)
        value.merge(["ok": true, "accepted": false, "state": "idle", "recordState": "waiting",
            "nativeRecordState": "idle", "id": "", "ticket": "", "recordingId": "",
            "reason": "", "samples": 0, "recordedSamples": 0, "elapsedMs": 0, "durationMs": 0,
            "gps": gpsValue, "gpsEnabled": gpsValue["enabled"] ?? false,
            "gpsOver50": preferences.bool(forKey: gpsAutoKey(scope)), "connected": false,
            "telemetry": [:], "telemetryTimes": [:], "fields": [:], "busy": false,
            "finished": false, "saved": false, "retryAvailable": false,
            "backgroundEnabled": false, "backgroundGuaranteed": false, "orphans": orphanSummary()]) { _, new in new }
        return value
    }

    private func snapshot(_ run: Run) -> [String: Any] {
        let live = active === run && !run.ending && !run.userPaused
        let gpsValue = live ? gps.snapshot() : ["ok": true, "enabled": false, "state": "disabled",
            "speedKph": NSNull(), "at": NSNull(), "seq": 0, "lat": NSNull(), "lng": NSNull(),
            "permissionGranted": gps.snapshot()["permissionGranted"] ?? NSNull()]
        let ble = bluetooth.snapshot()
        let nativeLease = bluetooth.currentRecordingLease()
        let sameLease = live && nativeLease?.recordingID == run.id && nativeLease?.scope == run.scope
            && bluetooth.canAcceptTelemetry
        let readings = visibleBLE(run)
        // not_recorded 是无文件终态，公共 UI 按 completed 退役；保留 nativeRecordState 解释真实原因。
        let saved = (run.completed && !run.saveFailed) || run.empty
        var value = permissionProjection(gpsValue, ble)
        value.merge(["ok": true, "accepted": false, "id": run.id.uuidString.lowercased(), "ticket": run.id.uuidString.lowercased(),
            "recordingId": run.id.uuidString.lowercased(), "state": run.state,
            "connectionGeneration": sameLease ? (nativeLease?.connectionGeneration as Any? ?? NSNull()) : NSNull(),
            "nativeAuthenticated": sameLease, "authorizationFresh": sameLease, "canAcceptTelemetry": sameLease,
            "recordState": IOSRideJSON.publicRecordState(run.recordState), "nativeRecordState": run.recordState,
            "reason": run.reason, "startedAt": run.startedAt, "endedAt": run.endedAt as Any? ?? NSNull(),
            "samples": run.samples, "recordedSamples": run.samples, "elapsedMs": run.elapsedMs, "durationMs": run.durationMs,
            "gps": gpsValue, "gpsEnabled": run.gpsWanted, "gpsOver50": run.gpsOver50,
            "connected": live && bluetooth.connected,
            "telemetry": readings["telemetry"] ?? [:], "telemetryTimes": readings["telemetryTimes"] ?? [:],
            "fields": live && bluetooth.connected ? run.latestBLEFields : [:],
            "telemetryRunning": live && bleFresh(run), "dashSeen": live && run.latestBLETimes["speedKph"] != nil,
            "dashRunning": live && (readings["telemetryTimes"] as? [String: Int64])?["speedKph"] != nil,
            "dashConfirmed": false, "backgroundRequested": run.backgroundWanted,
            "backgroundEnabled": live && (gps.backgroundAllowed || ble["backgroundEnabled"] as? Bool == true),
            "backgroundGuaranteed": false, "busy": run.saveInFlight || run.recordState == "saving",
            "finished": saved, "saved": saved, "retryAvailable": run.saveFailed, "savedBytes": run.savedBytes,
            "orphans": orphanSummary(), "report": report(run)]) { _, new in new }
        if run.empty {
            value["reason"] = "no_samples"
            value["summary"] = IOSRideText.notRecorded
        }
        return value
    }

    private func emptySnapshot(id: UUID, at: Int64, scope: IOSRideScope) -> [String: Any] {
        var value = idleSnapshot(scope: scope)
        value.merge(["id": id.uuidString.lowercased(), "ticket": id.uuidString.lowercased(),
            "recordingId": id.uuidString.lowercased(), "state": "not_recorded", "recordState": "completed",
            "nativeRecordState": "not_recorded", "reason": "no_samples", "summary": IOSRideText.notRecorded,
            "saved": true, "finished": true, "endedAt": at]) { _, new in new }
        return value
    }

    /// 孤儿记录只报数量与最近一条的开始时间，不带 id/身份；数量为 0 时也保持字段存在，
    /// 网页不用判 undefined。扫盘在 configureScopeProvider 之后异步补上，所以这里读的是内存副本。
    private func orphanSummary() -> [String: Any] {
        ["count": orphanCount, "latestAt": orphanLatestAt as Any? ?? NSNull()]
    }

    private func report(_ run: Run) -> [String: Any] {
        ["gpsSamples": run.gpsSamples, "bleSamples": run.bleSamples, "gaps": run.gaps.count,
         "distanceM": run.distanceSegments > 0 ? run.distanceM as Any : NSNull(), "distanceSource": "gps_observed_segments",
         "maxGPSSpeedKph": run.maxGPSSpeed as Any? ?? NSNull(), "batterySource": "visible_ble_only",
         "charging": NSNull(), "chargeState": "unknown", "energyKWh": NSNull(),
         "maxSamples": IOSRideDisk.maxSamples, "maxFileBytes": IOSRideDisk.maxFileBytes]
    }

    private func record(_ run: Run, final: Bool) -> [String: Any] {
        ["version": 1, "id": run.id.uuidString.lowercased(), "owner": run.scope.ownerHash,
         "generation": run.scope.generation, "startedAt": run.startedAt,
         "endedAt": final ? run.endedAt as Any? ?? NSNull() : NSNull(),
         "state": final ? run.targetState : run.state, "reason": final ? run.targetReason : run.reason,
         "samples": run.samples, "elapsedMs": run.elapsedMs, "durationMs": run.durationMs,
         "rawGPS": run.rawGPS, "telemetry": run.telemetry, "gaps": run.gaps, "report": report(run)]
    }

    private func checkpoint(_ run: Run, force: Bool) {
        guard active === run, !run.ending, run.samples > 0, run.checkpointDirty, !run.checkpointing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 只有连续失败到上限才真的停掉这条线；单次失败走下面的退避重试。
        guard !run.saveFailed else { return }
        guard force || now - run.lastCheckpoint >= 15 else { return }
        // 退避窗口内不重试：瞬时磁盘压力通常几秒就恢复，盲目每秒重试只会继续压队列。
        guard force || now >= run.checkpointRetryAt else { return }
        run.checkpointing = true
        run.checkpointDirty = false
        run.lastCheckpoint = now
        // evictionBudget 是「还能不能再删历史」的许可，只在 worker 内被 persist 扣减。
        // 回收成功或失败都由它自己置 false，回主线程后再同步到 run.evictionAttempted。
        var evictionBudget = !run.evictionAttempted
        let value = record(run, final: false)
        let owner = run.scope.ownerHash
        worker.async { [weak self, weak run] in
            guard let run = run else { return }
            // persist 会在真正动手回收前把 budget 扣成 false（成败都一样），
            // 主线程回调里再同步给 run —— 这样「回收 8 条也不够」时不会反复删。
            var budget = evictionBudget
            let result: Result<Saved, Error>
            do { result = .success(try Self.persist(value, owner: owner, id: run.id, evictionBudget: &budget)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                run.checkpointing = false
                if !budget { run.evictionAttempted = true }
                switch result {
                case .success(let saved):
                    run.checkpointFailures = 0
                    run.checkpointRetryAt = 0
                    self.observeSaved(run, saved)
                    if let kept = saved.keptSamples { self.applyTrim(run, kept: kept) }
                case .failure(let error):
                    run.checkpointFailures += 1
                    let code = (error as? IOSRideDisk.Failure)?.code ?? "save_write_failed"
                    // 数据已经变了却没写进去：把 dirty 放回去，下一次 tick 才有机会重试。
                    run.checkpointDirty = true
                    // 失败 3 次以上才判死；之前任何一次瞬时失败都会永久钉住 saveFailed。
                    if run.checkpointFailures >= 3 {
                        run.saveFailed = true
                        run.recordState = "save_failed"
                        run.reason = code
                        if !run.ending { self.markGap(run, source: "storage", reason: "source_unavailable") }
                    } else {
                        // 15s → 30s → 60s 退避，封顶 60s。
                        let delay = min(60, 15 * Double(1 << (run.checkpointFailures - 1)))
                        run.checkpointRetryAt = ProcessInfo.processInfo.systemUptime + delay
                        run.reason = code
                        IOSDiagnostics.shared.log("ride: checkpoint 第 \(run.checkpointFailures) 次失败（\(code)），\(Int(delay))s 后重试")
                    }
                }
            }
        }
    }

    private func end(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let id = requestedID(options) else { reply(failure("invalid_recording_id"), nil); return }
        if let run = active, run.id == id, run.scope == scope {
            stop(run, state: "completed", reason: "user_stop", reply: reply)
        } else if let run = finals[id], run.scope.ownerHash == scope.ownerHash {
            reply(acceptedSnapshot(run, status: ["ok": run.completed && !run.saveFailed]), nil)
        } else if let empty = emptyFinals.first(where: { $0.id == id && $0.owner == scope.ownerHash }) {
            // 0 采样记录已经销毁，但 end 的重复调用必须幂等回终态；
            // 之前这里落到 stale_ticket，网页只看到「重试」而看不到「本次没记录到数据」。
            var value = emptySnapshot(id: id, at: empty.at, scope: scope)
            value["accepted"] = true
            reply(value, nil)
        } else { reply(failure("stale_ticket"), nil) }
    }

    private func stop(_ run: Run, state: String, reason: String, reply: ((Any?, String?) -> Void)?) {
        if let reply = reply {
            guard run.saveWaiters.count < 16 else { reply(failure("save_busy"), nil); return }
            run.saveWaiters.append((page, scopeProvider?(), reply))
        }
        guard !run.ending else { return }
        run.ending = true
        run.targetState = state
        run.targetReason = reason
        run.endedAt = Int64(Date().timeIntervalSince1970 * 1000)
        run.endedUptime = ProcessInfo.processInfo.systemUptime
        pauseDuration(run)
        invalidateGauge(run)
        publishSystemSurface(run, eventAt: run.endedAt, elapsedSeconds: Double(run.elapsedMs) / 1000)
        gps.endRecording(id: run.id)
        bluetooth.setRecordingContext(id: nil, background: false, scope: nil)
        removeObservers()
        clock?.invalidate(); clock = nil
        if run.samples == 0 {
            // 0 采样不是失败：没有文件可写，但这条记录到此为止。
            // empty=true 让 snapshot()/replySaved 回 saved:true，否则网页会一直卡在「保存尚未确认」。
            run.state = "not_recorded"
            run.recordState = "not_recorded"
            run.reason = "no_samples"
            run.empty = true
            run.completed = true
            retire(run)
            replySaved(run)
            return
        }
        run.state = "saving"
        run.recordState = "saving"
        saveFinal(run)
    }

    /// 落盘结果。keptSamples 非空表示这次保存为压到 8 MiB 以内截断过尾部。
    /// evicted 表示这次为腾地方删过旧记录（调用方据此避免反复回收）。
    private struct Saved {
        let bytes: Int
        let samples: Int
        let keptSamples: Int?
        let evicted: Int
    }

    /// 统一的落盘入口：先正常写；单文件超 8 MiB 时截断尾部（保留最早样本）再写一次，
    /// 并把 trimmed_for_size 记进 gaps。整条记录因为超限永远存不下会把 saveFailed 永久钉住，
    /// 之后所有 checkpoint 都被跳过，所以这里必须兜住，而不是把 record_limit_reached 抛出去。
    ///
    /// owner_storage_full 是「删掉本 owner 的旧记录就能腾出空间」的那一类（本 owner 字节/文件数、
    /// 全库总字节）。`allowEviction` 用 inout 传：**回收前**就置成 false（表示「已经动过历史」），
    /// 这样无论这次重试成不成功，同一条 run 都不会再删第二次。
    /// 原来的写法只在成功时置位，「回收 8 条也不够」时（典型：别的 owner 目录占满 256MB 全局额度）
    /// 每个 checkpoint / saveFinal / 用户 retry 都会再删 8 条真实记录，删到几十条而保存依旧失败。
    /// 纯 recycle 的错误码（owner 数上限、别的目录塞满）仍然直接抛，删自己的记录修不好。
    private static func persist(_ record: [String: Any], owner: String, id: UUID,
                                evictionBudget: inout Bool) throws -> Saved {
        let samples = Int(IOSRideJSON.integer(record["samples"]) ?? 0)
        do {
            return Saved(bytes: try IOSRideDisk.save(record, owner: owner, id: id),
                         samples: samples, keptSamples: nil, evicted: 0)
        } catch let failure as IOSRideDisk.Failure where failure.code == "record_limit_reached" {
            guard let trimmed = IOSRideDisk.trimmed(record) else { throw failure }
            let bytes = try IOSRideDisk.save(trimmed, owner: owner, id: id)
            let kept = Int(IOSRideJSON.integer(trimmed["samples"]) ?? 0)
            return Saved(bytes: bytes, samples: max(kept, 1), keptSamples: kept, evicted: 0)
        } catch let failure as IOSRideDisk.Failure where failure.code == "owner_storage_full" {
            guard evictionBudget else { throw failure }
            // 先扣预算再动手：即使下面重试失败，也不会在下一轮再删一次。
            evictionBudget = false
            let removed = IOSRideDisk.evictOldestFinished(owner: owner, protecting: id)
            guard removed > 0 else { throw failure }
            IOSDiagnostics.shared.log("ride: 本 owner 存储触顶，回收 \(removed) 条最旧已完成记录后重试")
            do {
                return Saved(bytes: try IOSRideDisk.save(record, owner: owner, id: id),
                             samples: samples, keptSamples: nil, evicted: removed)
            } catch let retryFailure as IOSRideDisk.Failure where retryFailure.code == "record_limit_reached" {
                // 回收后仍超单文件上限：和普通路径一样走截断。
                guard let trimmed = IOSRideDisk.trimmed(record) else { throw retryFailure }
                let bytes = try IOSRideDisk.save(trimmed, owner: owner, id: id)
                let kept = Int(IOSRideJSON.integer(trimmed["samples"]) ?? 0)
                return Saved(bytes: bytes, samples: max(kept, 1), keptSamples: kept, evicted: removed)
            }
        }
    }

    /// 截断后主线程内存里的 run 也要跟着裁，否则下一次 checkpoint 又把尾部塞回去、
    /// 再超限再截断，形成「写成功但内容反复回弹」的死循环。
    private func applyTrim(_ run: Run, kept: Int) {
        guard kept > 0, kept < run.samples else { return }
        let total = run.rawGPS.count + run.telemetry.count
        guard total > 0 else { return }
        let keepGPS = min(run.rawGPS.count, Int((Double(kept) * Double(run.rawGPS.count) / Double(total)).rounded(.down)))
        let keepBLE = min(run.telemetry.count, kept - keepGPS)
        run.rawGPS = Array(run.rawGPS.prefix(keepGPS))
        run.telemetry = Array(run.telemetry.prefix(keepBLE))
        run.gpsSamples = keepGPS
        run.bleSamples = keepBLE
        run.samples = keepGPS + keepBLE
        // 截断只影响落盘体积；estimatedBytes 跟着缩，避免闸门继续按旧体积拒绝新样本。
        run.estimatedBytes = max(2048, run.savedBytes)
        markGap(run, source: "storage", reason: "trimmed_for_size", force: true)
    }

    private func saveFinal(_ run: Run) {
        guard !run.saveInFlight else { return }
        run.saveInFlight = true
        // 同 checkpoint：evictionBudget 在 worker 里被 persist 扣减，成功后同步回 run。
        var evictionBudget = !run.evictionAttempted
        let value = record(run, final: true)
        let owner = run.scope.ownerHash
        worker.async { [weak self, weak run] in
            guard let run = run else { return }
            var budget = evictionBudget
            var result: Result<Saved, Error>
            do { result = .success(try Self.persist(value, owner: owner, id: run.id, evictionBudget: &budget)) }
            catch { result = .failure(error) }
            // iOS 侧原来没有 save_failed 的出口：网页从不发 ride.action{retry}，
            // 用户看到「保存失败」就再也回不到 completed。这里在同一个 worker 上
            // 停 300ms 自动补一次（常见诱因是瞬时磁盘压力/文件保护未就绪），
            // 仍失败才真正置 save_failed，并让回执带 retryAvailable=true。
            if case .failure = result {
                // saveRetried 归主线程所有：这里回主线程取「这次由我重试」的权利再同步回来。
                // 用 sync 而不是再派发一个 async，是为了让重试仍然留在同一个 worker 上，
                // 不与用户发起的 retry 抢同一个文件。
                let alreadyRetried = DispatchQueue.main.sync { () -> Bool in
                    if run.saveRetried { return true }
                    run.saveRetried = true
                    return false
                }
                if !alreadyRetried {
                    Thread.sleep(forTimeInterval: 0.3)
                    // 第二次重试不再动历史（budget 已被扣成 false，这里复用同一个变量即可）。
                    do { result = .success(try Self.persist(value, owner: owner, id: run.id, evictionBudget: &budget)) }
                    catch { result = .failure(error) }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                run.saveInFlight = false
                // 回收成败都钉住：budget 一旦被扣就不允许这条 run 再删历史。
                if !budget { run.evictionAttempted = true }
                switch result {
                case .success(let saved):
                    self.observeSaved(run, saved)
                    if let kept = saved.keptSamples { self.applyTrim(run, kept: kept) }
                    run.saveFailed = false
                    run.completed = true
                    run.state = run.targetState
                    run.recordState = run.targetState
                    run.reason = run.targetReason
                case .failure(let error):
                    run.saveFailed = true
                    run.completed = false
                    run.state = "save_failed"
                    run.recordState = "save_failed"
                    run.reason = (error as? IOSRideDisk.Failure)?.code ?? "save_write_failed"
                }
                self.retire(run)
                self.replySaved(run)
            }
        }
    }

    private var pendingSaveCapacity: Bool {
        let failed = finals.values.filter { $0.saveFailed || $0.saveInFlight }
        // 为下一轮预留整份 8 MiB，失败已占四份时不再启动，不能静默牺牲唯一的重试数据。
        return failed.count < 4 && failed.reduce(0, { $0 + $1.estimatedBytes }) + IOSRideDisk.maxFileBytes <= 32 * 1024 * 1024
    }

    private func retire(_ run: Run) {
        if active === run { active = nil; if Self.leaseOwner === self { Self.leaseOwner = nil } }
        if run.empty {
            // 0 采样没有文件也没有可重试的数据，不能占 finals 的 4 个保存槽位。
            // 但网页重复调用 end 时仍应拿到终态回执，所以在内存里留一个短标记（只存 id/owner）。
            emptyFinals.append((id: run.id, owner: run.scope.ownerHash, at: run.endedAt ?? run.startedAt))
            if emptyFinals.count > 8 { emptyFinals.removeFirst(emptyFinals.count - 8) }
            return
        }
        finals[run.id] = run
        while finals.count > 4 {
            guard let remove = finals.values.filter({ !$0.saveFailed && !$0.saveInFlight && $0 !== run })
                .sorted(by: { $0.startedAt < $1.startedAt }).first else { break }
            finals.removeValue(forKey: remove.id)
        }
    }

    private func replySaved(_ run: Run) {
        let waiters = run.saveWaiters
        run.saveWaiters.removeAll()
        for (revision, captured, reply) in waiters {
            guard revision == page, captured != nil, scopeProvider?() == captured else { reply(nil, "stale_navigation"); continue }
            var value = snapshot(run)
            // not_recorded（empty）也算收尾成功：网页用这一条回执决定按钮文案和是否 throw，
            // 回 ok=false 会让它一直重试同一条已经不存在的记录。
            value["ok"] = !run.saveFailed
            value["accepted"] = !run.saveFailed
            // retryAvailable 现在与 snapshot 语义一致：只有真的 saveFailed 才提示可重试。
            value["retryAvailable"] = run.saveFailed
            reply(value, nil)
        }
    }

    private func action(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let action = options["action"] as? String else { reply(failure("invalid_action"), nil); return }
        let suppliedID = options["id"] ?? options["ticket"] ?? options["recordingId"]
        if suppliedID != nil && requestedID(options) == nil { reply(failure("invalid_recording_id"), nil); return }
        let id = requestedID(options) ?? active?.id
        let run = id.flatMap { active?.id == $0 ? active : finals[$0] }
        if suppliedID != nil, run == nil || run?.scope.ownerHash != scope.ownerHash {
            // 已销毁的空终态仍由 end 幂等处理，其他动作不准复活旧票据。
            if action != "stop" { reply(failure("stale_ticket"), nil); return }
        }
        if action == "records" {
            list(scope: scope) { [weak self, weak run] result, error in
                guard let self = self else { return }
                var value = run.map { self.snapshot($0) } ?? self.idleSnapshot(scope: scope)
                if let result = result as? [String: Any] { value.merge(result) { _, new in new } }
                else { value["ok"] = false; value["recordsError"] = error ?? "records_failed" }
                value["accepted"] = value["ok"] as? Bool == true
                reply(value, error)
            }
            return
        }
        if action == "stop" {
            var endOptions = options
            if let id = id { endOptions["id"] = id.uuidString.lowercased() }
            end(scope: scope, options: endOptions, reply: reply); return
        }
        if ["location-settings", "bluetooth-settings"].contains(action) {
            openSettings(scope: scope, run: run, options: options, reply: reply); return
        }
        if ["permission", "location-permission"].contains(action) {
            requestPermission(scope: scope, run: run, locationOnly: action == "location-permission", options: options, reply: reply); return
        }
        guard let id = id, let run = run, run.scope.ownerHash == scope.ownerHash else {
            reply(failure("invalid_recording_id"), nil); return
        }
        if action == "retry" || action == "retry_save" {
            guard finals[id] === run, run.saveFailed else {
                var value = snapshot(run)
                value["ok"] = false; value["accepted"] = false; value["available"] = false
                // 原生只重试同 UUID 落盘；重连/续认证仍由 privateJS driver 发真实 exchange。
                value["reason"] = active === run ? "private_driver_required" : "retry_unavailable"
                reply(value, nil); return
            }
            guard !run.saveInFlight, run.saveWaiters.count < 16 else { reply(failure("save_busy"), nil); return }
            run.state = "saving"; run.recordState = "saving"; run.saveRetried = false
            run.saveWaiters.append((page, scopeProvider?(), reply))
            saveFinal(run) // 同一 UUID 原子替换，不追加第二条历史。
            return
        }
        guard owns(run) else { reply(failure("stale_ticket"), nil); return }
        switch action {
        case "gps_auto_on", "gps_auto_off":
            run.gpsOver50 = action == "gps_auto_on"
            preferences.set(run.gpsOver50, forKey: gpsAutoKey(scope))
            invalidateGauge(run) // 偏好不是新速度观测，等下一条真实速度样本再发布。
            reply(acceptedSnapshot(run), nil)
        case "pause", "gps_off":
            markGap(run, source: "gps", reason: action == "pause" ? "user_pause" : "gps_disabled")
            if action == "pause" { run.userPaused = true; invalidateGauge(run) }
            else { run.gpsWanted = false; invalidateGauge(run, source: .gps) }
            run.lastRoute = nil
            gps.pauseRecording(id: run.id)
            if action == "pause" {
                markGap(run, source: "ble", reason: "user_pause")
                pauseDuration(run); run.state = "paused"; run.recordState = "paused"; run.reason = "user_pause"
                bluetooth.setRecordingContext(id: nil, background: false, scope: nil)
            } else if !bleFresh(run) {
                pauseDuration(run); run.state = "interrupted"; run.recordState = "gap"; run.reason = "gps_disabled"
            }
            checkpoint(run, force: true)
            publishSystemSurface(run, eventAt: Int64(Date().timeIntervalSince1970 * 1000), elapsedSeconds: Double(run.elapsedMs) / 1000)
            reply(acceptedSnapshot(run), nil)
        case "resume", "gps_on", "background_on":
            guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
            confirm(method: "ride.action", id: id, scope: scope, title: IOSStrings.rideRecordTitle,
                    message: IOSStrings.rideRecordMessage, reply: reply) { [weak self, weak run] consent in
                guard let self = self else { return }
                guard let run = run, self.owns(run) else { self.finish(consent, self.failure("stale_ticket")); return }
                var status: [String: Any] = ["ok": true]
                if action == "background_on" {
                    if run.gpsWanted { status = self.gps.setBackgroundRecording(id: run.id, enabled: true, requestPermission: true) }
                    if status["ok"] as? Bool == true { run.backgroundWanted = true }
                } else {
                    let wantedGPS = action == "gps_on" || run.gpsWanted
                    if wantedGPS { status = self.gps.beginRecording(id: run.id, background: run.backgroundWanted, requestPermission: true) }
                    if status["ok"] as? Bool == true {
                        run.userPaused = false; run.gpsWanted = wantedGPS
                        run.state = "waiting"; run.recordState = "waiting"; run.reason = "waiting_fix"
                    }
                }
                self.updateBLEContext(run)
                self.publishSystemSurface(run, eventAt: Int64(Date().timeIntervalSince1970 * 1000), elapsedSeconds: Double(run.elapsedMs) / 1000)
                self.finish(consent, self.acceptedSnapshot(run, status: status))
            }
        case "background_off":
            let status = run.gpsWanted ? gps.setBackgroundRecording(id: run.id, enabled: false, requestPermission: false) : ["ok": true]
            if status["ok"] as? Bool == true { run.backgroundWanted = false; updateBLEContext(run) }
            reply(acceptedSnapshot(run, status: status), nil)
        default:
            var value = snapshot(run)
            value["ok"] = false; value["accepted"] = false; value["available"] = false; value["reason"] = "unsupported_action"
            reply(value, nil)
        }
    }

    private func acceptedSnapshot(_ run: Run, status: [String: Any] = ["ok": true]) -> [String: Any] {
        var value = snapshot(run)
        let accepted = status["ok"] as? Bool == true
        value["ok"] = accepted; value["accepted"] = accepted
        if !accepted { value["reason"] = status["reason"] ?? "source_unavailable" }
        return value
    }

    private func openSettings(scope: IOSRideScope, run: Run?, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
        confirm(method: "ride.action", id: run?.id, scope: scope, title: IOSStrings.settingsTitle,
                message: IOSStrings.settingsMessage, reply: reply) { [weak self, weak run] consent in
            guard let self = self else { return }
            guard let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) else {
                self.finish(consent, self.failure("settings_unavailable")); return
            }
            // iOS 只公开本 App 设置入口，不使用私有蓝牙/定位 URL，也不谎称打开了系统蓝牙页。
            UIApplication.shared.open(url, options: [:]) { [weak self, weak run] opened in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    var value = run.map { self.snapshot($0) } ?? self.idleSnapshot(scope: scope)
                    value["ok"] = opened; value["accepted"] = opened; value["available"] = true
                    value["settingsOpened"] = opened; value["settingsDestination"] = "app"
                    if !opened { value["reason"] = "settings_unavailable" }
                    self.finish(consent, value)
                }
            }
        }
    }

    private func requestPermission(scope: IOSRideScope, run: Run?, locationOnly: Bool, options: [String: Any],
                                   reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
        guard UIApplication.shared.applicationState == .active else { reply(failure("foreground_required"), nil); return }
        guard !permissionBusy else { reply(failure("permission_busy"), nil); return }
        if let run = run, !owns(run) { reply(failure("stale_ticket"), nil); return }
        let ble = bluetooth.snapshot()
        let wantsLocation = locationOnly || (run?.gpsWanted == true && ble["authorization"] as? String == "allowed")
        if wantsLocation {
            if let run = run {
                confirm(method: "ride.action", id: run.id, scope: scope, title: IOSStrings.gpsReadTitle,
                        message: IOSStrings.gpsReadMessage, reply: reply) { [weak self, weak run] consent in
                    guard let self = self else { return }
                    guard let run = run, self.owns(run), !run.userPaused else {
                        self.finish(consent, self.failure("recording_paused")); return
                    }
                    // 真实原生确认后复用唯一定位服务；没有网页“已授权”捷径。
                    let status = self.gps.beginRecording(id: run.id, background: run.backgroundWanted, requestPermission: true)
                    if status["ok"] as? Bool == true { run.gpsWanted = true }
                    self.finish(consent, self.acceptedSnapshot(run, status: status))
                }
            } else {
                let revision = page
                permissionBusy = true
                gps.handle(method: "gps.begin", args: [["confirmed": true, "requestPermission": true]]) { [weak self] result, error in
                    guard let self = self else { return }
                    self.permissionBusy = false
                    guard self.page == revision, self.scopeProvider?() == scope else { reply(nil, "stale_navigation"); return }
                    let status = result as? [String: Any] ?? [:]
                    var value = self.idleSnapshot(scope: scope)
                    value["ok"] = error == nil && status["ok"] as? Bool == true
                    value["accepted"] = error == nil && status["accepted"] as? Bool == true
                    if value["accepted"] as? Bool != true { value["reason"] = status["reason"] ?? "permission_required" }
                    // gps.begin 的 ticket 不是 Ride UUID；不得让页面把它拿去 stop/read/delete。
                    reply(value, error)
                }
            }
            return
        }
        if ble["authorization"] as? String == "allowed" {
            var value = run.map { snapshot($0) } ?? idleSnapshot(scope: scope)
            value["accepted"] = true; reply(value, nil); return
        }
        if ["denied", "restricted"].contains(ble["authorization"] as? String ?? "") {
            var value = run.map { snapshot($0) } ?? idleSnapshot(scope: scope)
            value["ok"] = false; value["accepted"] = false; value["available"] = false
            value["reason"] = "permission_denied"; value["settingsAction"] = "bluetooth-settings"
            reply(value, nil); return
        }
        confirm(method: "ride.action", id: run?.id, scope: scope, title: IOSStrings.rideRecordTitle,
                message: IOSStrings.rideRecordMessage, reply: reply) { [weak self, weak run] consent in
            guard let self = self else { return }
            self.permissionBusy = true
            // 现有有界扫描会创建唯一 CBCentralManager 并触发系统权限；不另建连接/认证服务。
            self.bluetooth.handle(method: "ble.scan", args: [["confirmed": true, "timeoutMs": 1000]]) { [weak self, weak run] result, error in
                guard let self = self else { return }
                self.permissionBusy = false
                guard self.live(consent) else { self.finish(consent, self.failure("stale_session")); return }
                let status = result as? [String: Any] ?? [:]
                var value = run.map { self.snapshot($0) } ?? self.idleSnapshot(scope: scope)
                let accepted = error == nil && status["ok"] as? Bool == true
                if accepted, run?.gpsWanted == true, self.bluetooth.snapshot()["authorization"] as? String == "allowed" {
                    // 系统蓝牙回执已落定后才请求定位，不叠两个系统授权框。
                    self.requestPermission(scope: scope, run: run, locationOnly: true, options: options) { value, error in
                        self.finish(consent, value as? [String: Any] ?? self.failure(error ?? "permission_required"))
                    }
                    return
                }
                value["ok"] = accepted; value["accepted"] = accepted; value["available"] = accepted
                if !accepted { value["reason"] = status["reason"] ?? "permission_required" }
                self.finish(consent, value)
            }
        }
    }

    private func requestedID(_ options: [String: Any]) -> UUID? {
        guard let text = options["id"] as? String ?? options["ticket"] as? String ?? options["recordingId"] as? String else { return nil }
        return UUID(uuidString: text)
    }

    private func list(scope: IOSRideScope, reply: @escaping (Any?, String?) -> Void) {
        io(scope: scope, reply: reply) {
            try IOSRideDisk.list(owner: scope.ownerHash)
        }
    }

    private func detail(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let id = requestedID(options) else { reply(failure("invalid_recording_id"), nil); return }
        let offset = IOSRideJSON.integer(options["offset"] ?? 0, maximum: Int64(IOSRideDisk.maxSamples))
        let limit = IOSRideJSON.integer(options["limit"] ?? 500, minimum: 1, maximum: 2000)
        guard let start = offset, let count = limit else { reply(failure("invalid_page"), nil); return }
        io(scope: scope, reply: reply) {
            let record = try IOSRideDisk.read(owner: scope.ownerHash, id: id)
            let gps = record["rawGPS"] as? [[String: Any]] ?? []
            let ble = record["telemetry"] as? [[String: Any]] ?? []
            var result = IOSRideDisk.summary(record)
            result["ok"] = true
            result["version"] = 1
            result["rawGPS"] = Array(gps.dropFirst(Int(start)).prefix(Int(count)))
            result["telemetry"] = Array(ble.dropFirst(Int(start)).prefix(Int(count)))
            result["gaps"] = Array((record["gaps"] as? [[String: Any]] ?? []).prefix(256))
            result["offset"] = start
            result["limit"] = count
            result["moreGPS"] = gps.count > Int(start + count)
            result["moreTelemetry"] = ble.count > Int(start + count)
            return result
        }
    }

    private func delete(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true, let id = requestedID(options) else {
            reply(failure("user_action_required"), nil); return
        }
        guard active?.id != id, finals[id]?.saveInFlight != true else { reply(failure("recording_busy"), nil); return }
        // 切换账号后 finals 里可能还留着上一个 owner 的 save_failed 副本（同一 UUID 理论上不跨账号，
        // 但一旦出现，删掉的是别人唯一可重试的数据）。这里先按 owner 校验，再看磁盘。
        if let cached = finals[id], cached.scope.ownerHash != scope.ownerHash {
            reply(failure("stale_ticket"), nil); return
        }
        confirm(method: "ride.delete", id: id, scope: scope, title: IOSStrings.rideDeleteTitle,
                message: IOSStrings.rideDeleteMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            self.io(scope: scope, reply: { [weak self] value, error in
                guard let self = self else { return }
                if error == nil, (value as? [String: Any])?["ok"] as? Bool == true {
                    self.finals.removeValue(forKey: id)
                    self.emptyFinals.removeAll { $0.id == id }
                }
                self.finish(consent, value as? [String: Any] ?? self.failure(error ?? "delete_failed"))
            }) {
                // 磁盘路径按 scope.ownerHash 拼，越界不了；finals 归属已在上面主线程校验过。
                // 这里不碰 finals：work 闭包跑在 worker 上，读实例的主线程状态会引入竞争。
                try IOSRideDisk.delete(owner: scope.ownerHash, id: id)
                return ["ok": true, "id": id.uuidString.lowercased(), "deleted": true]
            }
        }
    }

    private func share(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true, let id = requestedID(options) else {
            reply(failure("user_action_required"), nil); return
        }
        guard active?.id != id, sharing == nil else { reply(failure("recording_busy"), nil); return }
        confirm(method: "ride.share", id: id, scope: scope, title: IOSStrings.rideShareTitle,
                message: IOSStrings.rideShareMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            self.sharing = consent
            self.worker.async { [weak self, weak consent] in
                guard let self = self, let consent = consent else { return }
                let result: Result<URL, Error>
                do {
                    _ = try IOSRideDisk.read(owner: scope.ownerHash, id: id)
                    result = .success(try IOSRideDisk.url(owner: scope.ownerHash, id: id))
                } catch { result = .failure(error) }
                DispatchQueue.main.async {
                    guard self.sharing === consent else { return }
                    guard self.live(consent) else { self.cancelShare("stale_navigation"); return }
                    guard case .success(let url) = result else { self.cancelShare("records_read_failed"); return }
                    guard let presenter = self.presenterProvider?(), presenter.viewIfLoaded?.window != nil,
                          presenter.presentedViewController == nil else { self.cancelShare("share_unavailable"); return }
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    self.activity = activity
                    activity.popoverPresentationController?.sourceView = presenter.view
                    activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    activity.completionWithItemsHandler = { [weak self, weak consent] _, completed, _, error in
                        guard let self = self, let consent = consent, self.sharing === consent else { return }
                        self.sharing = nil
                        self.activity = nil
                        self.finish(consent, ["ok": completed && error == nil, "id": id.uuidString.lowercased(),
                            "shared": completed && error == nil, "cancelled": !completed,
                            "reason": error == nil ? completed ? "" : "user_cancelled" : "share_failed"])
                    }
                    presenter.present(activity, animated: true)
                }
            }
        }
    }

    private func io(scope: IOSRideScope, reply: @escaping (Any?, String?) -> Void,
                    work: @escaping () throws -> [String: Any]) {
        guard pendingIO < 8 else { reply(failure("records_busy"), nil); return }
        pendingIO += 1
        let revision = page
        worker.async { [weak self] in
            let result: Result<[String: Any], Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingIO -= 1
                guard self.page == revision, self.scopeProvider?() == scope else { reply(nil, "stale_navigation"); return }
                switch result {
                case .success(let value): reply(value, nil)
                case .failure(let error): reply(self.failure((error as? IOSRideDisk.Failure)?.code ?? "records_failed"), nil)
                }
            }
        }
    }

    private func confirm(method: String, id: UUID?, scope: IOSRideScope, title: String, message: String,
                         reply: @escaping (Any?, String?) -> Void, accepted: @escaping (Consent) -> Void) {
        guard UIApplication.shared.applicationState == .active else { reply(failure("foreground_required"), nil); return }
        guard confirmation == nil, sharing == nil, let presenter = presenterProvider?(),
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            reply(failure("confirmation_unavailable"), nil); return
        }
        let consent = Consent(page: page, scope: scope, method: method, id: id, reply: reply)
        confirmation = consent
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        confirmationAlert = alert
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak consent] _ in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.cancelConsent("user_cancelled")
        })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self, weak consent] _ in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.confirmation = nil
            self.confirmationAlert = nil
            consent.timeout?.cancel(); consent.timeout = nil
            guard self.live(consent) else { self.finish(consent, self.failure("stale_session")); return }
            accepted(consent)
        })
        let timeout = DispatchWorkItem { [weak self, weak consent] in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.cancelConsent("confirmation_timeout")
        }
        consent.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        presenter.present(alert, animated: true)
    }

    private func live(_ consent: Consent) -> Bool {
        consent.reply != nil && consent.page == page && scopeProvider?() == consent.scope
            && UIApplication.shared.applicationState == .active
    }

    private func finish(_ consent: Consent, _ value: [String: Any]) {
        consent.timeout?.cancel(); consent.timeout = nil
        guard let reply = consent.reply else { return }
        consent.reply = nil
        if consent.page != page || scopeProvider?() != consent.scope { reply(nil, "stale_navigation") }
        else { reply(value, nil) }
    }

    private func cancelConsent(_ code: String) {
        guard let consent = confirmation else { return }
        confirmation = nil
        confirmationAlert?.dismiss(animated: false)
        confirmationAlert = nil
        finish(consent, failure(code))
    }

    private func cancelShare(_ code: String) {
        guard let consent = sharing else { return }
        sharing = nil
        activity?.dismiss(animated: false)
        activity = nil
        finish(consent, failure(code))
    }

    private func failure(_ code: String) -> [String: Any] {
        ["ok": false, "accepted": false, "available": false, "state": "error", "recordState": "error", "reason": code]
    }
}
