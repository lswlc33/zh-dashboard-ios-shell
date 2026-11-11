import Foundation

// 面板线路：同一份网页产物可以从两个入口拿。
// 对应安卓 PanelLine.java 的语义，但 iOS 侧线路切换是「换基址 + 重新初始化快照」，
// 不像安卓那样在原生层做下载代理，所以这里只保存线路选择与基址。
enum IOSPanelLine: String {
    case github
    case cf

    static let version = 1

    private static let defaultsKey = "io.github.lswlc33.dashboard.ios.panel-line"

    /// 当前选中的线路。默认 GitHub Pages（与历史行为一致）。
    static var current: IOSPanelLine {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return IOSPanelLine(rawValue: raw) ?? .github
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 面板主文档所在基址（以 `/` 结尾）。iOS 只从这两个 HTTPS 源加载。
    static func baseURL(for line: IOSPanelLine = current) -> URL {
        switch line {
        case .github:
            return URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!
        case .cf:
            // Cloudflare 线路是同一个静态根的反代；未配置时回落到 GitHub，避免整页打不开。
            return URL(string: "https://zhb.xn--fiqz59cpva341l.top/") ?? URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!
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
