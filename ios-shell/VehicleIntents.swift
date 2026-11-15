import Foundation
import AppIntents
import ZeehoSystemShared

// 车况查询类 App Intent（Siri / 快捷指令 / 小组件共用）。
//
// ## 为什么这些 intent 只读快照、不现拉接口
//
// 对照组：官方 App 的 SiriIntent.appex 自带 `ZHEEHTTPSessionManager` + `ZHEncryptInfoModel`，
// 每个 intent 都自己拉接口、自己算车锁 encrypt。它们能做到是因为官方有完整签名与
// App Group 权益，且主 App 一直在跑。
//
// 我们的约束不一样：
// 1. 主 App 的凭据在 Keychain + 网页会话里，扩展进程拿不到（也不该拿）；
// 2. Siri 语境下用户预期是「立刻回答」，等一次网络往返会先被系统超时；
// 3. 车况快照本来就是主 App 每次进前台 + 后台采样维护的，手机上那份足够新。
//
// 所以这里的策略是：**只读 App Group 里的车况快照，明确告诉用户数据时间**。
// 快照过期/缺失就如实说「请先打开 App 同步」，绝不拿旧值冒充实时车况 ——
// 与 `SystemSnapshotFreshness` 的窗口判据完全一致（车况标量 180 秒、统计字段 30 分钟）。
//
// 对照 Android：那边这些信息走模块的 `Module` hook 直读宿主进程内存，没有这套快照层。

// MARK: - 数据来源

/// 快照读取 + 文案拼装的唯一入口。
///
/// 所有 intent 都从这里取数，保证「同一个字段在所有 intent 里说法一致」——
/// 曾经在小组件里踩过同类坑（锁车三种叫法混用），这里统一收口。
@available(iOS 17.0, *)
enum ZeehoVehicleIntentData {

    /// 快照读取结果。`snapshot == nil` 且 `reason == nil` 表示「还没同步过」。
    struct Reading {
        let snapshot: SystemSnapshot?
        let reason: String?
    }

    /// 读当前车辆的快照。**只读**，不触发任何网络或写盘。
    static func read(now: Date = Date()) -> Reading {
        do {
            guard let value = try SystemSnapshotStore.readCurrent(now: now) else {
                return Reading(snapshot: nil, reason: nil)
            }
            // 整份快照过期（expiresAt 到点）时不再展示任何数值：
            // 主 App 15 分钟没进前台就说明用户没在用，不能拿上个小时的电量说事。
            if value.isStale(at: now) {
                return Reading(snapshot: nil, reason: ZeehoVehicleIntentStrings.staleWholeSnapshot)
            }
            return Reading(snapshot: value, reason: nil)
        } catch {
            // 未声明权益、缺文件、坏 JSON、owner 不符统一 fail closed。
            return Reading(snapshot: nil, reason: ZeehoVehicleIntentStrings.unavailable)
        }
    }

    /// 「未同步」的统一说法：区分「从没同步过」与「过期/读不到」。
    static func missingText(_ reading: Reading) -> String {
        reading.reason ?? ZeehoVehicleIntentStrings.neverSynced
    }

    /// 数据时间的人类可读说法，例如「3 分钟前」。用于每条回复末尾。
    static func ageText(_ timestamp: Int64?, now: Date = Date()) -> String? {
        guard let timestamp = timestamp, timestamp > 0 else { return nil }
        let seconds = now.timeIntervalSince1970 - Double(timestamp) / 1000
        guard seconds >= -SystemSnapshotFreshness.futureToleranceSeconds else { return nil }
        if seconds < 60 { return ZeehoVehicleIntentStrings.justNow }
        if seconds < 3600 { return ZeehoVehicleIntentStrings.minutesAgo(Int(seconds / 60)) }
        if seconds < 86_400 { return ZeehoVehicleIntentStrings.hoursAgo(Int(seconds / 3600)) }
        return ZeehoVehicleIntentStrings.daysAgo(Int(seconds / 86_400))
    }

    /// 车名兜底：快照没名字就说「当前车辆」。
    static func vehicleName(_ snapshot: SystemSnapshot?) -> String {
        guard let name = snapshot?.vehicle?.name, !name.isEmpty else {
            return ZeehoVehicleIntentStrings.genericVehicle
        }
        return name
    }

    /// 把多个「字段：值」拼成一句话。空数组返回统一的「暂无数据」。
    static func sentence(_ parts: [String]) -> String {
        parts.isEmpty ? ZeehoVehicleIntentStrings.noData : parts.joined(separator: ZeehoVehicleIntentStrings.separator)
    }
}

// MARK: - 车况查询

/// 查询当前车辆的整体车况（电量、充电、锁车、里程、胎压）。
///
/// 对应官方 `SeeCarState`（"查询车辆状态"），但我们**只读本地快照**，
/// 不联网 —— 这是与官方的核心差异，回复里会写明数据时间。
@available(iOS 17.0, *)
struct ZeehoVehicleStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "查询车况"
    static var description = IntentDescription(
        "读取几何面板最近一次同步的车况（电量、充电、锁车、里程、胎压）。只读本地快照，不会联网查询车辆。")
    /// 纯查询：不拉起 App，也不该被自动化当成「打开面板」用。
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reading = ZeehoVehicleIntentData.read()
        guard let snapshot = reading.snapshot, let vehicle = snapshot.vehicle else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.missingText(reading)))
        }
        let now = Date()
        var parts: [String] = [ZeehoVehicleIntentData.vehicleName(snapshot)]
        if let soc = vehicle.visibleSOCPercent(at: now) {
            parts.append(ZeehoVehicleIntentStrings.soc(soc))
        }
        if let charging = vehicle.visibleCharging(at: now) {
            // 充电中有进度就一起报，没进度就只说在充电。
            if charging, let progress = vehicle.visibleChargeProgress(at: now) {
                parts.append(ZeehoVehicleIntentStrings.chargingWith(progress))
            } else {
                parts.append(charging ? ZeehoVehicleIntentStrings.charging : ZeehoVehicleIntentStrings.notCharging)
            }
        }
        if let lock = vehicle.visibleLockState(at: now) {
            parts.append(ZeehoVehicleIntentStrings.lockState(lock))
        }
        if vehicle.visibleStatistics(at: now) {
            if let total = vehicle.visibleTotalMile(at: now) {
                parts.append(ZeehoVehicleIntentStrings.totalMile(total))
            }
            if let range = vehicle.visibleRange(at: now) {
                parts.append(ZeehoVehicleIntentStrings.range(range))
            }
            if vehicle.hasTirePressure {
                parts.append(ZeehoVehicleIntentStrings.tire(front: vehicle.tireFrontBar, rear: vehicle.tireRearBar))
            }
        }
        if let age = ZeehoVehicleIntentData.ageText(snapshot.capturedAt, now: now) {
            parts.append(age)
        }
        return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.sentence(parts)))
    }
}

// MARK: - 电量

/// 查询剩余电量。
///
/// 对应官方 `SafiriCheckRemBattery`。只报电量，不掺杂其他字段 ——
/// 用户问「还有多少电」时多说话反而吵。
@available(iOS 17.0, *)
struct ZeehoBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "查询剩余电量"
    static var description = IntentDescription("读取几何面板最近一次同步的剩余电量。只读本地快照，不会联网查询车辆。")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reading = ZeehoVehicleIntentData.read()
        guard let snapshot = reading.snapshot, let vehicle = snapshot.vehicle else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.missingText(reading)))
        }
        let now = Date()
        guard let soc = vehicle.visibleSOCPercent(at: now) else {
            // 快照在，但电量这一项过期或缺测 —— 不能拿旧 SOC 顶上。
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentStrings.socUnavailable))
        }
        var parts = [ZeehoVehicleIntentStrings.soc(soc)]
        if let charging = vehicle.visibleCharging(at: now), charging {
            parts.append(ZeehoVehicleIntentStrings.chargingNow)
        }
        if let age = ZeehoVehicleIntentData.ageText(vehicle.socUpdatedAt, now: now) {
            parts.append(age)
        }
        return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.sentence(parts)))
    }
}

// MARK: - 充电状态

/// 查询充电状态。
///
/// 对应官方 `SafiriCheckChargingStatus`。
/// **注意**：`charging == nil` 是「接口没给」，不是「未充电」—— 这个区别在
/// 后台通知的翻转判定里已经踩过一次（见 `BackgroundRunner.runRefresh` 注释），
/// 这里同样不能把 nil 说成未充电。
@available(iOS 17.0, *)
struct ZeehoChargingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "查询充电状态"
    static var description = IntentDescription("读取几何面板最近一次同步的充电状态与进度。只读本地快照，不会联网查询车辆。")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reading = ZeehoVehicleIntentData.read()
        guard let snapshot = reading.snapshot, let vehicle = snapshot.vehicle else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.missingText(reading)))
        }
        let now = Date()
        guard let charging = vehicle.visibleCharging(at: now) else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentStrings.chargeUnavailable))
        }
        var parts: [String] = []
        if charging {
            if let progress = vehicle.visibleChargeProgress(at: now) {
                parts.append(ZeehoVehicleIntentStrings.chargingWith(progress))
            } else {
                parts.append(ZeehoVehicleIntentStrings.charging)
            }
            // 充电时才值得顺带报电量：未充电时用户问的是「充没充」，电量是另一件事。
            if let soc = vehicle.visibleSOCPercent(at: now) {
                parts.append(ZeehoVehicleIntentStrings.soc(soc))
            }
        } else {
            parts.append(ZeehoVehicleIntentStrings.notCharging)
        }
        if let age = ZeehoVehicleIntentData.ageText(vehicle.chargingUpdatedAt, now: now) {
            parts.append(age)
        }
        return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.sentence(parts)))
    }
}

// MARK: - 车锁

/// 查询车辆锁状态（整车开/关机，不是坐垫锁）。
///
/// 官方只有「解锁/关锁」两个动作 intent，没有单独的「查锁状态」。
/// 我们加这条是因为：锁状态是**只读**的，做进快捷指令后可以配
/// 「如果 未锁 就发提醒」这类自动化，比让用户盲点一次解锁更安全。
@available(iOS 17.0, *)
struct ZeehoLockStateIntent: AppIntent {
    static var title: LocalizedStringResource = "查询车锁状态"
    static var description = IntentDescription("读取几何面板最近一次同步的车辆锁状态。只读本地快照，不会联网查询车辆，也不会锁车或解锁。")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reading = ZeehoVehicleIntentData.read()
        guard let snapshot = reading.snapshot, let vehicle = snapshot.vehicle else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.missingText(reading)))
        }
        let now = Date()
        guard let lock = vehicle.visibleLockState(at: now) else {
            return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentStrings.lockUnavailable))
        }
        var parts = [ZeehoVehicleIntentStrings.lockState(lock)]
        if let age = ZeehoVehicleIntentData.ageText(vehicle.statsUpdatedAt, now: now) {
            parts.append(age)
        }
        return .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleIntentData.sentence(parts)))
    }
}

// MARK: - 文案

/// 查询类 intent 的文案。
///
/// 与 `WidgetStrings` / `IOSStrings` 分开：这些句子只在 Siri/快捷指令回复里出现，
/// 和界面文案的生命周期不同（系统会朗读，得短、不能有括号套括号）。
@available(iOS 17.0, *)
enum ZeehoVehicleIntentStrings {
    static let genericVehicle = "当前车辆"
    static let separator = "，"

    static let neverSynced = "还没有车况数据，请先打开几何面板进入主页同步一次"
    static let unavailable = "读不到车况数据，请在几何面板里重新同步"
    static let staleWholeSnapshot = "车况数据已过期，请打开几何面板重新同步"
    static let noData = "暂时没有可显示的车况数据"

    static let socUnavailable = "暂时读不到电量，请打开几何面板重新同步"
    static let chargeUnavailable = "暂时读不到充电状态，请打开几何面板重新同步"
    static let lockUnavailable = "暂时读不到车锁状态，请打开几何面板重新同步"

    static let charging = "充电中"
    static let notCharging = "未充电"
    static let chargingNow = "正在充电"

    static let justNow = "刚刚更新"
    static func minutesAgo(_ value: Int) -> String { "\(value) 分钟前更新" }
    static func hoursAgo(_ value: Int) -> String { "\(value) 小时前更新" }
    static func daysAgo(_ value: Int) -> String { "\(value) 天前更新" }

    static func soc(_ value: Double) -> String { String(format: "电量 %.0f%%", value) }
    static func chargingWith(_ value: Double) -> String { String(format: "充电中 %.0f%%", value) }
    static func lockState(_ value: Int) -> String { value == 1 ? "已锁车" : "未锁车" }
    static func totalMile(_ value: Double) -> String { String(format: "总里程 %.0f 公里", value) }
    static func range(_ value: Double) -> String { String(format: "续航 %.0f 公里", value) }

    /// 胎压：两只都缺就整段不出现（由调用方判定 `hasTirePressure`），
    /// 只有一只时另一只写「—」而不是省略 —— 省略会让人误以为车只有一只胎。
    static func tire(front: Double?, rear: Double?) -> String {
        func bar(_ value: Double?) -> String {
            guard let value = value, value.isFinite else { return "—" }
            return String(format: "%.1f", value)
        }
        return "胎压 前 \(bar(front)) 后 \(bar(rear)) bar"
    }
}
