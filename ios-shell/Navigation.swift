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
    static var base: URL = defaultBase
    static var home: URL { base }

    /// 主文档允许的路径集合（相对基址）。
    private static func allowedPaths() -> [String] {
        let root = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return [String(root.dropLast()), root, root + "index.html"]
    }

    static func isPanel(_ url: URL) -> Bool {
        // 本地快照：zeeho-panel://panel/... 只有主文档可拥有原生桥。
        if url.scheme?.lowercased() == localScheme {
            guard url.host?.lowercased() == localHost,
                  url.user == nil, url.password == nil else { return false }
            let path = url.path.isEmpty ? "/index.html" : url.path
            return ["/", "/index.html"].contains(path)
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // Pages 同域还托管产物等页面；只有面板主文档可拥有原生桥。
        return parts.scheme?.lowercased() == "https" && parts.host?.lowercased() == home.host?.lowercased()
            && (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil
            && allowedPaths().contains(parts.percentEncodedPath)
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

    static func isExternal(_ url: URL) -> Bool {
        ["https", "http", "iosamap", "tel", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// 把线上主文档映射成同路径的自定义 scheme 地址（保留 `_shellNav`）。
    /// 是否真的用本地快照由调用方判断——这里只做纯字符串变换，便于单测。
    static func localURL(matching remote: URL) -> URL? {
        guard remote.scheme?.lowercased() == "https" else { return nil }
        var parts = URLComponents()
        parts.scheme = localScheme
        parts.host = localHost
        parts.path = remote.path.isEmpty ? "/index.html" : remote.path
        // 查询串必须保留：`_shellNav` 是桥的文档身份，丢了握手就失败。
        parts.query = remote.query
        return parts.url
    }
}
