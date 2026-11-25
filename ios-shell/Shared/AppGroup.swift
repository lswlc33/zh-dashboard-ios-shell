import Foundation

/// App Group 标识符：默认模板值，重签者可覆盖。
///
/// 未签名 IPA 交用户自签时，第三方描述文件里的 App Group 往往不是我们模板里的这一个。
/// 代码写死组名会让主 App 与 Widget/Broadcast 扩展各自读不到共享容器（containerURL 返回 nil），
/// 表现为桌面小组件永远「暂无数据」。各签名工具的回写习惯不同，所以按可靠性逐层回退：
///   1. Info.plist 的 ZeehoAppGroupID（重签者显式指定，最可靠）
///   2. Info.plist 的 ALTAppGroups（AltStore/SideStore 重签时逐个 bundle 回写）
///   3. embedded.mobileprovision 里的 application-groups（全能签/eSign/zsign 等 P12 工具
///      会把证书团队的组签进二进制，但不写 Info.plist；CMS 里内嵌的 plist 可读）
///   4. 模板默认值（我们的 ad-hoc 发布链路）
/// 按此顺序选首个 containerURL 可访问的合法组；全部不可用时保留首个合法组供诊断。
/// Host/Widgets 使用本模块；Broadcast 的 Cast mailbox 独立实现同一解析契约。
/// appex 常被单-profile 工具漏放 embedded.mobileprovision，所以还要回退读宿主的。
public enum AppGroup {
    public static let defaultIdentifier = "group.io.github.lswlc33.dashboard.ios"

    public static func current(
        bundle: Bundle = .main,
        containerProbe: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> String {
        resolve(bundle: bundle, containerProbe: containerProbe).identifier
    }

    /// 诊断用：让设置页能看到当前解析到哪个组、来自哪一层，避免「app_group_unavailable」
    /// 一句原始码完全没法判断重签工具到底签了什么。
    public static func resolution(
        bundle: Bundle = .main,
        containerProbe: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> [String: Any] {
        let value = resolve(bundle: bundle, containerProbe: containerProbe)
        return ["identifier": value.identifier, "source": value.source,
                "defaultIdentifier": defaultIdentifier,
                "matched": value.identifier != defaultIdentifier]
    }

    private static func resolve(
        bundle: Bundle, containerProbe: (String) -> URL?
    ) -> (identifier: String, source: String) {
        var firstValid: (identifier: String, source: String)?
        var seen = Set<String>()
        func accessible(_ groups: [String], source: String) -> (identifier: String, source: String)? {
            for group in groups where isValid(group) && seen.insert(group).inserted {
                let value = (identifier: group, source: source)
                if firstValid == nil { firstValid = value }
                if containerProbe(group) != nil { return value }
            }
            return nil
        }

        // 重签后旧 override / ALT / profile 的组名可能仍合法却已失去 entitlement。
        // 保留候选顺序，逐个探测实际容器；全失败才把首个合法值留给诊断。
        let info = bundle.infoDictionary ?? [:]
        if let explicit = info["ZeehoAppGroupID"] as? String,
           let value = accessible([explicit], source: "info_override") { return value }
        if let groups = info["ALTAppGroups"] as? [String],
           let value = accessible(groups, source: "altstore_plist") { return value }
        if let single = info["ALTAppGroups"] as? String,
           let value = accessible([single], source: "altstore_plist") { return value }
        for url in profileCandidates(bundle: bundle) {
            if let groups = provisionedGroups(at: url),
               let value = accessible(groups, source: "mobileprovision") { return value }
        }
        if let value = accessible([defaultIdentifier], source: "template_default") { return value }
        return firstValid ?? (defaultIdentifier, "template_default")
    }

    /// 从 CMS 包裹的 embedded.mobileprovision 里抽内嵌 plist。
    /// Apple 说现代系统不再把这份 plist 当 source of truth，重签工具也可能漏放——
    /// 所以这里只是 best-effort 兼容线索，拿不到就继续回退，绝不因读文件失败抛错。
    /// Sentry/OneSignal/Kototoro 都用同样的 <?xml ... </plist> 抽取法。
    private static func provisionedGroups(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound),
                  options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
    }

    /// 先读自己 bundle；appex 缺 profile 或其中组均不可访问时继续读 containing app。
    /// 单-profile 的 zsign/Feather 只给主 .app 放 profile，扩展经常是空的。
    private static func profileCandidates(bundle: Bundle) -> [URL] {
        var urls: [URL] = []
        if let own = bundle.path(forResource: "embedded", ofType: "mobileprovision") {
            urls.append(URL(fileURLWithPath: own))
        }
        let host = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let hostProfile = host.appendingPathComponent("embedded.mobileprovision")
        if hostProfile.path != urls.first?.path, FileManager.default.fileExists(atPath: hostProfile.path) {
            urls.append(hostProfile)
        }
        return urls
    }

    /// 组名只允许 ASCII 反向域名形态，避免坏 plist 把 containerURL 引到无效值。
    private static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix("group."), value.utf8.count <= 256,
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return false }
        let name = String(value.dropFirst("group.".count))
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                (byte >= 0x30 && byte <= 0x39) || byte == 0x2D
            }
        }
    }
}
