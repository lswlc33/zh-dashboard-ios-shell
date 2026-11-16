import Foundation
import os

// 扩展自己的执行回执；不含 token、VIN、地址或车况数值，也不把视图构建当作桌面显示成功。
public enum WidgetDiagnostics {
    public enum Phase: String, CaseIterable, Codable, Sendable {
        case launch
        case snapshotStarted
        case snapshot
        case localReadStarted
        case localReadFinished
        case fetchStarted
        case fetchFinished
        case fallback
        case timelineStarted
        case timelineReady
        case viewBuilt
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
        public let requestID: String?
        public let family: String?
        public let elapsedMs: Int64?
        public let processID: Int32?
        public let hasVehicle: Bool?
    }

    private static let directoryName = "WidgetDiagnostics-v1"
    private static let maxBytes = 2048
    private static let maxHistoryBytes = 64 * 1024
    private static let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.widget-diagnostics", qos: .utility)
    private static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    public static func record(_ phase: Phase, snapshot: SystemSnapshot? = nil,
                              origin: String = "", reason: String = "", requestID: String = "",
                              family: String = "", elapsedMs: Int64? = nil) {
        let recordedAt = Int64(Date().timeIntervalSince1970 * 1000)
        // 容器解析和写盘不能先于 Widget 注册、预览或时间线 completion。
        queue.async {
            let receipt = Receipt(phase: phase, recordedAt: recordedAt,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                appGroupIdentifier: AppGroup.current(), ownerID: snapshot?.owner.ownerIdentifierString,
                capturedAt: snapshot?.capturedAt, origin: String(origin.prefix(32)), reason: String(reason.prefix(96)),
                requestID: String(requestID.prefix(64)), family: String(family.prefix(32)),
                elapsedMs: elapsedMs, processID: ProcessInfo.processInfo.processIdentifier,
                hasVehicle: snapshot?.vehicle != nil)
            os_log("widget: phase=%{public}@ build=%{public}@ trace=%{public}@ family=%{public}@ origin=%{public}@ reason=%{public}@",
                   log: .default, type: .default, phase.rawValue, receipt.build,
                   receipt.requestID ?? "", receipt.family ?? "", receipt.origin, receipt.reason)
            guard let data = try? JSONEncoder().encode(receipt), data.count <= maxBytes,
                  let root = try? directory(create: true) else { return }
            write(data, to: root.appendingPathComponent(phase.rawValue + ".json"))
            // 有界事件历史保留同一次请求的先后顺序，不能只用各阶段最后一条拼接出假链路。
            var events = history(at: root).filter { $0.recordedAt >= recordedAt - Int64(maxAgeSeconds * 1000) }
            events.append(receipt)
            events = Array(events.suffix(32))
            if let historyData = try? JSONEncoder().encode(events), historyData.count <= maxHistoryBytes {
                write(historyData, to: root.appendingPathComponent("history.json"))
            }
        }
    }

    public static func read(_ phase: Phase, at date: Date = Date()) -> Receipt? {
        guard let root = try? directory(create: false),
              let data = boundedRead(root.appendingPathComponent(phase.rawValue + ".json"), limit: maxBytes),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.phase == phase,
              valid(receipt, at: date) else { return nil }
        return receipt
    }

    public static func recent(at date: Date = Date()) -> [Receipt] {
        guard let root = try? directory(create: false) else { return [] }
        return history(at: root).filter { valid($0, at: date) }
    }

    private static func valid(_ receipt: Receipt, at date: Date) -> Bool {
        let now = date.timeIntervalSince1970 * 1000
        return receipt.recordedAt > 0 && Double(receipt.recordedAt) <= now + 30_000
            && now - Double(receipt.recordedAt) <= maxAgeSeconds * 1000
            && receipt.appGroupIdentifier == AppGroup.current()
            && receipt.build.utf8.count <= 32 && receipt.bundleIdentifier.utf8.count <= 256
            && receipt.origin.utf8.count <= 128 && receipt.reason.utf8.count <= 384
            && (receipt.requestID?.utf8.count ?? 0) <= 64 && (receipt.family?.utf8.count ?? 0) <= 32
    }

    private static func history(at root: URL) -> [Receipt] {
        guard let data = boundedRead(root.appendingPathComponent("history.json"), limit: maxHistoryBytes),
              let receipts = try? JSONDecoder().decode([Receipt].self, from: data), receipts.count <= 32 else { return [] }
        return receipts
    }

    private static func boundedRead(_ url: URL, limit: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private static func write(_ data: Data, to url: URL) {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
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
