import Foundation
import CryptoKit
import Security

// 后台请求执行器：原生签名 + URLSession，不依赖 WebView。
//
// ## 为什么必须原生重写
//
// 后台不能跑网页（见 BackgroundTasks.swift 顶部注释）。签到与车况拉取原来都在
// tasks.js / app.js 里，用 JS 的 sha1/md5 算签名。这里用 CryptoKit 的 Insecure.SHA1
// 与 Insecure.MD5 复刻同一算法——**顺序不能变**：
//
//     sign = md5Hex(sha1Hex(body + "appId=..&nonce=..&timestamp=.." + SECRET))
//
// query 模式下是 sha1Hex(排序后的 query + param + SECRET)，body 为空。两者都是
// 「先拼原始串、再做两次摘要」，不是 HMAC。
//
// ## 为什么密钥不在这个文件里
//
// `ios-shell/` 会被 tools/sync-public-ios.sh **整目录同步到公开仓库**
// （lswlc33/zh-dashboard-ios-shell）。把 APP_SECRET 写成源码常量就等于公开发布密钥。
// 因此签名密钥与网页 sign.js 一样处理：**运行时由网页导入、存 Keychain**，原生只在
// 内存里短暂持有。这与既有 IOSSecretHandleService 的思路一致，差别只是 TTL 从
// 300 秒延长到「用户授权的自动任务有效期内」，否则后台任务永远等不到凭据。

/// 一个可以在后台独立发请求的账号凭据集。
///
/// 只保存后台真正需要的东西。**签名密钥与 token 一起存**，因为它们成对失效：
/// 只有 token 没有密钥算不出签名，只有密钥没有 token 也发不出请求。
struct IOSBackgroundCredential: Codable, Equatable, Sendable {
    var accountID: String
    var vin: String
    /// app 域 token（tapi.zeehoev.com）。
    var token: String
    /// h5 签到域 token。空表示这条账号还没导入签到凭据。
    var signinToken: String
    /// app 域签名密钥（与网页 sign.js 的 APP_SECRET 同一个值）。
    var appSecret: String
    /// h5 域签名密钥（与网页 tasks.js 的 H5_SECRET 同一个值）。
    var h5Secret: String
    /// app 域 appId（与网页 sign.js 的 APP_ID 同一个值）。
    var appID: String
    /// h5 域 appId（与网页 tasks.js 的 H5_APP_ID 同一个值）。
    var h5AppID: String
    /// 云端**内部用户 id**（17 位数字），积分任务列表与「我的动态」都只认它。
    ///
    /// 与 `accountID` 不是一回事：`accountID` 是账号池里的稳定标识（可能为空串、
    /// 也可能是用户自填的昵称），而 `integral/getByUserId` 必须传这个内部 id，
    /// 传错服务端不报错、只回空列表（见 docs/开发笔记.md:1812）。
    /// 老凭据没有这个字段时按空串解码，`canRunDailyTasks` 会因此为 false，
    /// 界面提示「重新授权」——绝不猜一个 uid 去发请求。
    var uid: String
    var updatedAt: Int64

    /// 向后兼容解码：老版本存进 Keychain 的 JSON 可能**缺字段**（例如还没有
    /// `signinToken`/`h5Secret`/`h5AppID` 的年代，以及还没有 `uid` 的现在）。合成 `Codable`
    /// 遇到缺键会整体解码失败 → `load()` 返回 nil → 用户看到 `no_credential`，但实际上他授权过。
    /// 这正是「快捷指令一直提示未导入后台凭据」的一个真实成因。
    ///
    /// 所以每个字段都按「缺键 = 空串」解码，再由 `isValid` 按域分别判定够不够用。
    /// 不用 `decodeIfPresent` + `?? ""` 逐个写，是因为那样新增字段仍会漏；这里用
    /// 统一容器，未来加字段也不会再炸老凭据。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            (try? box.decodeIfPresent(String.self, forKey: key)) ?? ""
        }
        accountID = text(.accountID)
        vin = text(.vin)
        token = text(.token)
        signinToken = text(.signinToken)
        appSecret = text(.appSecret)
        h5Secret = text(.h5Secret)
        appID = text(.appID)
        h5AppID = text(.h5AppID)
        uid = text(.uid)
        updatedAt = (try? box.decodeIfPresent(Int64.self, forKey: .updatedAt)) ?? 0
    }

    init(accountID: String, vin: String, token: String, signinToken: String,
         appSecret: String, h5Secret: String, appID: String, h5AppID: String,
         uid: String = "", updatedAt: Int64) {
        self.accountID = accountID; self.vin = vin; self.token = token; self.signinToken = signinToken
        self.appSecret = appSecret; self.h5Secret = h5Secret
        self.appID = appID; self.h5AppID = h5AppID; self.uid = uid
        self.updatedAt = updatedAt
    }

    /// 单字段合法性：非空、不超长、无控制字符。
    private static func ok(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// app 域够用就能拉车况（`vehicleHomePageV2`）。
    ///
    /// **这里刻意不再要求 h5 字段**：车况采样只用 `token`/`appID`/`appSecret`。
    /// 旧实现把 `isValid`（要求 h5 全齐）当成采样前提，于是「只导入了 app 域
    /// 凭据」的账号采样必然失败并报 `no_credential` —— 第二个真实成因。
    var canSampleVehicle: Bool {
        Self.ok(accountID) && Self.ok(vin) && Self.ok(token) && Self.ok(appSecret) && Self.ok(appID)
    }

    /// h5 域够用才能签到。签到要 h5 的 appId/secret，token 可以用 app 域顶替。
    var canSignIn: Bool {
        Self.ok(vin) && (!signinToken.isEmpty || !token.isEmpty) && Self.ok(h5Secret) && Self.ok(h5AppID)
    }

    /// 跑每日任务要 app 域凭据 + 内部 uid。
    ///
    /// uid 是硬门槛：任务列表 `/integral/getByUserId?userId=`、「我的动态」
    /// `/community/mineArticleInfo?userId=` 都只认 17 位内部 id，传错服务端会安静地
    /// 回一个空列表（不报错），于是「任务读到了 0 项」看起来像「今天全做完了」。
    /// 所以缺 uid 时明确判不可跑，让界面提示重新授权，绝不猜一个 uid 发请求。
    var canRunDailyTasks: Bool {
        canSampleVehicle && Self.ok(uid)
    }

    /// 两个域至少有一样能用。全废的凭据视为无效，`load()` 会当作没有。
    var isValid: Bool { canSampleVehicle || canSignIn }

    /// 诊断用：告诉用户到底缺哪个域（界面/回执文案直接用它，不猜）。
    var grantedScopes: [String] {
        var scopes: [String] = []
        if canSampleVehicle { scopes.append("app") }
        if canSignIn { scopes.append("h5") }
        if canRunDailyTasks { scopes.append("tasks") }
        return scopes
    }

    /// 擦除敏感字段后再丢弃，避免 JSON 副本在内存里留一层。
    mutating func clear() {
        token = ""; signinToken = ""; appSecret = ""; h5Secret = ""
    }
}

/// Keychain 里的后台凭据。
///
/// 与 Store.swift 的用法一致：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`——
/// 后台任务可能在锁屏时被唤醒，用 `WhenUnlocked` 会永远读不到；
/// `ThisDeviceOnly` 保证不随 iCloud 钥匙串同步到别的设备。
enum IOSBackgroundCredentialStore {
    private static let service = "io.github.lswlc33.dashboard.ios.background.credential"
    private static let account = "active"

    /// 读取结果。**必须区分「没有」和「有但坏了」**，否则两类完全不同的原因
    /// 会被压成同一个 `no_credential`，用户永远不知道该重新授权还是重装 App。
    enum LoadOutcome: Equatable {
        /// Keychain 里根本没有这一项：用户从没授权过，或重签/重装把它清掉了。
        case missing
        /// 有原始数据但解不开 / 两个域都不完整：凭据残留但不可用。
        case unusable(reason: String)
        /// 可用。
        case ready(IOSBackgroundCredential)

        var credential: IOSBackgroundCredential? {
            if case let .ready(value) = self { return value }
            return nil
        }
    }

    /// 保留旧签名给不关心原因的调用方用。
    static func load() -> IOSBackgroundCredential? { outcome().credential }

    /// 需要给用户解释原因时用这个。
    static func outcome() -> LoadOutcome {
        switch read() {
        case .nothing: return .missing
        case let .failure(status): return .unusable(reason: "keychain_\(status)")
        case let .success(data):
            guard let value = try? JSONDecoder().decode(IOSBackgroundCredential.self, from: data) else {
                return .unusable(reason: "credential_decode_failed")
            }
            guard value.isValid else {
                // 哪一路还活着就说哪一路，别只说「无效」。
                let scopes = value.grantedScopes
                return .unusable(reason: scopes.isEmpty ? "credential_incomplete" : "credential_partial")
            }
            return .ready(value)
        }
    }

    static func save(_ value: IOSBackgroundCredential) -> Bool {
        guard value.isValid else { return false }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private enum ReadResult {
        case nothing
        /// 带上 OSStatus（负数），诊断时能分清 `errSecInteractionNotAllowed`（-25308，
        /// 锁屏且未解锁过一次）与 `errSecAuthFailed`（-25293，重签后权限变了）
        /// 这类环境问题，而不是笼统的「没授权」。
        case failure(Int32)
        case success(Data)
    }

    private static func read() -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .nothing }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data else { return .nothing }
        return .success(data)
    }
}

/// 凭据不可用时的**细分原因码**。
///
/// 之前这些情况全报 `no_credential`，用户只能看到「未导入后台凭据」一句话，
/// 分不清是该重新授权、还是该退出重进解锁一次钥匙串。现在每一类单独成码，
/// 界面按码给不同的动作建议；`no_credential` 只保留给真正的「从没授权」。
enum IOSBackgroundCredentialIssue: String {
    /// Keychain 里没有这一项 —— 从没授权，或重签/重装被清掉。**这才是 no_credential**。
    case neverGranted = "no_credential"
    /// 有数据但解不开（旧版本 schema / 数据被截断）。
    case decodeFailed = "credential_decode_failed"
    /// 解开了，但两个域都不完整。
    case incomplete = "credential_incomplete"
    /// 某一域可用、另一域不可用（例如只导入了 app 域，签到会失败）。
    case partial = "credential_partial"
    /// 钥匙串访问被系统拒绝（锁屏未解锁过一次 / 重签后权限变化）。
    case keychainLocked = "keychain_locked"
    case keychainUnavailable = "keychain_unavailable"

    /// 把 `LoadOutcome` 映射成用户能据以行动的码。
    static func from(_ outcome: IOSBackgroundCredentialStore.LoadOutcome) -> IOSBackgroundCredentialIssue? {
        switch outcome {
        case .ready: return nil
        case .missing: return .neverGranted
        case let .unusable(reason):
            if reason.hasPrefix("keychain_") {
                // -25308 errSecInteractionNotAllowed：设备锁着且本进程还没解锁过钥匙串。
                // 后台唤醒时常见，属于「稍后重试即可」，不是用户操作问题。
                if reason.contains("25308") { return .keychainLocked }
                return .keychainUnavailable
            }
            if reason == "credential_decode_failed" { return .decodeFailed }
            if reason == "credential_partial" { return .partial }
            return .incomplete
        }
    }
}

/// 后台请求的失败分类。每个码都要能直接写进回执，界面上不做二次翻译。
enum IOSBackgroundError: Error, Equatable {
    /// 凭据不可用。**带原因码**，否则「没授权」和「授权了但缺一半」会被混为一谈
    /// （用户报的那个 bug 就是这么来的）。默认值保持向后兼容的 `no_credential`。
    case noCredential(IOSBackgroundCredentialIssue = .neverGranted)
    case unauthorized          // 401：token 失效，需要用户重新登录
    case throttled             // 429 / 服务端限流
    case server(Int)           // 其它 4xx/5xx
    case network(String)       // 传输层失败（DNS/超时/断网）
    case decode                // 响应不是预期结构

    var code: String {
        switch self {
        case let .noCredential(issue): return issue.rawValue
        case .unauthorized: return "http_401"
        case .throttled: return "http_429"
        case let .server(status): return "http_\(status)"
        case .network: return "network"
        case .decode: return "decode"
        }
    }
}


/// 签名算法的纯函数部分。不持有任何密钥，便于单测与复用。
enum IOSBackgroundSigning {
    static let apiBase = "https://tapi.zeehoev.com"
    static let h5Base = "https://h5.zeehoev.com"
    /// 签到接口。h5 域的签到用 **body + param** 拼串；其它查询用 **query + param**。
    static let signInPath = "/cfmotoservermine/H5/signin"
    static let nonceAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ text: String) -> String {
        hex(Data(Insecure.SHA1.hash(data: Data(text.utf8))))
    }

    static func md5Hex(_ text: String) -> String {
        hex(Data(Insecure.MD5.hash(data: Data(text.utf8))))
    }

    /// 16 位随机 nonce。网页用 UUID，服务端只当不透明串，长度对得上即可。
    static func nonce(length: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in nonceAlphabet.randomElement(using: &generator)! })
    }

    /// `appId=..&nonce=..&timestamp=..`。顺序固定，服务端按原串验签。
    static func param(appID: String, nonce: String, timestamp milliseconds: Int64) -> String {
        "appId=\(appID)&nonce=\(nonce)&timestamp=\(milliseconds)"
    }

    /// app 域 query 签名：query 按 key 字典序、value 不编码（同 sign.js 的 sortedRawNonEmpty）。
    static func querySignature(query: [(String, String)], param: String, secret: String) -> String {
        let sorted = query.filter { !$0.1.isEmpty }.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return md5Hex(sha1Hex(sorted + param + secret))
    }

    /// h5 域 body 签名（签到用这条）。
    static func bodySignature(body: String, param: String, secret: String) -> String {
        md5Hex(sha1Hex(body + param + secret))
    }
}

/// 后台请求的最小执行器。
///
/// 刻意不复用桥的传输层：桥的每条 RPC 都绑定当前网页的 navigation/frame/epoch，
/// 后台没有这些上下文。独立一份能保证后台任务不受前后台切换影响，也不会把请求
/// 记进网页的诊断日志（那需要网页活着）。
final class IOSBackgroundClient {
    static let shared = IOSBackgroundClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // 后台任务窗口只有约 30 秒，必须让请求自己先超时，而不是等系统强杀。
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    struct SignInResult: Equatable {
        /// 是否已经签到（今天本来签过也算成功，不重复报错）。
        let signed: Bool
        /// 今天是否本来就已经签过。
        let repeated: Bool
        /// 连签天数。服务端没给就是 nil（不猜）。
        let days: Int?
        let code: String?
        let message: String?
    }

    struct VehicleSample: Equatable {
        let socPercent: Double?
        let charging: Bool?
        let capturedAt: Int64
    }

    // MARK: - 签到

    /// 执行一次 h5 签到。
    ///
    /// 与 tasks.js 的 signin() 完全同构：body 固定 `{}`，签名用 body+param+H5_SECRET，
    /// 成功判据是 `code == "10000"` 或 message 表示「今天已签」。
    ///
    /// **绝不能改成调原生 PsModel 式端点**（Android 侧教训：那会让全局 401 映射把
    /// 登录态清掉并弹「登录已过期」）。h5 通道的 401 只影响本次结果。
    func signIn(credential: IOSBackgroundCredential) async -> Result<SignInResult, IOSBackgroundError> {
        // 越界防御：Runner 已按 canSignIn 拦过一次，这里是第二道。
        // 走到这里说明凭据**缺 h5 域**（不是完全没授权），所以报 partial 而不是 neverGranted。
        guard credential.canSignIn else { return .failure(.noCredential(.partial)) }
        let token = credential.signinToken.isEmpty ? credential.token : credential.signinToken
        let body = "{}"
        let param = IOSBackgroundSigning.param(
            appID: credential.h5AppID,
            nonce: IOSBackgroundSigning.nonce(),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        let sign = IOSBackgroundSigning.bodySignature(
            body: body, param: param, secret: credential.h5Secret)

        guard let url = URL(string: IOSBackgroundSigning.h5Base + IOSBackgroundSigning.signInPath) else {
            return .failure(.decode)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(param, forHTTPHeaderField: "cfmoto-x-param")
        request.setValue(sign, forHTTPHeaderField: "cfmoto-x-sign")
        request.setValue("0", forHTTPHeaderField: "cfmoto-x-sign-type")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (payload, response) = try await session.data(for: request)
            guard let value = response as? HTTPURLResponse else { return .failure(.decode) }
            data = payload; http = value
        } catch {
            return .failure(.network((error as NSError).domain))
        }
        switch http.statusCode {
        case 200...299: break
        case 401: return .failure(.unauthorized)
        case 429: return .failure(.throttled)
        default: return .failure(.server(http.statusCode))
        }
        // 401 时正文是 XML，不要尝试解析；这里只处理 2xx。
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decode)
        }
        let code = Self.text(object["code"])
        let message = object["message"] as? String
        let ok = code == "10000"
        let repeated = (message?.range(of: "已签|重复|repeatedly", options: .regularExpression) != nil)
            || code == "repeatedly_operation"
        guard ok || repeated else {
            return .success(SignInResult(signed: false, repeated: false, days: nil, code: code, message: message))
        }
        var days: Int?
        if let payload = object["data"] as? [String: Any] {
            for key in ["continueDays", "signCount", "count"] {
                if let n = number(payload[key]), n >= 0, n.rounded() == n {
                    days = Int(n); break
                }
            }
        }
        return .success(SignInResult(signed: true, repeated: repeated, days: days, code: code, message: message))
    }

    // MARK: - 车况采样

    /// 读一次车况里的电量与充电态。
    ///
    /// 只认两个字段：`socPercent`（电量）与 `chargeState`。
    /// **只有字符串 "1" 是充电中**——与网页 model.js 同口径；其它值（"0"/"2"/"3"/"-1"）
    /// 一律按未充电，缺失才是未知。Android 的通知 getter 还兼容 "true"，那是历史偏差，
    /// 不要照抄过来。
    func vehicleSample(credential: IOSBackgroundCredential) async -> Result<VehicleSample, IOSBackgroundError> {
        // 同上：缺 app 域时是部分授权，不是完全没授权。
        guard credential.canSampleVehicle else { return .failure(.noCredential(.partial)) }
        let path = "/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(credential.vin)"
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let param = IOSBackgroundSigning.param(
            appID: credential.appID, nonce: IOSBackgroundSigning.nonce(), timestamp: timestamp)
        let sign = IOSBackgroundSigning.querySignature(
            query: [], param: param, secret: credential.appSecret)
        guard let url = URL(string: IOSBackgroundSigning.apiBase + path) else { return .failure(.decode) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(param, forHTTPHeaderField: "cfmoto-x-param")
        request.setValue(sign, forHTTPHeaderField: "cfmoto-x-sign")
        request.setValue("0", forHTTPHeaderField: "cfmoto-x-sign-type")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.decode) }
            switch http.statusCode {
            case 200...299: break
            case 401: return .failure(.unauthorized)
            case 429: return .failure(.throttled)
            default: return .failure(.server(http.statusCode))
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.decode)
            }
            // 车况字段的真实位置随接口版本变过：先找 data，再退到根对象。
            let body = (object["data"] as? [String: Any]) ?? object
            let soc = number(body["socPercent"]) ?? number(body["soc"]) ?? number(body["batterySoc"])
            let raw = body["chargeState"]
            let charging: Bool?
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                charging = trimmed.isEmpty ? nil : (trimmed == "1")
            } else if let value = number(raw) {
                charging = value == 1
            } else {
                charging = nil
            }
            return .success(VehicleSample(socPercent: soc, charging: charging, capturedAt: timestamp))
        } catch {
            return .failure(.network((error as NSError).domain))
        }
    }

    /// code 可能是字符串也可能是数字，统一成字符串比较。
    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    /// NSNumber 的布尔值必须排除：JSON 的 true 也是 NSNumber，会被误读成 1。
    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}
