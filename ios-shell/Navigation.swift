import Foundation

enum PanelNavigation {
    static let home = URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!
    static func isPanel(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // Pages 同域还托管产物等页面；只有面板主文档可拥有原生桥。
        let root = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return parts.scheme?.lowercased() == "https" && parts.host?.lowercased() == home.host?.lowercased()
            && (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil
            && [String(root.dropLast()), root, root + "index.html"].contains(parts.percentEncodedPath)
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
}
