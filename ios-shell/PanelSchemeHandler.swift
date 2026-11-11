import Foundation
import WebKit
import UniformTypeIdentifiers

// 把本地快照通过自定义 scheme 交给 WKWebView。
// 用 scheme 而不是 file:// 的原因：
//   1. file:// 在 WKWebView 里跨目录读取受限，且 fetch/XHR 会被 CORS 挡死；
//   2. 自定义 scheme 有稳定的 origin，网页的 localStorage/IndexedDB 能正常用；
//   3. 能像 HTTP 一样返回真实 MIME 与状态码，网页的 `fetch('mock.json')` 不用改。
//
// scheme 名不能和 PanelNavigation 的白名单脱节：`isPanel()` 必须同时认
// `zeeho-panel://` 与线上 https 源，否则主文档导航会被当成外部链接取消。
final class IOSPanelSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "zeeho-panel"
    static let host = "panel"

    /// 快照根目录由外部注入，避免 handler 自己猜路径。
    private let rootProvider: () -> URL?

    init(rootProvider: @escaping () -> URL?) {
        self.rootProvider = rootProvider
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let root = rootProvider() else {
            fail(urlSchemeTask, code: NSURLErrorResourceUnavailable)
            return
        }
        // 只暴露快照目录内的普通文件：拒绝 `..`、绝对路径与符号链接。
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else {
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }
        let file = root.appendingPathComponent(relative, isDirectory: false)
        // 解析符号链接后必须仍在 root 之内，防止快照被塞进指向外部的链接。
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFile == resolvedRoot || resolvedFile.hasPrefix(resolvedRoot + "/") else {
            fail(urlSchemeTask, code: NSURLErrorNoPermissionsToReadFile)
            return
        }
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }
        let response = URLResponse(url: url, mimeType: Self.mimeType(for: relative),
                                   expectedContentLength: data.count, textEncodingName: Self.encoding(for: relative))
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 读取是同步完成的，没有需要中断的异步工作。
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    private static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "webmanifest": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "ico": return "image/x-icon"
        case "mp4": return "video/mp4"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private static func encoding(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "js", "mjs", "css", "json", "webmanifest", "svg":
            return "utf-8"
        default:
            return nil
        }
    }

    /// 快照内主文档的 URL。`PanelNavigation` 用它构造起始地址。
    static func documentURL() -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.path = "/index.html"
        return parts.url
    }

    /// 把 https 主文档地址映射到同路径的自定义 scheme 地址。
    /// 实现在 PanelNavigation（纯字符串变换，可单测），这里只做转发避免两份逻辑漂移。
    static func localURL(matching remote: URL) -> URL? {
        PanelNavigation.localURL(matching: remote)
    }
}
