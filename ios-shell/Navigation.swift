import Foundation

enum PanelNavigation {
    /// 面板主文档地址。基址随线路选择变化（GitHub / Cloudflare）。
    static var home: URL { IOSPanelLine.baseURL() }

    /// 主文档允许的路径集合（相对基址）。
    private static func allowedPaths() -> [String] {
        let root = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return [String(root.dropLast()), root, root + "index.html"]
    }

    static func isPanel(_ url: URL) -> Bool {
        // 本地快照：zeeho-panel://panel/... 只有主文档可拥有原生桥。
        if url.scheme?.lowercased() == IOSPanelSchemeHandler.scheme {
            guard url.host?.lowercased() == IOSPanelSchemeHandler.host,
                  url.user == nil, url.password == nil else { return false }
            let path = url.path.isEmpty ? "/index.html" : url.percentEncodedPath
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

    /// 有可用本地快照时，把主文档地址改写到自定义 scheme。
    /// 这样面板能在弱网/离线直接打开，且资源全部走本机。
    static func resolved(_ url: URL) -> URL {
        guard IOSPanelCache.shared.snapshotDirectory() != nil else { return url }
        guard isPanel(url), url.scheme?.lowercased() != IOSPanelSchemeHandler.scheme else { return url }
        return IOSPanelSchemeHandler.localURL(matching: url) ?? url
    }
}
