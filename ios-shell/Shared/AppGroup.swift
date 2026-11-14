import Foundation

/// App Group 标识符：默认模板值，重签者可覆盖。
///
/// 未签名 IPA 交用户自签时，第三方描述文件里的 App Group 往往不是我们模板里的这一个。
/// 代码写死组名会让主 App 与 Widget/Broadcast 扩展各自读不到共享容器（containerURL 返回 nil），
/// 表现为桌面小组件永远「暂无数据」。NetNewsWire 用 Info.plist 参数化、AltStore/SideStore
/// 在重签时把 profile 的 app groups 回写进 Info.plist 的 ALTAppGroups，这里两者都兼容：
/// 优先读显式 ZeehoAppGroupID，其次读签名工具回写的 ALTAppGroups，最后回退模板默认值。
/// 三个 target（Host/Widgets/Broadcast）都链接本模块，必须解析出同一个组名。
public enum AppGroup {
    public static let defaultIdentifier = "group.io.github.lswlc33.dashboard.ios"

    public static func current(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        if let explicit = info["ZeehoAppGroupID"] as? String, isValid(explicit) {
            return explicit
        }
        // AltStore/SideStore 重签时把描述文件里的 app groups 写进 host Info.plist。
        // 扩展的 Info.plist 没有这份回写，但三个进程共用同一个解析入口会各自读取；
        // 若签名工具只回写了 host，重签者应在扩展 Info.plist 里也补 ZeehoAppGroupID。
        if let groups = info["ALTAppGroups"] as? [String],
           let first = groups.first(where: { isValid($0) }) {
            return first
        }
        if let single = info["ALTAppGroups"] as? String, isValid(single) {
            return single
        }
        return defaultIdentifier
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
