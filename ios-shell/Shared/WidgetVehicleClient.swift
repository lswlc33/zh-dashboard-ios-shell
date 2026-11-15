import Foundation
import CryptoKit

// 小组件自己拉车况的最小客户端（照官方 `ZHEEHTTPSessionManager` + `ZHNetTool` 的做法）。
//
// ## 为什么放在 Shared
//
// 扩展要能独立发请求，就不能依赖主 App 的 `IOSBackgroundClient`（那个类在 Host 模块里，
// 且绑定后台任务语义）。这里只放**纯函数 + 一次有界 URLSession**，Host 与扩展都能链接，
// 密钥仍然只从 `WidgetCredential` 读、不写死在源码里（`ios-shell/` 会整体同步到公开仓库）。
//
// ## 签名算法
//
// 与 `IOSBackgroundSigning`（BackgroundSigning.swift）以及网页 `sign.js` 完全同一套：
//     sign = md5Hex(sha1Hex(排序后 query + param + SECRET))
// query 按 key 字典序、value 不编码、丢弃空值；param 固定为
// `appId=..&nonce=..&timestamp=<毫秒>`。**顺序不能变**，服务端按原串验签。
//
// 这里没有直接复用 `IOSBackgroundSigning`：那个枚举在 Host 模块里、`ios-shell/` 根目录，
// 扩展不链接 Host 源码（build-support.py 的 target 契约）。算法只有十行，两边各自一份
// 比把 Host 源码塞进扩展干净；差异必须保持为零，改动时两边一起看。
public enum WidgetSigning {
    public static let apiBase = "https://tapi.zeehoev.com"
    private static let nonceAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    public static func sha1Hex(_ text: String) -> String {
        hex(Data(Insecure.SHA1.hash(data: Data(text.utf8))))
    }
    public static func md5Hex(_ text: String) -> String {
        hex(Data(Insecure.MD5.hash(data: Data(text.utf8))))
    }
    public static func nonce(length: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in nonceAlphabet.randomElement(using: &generator)! })
    }
    public static func param(appID: String, nonce: String, timestamp milliseconds: Int64) -> String {
        "appId=\(appID)&nonce=\(nonce)&timestamp=\(milliseconds)"
    }
    /// app 域 query 签名（小组件全部走 GET，不需要 body 那条）。
    public static func querySignature(query: [(String, String)], param: String, secret: String) -> String {
        let sorted = query.filter { !$0.1.isEmpty }.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return md5Hex(sha1Hex(sorted + param + secret))
    }
}

/// 小组件一次取数的结果。字段与 `SystemVehicleSnapshot` 一一对应，缺测保持 nil。
public struct WidgetFetchedVehicle: Equatable, Sendable {
    public var name: String?
    public var socPercent: Double?
    public var charging: Bool?
    public var chargeProgressPercent: Double?
    public var voltage: Double?
    public var current: Double?
    public var power: Double?
    public var lockState: Int?
    public var seatState: Int?
    public var online: Int?
    public var todayMileKm: Double?
    public var lastMileKm: Double?
    public var lastRideMinutes: Double?
    public var totalMileKm: Double?
    public var rangeKm: Double?
    public var integral: Double?
    public var unread: Int?
    public var tireFrontBar: Double?
    public var tireRearBar: Double?
    public var tireFrontTemp: Double?
    public var tireRearTemp: Double?
    /// 车况类采样的响应到达时刻（毫秒）。
    public var sampledAt: Int64
    /// 统计类字段的响应到达时刻（毫秒）；一个统计字段都没拿到时为 nil。
    public var statsUpdatedAt: Int64?

    public var hasStatistics: Bool {
        statsUpdatedAt != nil && (voltage != nil || current != nil || power != nil
            || lockState != nil || seatState != nil || online != nil
            || todayMileKm != nil || lastMileKm != nil || lastRideMinutes != nil
            || totalMileKm != nil || rangeKm != nil || integral != nil || unread != nil
            || tireFrontBar != nil || tireRearBar != nil
            || tireFrontTemp != nil || tireRearTemp != nil)
    }
}

/// 失败分类：每个码都能直接进诊断，不做二次翻译。
public enum WidgetFetchError: Error, Equatable, Sendable {
    case noCredential
    case unauthorized
    case throttled
    case server(Int)
    case network
    case decode

    public var code: String {
        switch self {
        case .noCredential: return "no_credential"
        case .unauthorized: return "http_401"
        case .throttled: return "http_429"
        case let .server(status): return "http_\(status)"
        case .network: return "network"
        case .decode: return "decode"
        }
    }
}

/// 扩展进程里的取数器。
///
/// 只做两波请求：第一波 `vehicleHomePageV2`（车况/锁/坐垫/在线/总里程/车名/续航），
/// 第二波并发 `batteryInfo` + `homeRideInfo` + `tire/monitoring`。积分与未读数需要
/// 额外的 uid 探测接口，小组件**不拉**——那是账号页才关心的慢变量，用它换两次请求
/// 不划算（Android 小组件走的是快照，不受影响）。
public enum WidgetVehicleClient {
    /// 单次请求超时。扩展被系统唤起的时间预算很紧，宁可失败退回快照。
    private static let requestTimeout: TimeInterval = 10
    private static let resourceTimeout: TimeInterval = 18

    /// 取一次车况。任何一项失败都不影响已拿到的其它项：
    /// 第一波失败才整体失败（没有车况快照就没有意义的「部分成功」）。
    public static func fetch(_ credential: WidgetCredential, at date: Date = Date()) async -> Result<WidgetFetchedVehicle, WidgetFetchError> {
        guard credential.isUsable(at: date) else { return .failure(.noCredential) }
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        // 第一波：车况主接口。
        let homeResult = await getJSON(session: session, path: "/v1.0/app/cfmotoserverapp/vehicleHomePageV2/\(credential.vin)",
                                       query: [], credential: credential)
        let home: [String: Any]
        switch homeResult {
        case .failure(let error): return .failure(error)
        case .success(let object):
            guard let data = object["data"] as? [String: Any] else { return .failure(.decode) }
            home = data
        }
        let homeAt = nowMs()

        // 第二波：电池 / 骑行 / 胎压并发。任何一个失败都只留空该组字段。
        async let batteryTask = getJSON(session: session, path: "/v1.0/app/cfmotoserverapp/batteryInfo/\(credential.vin)",
                                        query: [], credential: credential)
        async let rideTask = getJSON(session: session, path: "/v1.0/app/cfmotoserverapp/homeRideInfo",
                                     query: [("vinNo", credential.vin)], credential: credential)
        async let tireTask = getJSON(session: session, path: "/v1.0/app/cfmotoserverapp/app/vehicle/tire/monitoring",
                                     query: [("sensorType", tireSensorType(home)), ("vinNo", credential.vin)],
                                     credential: credential)
        let (batteryResult, rideResult, tireResult) = await (batteryTask, rideTask, tireTask)
        let statsAt = nowMs()

        let battery = value(batteryResult).flatMap { $0["data"] as? [String: Any] }
        let ride = value(rideResult).flatMap { $0["data"] as? [String: Any] }
        let tires = value(tireResult).flatMap { $0["data"] as? [String: Any] }

        var out = WidgetFetchedVehicle(sampledAt: homeAt)
        // ---- 车况（vehicleHomePageV2）----
        out.socPercent = percent(number(home["bmssoc"]))
        // 充电判据与网页 model.js / system-surfaces.js 同口径：**只有 "1" 是充电中**，
        // 空/缺失才是未知，其它值（"0"/"2"/"3"/"-1"）一律按未充电。
        if let code = text(home["chargeState"]), !code.isEmpty {
            out.charging = code == "1"
        } else {
            out.charging = nil
        }
        // vehicleType 才是 Android 小组件显示的车名（不是 vehicleName），长度/字符另在展示层校验。
        out.name = text(home["vehicleType"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        out.lockState = state(home["headLockState"])
        // 坐垫三态：字段缺失是「未知」而不是「未锁」，与 model.js 的 seatLock 一致。
        out.seatState = home["seatLockState"] == nil ? nil : state(home["seatLockState"])
        out.online = state(home["onlineStatus"])
        out.totalMileKm = nonNegative(number(home["totalRideMile"]))
        out.rangeKm = nonNegative(number(home["hmiRidableMile"]))
        // 充电进度：只有「已充时长」与「预计充满」都是正整数才按比例算，与 model.js 的
        // chargeState().progress 完全一致；两个数不同步时宁可 null 也不猜。
        if out.charging == true,
           let charged = minutes(text(home["chargeTimeString"])),
           let expectValue = number(home["expectFullTimeDescribe"]).map({ Int($0) }),
           expectValue > 0, charged > 0 {
            out.chargeProgressPercent = min(100, Double((charged * 100 + expectValue / 2) / expectValue))
        }
        // ---- 电池（batteryInfo）----
        if let battery = battery {
            let voltage = number(battery["voltage"]) ?? number(battery["bmsVoltage"])
            if let voltage = voltage, voltage > 0, voltage <= 200 { out.voltage = voltage }
            // 电流优先自报；自报缺失或与「电压×电流≈功率」差太远时用功率反推，
            // 与 model.js 的 currentAmp 同一判据（差 5% 以上认为自报不准）。
            let reportedCurrent = number(battery["current"])
            let reportedPower = number(battery["power"])
            out.current = correctedCurrent(voltage: out.voltage, current: reportedCurrent, power: reportedPower)
            out.power = correctedPower(voltage: out.voltage, current: out.current, power: reportedPower)
            // 电池接口的 bmssoc / chargeState 比车况更新，有就覆盖（网页侧同样优先）。
            if let soc = percent(number(battery["bmssoc"])) { out.socPercent = soc }
            if let code = text(battery["chargeState"]), !code.isEmpty { out.charging = code == "1" }
        }
        // ---- 骑行（homeRideInfo）----
        if let ride = ride {
            out.todayMileKm = nonNegative(number(ride["rideMileageDay"]))
            out.lastMileKm = nonNegative(number(ride["lastRideMileage"]))
            out.lastRideMinutes = nonNegative(number(ride["lastRidingTimeUnitMinute"]))
        }
        // ---- 胎压（tire/monitoring）----
        if let tires = tires, let rows = tires["realTimeData"] as? [[String: Any]] {
            for row in rows {
                // sensorPosition 1=前轮 2=后轮；其它值忽略（不猜）。
                guard let position = number(row["sensorPosition"]).map({ Int($0) }) else { continue }
                let pressure = number(row["tirePressure"]).flatMap { $0 > 0 && $0 <= 20 ? $0 : nil }
                let temp = number(row["tireTemp"]).flatMap { $0 >= -60 && $0 <= 200 ? $0 : nil }
                if position == 1 {
                    out.tireFrontBar = pressure
                    out.tireFrontTemp = temp
                } else if position == 2 {
                    out.tireRearBar = pressure
                    out.tireRearTemp = temp
                }
            }
        }
        // 统计时间只在真的拿到至少一个统计字段时才写；否则保持 nil（缺测合法）。
        out.statsUpdatedAt = hasAnyStatistic(out) ? statsAt : nil
        return .success(out)
    }

    // MARK: - 内部

    private static func hasAnyStatistic(_ value: WidgetFetchedVehicle) -> Bool {
        value.voltage != nil || value.current != nil || value.power != nil
            || value.lockState != nil || value.seatState != nil || value.online != nil
            || value.todayMileKm != nil || value.lastMileKm != nil || value.lastRideMinutes != nil
            || value.totalMileKm != nil || value.rangeKm != nil
            || value.tireFrontBar != nil || value.tireRearBar != nil
            || value.tireFrontTemp != nil || value.tireRearTemp != nil
    }

    /// 胎压传感器类型：优先看车况接口自报，拿不到按外置（与网页 endpoints 的默认一致）。
    private static func tireSensorType(_ home: [String: Any]) -> String {
        guard let builtIn = home["builtInTirePressure"] as? Bool else { return "EXTERNAL" }
        return builtIn ? "INTERNAL" : "EXTERNAL"
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    /// 一次带签名的 GET。返回 `[String: Any]` 顶层对象（不解析 data，交给调用方）。
    private static func getJSON(session: URLSession, path: String, query: [(String, String)],
                                credential: WidgetCredential) async -> Result<[String: Any], WidgetFetchError> {
        let timestamp = nowMs()
        let param = WidgetSigning.param(appID: credential.appID,
                                        nonce: WidgetSigning.nonce(), timestamp: timestamp)
        let sign = WidgetSigning.querySignature(query: query, param: param, secret: credential.appSecret)
        var components = URLComponents(string: WidgetSigning.apiBase + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components?.url else { return .failure(.decode) }
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
            return .success(object)
        } catch {
            return .failure(.network)
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func value<T>(_ result: Result<T, WidgetFetchError>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }

    /// 数值：排除 JSON 的 true/false（NSNumber 会把它们当 1/0）。
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    /// 三态状态位：只认 "1" / "0"（也接受 true/false），其余（含 "ONLINE"）走 online 专用解析。
    private static func state(_ value: Any?) -> Int? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "online", "on"].contains(trimmed) { return 1 }
            if ["0", "false", "offline", "off"].contains(trimmed) { return 0 }
            return nil
        }
        if let number = number(value) { return number == 1 ? 1 : (number == 0 ? 0 : nil) }
        return nil
    }

    private static func percent(_ value: Double?) -> Double? {
        guard let value = value, value >= 0, value <= 100 else { return nil }
        return value
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value = value, value >= 0 else { return nil }
        return value
    }

    /// "1h54min" → 114。与 model.js 的 `^(\d+h)?\s*(\d+)\s*min$` 同一口径。
    private static func minutes(_ text: String?) -> Int? {
        guard let text = text else { return nil }
        let pattern = "^(?:(\\d+)\\s*h)?\\s*(\\d+)\\s*min$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        func group(_ index: Int) -> Int? {
            let groupRange = match.range(at: index)
            guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) else { return nil }
            return Int(text[swiftRange])
        }
        let hours = group(1) ?? 0
        guard let mins = group(2) else { return nil }
        return hours * 60 + mins
    }

    /// 与 model.js 的 currentAmp 同一判据：自报功率与「电压×电流」差 5% 以上就用功率反推。
    private static func correctedCurrent(voltage: Double?, current: Double?, power: Double?) -> Double? {
        guard let power = power, abs(power) > 0 else { return current }
        guard let voltage = voltage, voltage > 0 else { return current }
        guard let current = current else { return round1(power / voltage) }
        if abs(voltage * current - power) > abs(power) * 0.05 { return round1(power / voltage) }
        return current
    }

    private static func correctedPower(voltage: Double?, current: Double?, power: Double?) -> Double? {
        if let power = power, abs(power) <= 30_000, power.isFinite { return power }
        guard let voltage = voltage, let current = current else { return nil }
        let value = voltage * current
        return abs(value) <= 30_000 ? value : nil
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
