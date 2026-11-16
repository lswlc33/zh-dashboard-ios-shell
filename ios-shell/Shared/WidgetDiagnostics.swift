import Foundation
import os

// 扩展自己的执行回执：宿主写入成功不能证明 Widget 的入口、读盘或时间线已经执行。
// 只记阶段、匿名归属和样本时间；回执不含 token、VIN、车况数值，也不声称桌面已渲染。
public enum WidgetDiagnostics {
    public enum Phase: String, CaseIterable, Codable, Sendable {
        case launch
        case snapshot
        case timelineStarted
        case timelineReady
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public let phase: Phase
        public let recordedAt: Int64
        public let build: String
        public let bundleIdentifier: String
        public let appGroupIdentifier: String
        public let ownerID: String?
        public let capturedAt: Int64?
        public let origin: String
        public let reason: String
    }

    private static let directoryName = "WidgetDiagnostics-v1"
    private static let maxBytes = 2048

    public static func record(_ phase: Phase, snapshot: SystemSnapshot? = nil,
                              origin: String = "", reason: String = "") {
        let receipt = Receipt(phase: phase, recordedAt: Int64(Date().timeIntervalSince1970 * 1000),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appGroupIdentifier: AppGroup.current(), ownerID: snapshot?.owner.ownerIdentifierString,
            capturedAt: snapshot?.capturedAt, origin: String(origin.prefix(32)), reason: String(reason.prefix(96)))
        os_log("widget: phase=%{public}@ build=%{public}@ snapshot=%{public}@ origin=%{public}@ reason=%{public}@",
               log: .default, type: .default, phase.rawValue, receipt.build,
               snapshot == nil ? "false" : "true", receipt.origin, receipt.reason)
        guard let data = try? JSONEncoder().encode(receipt), data.count <= maxBytes,
              let root = try? directory(create: true) else { return }
        let url = root.appendingPathComponent(phase.rawValue + ".json")
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    public static func read(_ phase: Phase, at date: Date = Date()) -> Receipt? {
        guard let root = try? directory(create: false) else { return nil }
        let url = root.appendingPathComponent(phase.rawValue + ".json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.phase == phase,
              receipt.recordedAt > 0,
              Double(receipt.recordedAt) <= date.timeIntervalSince1970 * 1000 + 30_000,
              receipt.appGroupIdentifier == AppGroup.current(),
              receipt.build.utf8.count <= 32, receipt.bundleIdentifier.utf8.count <= 256,
              receipt.origin.utf8.count <= 128, receipt.reason.utf8.count <= 384 else { return nil }
        return receipt
    }

    private static func directory(create: Bool) throws -> URL {
        let root = try SystemSnapshotStore.containerURL().appendingPathComponent(directoryName, isDirectory: true)
        let manager = FileManager.default
        if create, !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SystemSnapshotError("widget_diagnostics_unavailable")
        }
        #if os(iOS)
        if create {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: root.path)
        }
        #endif
        return root
    }
}
