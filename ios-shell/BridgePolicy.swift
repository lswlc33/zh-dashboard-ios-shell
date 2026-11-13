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
        "ble.diagnostic.open", "session.renew.prepare", "compat.call", "cast.start"
    ]
    static let maxBodyBytes = 8 * 1024 * 1024
    static let maxResponseBytes = 4 * 1024 * 1024
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

    static func transaction(_ object: [String: Any], transportID: String) throws -> Transaction {
        guard Set(object.keys).isSubset(of: ["id", "url", "method", "headers", "bodyB64", "timeoutMs"]),
              let id = object["id"] as? String, identifier(id) else { throw Failure("invalid_request_id") }
        guard let urlText = object["url"] as? String, urlText.utf8.count <= 4096,
              !urlText.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string: urlText), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.fragment == nil,
              ["tapi.zeehoev.com", "h5.zeehoev.com"].contains(parts.host?.lowercased() ?? "") else {
            throw Failure("url_not_allowed")
        }
        let method = (object["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PUT", "DELETE"].contains(method) else { throw Failure("method_not_allowed") }
        var headers: [String: String] = [:]
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
                guard headers[lower] == nil else { throw Failure("duplicate_header") }
                if allowedHeaders.contains(lower) { headers[lower] = value }
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
        let normalized: [String: Any] = ["id": transportID, "url": urlText, "method": method,
                                         "headers": headers, "bodyB64": body, "timeoutMs": timeout]
        return Transaction(id: id, json: try json(normalized), timeoutMs: timeout)
    }

    static func transactionResult(_ text: String, transportID: String, requestID: String) throws -> [String: Any] {
        guard text.utf8.count <= ((maxResponseBytes + 2) / 3) * 4 + 8192,
              let data = text.data(using: .utf8),
              var result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["id"] as? String == transportID,
              let http = integer(result["http"]), http == 0 || (100...599).contains(http),
              let at = integer(result["at"]), at >= 0,
              let truncated = result["truncated"] as? Bool else { throw Failure("invalid_transport_result") }
        if let error = result["err"] {
            guard http == 0, let error = error as? String, identifier(error, limit: 80),
                  result["bodyB64"] is NSNull else { throw Failure("invalid_transport_result") }
            // 不回显 URL、凭据或响应内容拼成的异常；只接受有界的错误代码。
            result["message"] = error
        } else {
            guard http != 0, let body = result["bodyB64"] as? String,
                  let bytes = Data(base64Encoded: body), bytes.count <= maxResponseBytes,
                  bytes.base64EncodedString() == body else { throw Failure("invalid_transport_result") }
            result.removeValue(forKey: "message")
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
