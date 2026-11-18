import Foundation
import UserNotifications
import UIKit
import ZeehoSystemShared

// 后台任务的实际执行体：签到、电量采样、充电状态变化通知。
//
// 这里只做「跑一次 + 记账 + 发本地通知」，调度在 IOSBackgroundScheduler。
// 所有函数都必须在后台窗口内尽快返回：BGAppRefreshTask 只给约 30 秒。
//
// 标 iOS 13：内部用到的 BGTaskScheduler 是 13.0 起可用，与 BackgroundTasks.swift
// 的 IOSBackgroundScheduler 保持同一个下限，避免调用点要做可用性分支。
@available(iOS 13.0, *)
enum IOSBackgroundRunner {
    /// 同一轮（包括快捷指令的签到→任务→采样）只领一次槽位、使用同一个绝对期限。
    static func withRun<T: Sendable>(source: IOSBackgroundRunSource, budget: TimeInterval = 25,
        body: @escaping @Sendable (IOSBackgroundRunContext) async throws -> T) async throws -> T {
        let coordinator = IOSBackgroundRunCoordinator.shared
        let context = try coordinator.begin(source: source, budget: budget)
        defer { coordinator.finish(context) }
        return try await withTaskCancellationHandler(operation: {
            let operation = Task {
                try await iosBackgroundWithinDeadline(context) { try await body(context) }
            }
            coordinator.installCancellation(context) { operation.cancel() }
            return try await operation.value
        }, onCancel: { coordinator.cancel(context) })
    }

    /// 保留 AppDelegate 的 completion 入口，但把真实 Task 交回调度器，expiration 可以取消它。
    @discardableResult
    static func runSignIn(force: Bool = false, completion: @escaping (Bool) -> Void) -> Task<Void, Never> {
        Task {
            let report = await runSignIn(force: force)
            completion(["signed", "already_signed", "disabled"].contains(report.lastResult)
                || ZeehoCredentialIssueText.isCredentialIssue(report.lastResult))
        }
    }

    static func runSignIn(force: Bool = false, budget: TimeInterval = 25) async -> IOSBackgroundTaskReport {
        do {
            return try await withRun(source: .system(IOSBackgroundTaskID.signIn), budget: budget) { context in
                await runSignIn(force: force, context: context)
            }
        } catch { return stoppedReport(error) }
    }

    /// 快捷指令主动触发可以忽略自动开关；系统后台路径仍尊重用户的选择。
    static func runSignIn(force: Bool, context: IOSBackgroundRunContext) async -> IOSBackgroundTaskReport {
        do { try context.check() } catch { return stoppedReport(error) }
        guard force || IOSBackgroundPreferences.autoSignInEnabled else {
            return IOSBackgroundTaskReport(lastResult: "disabled", runCount: 0, successCount: 0)
        }
        let outcome = IOSBackgroundCredentialStore.outcome()
        let credential = outcome.credential
        var report = nextReport(IOSBackgroundTaskID.signIn, ownerID: credential?.ownerHash, day: context.day)
        report.lastSignInDays = nil; report.lastSignInAt = nil
        guard let credential, credential.canSignIn else {
            report.lastResult = (IOSBackgroundCredentialIssue.from(outcome) ?? .partial).rawValue
            _ = persist(report, identifier: IOSBackgroundTaskID.signIn, context: context)
            return report
        }
        let value = await IOSBackgroundClient.shared.signIn(credential: credential, context: context)
        do { try context.check() } catch { return stoppedReport(error) }
        var notify: (String, String)?
        switch value {
        case let .success(result):
            if result.signed {
                report.lastResult = result.repeated ? "already_signed" : "signed"
                report.lastSignInDays = result.days
                report.lastSignInAt = nowMs()
                report.successCount += 1
                if IOSBackgroundPreferences.taskNotifyEnabled {
                    notify = (result.repeated ? IOSBackgroundStrings.signInAlreadyTitle : IOSBackgroundStrings.signInDoneTitle,
                              result.days.map { IOSBackgroundStrings.signInDays($0) } ?? IOSBackgroundStrings.signInDoneBody)
                }
            } else { report.lastResult = "rejected" }
        case let .failure(error): report.lastResult = error.code
        }
        guard persist(report, identifier: IOSBackgroundTaskID.signIn, context: context) else {
            return stoppedReport(IOSBackgroundError.cancelled)
        }
        if let message = notify {
            IOSBackgroundNotifier.post(id: "auto-signin", title: message.0, body: message.1, context: context)
        }
        IOSBackgroundLog.write("签到结束 \(report.lastResult)")
        return report
    }

    @discardableResult
    static func runRefresh(completion: @escaping (Bool) -> Void) -> Task<Void, Never> {
        Task {
            let report = await runRefresh()
            completion(!["cancelled", "budget_exhausted", "task_already_running"].contains(report.lastResult))
        }
    }

    static func runRefresh(budget: TimeInterval = 25) async -> IOSBackgroundTaskReport {
        do {
            return try await withRun(source: .system(IOSBackgroundTaskID.refresh), budget: budget) { context in
                await runRefresh(context: context)
            }
        } catch { return stoppedReport(error) }
    }

    static func runRefresh(context: IOSBackgroundRunContext) async -> IOSBackgroundTaskReport {
        do { try context.check() } catch { return stoppedReport(error) }
        let outcome = IOSBackgroundCredentialStore.outcome()
        let credential = outcome.credential
        let previous = IOSBackgroundScheduler.report(IOSBackgroundTaskID.refresh)
        var report = nextReport(IOSBackgroundTaskID.refresh, ownerID: credential?.ownerHash, day: context.day)
        guard let credential, credential.canSampleVehicle else {
            report.lastResult = (IOSBackgroundCredentialIssue.from(outcome) ?? .partial).rawValue
            _ = persist(report, identifier: IOSBackgroundTaskID.refresh, context: context)
            return report
        }
        let value = await IOSBackgroundClient.shared.vehicleSample(credential: credential, context: context)
        do { try context.check() } catch { return stoppedReport(error) }
        var notify: (String, String)?
        var acceptedSample: IOSBackgroundClient.VehicleSample?
        switch value {
        case let .success(sample):
            report.lastResult = "ok"; report.lastSocPercent = sample.socPercent
            // 缺测不能抹掉上一份明确状态，否则 true→nil→false 会漏掉充电结束。
            if let charging = sample.charging { report.lastCharging = charging }
            report.successCount += 1
            if let current = sample.charging, let last = previous.lastCharging, current != last,
               previous.ownerID == credential.ownerHash, IOSBackgroundPreferences.chargeNotifyEnabled {
                notify = (current ? IOSBackgroundStrings.chargeStartTitle : IOSBackgroundStrings.chargeStopTitle,
                          sample.socPercent.map { IOSBackgroundStrings.chargeSoc($0) } ?? IOSBackgroundStrings.chargeSocUnknown)
            }
            if IOSBackgroundRunCoordinator.shared.commit(context, {
                IOSBackgroundHistory.append(sample: sample, credential: credential, context: context)
            }) { acceptedSample = sample }
        case let .failure(error): report.lastResult = error.code
        }
        guard persist(report, identifier: IOSBackgroundTaskID.refresh, context: context) else {
            return stoppedReport(IOSBackgroundError.cancelled)
        }
        if let sample = acceptedSample {
            await MainActor.run {
                // 结果已经记账，仍需检查凭据 epoch；finish 后 canDeliver 仍能识别撤销。
                guard context.canDeliver, IOSBackgroundCredentialStore.load() == credential else { return }
                IOSSystemSurfacesService.acceptBackgroundSample(sample, credential: credential, context: context)
            }
        }
        if let message = notify {
            IOSBackgroundNotifier.post(id: "charge-change", title: message.0, body: message.1, context: context)
        }
        IOSBackgroundLog.write("采样结束 \(report.lastResult)")
        return report
    }

    static func runDailyTasks(force: Bool = false, signInDone: Bool = false,
                              budget: TimeInterval = 25, ownerID: String? = nil,
                              source: IOSBackgroundRunSource = .system(IOSBackgroundTaskID.dailyTasks)) async -> IOSDailyTasksReport {
        do {
            return try await withRun(source: source, budget: budget) { context in
                if let ownerID, IOSBackgroundCredentialStore.load()?.ownerHash != ownerID {
                    throw IOSBackgroundError.cancelled
                }
                return await runDailyTasks(force: force, signInDone: signInDone, context: context)
            }
        } catch {
            var report = IOSDailyTasksReport(); report.signInDone = signInDone
            report.result = IOSDailyTasksClient.code(of: error)
            report.budgetExhausted = report.result == "budget_exhausted"
            return report
        }
    }

    static func runDailyTasks(force: Bool, signInDone: Bool, context: IOSBackgroundRunContext) async -> IOSDailyTasksReport {
        var report = IOSDailyTasksReport(); report.signInDone = signInDone
        do { try context.check() } catch { report.result = IOSDailyTasksClient.code(of: error); return report }
        guard force || IOSBackgroundPreferences.autoDailyTasksEnabled else {
            report.skipped = ["每日任务"]; report.result = "disabled"
            return report
        }
        let outcome = IOSBackgroundCredentialStore.outcome()
        let credential = outcome.credential
        if let credential, credential.canRunDailyTasks {
            report = await IOSDailyTasksClient.shared.run(credential: credential,
                signInDone: signInDone || signInIsCurrent(ownerID: credential.ownerHash, day: context.day), context: context)
        } else {
            report.result = (IOSBackgroundCredentialIssue.from(outcome) ?? .partial).rawValue
            report.skipped = ["每日任务"]
        }
        do { try context.check() } catch { report.result = IOSDailyTasksClient.code(of: error); return report }
        var value = nextReport(IOSBackgroundTaskID.dailyTasks, ownerID: credential?.ownerHash, day: context.day)
        value.lastResult = report.result; value.lastDailyDone = report.doneCount
        value.lastDailyTotal = report.totalCount; value.lastDailySummary = summary(report)
        if report.result == "ok" { value.successCount += 1 }
        guard persist(value, identifier: IOSBackgroundTaskID.dailyTasks, context: context) else {
            report.result = "cancelled"; return report
        }
        IOSBackgroundLog.write("每日任务结束 \(summary(report)) result=\(report.result)")
        // 完成通知必须来自最后一次完整服务端复核；初读空列表、本地写成功都不是证据。
        if IOSBackgroundPreferences.taskNotifyEnabled, report.serverVerifiedAll,
           report.result == "ok", report.doneCount == report.totalCount {
            IOSBackgroundNotifier.post(id: "daily-tasks", title: "每日任务完成", body: summary(report), context: context)
        }
        return report
    }

    static func signInIsCurrent(ownerID: String?, day: String) -> Bool {
        guard let ownerID else { return false }
        let value = IOSBackgroundScheduler.report(IOSBackgroundTaskID.signIn)
        return value.ownerID == ownerID && value.day == day && value.lastSignInAt != nil
            && ["signed", "already_signed"].contains(value.lastResult)
    }

    static func beijingDay(_ date: Date) -> String { IOSBackgroundCalendar.beijingDay(date) }

    static func summary(_ report: IOSDailyTasksReport) -> String {
        var parts = ["今日 \(report.doneCount)/\(report.totalCount)"]
        if report.doneCount > 0 { parts.append("服务端确认 \(report.doneCount) 项") }
        if !report.failed.isEmpty { parts.append("失败：" + report.failed.map { $0.name }.joined(separator: "、")) }
        if report.budgetExhausted { parts.append("时间用尽，剩余项下次再跑") }
        if report.result == "credential_partial" { parts.append("请重新授权以补全账号 id") }
        return parts.joined(separator: " · ")
    }

    private static func stoppedReport(_ error: Error) -> IOSBackgroundTaskReport {
        IOSBackgroundTaskReport(lastResult: IOSDailyTasksClient.code(of: error), runCount: 0, successCount: 0)
    }

    private static func nextReport(_ identifier: String, ownerID: String?, day: String) -> IOSBackgroundTaskReport {
        var value = IOSBackgroundScheduler.report(identifier)
        if value.ownerID != ownerID {
            value.lastSocPercent = nil; value.lastCharging = nil
        }
        value.ownerID = ownerID; value.day = day
        value.lastRunAt = nowMs(); value.runCount += 1
        return value
    }

    private static func persist(_ value: IOSBackgroundTaskReport, identifier: String, context: IOSBackgroundRunContext) -> Bool {
        IOSBackgroundRunCoordinator.shared.commit(context) {
            IOSBackgroundScheduler.record({ $0 = value }, identifier: identifier)
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
    static func post(id: String, title: String, body: String, sound: Bool = true,
                     context: IOSBackgroundRunContext? = nil) {
        guard context?.canDeliver != false else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard context?.canDeliver != false else { return }
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
                guard context?.canDeliver != false else { return }
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

    // 旧版队列可能含停充/未知点；只过滤待合并队列，不碰已经存下的历史档案。
    private static func chargingSamples(_ data: Data) -> [Sample] {
        ((try? JSONDecoder().decode([Sample].self, from: data)) ?? []).filter {
            $0.charging == true && $0.socPercent.isFinite && (0...100).contains($0.socPercent)
        }
    }

    static func append(_ sample: Sample, context: IOSBackgroundRunContext? = nil) {
        guard sample.charging == true, sample.socPercent.isFinite,
              (0...100).contains(sample.socPercent) else { return }
        queue.async {
            guard context?.canDeliver != false else { return }
            guard let url = fileURL else { return }
            var items = (try? Data(contentsOf: url)).map { chargingSamples($0) } ?? []
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
            return chargingSamples(data)
        }
    }

    /// 只读不删，供状态页显示「有几个后台点待合并」。
    static func count() -> Int {
        queue.sync {
            guard let url = fileURL, let data = try? Data(contentsOf: url) else { return 0 }
            return chargingSamples(data).count
        }
    }
}

enum IOSBackgroundHistory {
    static func append(sample: IOSBackgroundClient.VehicleSample, credential: IOSBackgroundCredential,
                       context: IOSBackgroundRunContext) {
        // 只把明确正在充电的样本排进前台合并队列，避免非充电时的电量点占用本机空间。
        guard sample.charging == true, let soc = sample.socPercent, soc >= 0, soc <= 100 else { return }
        IOSBackgroundSampleQueue.append(IOSBackgroundSampleQueue.Sample(
            vin: credential.vin, capturedAt: sample.capturedAt,
            socPercent: soc, charging: sample.charging), context: context)
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
