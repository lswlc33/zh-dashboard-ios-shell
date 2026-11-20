import Foundation
import Darwin

/// Main App <-> widget command mailbox.
///
/// The mailbox is a one-shot, owner-bound handoff. A command without its original
/// owner scope or a fresh timestamp must never be rebound to the currently selected
/// vehicle by the host app.
public enum ZeehoWidgetCommandMailbox {
    public static let directoryName = "WidgetCommands"
    public static let fileName = "pending-command.json"
    public static let maxAgeMs: Int64 = 60_000

    public struct Command: Codable, Sendable {
        public let id: String
        public let action: String
        public let ownerID: String
        public let createdAt: Int64
    }

    private static func lockURL(_ root: URL) -> URL { root.appendingPathComponent(".command.lock") }

    private static func withLock<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        let path = lockURL(root).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var locked = false
        for attempt in 0..<21 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if attempt < 20 { usleep(5_000) }
        }
        guard locked else { throw CocoaError(.fileLocking) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static let actions: Set<String> = ["unlock", "lock", "horn", "seat"]

    @discardableResult
    public static func post(_ action: String, ownerID: String) -> Bool {
        guard actions.contains(action), SystemSnapshotStore.ownerIdentifier(ownerID) != nil,
              let active = try? SystemSnapshotStore.currentOwner(), active.ownerIdentifierString == ownerID,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.current()) else { return false }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try withLock(root) {
                let payload = Command(id: UUID().uuidString, action: action, ownerID: ownerID,
                                      createdAt: Int64(Date().timeIntervalSince1970 * 1000))
                let data = try JSONEncoder().encode(payload)
                try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
            }
            NotificationCenter.default.post(name: Notification.Name("io.github.lswlc33.dashboard.vehicle-command-posted"), object: nil)
            return true
        } catch { return false }
    }

    /// 旧小组件命令永不重绑定到当前选中的 owner。
    public static func consume(ownerID: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Command? {
        guard SystemSnapshotStore.ownerIdentifier(ownerID) != nil,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.current()) else { return nil }
        let url = root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
        return (try? withLock(root) { () -> Command? in
            guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let size = metadata.fileSize, size > 0, size <= 1024,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 1025), data.count <= 1024,
                  let value = try? JSONDecoder().decode(Command.self, from: data) else {
                try? FileManager.default.removeItem(at: url); return nil
            }
            guard UUID(uuidString: value.id) != nil, actions.contains(value.action), value.ownerID == ownerID,
                  value.createdAt > 0, now >= value.createdAt, now - value.createdAt <= maxAgeMs else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            // If the one-shot file cannot be removed, do not return an executable action.
            // Replaying a lock/seat command is worse than dropping this click.
            guard (try? FileManager.default.removeItem(at: url)) != nil else { return nil }
            return value
        }) ?? nil
    }
}
