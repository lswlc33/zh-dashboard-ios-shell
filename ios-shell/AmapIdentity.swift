import Foundation

/// 两端共用获准的地图身份；不能改用本壳重签后的证书，否则 scode 会与 Key 的绑定不一致。
/// Base64 仅用于避免明文常量直接出现，是可逆编码，不提供密钥保密性。
enum IOSAmapIdentity {
    private static let keyBase64 = "NjhmZmU1ZmUwNDQxMzcwMjRmMGM4ODIzMDE5MTJkMTc="
    private static let identityBase64 = "QTk6RTc6NkM6MkM6MEY6N0Q6RDE6MjA6OEI6NDQ6NjQ6QzQ6QTc6QkE6Q0M6MDE6MEM6OEQ6MTA6Nzc6Y29tLmNmbW90bw=="

    // 只解码一次并留在进程内存；不读取其他 App、不写偏好、不记录回执内容。
    private static let payload: [String: Any] = {
        guard let keyData = Data(base64Encoded: keyBase64),
              let identityData = Data(base64Encoded: identityBase64),
              let key = String(data: keyData, encoding: .utf8),
              let identity = String(data: identityData, encoding: .utf8),
              key.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              identity.range(of: "^([0-9A-F]{2}:){20}com\\.cfmoto$", options: .regularExpression) != nil else {
            return ["ok": false, "version": 1, "key": "", "identity": "", "error": "unavailable"]
        }
        return ["ok": true, "version": 1, "key": key, "identity": identity, "error": ""]
    }()

    static func read() -> [String: Any] { payload }
}
