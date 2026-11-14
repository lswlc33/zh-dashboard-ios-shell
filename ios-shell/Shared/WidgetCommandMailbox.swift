import Foundation

/// 主 App ↔ 扩展的命令邮箱：扩展只写文件，主 App 在前台/后台被唤起时消费。
/// 与 Android 的 ActionActivity + PendingIntent 语义等价：不伪造「已执行」，
/// 只投递一条待处理命令。
public enum ZeehoWidgetCommandMailbox {
    public static let directoryName = "WidgetCommands"
    public static let fileName = "pending-command.json"

    public struct Command: Codable, Sendable {
        public let action: String
        public let ownerScopeID: String
        public let createdAt: Int64
    }

    /// 扩展侧投递：只写一条，覆盖上一条未消费的命令（用户连点以最后一次为准）。
    @discardableResult
    public static func post(_ action: String, owner: SystemSnapshotOwner?) -> Bool {
        guard let owner = owner,
              let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.current()) else { return false }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = Command(action: action, ownerScopeID: owner.scopeID,
                                  createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            let data = try JSONEncoder().encode(payload)
            try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
            return true
        } catch { return false }
    }

    /// 主 App 侧消费：读一条并原子删除，返回动作名。
    public static func consume() -> String? {
        guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.current()) else { return nil }
        let url = root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Command.self, from: data) else { return nil }
        return value.action
    }
}
