import Foundation

// 面板线路只决定后续检查与下载，切换不替换当前文档或迁移账号。
enum IOSPanelLine: String {
    case github
    case cf

    static let version = 1

    private static let defaultsKey = "io.github.lswlc33.dashboard.ios.panel-line"
    private static let lock = NSLock()
    private static var changeRevision: UInt64 = 0
    static let didChangeNotification = Notification.Name("io.github.lswlc33.dashboard.ios.panel-line.changed")
    static var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return changeRevision
    }

    /// 当前选中的线路。默认 GitHub Pages。
    /// 注意：用户一旦在更新面板里选过，就会持久化在 UserDefaults 里——
    /// 换版本后不会自动回到 GitHub，这是有意的（尊重用户选择）。
    static var current: IOSPanelLine {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return IOSPanelLine(rawValue: raw) ?? .github
        }
        set {
            guard newValue != current else { return }
            lock.lock()
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            changeRevision &+= 1
            lock.unlock()
            PanelNavigation.base = baseURL(for: newValue)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// 启动时把持久化的线路应用到导航基址。
    static func applyPersisted() {
        PanelNavigation.base = baseURL(for: current)
    }

    /// 面板主文档所在基址（以 `/` 结尾）。iOS 只从这两个 HTTPS 源加载。
    static func baseURL(for line: IOSPanelLine = current) -> URL {
        switch line {
        case .github:
            return URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!
        case .cf:
            return URL(string: "https://zhb.xn--fiqz59cpva341l.top/")!
        }
    }

    static func baseURL() -> URL { baseURL(for: current) }

    var displayName: String {
        switch self {
        case .github: return "GitHub 线路"
        case .cf: return "Cloudflare 线路"
        }
    }

    /// 桥回执里的 info 结构，字段名与安卓 PanelLineInfo 对齐。
    static func infoJSON() -> [String: Any] {
        let line = current
        return [
            "version": version,
            "line": line.rawValue,
            "logicalOrigin": baseURL(for: line).absoluteString,
            "busy": false,
            "actualSource": line.rawValue
        ]
    }
}
