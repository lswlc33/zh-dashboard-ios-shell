import Foundation
#if os(iOS) || os(macOS)
import Darwin
#endif

// 共享同账号最多 8 辆已批准车辆的有界摘要；无 App Group 权益明确失败，Broadcast 使用独立目录。
public enum SystemSnapshotStore {
    public static let appGroupIdentifier = "group.io.github.lswlc33.dashboard.ios"
    public static let maxSnapshotBytes = 8 * 1024
    public static let maxVehicles = 8
    private static let markerName = "active-owner.json"
    private static let lockName = ".snapshot-lock"
    private static let settingsName = "widget-settings.json"

    public static func isAvailable() -> Bool {
        #if os(iOS) || os(macOS)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
        #else
        return false
        #endif
    }

    public static func currentOwner() throws -> SystemSnapshotOwner? {
        try coordinated(create: false) { root in try owner(at: root) }
    }

    public static func read(expectedOwner: SystemSnapshotOwner, now: Date = Date()) throws -> SystemSnapshot? {
        guard expectedOwner.isValid else { throw SystemSnapshotError("invalid_snapshot_owner") }
        return try coordinated(create: false) { root in
            guard let selected = try owner(at: root) else { return nil }
            guard selected == expectedOwner else { throw SystemSnapshotError("snapshot_owner_mismatch") }
            return try snapshot(at: root, expectedOwner: expectedOwner, now: now)
        }
    }

    // Widget 没有主 App 的账号/凭据存储；只读原生已批准的当前匿名 owner，且在同一跨进程锁内核对。
    public static func readCurrent(now: Date = Date()) throws -> SystemSnapshot? {
        try coordinated(create: false) { root in
            guard let selected = try owner(at: root) else { return nil }
            return try snapshot(at: root, expectedOwner: selected, now: now)
        }
    }

    // 配置选 B 时缺测就是 nil，绝不能回退当前 A。活动 account marker 在同一锁内验证。
    public static func readVehicle(identifier: String?, now: Date = Date()) throws -> SystemSnapshot? {
        try coordinated(create: false) { root in
            guard let active = try owner(at: root) else { return nil }
            let requested = try identifier ?? settings(at: root, active: active).vehicleID
            guard let requested = requested else { return try snapshot(at: root, expectedOwner: active, now: now) }
            guard let selected = try selectedOwner(requested, at: root), selected.sharesAccount(with: active) else {
                return nil
            }
            return try snapshot(at: root, expectedOwner: selected, now: now)
        }
    }

    public static func vehicles(now: Date = Date()) throws -> [SystemWidgetVehicle] {
        try coordinated(create: false) { root in
            guard let active = try owner(at: root) else { return [] }
            return try snapshotOwners(at: root).compactMap { selected in
                guard selected.sharesAccount(with: active),
                      let value = try snapshot(at: root, expectedOwner: selected, now: now) else { return nil }
                return SystemWidgetVehicle(owner: selected, name: value.vehicle?.name, suffix: value.vehicle?.vinDisplaySuffix)
            }
        }
    }

    public static func widgetSettings(expectedOwner: SystemSnapshotOwner) throws -> SystemWidgetSettings {
        try coordinated(create: false) { root in
            guard let active = try owner(at: root), active == expectedOwner else {
                throw SystemSnapshotError("snapshot_owner_mismatch")
            }
            return try settings(at: root, active: active)
        }
    }

    public static func writeWidgetSettings(_ value: SystemWidgetSettings, expectedOwner: SystemSnapshotOwner) throws {
        _ = try value.validated()
        try coordinated(create: true) { root in
            guard let active = try owner(at: root), active == expectedOwner,
                  (active.accountHash ?? active.accountVINHash) == value.accountHash else {
                throw SystemSnapshotError("snapshot_owner_mismatch")
            }
            if let id = value.vehicleID {
                guard let selected = try selectedOwner(id, at: root), selected.sharesAccount(with: active) else {
                    throw SystemSnapshotError("widget_vehicle_unavailable")
                }
            }
            let target = root.appendingPathComponent(settingsName)
            try ensureRegularFile(target, missingAllowed: true)
            try protectedWrite(try JSONEncoder().encode(value), to: target)
        }
    }

    public static func ownerIdentifier(_ id: String) -> SystemSnapshotOwner? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = SystemSnapshotOwner(scopeID: String(parts[1]), accountVINHash: String(parts[0]))
        return owner.isValid ? owner : nil
    }

    private static func selectedOwner(_ id: String, at root: URL) throws -> SystemSnapshotOwner? {
        guard let parsed = ownerIdentifier(id),
              let data = try boundedRead(path(root, owner: parsed), limit: maxSnapshotBytes) else { return nil }
        try validateShape(data)
        let value = try JSONDecoder().decode(SystemSnapshot.self, from: data)
        guard value.owner.scopeID == parsed.scopeID, value.owner.accountVINHash == parsed.accountVINHash else {
            throw SystemSnapshotError("snapshot_owner_mismatch")
        }
        return try value.validated(expectedOwner: value.owner).owner
    }

    private static func snapshotOwners(at root: URL) throws -> [SystemSnapshotOwner] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let ids = entries.filter { $0.hasSuffix(".json") && $0 != markerName && $0 != settingsName }
        guard ids.count <= maxVehicles else { throw SystemSnapshotError("snapshot_storage_limit") }
        return try ids.compactMap { try selectedOwner(String($0.dropLast(5)), at: root) }
    }

    private static func settings(at root: URL, active: SystemSnapshotOwner) throws -> SystemWidgetSettings {
        let account = active.accountHash ?? active.accountVINHash
        guard let data = try boundedRead(root.appendingPathComponent(settingsName), limit: 1024) else {
            return SystemWidgetSettings(accountHash: account)
        }
        let shape = try object(data)
        guard Set(shape.keys).isSubset(of: ["accountHash", "vehicleID", "showName", "showTime"]) else {
            throw SystemSnapshotError("invalid_widget_settings")
        }
        let value = try JSONDecoder().decode(SystemWidgetSettings.self, from: data).validated()
        return value.accountHash == account ? value : SystemWidgetSettings(accountHash: account)
    }

    public static func write(_ value: SystemSnapshot, expectedOwner: SystemSnapshotOwner) throws {
        _ = try value.validated(expectedOwner: expectedOwner)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maxSnapshotBytes else { throw SystemSnapshotError("snapshot_too_large") }
        try validateShape(data)
        try coordinated(create: true) { root in
            if let current = try owner(at: root), current != expectedOwner {
                throw SystemSnapshotError("snapshot_owner_mismatch")
            }
            // orphan 清理排在实际发布之前：旧快照先删掉，目录里就不会因为残留的
            // 临时文件/未知条目把下面的原子写卡死在 snapshot_storage_invalid。
            // （清理本身只删「本 store 命名的旧快照」与临时文件，不碰别的文件。）
            // 同文件旧 v1 owner 可迁移到带 accountHash 的摘要，不先删正在写的 target。
            let target = path(root, owner: expectedOwner)
            if let data = try boundedRead(target, limit: maxSnapshotBytes) {
                try validateShape(data)
                let old = try JSONDecoder().decode(SystemSnapshot.self, from: data)
                guard old.owner.accountVINHash == expectedOwner.accountVINHash,
                      old.owner.scopeID == expectedOwner.scopeID else { throw SystemSnapshotError("snapshot_owner_mismatch") }
                if old.owner != expectedOwner { try FileManager.default.removeItem(at: target) }
            }
            try removeOrphans(root, keepingOwner: expectedOwner)
            // 超过目录容量如实拒绝，不静默驱逐用户配置的车辆。
            let existing = try snapshotOwners(at: root)
            guard existing.contains(expectedOwner) || existing.count < maxVehicles else {
                throw SystemSnapshotError("widget_vehicle_limit")
            }
            // 先完整原子写数据，再原子发布 owner；崩溃中断时最多读不到，绝不读到另一账号的数据。
            try ensureRegularFile(target, missingAllowed: true)
            try protectedWrite(data, to: target)
            let marker = root.appendingPathComponent(markerName, isDirectory: false)
            try ensureRegularFile(marker, missingAllowed: true)
            try protectedWrite(try encoder.encode(expectedOwner), to: marker)
        }
    }

    // 主服务切换到经过原生会话核验的 owner；同账号保留可配置车辆，换账号先清后发布 marker。
    public static func activate(_ selected: SystemSnapshotOwner) throws {
        guard selected.isValid else { throw SystemSnapshotError("invalid_snapshot_owner") }
        try coordinated(create: true) { root in
            // 激活新 scope 前撤掉旧 marker；清理失败时最多无数据，不能继续展示旧 owner。
            if let active = try owner(at: root), active != selected {
                if !active.sharesAccount(with: selected) { try revokeAccount(at: root, expectedOwner: active) }
                else { try FileManager.default.removeItem(at: root.appendingPathComponent(markerName)) }
            }
            try removeOrphans(root, keepingOwner: selected)
            let marker = root.appendingPathComponent(markerName)
            try ensureRegularFile(marker, missingAllowed: true)
            try protectedWrite(try JSONEncoder().encode(selected), to: marker)
        }
    }

    public static func clearAccount(expectedOwner: SystemSnapshotOwner) throws {
        guard expectedOwner.isValid else { throw SystemSnapshotError("invalid_snapshot_owner") }
        // 撤权不能被目录数量/坏 sibling 挡在锁外；仍验证 App Group、真实目录与跨进程锁。
        try coordinated(create: false, revoking: true) { root in
            try revokeAccount(at: root, expectedOwner: expectedOwner)
        }
    }

    // 独立于 Apple 容器的文件操作，fixture 可对真实临时目录覆盖损坏 sibling。
    // 必须先撤 marker：下面的清理是 best effort，不是读取权限成立的前置条件。
    static func revokeAccount(at root: URL, expectedOwner: SystemSnapshotOwner) throws {
        let active = try owner(at: root)
        if active?.sharesAccount(with: expectedOwner) == true {
            try FileManager.default.removeItem(at: root.appendingPathComponent(markerName))
            let settings = root.appendingPathComponent(settingsName)
            if (try? ensureRegularFile(settings, missingAllowed: true)) != nil,
               FileManager.default.fileExists(atPath: settings.path) {
                try? FileManager.default.removeItem(at: settings)
            }
        }
        // 只有验证过归属与真实 regular file 的摘要才删；坏文件/未知条目原样保留，不牵连撤权。
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
              entries.count <= 64 else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".json"), ownerIdentifier(String(name.dropLast(5))) != nil else { continue }
            do {
                guard let selected = try selectedOwner(String(name.dropLast(5)), at: root),
                      selected.sharesAccount(with: expectedOwner) else { continue }
                try ensureRegularFile(entry, missingAllowed: false)
                try FileManager.default.removeItem(at: entry)
            } catch { continue }
        }
    }

    public static func clear(expectedOwner: SystemSnapshotOwner) throws {
        guard expectedOwner.isValid else { throw SystemSnapshotError("invalid_snapshot_owner") }
        try coordinated(create: false) { root in
            // 老 owner 的迟到清理不能删除新 owner；先撤销 marker，再清文件与 orphan。
            if let current = try owner(at: root), current == expectedOwner {
                try FileManager.default.removeItem(at: root.appendingPathComponent(markerName))
            }
            let target = path(root, owner: expectedOwner)
            try ensureRegularFile(target, missingAllowed: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    private static func path(_ root: URL, owner: SystemSnapshotOwner) -> URL {
        root.appendingPathComponent(owner.accountVINHash + "." + owner.scopeID + ".json", isDirectory: false)
    }

    private static func owner(at root: URL) throws -> SystemSnapshotOwner? {
        guard let data = try boundedRead(root.appendingPathComponent(markerName), limit: 512) else { return nil }
        let shape = try object(data)
        guard Set(shape.keys).isSubset(of: ["scopeID", "accountVINHash", "accountHash"]),
              Set(["scopeID", "accountVINHash"]).isSubset(of: Set(shape.keys)) else {
            throw SystemSnapshotError("invalid_snapshot_owner")
        }
        let selected = try JSONDecoder().decode(SystemSnapshotOwner.self, from: data)
        guard selected.isValid else { throw SystemSnapshotError("invalid_snapshot_owner") }
        return selected
    }

    private static func snapshot(at root: URL, expectedOwner: SystemSnapshotOwner, now: Date) throws -> SystemSnapshot? {
        guard let data = try boundedRead(path(root, owner: expectedOwner), limit: maxSnapshotBytes) else { return nil }
        try validateShape(data)
        return try JSONDecoder().decode(SystemSnapshot.self, from: data).validated(expectedOwner: expectedOwner, now: now)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SystemSnapshotError("invalid_snapshot_utf8")
        }
        return result
    }

    private static func validateShape(_ data: Data) throws {
        let value = try object(data)
        func keys(_ source: [String: Any], allowed: Set<String>, required: Set<String>) throws {
            guard Set(source.keys).isSubset(of: allowed), required.isSubset(of: Set(source.keys)) else {
                throw SystemSnapshotError("snapshot_fields_not_allowed")
            }
        }
        try keys(value, allowed: ["version", "owner", "capturedAt", "expiresAt", "vehicle", "ride", "gauge"],
                 required: ["version", "owner", "capturedAt", "expiresAt"])
        guard let selected = value["owner"] as? [String: Any] else { throw SystemSnapshotError("invalid_snapshot_owner") }
        try keys(selected, allowed: ["scopeID", "accountVINHash", "accountHash"], required: ["scopeID", "accountVINHash"])
        if let source = value["vehicle"], !(source is NSNull) {
            guard let source = source as? [String: Any] else { throw SystemSnapshotError("invalid_vehicle_snapshot") }
            try keys(source, allowed: ["name", "vinDisplaySuffix", "socPercent", "socUpdatedAt", "charging",
                                      "chargingUpdatedAt", "chargeProgressPercent", "chargeProgressUpdatedAt", "updatedAt"],
                     required: ["updatedAt"])
        }
        if let source = value["gauge"], !(source is NSNull) {
            guard let source = source as? [String: Any] else { throw SystemSnapshotError("invalid_gauge_snapshot") }
            try keys(source, allowed: ["source", "speedKph", "updatedAt"], required: ["source", "speedKph", "updatedAt"])
        }
        if let source = value["ride"], !(source is NSNull) {
            guard let source = source as? [String: Any] else { throw SystemSnapshotError("invalid_ride_snapshot") }
            try keys(source, allowed: ["state", "startedAt", "updatedAt", "speedKph", "speedUpdatedAt", "lastLocationAt",
                                      "lastSignalAt", "locationAgeSeconds", "elapsedSeconds", "gapCount"],
                     required: ["state", "startedAt", "updatedAt"])
        }
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ensureRegularFile(url, missingAllowed: false)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
        guard size > 0, size <= limit else { throw SystemSnapshotError("snapshot_too_large") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw SystemSnapshotError("snapshot_too_large") }
        return data
    }

    private static func ensureRegularFile(_ url: URL, missingAllowed: Bool) throws {
        if missingAllowed, !FileManager.default.fileExists(atPath: url.path) { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SystemSnapshotError("snapshot_storage_invalid")
        }
    }

    private static func protectedWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        // 锁屏后 extension 仍可读最后一次获准快照；首次解锁前拒绝读，不存凭据或精确位置。
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var protected = url
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try protected.setResourceValues(resource)
    }

    // 仅清本匿名 summary 命名空间；保留同账号车辆，未知文件 fail closed，绝不触碰 Broadcast。
    private static func removeOrphans(_ root: URL, keepingOwner active: SystemSnapshotOwner) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        for entry in entries {
            let name = entry.lastPathComponent
            if [markerName, lockName, settingsName].contains(name) { continue }
            if name.hasPrefix(".dat.nosync") {
                try ensureRegularFile(entry, missingAllowed: false)
                try FileManager.default.removeItem(at: entry)
                continue
            }
            guard name.hasSuffix(".json"), ownerIdentifier(String(name.dropLast(5))) != nil else {
                throw SystemSnapshotError("snapshot_storage_invalid")
            }
            guard let selected = try selectedOwner(String(name.dropLast(5)), at: root) else { continue }
            if !selected.sharesAccount(with: active)
                || (selected.accountVINHash == active.accountVINHash && selected.scopeID != active.scopeID) {
                try FileManager.default.removeItem(at: entry)
            }
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).count
        guard remaining <= maxVehicles + 3 else { throw SystemSnapshotError("snapshot_storage_limit") }
    }

    private static func coordinated<T>(create: Bool, revoking: Bool = false, action: (URL) throws -> T) throws -> T {
        #if os(iOS) || os(macOS)
        let manager = FileManager.default
        guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SystemSnapshotError("app_group_unavailable")
        }
        let root = container.appendingPathComponent("ZeehoSystemSnapshots-v1", isDirectory: true)
        if !manager.fileExists(atPath: root.path) {
            // 读操作也建立空有界目录以取得跨进程锁；绝不建立替代共享路径。
            do { try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: nil) }
            catch {
                guard manager.fileExists(atPath: root.path) else { throw error }
            }
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw SystemSnapshotError("snapshot_storage_invalid") }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        let lockURL = root.appendingPathComponent(lockName, isDirectory: false)
        // O_NOFOLLOW + flock 避免 extension 与主 App 的原子 owner/data 发布被交错读取。
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SystemSnapshotError("snapshot_storage_unavailable") }
        defer { close(descriptor) }
        var locked = false
        // Widget 的极短读锁不能导致账号切换清理永久失败；最多等 100 ms，不无界阻塞 extension。
        for attempt in 0..<21 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if attempt < 20 { usleep(5_000) }
        }
        guard locked else { throw SystemSnapshotError("snapshot_store_busy") }
        defer { _ = flock(descriptor, LOCK_UN) }
        // 撤权先进入 action 删除匹配 marker；枚举限额只约束可选清理，不能阻断撤权。
        if !revoking {
            let entries = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
            guard entries.count <= (create ? 64 : maxVehicles + 3) else { throw SystemSnapshotError("snapshot_storage_limit") }
        }
        return try action(root)
        #else
        throw SystemSnapshotError("app_group_unavailable")
        #endif
    }
}
