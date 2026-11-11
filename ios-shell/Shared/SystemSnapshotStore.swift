import Foundation
#if os(iOS) || os(macOS)
import Darwin
#endif

// 一次只共享当前车辆的一份有界快照。没有 App Group 权益时明确失败，不能回退到临时目录骗报支持。
public enum SystemSnapshotStore {
    public static let appGroupIdentifier = "group.io.github.lswlc33.dashboard.ios"
    public static let maxSnapshotBytes = 8 * 1024
    private static let markerName = "active-owner.json"
    private static let lockName = ".snapshot-lock"

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
            // 先完整原子写数据，再原子发布 owner；崩溃中断时最多读不到，绝不读到另一账号的数据。
            let target = path(root, owner: expectedOwner)
            try ensureRegularFile(target, missingAllowed: true)
            try protectedWrite(data, to: target)
            let marker = root.appendingPathComponent(markerName, isDirectory: false)
            try ensureRegularFile(marker, missingAllowed: true)
            try protectedWrite(try encoder.encode(expectedOwner), to: marker)
            try removeOrphans(root, keeping: target.lastPathComponent)
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
        guard Set(shape.keys) == ["scopeID", "accountVINHash"] else { throw SystemSnapshotError("invalid_snapshot_owner") }
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
        try keys(value, allowed: ["version", "owner", "capturedAt", "expiresAt", "vehicle", "ride"],
                 required: ["version", "owner", "capturedAt", "expiresAt"])
        guard let selected = value["owner"] as? [String: Any] else { throw SystemSnapshotError("invalid_snapshot_owner") }
        try keys(selected, allowed: ["scopeID", "accountVINHash"], required: ["scopeID", "accountVINHash"])
        if let source = value["vehicle"], !(source is NSNull) {
            guard let source = source as? [String: Any] else { throw SystemSnapshotError("invalid_vehicle_snapshot") }
            try keys(source, allowed: ["name", "vinDisplaySuffix", "socPercent", "socUpdatedAt", "charging",
                                      "chargingUpdatedAt", "chargeProgressPercent", "chargeProgressUpdatedAt", "updatedAt"],
                     required: ["updatedAt"])
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

    private static func removeOrphans(_ root: URL, keeping name: String) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        guard entries.count <= 8 else { throw SystemSnapshotError("snapshot_storage_limit") }
        for entry in entries where ![name, markerName, lockName].contains(entry.lastPathComponent) {
            // 不枚举账号历史；仅清理由此 store 命名的旧匿名快照。
            let parts = entry.lastPathComponent.split(separator: ".")
            guard parts.count == 3, parts[2] == "json",
                  SystemSnapshotOwner(scopeID: String(parts[1]), accountVINHash: String(parts[0])).isValid else {
                throw SystemSnapshotError("snapshot_storage_invalid")
            }
            try ensureRegularFile(entry, missingAllowed: false)
            try FileManager.default.removeItem(at: entry)
        }
    }

    private static func coordinated<T>(create: Bool, action: (URL) throws -> T) throws -> T {
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
        let entries = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
        guard entries.count <= 8 else { throw SystemSnapshotError("snapshot_storage_limit") }
        return try action(root)
        #else
        throw SystemSnapshotError("app_group_unavailable")
        #endif
    }
}
