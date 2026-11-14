import Foundation
import UserNotifications
import UIKit

// 后台任务的实际执行体：签到、电量采样、充电状态变化通知。
//
// 这里只做「跑一次 + 记账 + 发本地通知」，调度在 IOSBackgroundScheduler。
// 所有函数都必须在后台窗口内尽快返回：BGAppRefreshTask 只给约 30 秒。
//
// 标 iOS 13：内部用到的 BGTaskScheduler 是 13.0 起可用，与 BackgroundTasks.swift
// 的 IOSBackgroundScheduler 保持同一个下限，避免调用点要做可用性分支。
@available(iOS 13.0, *)
enum IOSBackgroundRunner {
    /// 每日自动签到。
    ///
    /// 只有用户在设置里开了开关、并且导入过凭据才会真的发请求；否则直接成功返回，
    /// 这样系统不会因为我们「跑了但什么也没做」而降低后续调度意愿。
    static func runSignIn(completion: @escaping (Bool) -> Void) {
        guard IOSBackgroundPreferences.autoSignInEnabled else {
            IOSBackgroundLog.write("跳过签到：用户未开启自动签到")
            completion(true)
            return
        }
        guard let credential = IOSBackgroundCredentialStore.load() else {
            IOSBackgroundLog.write("跳过签到：没有已授权的后台凭据")
            IOSBackgroundScheduler.record({ report in
                report.lastRunAt = nowMs()
                report.lastResult = "no_credential"
                report.runCount += 1
            }, identifier: IOSBackgroundTaskID.signIn)
            completion(true)   // 缺凭据不是运行失败，不该让系统扣我们的调度分
            return
        }
        Task {
            let outcome = await IOSBackgroundClient.shared.signIn(credential: credential)
            var result = "ok"
            var days: Int?
            var notify: (String, String)?
            switch outcome {
            case let .success(value):
                days = value.days
                if value.signed {
                    result = value.repeated ? "already_signed" : "signed"
                    // 后台签到完成提醒：只在这条路径发，前台手动签到由网页自己提示。
                    if IOSBackgroundPreferences.taskNotifyEnabled {
                        let title = value.repeated
                            ? IOSBackgroundStrings.signInAlreadyTitle
                            : IOSBackgroundStrings.signInDoneTitle
                        let body = value.days.map { IOSBackgroundStrings.signInDays($0) }
                            ?? IOSBackgroundStrings.signInDoneBody
                        notify = (title, body)
                    }
                } else {
                    result = "rejected:\(value.code ?? "unknown")"
                    IOSBackgroundLog.write("签到被拒 code=\(value.code ?? "-") message=\(value.message ?? "-")")
                }
            case let .failure(error):
                result = error.code
                IOSBackgroundLog.write("签到失败 \(error.code)")
            }
            IOSBackgroundScheduler.record({ report in
                report.lastRunAt = nowMs()
                report.lastResult = result
                if let days = days { report.lastSignInDays = days }
                report.runCount += 1
                if result == "signed" || result == "already_signed" { report.successCount += 1 }
            }, identifier: IOSBackgroundTaskID.signIn)
            if let message = notify {
                // 后台发通知不需要任何额外权限：用户已在 notifications.request 里授权过。
                IOSBackgroundNotifier.post(id: "auto-signin", title: message.0, body: message.1)
            }
            completion(result == "signed" || result == "already_signed")
        }
    }

    /// 后台采样一次电量，并在充电状态**发生翻转**时发通知。
    ///
    /// 关键约束：iOS 后台唤醒不可靠，所以「充电开始/结束」只在真的采到样本、
    /// 且与上一次样本比较出翻转时才发。绝不因为「上次是充电中、这次没唤醒」就推断结束。
    static func runRefresh(completion: @escaping (Bool) -> Void) {
        guard let credential = IOSBackgroundCredentialStore.load() else {
            IOSBackgroundLog.write("跳过采样：没有已授权的后台凭据")
            IOSBackgroundScheduler.record({ report in
                report.lastRunAt = nowMs()
                report.lastResult = "no_credential"
                report.runCount += 1
            }, identifier: IOSBackgroundTaskID.refresh)
            completion(true)
            return
        }
        Task {
            let outcome = await IOSBackgroundClient.shared.vehicleSample(credential: credential)
            var result = "ok"
            var soc: Double?
            var charging: Bool?
            switch outcome {
            case let .success(sample):
                soc = sample.socPercent
                charging = sample.charging
                let previous = IOSBackgroundScheduler.report(IOSBackgroundTaskID.refresh)
                // 翻转判定只在两次都有明确值时才成立：nil 是「接口没给」，不是「未充电」。
                if let current = sample.charging, let last = previous.lastCharging, current != last,
                   IOSBackgroundPreferences.chargeNotifyEnabled {
                    let title = current
                        ? IOSBackgroundStrings.chargeStartTitle
                        : IOSBackgroundStrings.chargeStopTitle
                    let body = sample.socPercent.map { IOSBackgroundStrings.chargeSoc($0) }
                        ?? IOSBackgroundStrings.chargeSocUnknown
                    IOSBackgroundNotifier.post(id: "charge-change", title: title, body: body)
                }
                // 把样本追加进电量历史，让网页与小组件能看到后台补的点。
                // 写入失败不影响任务本身：历史是尽力而为的附加产物。
                IOSBackgroundHistory.append(sample: sample, credential: credential)
            case let .failure(error):
                result = error.code
                IOSBackgroundLog.write("采样失败 \(error.code)")
            }
            IOSBackgroundScheduler.record({ report in
                report.lastRunAt = nowMs()
                report.lastResult = result
                if let soc = soc { report.lastSocPercent = soc }
                if let charging = charging { report.lastCharging = charging }
                report.runCount += 1
                if result == "ok" { report.successCount += 1 }
            }, identifier: IOSBackgroundTaskID.refresh)
            completion(true)
        }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// 后台任务的本地通知投递。
///
/// 复用 `dashboard.local.` 前缀与 namespace 约定（见 System.swift），这样
/// 网页侧的 `notifications.cancel` 也能取消这些提醒，不会出现「后台发的通知
/// 用户没法在面板里删掉」。
enum IOSBackgroundNotifier {
    static let prefix = "dashboard.local."
    static let namespace = "dashboard.system.local.v1"
    static let businessKey = "dashboardBusinessID"
    static let namespaceKey = "dashboardNamespace"

    /// - Parameter id: 业务 ID。同一个 ID 会先撤掉旧的再发，避免同一件事堆多条。
    static func post(id: String, title: String, body: String, sound: Bool = true) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            guard allowed else {
                IOSBackgroundLog.write("通知未授权，丢弃 \(id)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = "dashboard.local"
            content.userInfo = [namespaceKey: namespace, businessKey: id]
            if sound { content.sound = .default }
            // 立刻投递：1 秒是 UNTimeIntervalNotificationTrigger 的下限。
            let request = UNNotificationRequest(
                identifier: prefix + UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.getPendingNotificationRequests { pending in
                // 同一业务 ID 的旧提醒先撤掉；否则每次充电翻转都会多留一条。
                let stale = pending.filter {
                    $0.content.userInfo[namespaceKey] as? String == namespace
                        && $0.content.userInfo[businessKey] as? String == id
                }.map { $0.identifier }
                if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
                center.add(request) { error in
                    if error != nil { IOSBackgroundLog.write("通知投递失败 \(id)") }
                }
            }
        }
    }
}

/// 后台采样写进「待合并样本队列」。
///
/// **不直接写 History.swift 的历史文件**：那套格式有 battery/ledger 双份、
/// storageRevision、fingerprint 校验和 8MB 上界，后台硬写一次格式不符就会让
/// 用户整份历史变成 `history_invalid_file`（进而被隔离成墓碑）。
///
/// 改成落一个独立的小队列文件，网页回到前台后用 `background.samples.take` 取走，
/// 再走原有的 `history.record`。这样：
/// - 后台只做「按接口返回原样记录」，不推断缺口、不合成电压电流；
/// - 采样准入、积分、缺口、充电段仍全部由 KMP 判（与前台同一条链路）；
/// - 队列损坏最坏只是丢几个后台点，绝不影响用户已有历史。
enum IOSBackgroundSampleQueue {
    /// 单条待合并样本。字段与 history.record 的 snapshot 形状保持一致，
    /// 网页取走后可以直接构造 record 参数。
    struct Sample: Codable, Equatable {
        let vin: String
        /// 采样时间（Unix 毫秒）。后台任务的真实时间，不是「现在」。
        let capturedAt: Int64
        let socPercent: Double
        /// true=充电中 / false=未充电 / nil=接口没给。
        let charging: Bool?
    }

    private static let fileName = "background-samples.json"
    private static let maxSamples = 64
    private static let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.bg.samples", qos: .utility)

    private static var fileURL: URL? {
        guard let root = try? SystemSnapshotStore.containerURL() else { return nil }
        return root.appendingPathComponent(fileName, isDirectory: false)
    }

    static func append(_ sample: Sample) {
        queue.async {
            guard let url = fileURL else { return }
            var items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
            // 同一毫秒的重复点直接替换：后台与前台可能几乎同时采到同一秒。
            items.removeAll { $0.vin == sample.vin && $0.capturedAt == sample.capturedAt }
            items.append(sample)
            // 只保留最新的 N 条：队列是「补点」用途，攒太多说明前台很久没回来，
            // 那些老点对电量曲线已经没有价值（时间轴上本来就是缺口）。
            if items.count > maxSamples { items = Array(items.suffix(maxSamples)) }
            if let data = try? JSONEncoder().encode(items) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 取走全部待合并样本并清空文件（take 语义：读到就删，避免重复入账）。
    static func take() -> [Sample] {
        queue.sync {
            guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
            try? FileManager.default.removeItem(at: url)
            return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
        }
    }

    /// 只读不删，供状态页显示「有几个后台点待合并」。
    static func count() -> Int {
        queue.sync {
            guard let url = fileURL, let data = try? Data(contentsOf: url) else { return 0 }
            return ((try? JSONDecoder().decode([Sample].self, from: data)) ?? []).count
        }
    }
}

enum IOSBackgroundHistory {
    static func append(sample: IOSBackgroundClient.VehicleSample, credential: IOSBackgroundCredential) {
        // 电量缺失时没有任何可记录的量，直接跳过（不记 0）。
        guard let soc = sample.socPercent, soc >= 0, soc <= 100 else { return }
        IOSBackgroundSampleQueue.append(IOSBackgroundSampleQueue.Sample(
            vin: credential.vin, capturedAt: sample.capturedAt,
            socPercent: soc, charging: sample.charging))
    }
}

/// 后台任务相关文案。
///
/// 集中在这里而不是 IOSStrings：这些只在后台路径用到，混进主界面文案表会让
/// test.py 的「界面文案必须走 R.string/IOSStrings」断言变模糊。
enum IOSBackgroundStrings {
    static let signInDoneTitle = "自动签到完成"
    static let signInDoneBody = "今日签到已完成。"
    static let signInAlreadyTitle = "今日已签到"
    static func signInDays(_ days: Int) -> String { "已连续签到 \(days) 天。" }
    static let chargeStartTitle = "开始充电"
    static let chargeStopTitle = "充电结束"
    static func chargeSoc(_ soc: Double) -> String {
        let value = soc.rounded()
        return value == soc ? "当前电量 \(Int(value))%。" : String(format: "当前电量 %.1f%%。", soc)
    }
    static let chargeSocUnknown = "车辆已切换充电状态。"
}
