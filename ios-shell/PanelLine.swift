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
    ///
    /// 但「持久化的值坏掉」不能静默回默认：解析失败后 `chosen` 仍为 true（键还在），
    /// 网页认为「用户已选过」既不提示也不弹选择页；而用户重新选 GitHub 时 `markChosen`
    /// 又会因 `current == line && chosen` 提前 return——脏值永远留在盘上，表现为「设置丢了」。
    /// 所以读取时顺手自愈：键存在但不是合法线路就重写成默认值，让 chosen 的语义重新可信。
    static var current: IOSPanelLine {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            if let parsed = IOSPanelLine(rawValue: raw) { return parsed }
            // 空串/缺失表示没选过，保持原样（chosen == false，网页会正常弹选择页）。
            if !raw.isEmpty {
                UserDefaults.standard.set(IOSPanelLine.github.rawValue, forKey: defaultsKey)
            }
            return .github
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

    /// 是否已经由用户显式选过线路。网页据此决定「首次启动才让选一次」：
    /// 没选过就弹一次选择页，选过之后每次手动检查直接用已保存的线路。
    static var chosen: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) != nil
    }

    /// 记下「用户已经选过」，即使选中的正是当前默认值。
    /// 只调用 `current` 的 setter 不够：它与当前值相同时直接 return，偏好键永远不会写，
    /// 网页就会一直认为「还没选过」，每次检查都再弹一次选择页。
    static func markChosen(_ line: IOSPanelLine) {
        if current == line && chosen { return }
        UserDefaults.standard.set(line.rawValue, forKey: defaultsKey)
        if PanelNavigation.base != baseURL(for: line) {
            PanelNavigation.base = baseURL(for: line)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
        lock.lock()
        changeRevision &+= 1
        lock.unlock()
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
            "actualSource": line.rawValue,
            // 网页据此只在首次使用时弹一次线路选择；之后手动检查直接用已保存的线路。
            "chosen": chosen
        ]
    }
}
