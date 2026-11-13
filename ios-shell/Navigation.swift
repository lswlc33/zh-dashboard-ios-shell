import Foundation

// 纯 URL 判定：只依赖 Foundation，能被 navigation-test.swift 单独编译验证。
// 本地快照相关的常量与解析交给 PanelSchemeHandler，这里只用字符串常量，
// 避免把整个 WKWebView/PanelCache 依赖链拖进这个小测试。
enum PanelNavigation {
    /// 本地快照的自定义 scheme 与 host。与 PanelSchemeHandler 保持一致，
    /// 但这里是字面量，不 import 那个文件（否则单独编译 Navigation.swift 会失败）。
    static let localScheme = "zeeho-panel"
    static let localHost = "panel"

    /// 面板主文档地址。默认 GitHub Pages；线路切换后由 PanelLine 覆写 `base`。
    /// 这里用字面量而不是 `IOSPanelLine.baseURL()`，是为了让本文件能被
    /// navigation-test.swift 单独编译（那个测试不链接 PanelLine/PanelCache）。
    private static let defaultBase = URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!

    /// 主线程写（线路切换、applyPersisted），worker 队列读（Bridge.prepareNavigation →
    /// withNavigationID → isPanel → originKey(home)）。裸 `static var` 对跨线程读写不提供
    /// 原子性，切换线路那一瞬可能读到新旧混合的 base，导致一次导航被判成非面板而失败。
    /// 用锁把单次读写变成原子操作。
    ///
    /// 注意：`isPanel` 内部仍会多次取 base（homeOriginKey + allowedPaths 里的 home），
    /// 跨两次取值的混合理论上仍在。完整的根治要在 isPanel 开头取一次快照再传下去，
    /// 但那会改判定签名与 navigation-test 的覆盖范围；这里先解决「单次读取撕裂」，
    /// 剩下的窗口只有「切换线路的同一毫秒内正好有一次导航判定」，实践里不可见。
    private static let baseLock = NSLock()
    private static var baseStorage: URL = defaultBase
    static var base: URL {
        get {
            baseLock.lock(); defer { baseLock.unlock() }
            return baseStorage
        }
        set {
            baseLock.lock(); baseStorage = newValue; baseLock.unlock()
        }
    }
    static var home: URL { base }

    /// 主文档允许的路径集合（相对基址）。
    private static func allowedPaths() -> [String] {
        let root = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return [String(root.dropLast()), root, root + "index.html"]
    }

    /// 规范化 origin 用于比较。
    ///
    /// 不能直接比 `URLComponents.host` 字符串：Cloudflare 线路用的是国际化域名
    /// `zhb.xn--fiqz59cpva341l.top`，Foundation 在不同入口可能给出 punycode
    /// 或 Unicode 两种形式，字符串不等就会把自家首页判成「非面板」——
    /// 真机上表现为点「进入面板」后 navigation_not_allowed 直接白屏。
    ///
    /// 做法：优先取 `percentEncodedHost`（URL 里原样的 ASCII 形态，punycode 就是
    /// punycode）；只有拿不到时才退回 `host`。**不要指望再 `URL(string:)` 一次能
    /// 把 Unicode 转成 punycode**——Foundation 的 URL 解析不做 IDNA/A-label 转换，
    /// 那一步只能让「percent 编码形态 ↔ 解码形态」收敛。
    ///
    /// 解析失败返回不可匹配的哨兵（而不是 ""）：否则 home 与 url 同时失败时会
    /// 因为 "" == "" 判成同一 origin，等于 fail-open。
    private static func originKey(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "invalid://\(url.absoluteString)"
        }
        let scheme = (parts.scheme ?? "").lowercased()
        let host = (parts.percentEncodedHost ?? parts.host ?? "").lowercased()
        let port = (parts.port == nil || parts.port == 443) ? "" : ":\(parts.port!)"
        return "\(scheme)://\(host)\(port)"
    }

    /// 主文档 origin（基准）。
    private static var homeOriginKey: String { originKey(home) }

    static func isPanel(_ url: URL) -> Bool {
        // 本地快照：zeeho-panel://panel/index.html 只有主文档可拥有原生桥。
        // 端口也要像 https 分支一样只允许默认端口：否则网页把指向 :8443 的地址
        // 交给导航，会拿到同内容但不同 origin 的文档（localStorage 分桶）。
        // 不是越权，但会让「刷新后面板配置全丢」这类问题无法归因。
        if url.scheme?.lowercased() == localScheme {
            guard url.host?.lowercased() == localHost,
                  url.user == nil, url.password == nil else { return false }
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.port == nil else { return false }
            // 本地快照根固定是 /index.html：快照目录里 index.html 就在根下，
            // 子资源也全部相对根解析。不能再接受任意子路径——线上的
            // /zeeho-3d-models/ 基址被搬到自定义 scheme 后会指到不存在的目录。
            let path = parts.percentEncodedPath
            return ["/", "/index.html"].contains(path.isEmpty ? "/index.html" : path)
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // Pages 同域还托管产物等页面；只有面板主文档可拥有原生桥。
        guard parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return false }
        // origin 比较走规范化后的 key，避免国际化域名两种形态被当成不同站点。
        guard originKey(url) == homeOriginKey else { return false }
        // 路径按 base 的相对根判断，支持任意线路基址。
        return allowedPaths().contains(parts.percentEncodedPath)
    }

    static func navigationID(in url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "_shellNav" } ?? []
        guard items.count == 1, let value = items.first?.value,
              !value.isEmpty, value.utf8.count <= 128 else { return "" }
        return value
    }

    static func withNavigationID(_ url: URL, id: String) -> URL? {
        guard isPanel(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = parts.queryItems?.filter { $0.name != "_shellNav" } ?? []
        items.append(URLQueryItem(name: "_shellNav", value: id))
        parts.queryItems = items
        return parts.url
    }

    /// 可以交给系统打开的外链 scheme 白名单。
    ///
    /// 这里是**唯一**的外链闸门：`decidePolicyFor` 与 `createWebViewWith` 都先问它。
    /// 地图类 scheme 必须逐个列出——网页的「选择导航地图」提供高德/百度/腾讯/Google
    /// 四个入口，只认 iosamap 会让另外三个静默失败（壳 cancel 掉、网页看起来"点了没反应"）。
    /// tel/mailto 是面板里的联系方式入口。
    static func isExternal(_ url: URL) -> Bool {
        ["https", "http", "iosamap", "baidumap", "qqmap", "comgooglemaps", "tel", "mailto"]
            .contains(url.scheme?.lowercased() ?? "")
    }

    /// 判断某个 (scheme, host, port) 三元组是否属于当前面板 origin。
    ///
    /// 桥的安全校验用它（`BridgePolicy.trustedOrigin`），和 `isPanel` 共用同一套
    /// 判定，避免两处各写一份字符串比较：只要有一处不认本地快照
    /// （`zeeho-panel://panel`），本地文档发出的每条 RPC 都会被拒
    /// `untrusted_document`，表现为「桥候选为真但不可用、永久停在 UI 测试预览」。
    ///
    /// - Parameter port: 调用方给 0 表示「没有端口」。
    static func isTrustedOrigin(scheme: String, host: String, port: Int) -> Bool {
        let lowerScheme = scheme.lowercased()
        let lowerHost = host.lowercased()
        // 本地快照：自定义 scheme 没有「默认端口」，只接受不带端口。
        if lowerScheme == localScheme {
            return lowerHost == localHost && port == 0
        }
        guard lowerScheme == "https", port == 0 || port == 443 else { return false }
        guard let homeParts = URLComponents(url: home, resolvingAgainstBaseURL: false) else { return false }
        let homeHost = (homeParts.percentEncodedHost ?? homeParts.host ?? "").lowercased()
        // 两种形态都认：WebKit 可能给 punycode，也可能给百分号编码后的 Unicode。
        if lowerHost == homeHost { return true }
        if let decoded = homeHost.removingPercentEncoding?.lowercased(), lowerHost == decoded { return true }
        if let decoded = lowerHost.removingPercentEncoding?.lowercased(), decoded == homeHost { return true }
        return false
    }

    /// 把线上主文档映射成自定义 scheme 的**根**地址（保留 `_shellNav` 与 fragment）。
    /// 是否真的用本地快照由调用方判断——这里只做纯字符串变换，便于单测。
    ///
    /// 路径必须固定落到 `/index.html`，不能继承线上的基址子目录：
    /// GitHub 线路的 base 是 `.../zeeho-3d-models/`，原样搬运会得到
    /// `zeeho-panel://panel/zeeho-3d-models/`，而 `isPanel` 的本地分支只认
    /// `/` 与 `/index.html`（快照目录里 index.html 就在根下，子资源也相对根解析）。
    /// 真机后果：默认线路（GitHub）100% 打不开，且 `fallbackToNetwork` 会再生成
    /// 同一个坏地址形成同步递归。只有 Cloudflare 线路（base 路径是 `/`）侥幸能过。
    static func localURL(matching remote: URL) -> URL? {
        guard remote.scheme?.lowercased() == "https" else { return nil }
        var parts = URLComponents()
        parts.scheme = localScheme
        parts.host = localHost
        parts.path = "/index.html"
        // 查询串必须保留：`_shellNav` 是桥的文档身份，丢了握手就失败。
        parts.query = remote.query
        // fragment 也一并保留：深链（如 #settings）落到页首会让用户以为链接失效。
        parts.fragment = remote.fragment
        return parts.url
    }
}
