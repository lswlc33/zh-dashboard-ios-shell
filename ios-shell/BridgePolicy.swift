import Foundation
import WebKit
import Security
import CoreFoundation

// 来源、导航和形状都要通过；随机 nonce 只是文档代号，不能替代来源认证。
enum IOSBridgePolicy {
    static let handlerName = "zeehoIOS"
    static let version = 1
    static let maxPending = 48
    static let maxRequestBytes = 12 * 1024 * 1024
    static let maxServiceBytes = 512 * 1024
    static let maxFileEnvelopeBytes = 28 * 1024 * 1024
    static let maxPendingBytes = 32 * 1024 * 1024
    static let fileMethods: Set<String> = ["file.share", "file.save", "photos.save", "asset.zip.build.begin"]
    static let interactiveMethods: Set<String> = [
        "file.share", "file.save", "photos.save", "clipboard.read", "clipboard.write", "media.permission",
        "notifications.request", "notifications.schedule", "notifications.cancel", "app.settings",
        "gps.begin", "ble.scan", "ble.connect", "ble.write", "ride.begin", "history.clear",
        "system.snapshot", "liveActivity.start", "liveActivity.end", "panel.update",
        "ui.confirm", "wifi.join", "network.open", "blob.pick", "ble.open", "ble.systemPairing",
        "ble.diagnostic.open", "session.renew.prepare", "compat.call", "cast.start",
        // 本地实验壁纸 ZIP 构建+MD5 可能超默认 30s；与 ios-bridge.js 的 INTERACTIVE 逐项对齐，
        // 不加会让「网页还在等、原生 30s 到点已撤单」。
        "asset.zip.build.begin",
        // 后台凭据会落 Keychain 并长期有效，原生必定弹确认框；超时必须放宽，
        // 否则用户还在读说明文字，网页已经报超时了。
        "background.credential"
    ]
    static let maxBodyBytes = 8 * 1024 * 1024
    static let maxResponseBytes = 4 * 1024 * 1024 // 既有官方 API/KMP 边界，不给资源改动一起升限。
    static let maxResourceResponseBytes = IOSBridgeBudget.maxTransactionResponseBytes
    static let maxTransactionReplyBytes = IOSBridgeBudget.maxTransactionReplyBytes
    static let maxResourceRedirects = 5
    static let maxConcurrentResources = 4
    static let maxURLBytes = 4096
    static let credentialHeaders: Set<String> = [
        "cfmoto-x-param", "cfmoto-x-sign", "cfmoto-x-sign-type",
        "cfmoto-sign", "cfmoto-sign-type", "authorization"
    ]
    static let allowedHeaders: Set<String> = [
        "cfmoto-x-param", "cfmoto-x-sign", "cfmoto-x-sign-type",
        "cfmoto-sign", "cfmoto-sign-type", "authorization", "content-type", "accept"
    ]

    struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    struct Transaction {
        let id: String
        let json: String
        let timeoutMs: Int
        let url: URL
        let headers: [String: String]
        let followRedirects: Bool
        let resource: Bool
        var responseLimit: Int { resource ? IOSBridgePolicy.maxResourceResponseBytes : IOSBridgePolicy.maxResponseBytes }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) <= 9_007_199_254_740_991 else { return nil }
        return number.intValue
    }

    static func identifier(_ value: String, limit: Int = 128) -> Bool {
        !value.isEmpty && value.utf8.count <= limit
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value)
                    || (97...122).contains($0.value) || [45, 46, 58, 95].contains($0.value)
            }
    }

    static func methodName(_ value: String) -> Bool {
        value.utf8.count <= 80 && value.range(of: "^[a-z][a-zA-Z0-9]*(\\.[a-zA-Z][a-zA-Z0-9]*)*$",
                                             options: .regularExpression) != nil
    }

    static func randomIdentifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure("random_unavailable")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func trustedOrigin(_ origin: WKSecurityOrigin) -> Bool {
        // 复用 PanelNavigation 的判定：本地快照页（zeeho-panel://panel）也要认。
        // 这里曾经写死 https + home.host，导致「本地快照优先」这条主路径上
        // 每一条 RPC（含 hello）都被回 untrusted_document —— 桥候选为真、
        // available 恒假，网页永久停在「UI 测试预览」，而且因为 candidate 非假，
        // Dashboard 的「桥不可用就回退线上」也不会触发。
        PanelNavigation.isTrustedOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    static func trustedFrame(_ frame: WKFrameInfo, navigationID: String) -> Bool {
        guard frame.isMainFrame, trustedOrigin(frame.securityOrigin),
              let url = frame.request.url, PanelNavigation.isPanel(url) else { return false }
        return PanelNavigation.navigationID(in: url) == navigationID
    }

    static func json(_ value: Any, limit: Int = maxRequestBytes) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw Failure("invalid_json") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw Failure("request_too_large")
        }
        return text
    }

    // 配置只经过 JSON 编码放进固定模板；值中的引号、换行或 </script> 不是代码。
    static func scriptJSON(_ value: Any) throws -> String {
        try json(value, limit: IOSStore.maxArchiveBytes + 1024 * 1024)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // 资源不穷举域名；仍拒绝 userinfo、控制字符、反斜线和非法端口，不能把 URL 解析歧义当可信接口。
    static func transactionURL(_ text: String) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= maxURLBytes,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                      || $0.value == 92
              }), let separator = text.range(of: "://") else { throw Failure("url_not_allowed") }
        let scheme = String(text[..<separator.lowerBound]).lowercased()
        let authority = text[separator.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard ["http", "https"].contains(scheme), !authority.isEmpty,
              !authority.contains("@"), !authority.contains("%"),
              let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme, let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { throw Failure("url_not_allowed") }
        return url
    }

    static func credentialEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        return ["tapi.zeehoev.com", "h5.zeehoev.com"].contains(parts.host?.lowercased() ?? "")
    }

    static func transaction(_ object: [String: Any], transportID: String) throws -> Transaction {
        guard Set(object.keys).isSubset(of: ["id", "url", "method", "headers", "bodyB64", "timeoutMs", "followRedirects"]),
              let id = object["id"] as? String, identifier(id) else { throw Failure("invalid_request_id") }
        guard let urlText = object["url"] as? String else { throw Failure("url_not_allowed") }
        let url = try transactionURL(urlText)
        let method = (object["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "DELETE"].contains(method) else { throw Failure("method_not_allowed") }
        let followRedirects: Bool
        if let value = object["followRedirects"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw Failure("invalid_redirect_policy")
            }
            followRedirects = number.boolValue
        } else { followRedirects = false }
        let trustedAPI = credentialEndpoint(url)
        guard trustedAPI || method == "GET", !followRedirects || method == "GET" else {
            throw Failure("method_not_allowed")
        }
        // 显式跟镜像的 GET 属于资源通道，连官方 host 上的资源也不需要账号/签名头。
        // 这里只隔离原生转发的头，不能阻止页面主动把凭据拼到 URL 或正文。
        let resource = !trustedAPI || followRedirects
        var headers: [String: String] = [:]
        var headerNames = Set<String>()
        var headerBytes = 0
        if let source = object["headers"], !(source is NSNull) {
            guard let source = source as? [String: Any], source.count <= 32 else { throw Failure("invalid_headers") }
            for (name, value) in source {
                guard let value = value as? String, name.utf8.count <= 128, value.utf8.count <= 8192,
                      name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    throw Failure("invalid_header")
                }
                headerBytes += name.utf8.count + value.utf8.count
                guard headerBytes <= 16 * 1024 else { throw Failure("headers_too_large") }
                let lower = name.lowercased()
                guard headerNames.insert(lower).inserted else { throw Failure("duplicate_header") }
                if allowedHeaders.contains(lower), !resource || !credentialHeaders.contains(lower) { headers[lower] = value }
            }
        }
        var body: Any = NSNull()
        if let value = object["bodyB64"], !(value is NSNull) {
            guard let text = value as? String, text.utf8.count <= ((maxBodyBytes + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: text), bytes.count <= maxBodyBytes,
                  bytes.base64EncodedString() == text else { throw Failure("invalid_body_base64") }
            guard method != "GET" || bytes.isEmpty else { throw Failure("get_body_not_allowed") }
            body = text
        }
        let timeout: Int
        if let value = object["timeoutMs"] {
            guard let number = integer(value), number > 0 else { throw Failure("invalid_timeout") }
            timeout = min(number, 60_000)
        } else { timeout = 12_000 }
        // 老 API/KMP 请求仍只收到既有字段；followRedirects 是 Swift 资源分流依据，不改共享协议。
        let normalized: [String: Any] = ["id": transportID, "url": urlText, "method": method,
                                         "headers": headers, "bodyB64": body, "timeoutMs": timeout]
        return Transaction(id: id, json: try json(normalized), timeoutMs: timeout, url: url,
                           headers: headers, followRedirects: followRedirects, resource: resource)
    }

    static func transactionResult(_ text: String, transportID: String, requestID: String,
                                  responseLimit: Int = maxResponseBytes) throws -> [String: Any] {
        let limit = min(maxResourceResponseBytes, responseLimit)
        let metadataBytes = limit == maxResponseBytes ? 8192 : 64 * 1024
        guard limit > 0, text.utf8.count <= ((limit + 2) / 3) * 4 + metadataBytes,
              let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("invalid_transport_result")
        }
        return try transactionResult(result, transportID: transportID, requestID: requestID, responseLimit: limit)
    }

    // Swift 资源直接交 JSON 值给 withReply，不把 28MB Base64 再编码成中间 JSON 字符串。
    static func transactionResult(_ value: [String: Any], transportID: String, requestID: String,
                                  responseLimit: Int) throws -> [String: Any] {
        guard responseLimit > 0, responseLimit <= maxResourceResponseBytes,
              Set(value.keys).isSubset(of: ["id", "http", "bodyB64", "at", "truncated", "err", "message", "location", "finalUrl"]),
              value["id"] as? String == transportID,
              let http = integer(value["http"]), http == 0 || (100...599).contains(http),
              let at = integer(value["at"]), at >= 0,
              let truncated = value["truncated"] as? Bool else { throw Failure("invalid_transport_result") }
        var result = value
        if let error = result["err"] {
            guard http == 0, let error = error as? String, identifier(error, limit: 80),
                  result["bodyB64"] is NSNull else { throw Failure("invalid_transport_result") }
            result["message"] = error
        } else {
            guard http != 0, let body = result["bodyB64"] as? String,
                  IOSBridgeBudget.transactionBodySize(body, limit: responseLimit) != nil,
                  body.utf8.count <= maxTransactionReplyBytes - 64 * 1024 else {
                throw Failure("invalid_transport_result")
            }
            result.removeValue(forKey: "message")
        }
        // 两个可选 URL 最多各 4096 UTF-8 字节，JSON 转义上界也在 64KiB metadata 余量内。
        for key in ["location", "finalUrl"] {
            if let metadata = result[key] {
                guard let text = metadata as? String, text.utf8.count <= maxURLBytes,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw Failure("invalid_transport_result")
                }
                if key == "finalUrl" { _ = try transactionURL(text) }
            }
        }
        result["id"] = requestID
        result["truncated"] = truncated
        return result
    }

    static func failure(method: String, code: String, requestID: String = "") -> [String: Any] {
        if method == "store.commit" { return ["ok": false, "reason": code] }
        if method == "txn.request" {
            return ["id": requestID, "http": 0, "bodyB64": NSNull(),
                    "at": Int(Date().timeIntervalSince1970 * 1000), "truncated": false,
                    "err": code, "message": code]
        }
        return ["ok": false, "error": ["code": code, "message": code]]
    }
}

// 仅公开资源 GET 使用；官方 API 默认仍走 KMP 的旧上限/超时/不跟跳转语义。
// 所有会话/缓冲/完成状态只在同一串行 delegate 队列访问，取消会关闭真实任务并只回执一次。
final class IOSResourceRequest: NSObject, URLSessionDataDelegate {
    private let request: IOSBridgePolicy.Transaction
    private let transportID: String
    private let io = OperationQueue()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private var finished = false
    private var completion: (([String: Any]) -> Void)?

    init(request: IOSBridgePolicy.Transaction, transportID: String, completion: @escaping ([String: Any]) -> Void) {
        self.request = request; self.transportID = transportID; self.completion = completion
        super.init()
        io.name = "io.github.lswlc33.dashboard.ios.resource-request"
        io.maxConcurrentOperationCount = 1; io.qualityOfService = .userInitiated
    }

    func start() { io.addOperation { [self] in begin() } }
    func cancel() { io.addOperation { [self] in fail("cancelled") } }

    private func get(_ url: URL) -> URLRequest {
        var value = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                               timeoutInterval: Double(request.timeoutMs) / 1000)
        value.httpMethod = "GET"; value.httpShouldHandleCookies = false
        // 每跳都从空白 GET 构造，不继承 URLSession 拷贝来的 Authorization/Cookie/签名头。
        for (name, text) in request.headers where !IOSBridgePolicy.credentialHeaders.contains(name.lowercased()) {
            value.setValue(text, forHTTPHeaderField: name)
        }
        value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return value
    }

    private func begin() {
        guard !finished, request.resource else { fail("invalid_resource_request"); return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Double(request.timeoutMs) / 1000
        config.timeoutIntervalForResource = Double(request.timeoutMs) / 1000
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: io)
        self.session = session
        let task = session.dataTask(with: get(request.url)); self.task = task
        task.resume()
    }

    private func fail(_ code: String) {
        finish(IOSBridgePolicy.failure(method: "txn.request", code: code, requestID: transportID))
    }

    private func finish(_ value: [String: Any]) {
        guard !finished else { return }
        finished = true
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        data.removeAll(keepingCapacity: false); response = nil
        let callback = completion; completion = nil
        callback?(value)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard !finished else { completionHandler(nil); return }
        guard self.request.followRedirects else { completionHandler(nil); return }
        guard redirects < IOSBridgePolicy.maxResourceRedirects,
              let target = request.url,
              let safeURL = try? IOSBridgePolicy.transactionURL(target.absoluteString) else {
            completionHandler(nil); fail("redirect_not_allowed"); return
        }
        redirects += 1
        completionHandler(get(safeURL))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished, let http = response as? HTTPURLResponse, (100...599).contains(http.statusCode),
              let url = http.url, (try? IOSBridgePolicy.transactionURL(url.absoluteString)) != nil else {
            completionHandler(.cancel); fail("invalid_resource_response"); return
        }
        // Content-Length 可缺失或被压缩影响；真正的解码后上限还由 didReceive(data:) 逐块检查。
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if (encoding == nil || encoding == "identity"), http.expectedContentLength > Int64(request.responseLimit) {
            completionHandler(.cancel); fail("response_too_large"); return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard data.count <= request.responseLimit - self.data.count else { fail("response_too_large"); return }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error = error as NSError? {
            let code = error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut ? "timeout"
                : (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled ? "cancelled" : "io")
            fail(code); return
        }
        guard let response = response, let url = response.url else { fail("invalid_resource_response"); return }
        var value: [String: Any] = ["id": transportID, "http": response.statusCode,
                                    "bodyB64": data.base64EncodedString(),
                                    "at": Int(Date().timeIntervalSince1970 * 1000), "truncated": false,
                                    "finalUrl": url.absoluteString]
        if let location = response.value(forHTTPHeaderField: "Location"),
           location.utf8.count <= IOSBridgePolicy.maxURLBytes,
           !location.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            value["location"] = location
        }
        finish(value)
    }

    // 不弹 HTTP Basic/客户端证书登录，不读共享凭据；HTTPS 信任继续由系统验证，不接受自签例外。
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let serverTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        completionHandler(serverTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
