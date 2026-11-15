import Foundation

// 桌面小组件自己拉接口所需的凭据（App Group 里的最小只读副本）。
//
// ## 为什么需要它
//
// 官方 `ZHWidgetExtension.appex` 自带 `ZHEEHTTPSessionManager` + `ZHNetTool` +
// `ZHEncryptInfoModel`，在扩展进程里**自己发请求、自己算加密**，不依赖宿主 App
// 存活，也没有 180 秒 TTL / 残留 vehicleID / 快照写盘时序这些问题。
//
// 我们原来的链路是「宿主写快照 → 扩展读快照」，天然被这三件事拖住。这里搬官方的
// 做法：主 App 在前台把一份**最小凭据**镜像进 App Group，扩展拿它自己拉数据，
// 快照继续保留做兜底（弱网/未授权/接口全挂时仍显示最后一次同步）。
//
// ## 与 Keychain 那份的关系
//
// `IOSBackgroundCredential`（BackgroundSigning.swift）是**长期**后台任务凭据，
// 存在 Keychain、带二次确认、可随时清除。本文件这份是它的**投影**：
//   · 只存小组件展示要用的字段（token / appSecret / appID / vin / 匿名 owner）；
//   · 生命周期跟随前台会话，账号切换或撤销授权时立刻清掉；
//   · 只有 App Group 成员（宿主 + 扩展）读得到，不进系统钥匙串同步。
//
// 两份都必须存在：Keychain 那份不能给扩展（扩展没有 Keychain 访问组授权，
// 且自签环境下 access group 不可靠）；App Group 这份不能用于后台任务（
// 它随前台会话更新，后台唤醒时可能已经过期）。
//
// ## 安全口径
//
// · 只接受 https 官方域；token 与密钥与其他凭据同一套长度/控制字符校验；
// · 文件名固定、放在独立子目录 `WidgetCredentials-v1`，避免被快照 store 的
//   orphan 清理扫到（那套清理只认自己的命名空间，混进去会被当未知条目）；
// · 写入用 `.completeFileProtectionUntilFirstUserAuthentication`——锁屏后扩展
//   仍能读到（否则锁屏小组件永远空白），但首次解锁前不给。
public struct WidgetCredential: Codable, Equatable, Sendable {
    /// 匿名 owner id（accountVINHash.scopeID），与快照/车模素材同一拼法。
    /// 空串表示「没绑定具体车辆」，此时扩展不自己拉，只用快照兜底。
    public var ownerID: String
    /// 原始 VIN：接口路径要它。只存在 App Group 内部，绝不进快照/日志。
    public var vin: String
    /// app 域 token（tapi.zeehoev.com）。
    public var token: String
    /// app 域 appId / 签名密钥。
    public var appID: String
    public var appSecret: String
    /// 写入时刻（毫秒）。扩展据此判断这份凭据是否还有效，过期就只用快照。
    public var updatedAt: Int64

    public init(ownerID: String, vin: String, token: String, appID: String,
                appSecret: String, updatedAt: Int64) {
        self.ownerID = ownerID
        self.vin = vin
        self.token = token
        self.appID = appID
        self.appSecret = appSecret
        self.updatedAt = updatedAt
    }

    /// 与 `IOSBackgroundCredential.isValid` 同一套判据：非空、长度受限、无控制字符。
    public var isValid: Bool {
        [ownerID, vin, token, appID, appSecret].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 4096
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
            && SystemSnapshotStore.ownerIdentifier(ownerID) != nil
            && updatedAt > 0
    }

    /// 是否还在可用期内。默认 24 小时：token 失效由接口 401 立即反映，
    /// 这个窗口只是防止一份很久以前的前台凭据在扩展里无限期被拿来打接口。
    public func isUsable(at date: Date = Date(), maxAgeSeconds: Double = 24 * 3600) -> Bool {
        guard isValid else { return false }
        let age = date.timeIntervalSince1970 - Double(updatedAt) / 1000
        return age >= -SystemSnapshotFreshness.futureToleranceSeconds && age < maxAgeSeconds
    }
}

/// App Group 里的凭据存储。**只给小组件展示取数用**，不承担后台任务。
public enum WidgetCredentialStore {
    /// 独立子目录：不与 `ZeehoSystemSnapshots-v1` 混放，避免快照清理误删。
    private static let directoryName = "WidgetCredentials-v1"
    private static let fileName = "widget-credential.json"
    /// 凭据 JSON 的字节上限（字段都是短串，4KB 足够）。
    private static let maxBytes = 4096

    private static func directoryURL() throws -> URL {
        let root = try SystemSnapshotStore.containerURL()
            .appendingPathComponent(directoryName, isDirectory: true)
        return root
    }

    private static func fileURL() throws -> URL {
        try directoryURL().appendingPathComponent(fileName, isDirectory: false)
    }

    /// 读一份可用凭据。任何失败（无组、缺文件、坏 JSON、过期）都返回 nil：
    /// 调用方据此退回快照，绝不因为凭据问题挡住小组件渲染。
    public static func read(at date: Date = Date()) -> WidgetCredential? {
        guard let data = boundedRead(try? fileURL(), limit: maxBytes),
              let value = try? JSONDecoder().decode(WidgetCredential.self, from: data),
              value.isUsable(at: date) else { return nil }
        return value
    }

    /// 主 App 在前台授权/刷新时写入。返回是否真的落盘。
    @discardableResult
    public static func save(_ value: WidgetCredential) -> Bool {
        guard value.isValid, let encoded = try? JSONEncoder().encode(value),
              encoded.count <= maxBytes else { return false }
        do {
            let directory = try directoryURL()
            // 目录与文件都显式建：扩展可能在主 App 第一次写之前就来读。
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
            #endif
            var url = try fileURL()
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try url.setResourceValues(resource)
            return true
        } catch {
            return false
        }
    }

    /// 账号切换 / 撤销授权 / 清除后台凭据时调用。删不掉也不报错（下次读取会因
    /// 文件损坏或旧 owner 不匹配而如实退化成快照模式）。
    public static func clear() {
        guard let directory = try? directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// 有界读：先看尺寸再读，绝不把异常大文件读进扩展内存。
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
