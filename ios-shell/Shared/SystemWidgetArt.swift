import Foundation

// 桌面小组件的车模素材（App Group 里的 PNG，主 App 写、扩展读）。
//
// 与 Android WidgetCar 同一口径：URL 来自官方接口的公开 OSS 车图，主 App 在后台
// 下载并缩到 420×280 存盘，URL 没变就不重下，失败保留旧图。
// 文件按**匿名 owner id** 分文件（accountVINHash.scopeID），绝不用原始 VIN/账号，
// 换车/换账号自然不会串图——这是既有隐私口径，别为了少一个文件名改动它。
//
// 本文件属于 Shared 模块，host 与 widget 扩展同时链接：只能用 Foundation，
// 不能 import UIKit（扩展侧的 UIImage 解码在 Widgets/WidgetArt.swift 里做）。
// 素材是尽力而为的附加产物：任何失败都静默返回，绝不影响快照主链路。
public enum SystemWidgetArt {
    /// 单张素材的字节上限，与 Android WidgetCar.MAX_BYTES 对齐。
    public static let maxBytes = 4 * 1024 * 1024
    /// 解码/缩放上限，与 Android WidgetCar.MAX_W/H 对齐。
    ///
    /// 放在 Shared 而不是各自写一份：主 App 下载后按它缩图、扩展按它兜底再缩，
    /// 两边用不同的数会让「宿主以为已缩好、扩展又缩一次」多花一次渲染。
    public static let maxPixelWidth = 420
    public static let maxPixelHeight = 280
    /// 旁路索引（记录「这张图对应哪个 URL」）的字节上限。
    private static let maxIndexBytes = 2048
    /// 文件名里的 id 长度上限 = accountVINHash(64) + '.'(1) + scopeID(≤96)。
    ///
    /// 不能写 160：SystemSnapshotOwner.isValid 允许 scopeID 到 96 字节，加起来是 161，
    /// 卡在 160 会把合法 owner 挡在门外（表现是「车模永远不出现」且日志里什么都没有）。
    private static let maxOwnerBytes = 64 + 1 + 96
    private static let filePrefix = "widget-vehicle-art-"
    private static let fileSuffix = ".png"
    private static let indexName = "widget-vehicle-art-index.json"

    /// 素材文件路径（App Group 根目录，不是 snapshots 子目录：那里会被 store 的
    /// orphan 清理当成未知条目，且不随 owner 白名单扫除）。
    public static func fileURL(ownerID: String) throws -> URL {
        let safe = try safeOwnerID(ownerID)
        return try SystemSnapshotStore.containerURL()
            .appendingPathComponent(filePrefix + safe + fileSuffix, isDirectory: false)
    }

    /// 有界读：超过 limit 直接 nil，不把大文件读进内存（扩展内存预算很小）。
    /// 读失败一律 nil，由调用方保持占位。
    public static func read(ownerID: String, limit: Int) -> Data? {
        guard limit > 0, limit <= maxBytes, let url = try? fileURL(ownerID: ownerID) else { return nil }
        return boundedRead(url, limit: limit)
    }

    /// 有界写：原子替换 + 排除 iCloud 备份。写完顺手更新旁路索引，供下次判「URL 没变」。
    ///
    /// 索引写失败不影响图片本身（下次只是会多下载一次），所以两步都只忽略失败。
    public static func write(_ data: Data, ownerID: String, sourceURL: String) {
        guard !data.isEmpty, data.count <= maxBytes, !sourceURL.isEmpty,
              sourceURL.utf8.count <= maxIndexBytes,
              let safe = try? safeOwnerID(ownerID),
              let url = try? fileURL(ownerID: safe) else { return }
        guard (try? protectedWrite(data, to: url)) != nil else { return }
        // 索引只记匿名 id 与 URL；URL 来自官方接口，不含账号/VIN（网页侧取的是车图地址）。
        let payload: [String: String] = ["owner": safe, "url": sourceURL]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              encoded.count <= maxIndexBytes,
              let indexURL = try? indexFileURL(),
              (try? protectedWrite(encoded, to: indexURL)) != nil else { return }
    }

    /// 索引里 owner 与 URL 都一致、且图片文件存在且非空（且没超上限）→ 不需要重下。
    public static func needsDownload(ownerID: String, sourceURL: String) -> Bool {
        guard !sourceURL.isEmpty, let safe = try? safeOwnerID(ownerID),
              let url = try? fileURL(ownerID: safe) else { return true }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maxBytes else { return true }
        guard let indexURL = try? indexFileURL(), let data = boundedRead(indexURL, limit: maxIndexBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["owner"] as? String == safe, object["url"] as? String == sourceURL else { return true }
        return false
    }

    // MARK: - 内部

    private static func indexFileURL() throws -> URL {
        try SystemSnapshotStore.containerURL()
            .appendingPathComponent(indexName, isDirectory: false)
    }

    /// 只接受 `accountVINHash.scopeID` 形态的匿名 id（与 SystemSnapshotStore.ownerIdentifier 同一拼法）。
    ///
    /// 比「只放行 [0-9a-fA-F.]」更严格也更正确：那个集合会把**所有**真实 owner 拒之门外——
    /// scopeID 是 lowercased UUID，本身就带 `-`；只放行 hex+点等于素材永远写不进来。
    /// 这里要求恰好两段：64 位 hex 摘要 + 非空 scopeID，两段合计不超过 maxOwnerBytes。
    /// 点只作为唯一分隔符出现，路径分隔符/空白/`..`/NUL 因此在结构上就不可能拼进来。
    private static func safeOwnerID(_ ownerID: String) throws -> String {
        let bytes = ownerID.utf8.count
        let parts = ownerID.split(separator: ".", omittingEmptySubsequences: false)
        func isHex(_ text: Substring) -> Bool {
            text.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value) || (65...70).contains($0.value)
            }
        }
        // scopeID 的字符集与 SystemSnapshotOwner.isValid 对齐（字母数字 + `-` + `_`）；
        // 不含点，所以「两段」这个结构本身就把额外的点挡在外面。
        func isScope(_ text: Substring) -> Bool {
            text.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
                    || $0.value == 45 /* - */ || $0.value == 95 /* _ */
            }
        }
        guard bytes > 0, bytes <= maxOwnerBytes, parts.count == 2,
              parts[0].utf8.count == 64, isHex(parts[0]),
              !parts[1].isEmpty, parts[1].utf8.count <= 96, isScope(parts[1]) else {
            throw SystemSnapshotError("widget_art_owner_invalid")
        }
        return ownerID
    }

    /// 有界读（图片与索引共用；读不到就是 nil，不当错误）。
    ///
    /// 先看 fileSize 再读：`read(upToCount:)` 也会分配缓冲，大文件必须先被尺寸拦住。
    /// 用显式 do/catch 而不是 `try?` —— `read(upToCount:)` 本身返回可选，
    /// 再套一层会得到双层可选，Swift 版本间的扁平化行为容易写错。
    private static func boundedRead(_ url: URL, limit: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data?
        do { data = try handle.read(upToCount: limit + 1) } catch { return nil }
        guard let read = data, !read.isEmpty, read.count <= limit else { return nil }
        return read
    }

    /// 与 SystemSnapshotStore.protectedWrite 等价的一份实现。
    ///
    /// 那边是 private，Shared 里另抄一份比把它改成 public 更安全：快照存储的写入契约
    /// 不该因为「小组件要存一张车图」而扩大对外接口。
    private static func protectedWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        // 锁屏后扩展仍要能读到上一次已落盘的素材；首次解锁前不提供，与快照同一保护等级。
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var protected = url
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try protected.setResourceValues(resource)
    }
}
