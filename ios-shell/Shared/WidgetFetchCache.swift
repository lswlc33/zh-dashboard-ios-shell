import Foundation

// 小组件自己拉到的车况在 App Group 里的短期缓存。
//
// 为什么需要缓存而不是每次渲染都打接口：
// · WidgetKit 一个时间线会渲染多次（快照预览、刷新、系统重绘），每次都联网既慢又费流量；
// · 「刷新」按钮是 AppIntent，执行完必须靠 `reloadTimelines` 让系统重读，而 intent 无法
//   把数据直接塞进渲染 —— 只能落一份缓存，让下一次读取命中。
//
// 缓存只存 `SystemSnapshot`（Shared 白名单里的同一个结构），不含 token、VIN 以外的
// 任何凭据；VIN 本来就在快照的 owner 摘要之外单独存放，所以这里也不落原始 VIN。
public enum WidgetFetchCache {
    private static let directoryName = "WidgetFetch-v1"
    private static let fileName = "widget-fetch.json"
    /// 快照本身的存储上限是 8KB，这里留一倍余量。
    private static let maxBytes = 16 * 1024

    private static func directoryURL() throws -> URL {
        try SystemSnapshotStore.containerURL().appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func fileURL() throws -> URL {
        try directoryURL().appendingPathComponent(fileName, isDirectory: false)
    }

    /// 读缓存。owner 必须与请求方一致（换车/换账号后旧缓存立刻失效），
    /// 且 `capturedAt` 不能超过 maxAgeSeconds —— 过期就当作没有，由调用方重新拉或退快照。
    public static func read(ownerID: String, at date: Date = Date(), maxAgeSeconds: Double) -> SystemSnapshot? {
        guard maxAgeSeconds > 0, let data = boundedRead(try? fileURL(), limit: maxBytes),
              let snapshot = try? JSONDecoder().decode(SystemSnapshot.self, from: data),
              snapshot.owner.ownerIdentifierString == ownerID,
              snapshot.vehicle != nil else { return nil }
        let age = date.timeIntervalSince1970 - Double(snapshot.capturedAt) / 1000
        guard age >= -SystemSnapshotFreshness.futureToleranceSeconds, age < maxAgeSeconds else { return nil }
        return snapshot
    }

    /// 写入缓存。任何失败都静默忽略：缓存是加速手段，丢了最多多打一次接口。
    public static func write(_ snapshot: SystemSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot), data.count <= maxBytes else { return }
        guard let directory = try? directoryURL() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        #endif
        guard let url = try? fileURL() else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
        var protected = url
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? protected.setResourceValues(resource)
    }

    public static func clear() {
        guard let directory = try? directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func boundedRead(_ url: URL?, limit: Int) -> Data? {
        guard let url = url,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data?
        do { data = try handle.read(upToCount: limit + 1) } catch { return nil }
        guard let read = data, !read.isEmpty, read.count <= limit else { return nil }
        return read
    }
}
