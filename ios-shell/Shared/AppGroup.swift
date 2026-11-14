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
/// 三个 target（Host/Widgets/Broadcast）都链接本模块，必须解析出同一个组名。
/// appex 常被单-profile 工具漏放 embedded.mobileprovision，所以还要回退读宿主的。
public enum AppGroup {
    public static let defaultIdentifier = "group.io.github.lswlc33.dashboard.ios"

    public static func current(bundle: Bundle = .main) -> String {
        resolve(bundle: bundle).identifier
    }

    /// 诊断用：让设置页能看到当前解析到哪个组、来自哪一层，避免「app_group_unavailable」
    /// 一句原始码完全没法判断重签工具到底签了什么。
    public static func resolution(bundle: Bundle = .main) -> [String: Any] {
        let value = resolve(bundle: bundle)
        return ["identifier": value.identifier, "source": value.source,
                "defaultIdentifier": defaultIdentifier,
                "matched": value.identifier != defaultIdentifier]
    }

    private static func resolve(bundle: Bundle) -> (identifier: String, source: String) {
        let info = bundle.infoDictionary ?? [:]
        if let explicit = info["ZeehoAppGroupID"] as? String, isValid(explicit) {
            return (explicit, "info_override")
        }
        if let groups = info["ALTAppGroups"] as? [String],
           let first = groups.first(where: { isValid($0) }) {
            return (first, "altstore_plist")
        }
        if let single = info["ALTAppGroups"] as? String, isValid(single) {
            return (single, "altstore_plist")
        }
        // P12 重签工具（全能签/eSign/zsign 等）不会回写 Info.plist，但会把证书团队的组
        // 签进 entitlements，并通常把 embedded.mobileprovision 留在主 App bundle 里。
        if let groups = provisionedGroups(bundle: bundle),
           let first = groups.first(where: { isValid($0) }) {
            return (first, "mobileprovision")
        }
        return (defaultIdentifier, "template_default")
    }

    /// 从 CMS 包裹的 embedded.mobileprovision 里抽内嵌 plist。
    /// Apple 说现代系统不再把这份 plist 当 source of truth，重签工具也可能漏放——
    /// 所以这里只是 best-effort 兼容线索，拿不到就继续回退，绝不因读文件失败抛错。
    /// Sentry/OneSignal/Kototoro 都用同样的 <?xml ... </plist> 抽取法。
    private static func provisionedGroups(bundle: Bundle) -> [String]? {
        for url in profileCandidates(bundle: bundle) {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data.subdata(in: start.lowerBound..<end.upperBound),
                      options: [], format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String],
                  !groups.isEmpty else { continue }
            return groups
        }
        return nil
    }

    /// 先读自己 bundle；appex 里没有时回退到 containing app 的 bundle。
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
