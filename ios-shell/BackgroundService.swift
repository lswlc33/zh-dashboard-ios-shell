import Foundation
import UIKit
import ZeehoSystemShared

/// 桥参数校验失败。
///
/// 必须在**文件级**、且不是 private：`handle(method:args:reply:)` 是协议要求的
/// internal 方法，它 throws 的类型若是 private，Swift 会报
/// "method must be declared private because its parameter uses a private type"。
struct BackgroundArgumentError: Error { let code: String; init(_ code: String) { self.code = code } }

// 后台能力对网页暴露的桥。
// 网页侧只能做三件事：
//   1) `background.status` 读真实状态（含「系统是否真的会跑」的诚实说明）；
//   2) `background.credential` 授权后台凭据（网页把当前账号的 token 与签名密钥交出去）；
//   3) `background.samples.take` 取走后台补的电量点。
//
// 前台进入已保存的账号/车辆后自动同步后台凭据；保存动作仍校验原生会话与存档，
// 不会因为授权而执行签到或每日任务。旧手动授权入口保留供旧网页兼容。
//
// 标 iOS 13：内部引用的 IOSBackgroundScheduler 是 13.0 起，同一份下限。
@available(iOS 13.0, *)
final class IOSBackgroundService: NSObject, IOSBridgeService, IOSBridgeCancellableService {
    let methods = ["background.status", "background.credential", "background.credential.clear",
                   "background.samples.take", "background.schedule", "background.notify",
                   "background.tasks.run", "background.tasks.status", "background.credential.v2",
                   "background.credential.sync"]

    // 不能用 `private typealias`：handle(method:args:reply:) 是协议要求的 internal
    // 方法，签名里出现 private 类型会被拒（CI 实测 "method must be declared private
    // because its parameter uses a private type"）。
    typealias Reply = (Any?, String?) -> Void
    private let presenterProvider: () -> UIViewController?
    private var pendingConfirmation: (() -> Void)?
    private var jobID = UUID()
    private var scopeProvider: (() -> IOSRideScope?)?
    private let webOwner = UUID()
    private var dailyTaskID: UUID?
    private var activeDailyTask: Task<Void, Never>?
    private let dailyTaskLock = NSLock()

    init(presenter: @escaping () -> UIViewController?) {
        presenterProvider = presenter
        super.init()
    }

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        scopeProvider = provider
    }

    func navigationChanged() {
        jobID = UUID()
        pendingConfirmation = nil
        cancelDailyTask()
    }

    func applicationBackgrounded() {
        jobID = UUID()
        pendingConfirmation = nil
        cancelDailyTask()
    }

    func cancel(method: String, args: [Any]) {
        if method == "background.credential.sync" { jobID = UUID() }
        pendingConfirmation = nil
        if method == "background.tasks.run" { cancelDailyTask() }
    }

    private func cancelDailyTask() {
        dailyTaskLock.lock()
        let task = activeDailyTask
        activeDailyTask = nil; dailyTaskID = nil
        dailyTaskLock.unlock()
        IOSBackgroundRunCoordinator.shared.cancelWeb(webOwner)
        task?.cancel()
    }

    private func installDailyTask(_ task: Task<Void, Never>, id: UUID) {
        dailyTaskLock.lock()
        let current = dailyTaskID == id
        if current { activeDailyTask = task }
        dailyTaskLock.unlock()
        if !current { task.cancel() }
    }

    private func finishDailyTask(_ id: UUID) -> Bool {
        dailyTaskLock.lock()
        defer { dailyTaskLock.unlock() }
        guard dailyTaskID == id else { return false }
        activeDailyTask = nil; dailyTaskID = nil
        return true
    }

    func handle(method: String, args: [Any], reply: @escaping Reply) {
        do {
            switch method {
            case "background.status":
                try requireEmpty(args)
                reply(statusPayload(), nil)
            case "background.credential":
                try grant(args, reply: reply)
            case "background.credential.sync":
                try syncCredential(args, reply: reply)
            case "background.credential.clear":
                try requireEmpty(args)
                // 先撤销本轮授权；Keychain 失败也不能跳过小组件与后台任务的清理。
                let removed = IOSBackgroundRunCoordinator.shared.clearCredential()
                cancelDailyTask()
                // 小组件那份投影必须一起清：只清 Keychain 会让扩展继续用旧 token 打接口，
                // 用户点了「清除凭据」却发现小组件还在联网，属于权限与预期双重不符。
                WidgetCredentialStore.clear()
                WidgetFetchCache.clear()
                IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.refresh)
                IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.processing)
                IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.signIn)
                IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.dailyTasks)
                IOSSystemSurfacesService.backgroundCredentialCleared()
                guard removed else { throw BackgroundArgumentError("keychain_unavailable") }
                IOSBackgroundLog.write("后台凭据已清除")
                reply(statusPayload(), nil)
            case "background.samples.take":
                try requireEmpty(args)
                let samples = IOSBackgroundSampleQueue.take()
                reply(["ok": true, "samples": samples.map { sampleJSON($0) }, "count": samples.count], nil)
            case "background.schedule":
                try schedule(args, reply: reply)
            case "background.notify":
                try notify(args, reply: reply)
            case "background.tasks.status":
                try requireEmpty(args)
                reply(tasksStatusPayload(), nil)
            case "background.tasks.run":
                try tasksRun(args, reply: reply)
            default:
                reply(nil, "unsupported_method")
            }
        } catch let error as BackgroundArgumentError {
            reply(nil, error.code)
        } catch {
            reply(nil, "invalid_args")
        }
    }

    // MARK: - 状态

    /// 状态必须是「诚实的」：后台唤醒没有保证这件事要直接写在回执里，
    /// 而不是让界面自己编一句「每小时自动」。
    ///
    /// 通知授权状态不在这里读：`getNotificationSettings` 是异步的，为了它阻塞
    /// 桥回执会让状态页卡 0.2 秒。授权状态由既有的 `notifications.status` 负责，
    /// 界面把两个回执拼起来即可。
    private func statusPayload() -> [String: Any] {
        // 用 outcome() 而不是 load()：界面需要区分「从没授权」与「授权过但读不到」。
        let outcome = IOSBackgroundCredentialStore.outcome()
        let credential = outcome.credential
        let issue = IOSBackgroundCredentialIssue.from(outcome)
        let signIn = IOSBackgroundScheduler.report(IOSBackgroundTaskID.signIn)
        let refresh = IOSBackgroundScheduler.report(IOSBackgroundTaskID.refresh)
        return [
            "ok": true,
            "supported": true,
            // 网页只在此 schema version 明确匹配时附带 uid/autoDailyTasks；旧壳不会误拒额外字段。
            "credentialSchemaVersion": 2,
            // 调度能力：BGTaskScheduler 存在不代表系统会跑，这里如实分开两个字段。
            "schedulerAvailable": true,
            "deliveryGuaranteed": false,
            "explain": "iOS 没有定时后台执行机制：系统按你的使用习惯决定何时唤醒，可能数小时才跑一次，也可能完全不跑。上滑关闭 App 后将不再后台运行。",
            "autoSignInEnabled": IOSBackgroundPreferences.autoSignInEnabled,
            "chargeNotifyEnabled": IOSBackgroundPreferences.chargeNotifyEnabled,
            "taskNotifyEnabled": IOSBackgroundPreferences.taskNotifyEnabled,
            // 每日任务：写操作，默认关；用户显式打开才让系统定时跑。
            "autoDailyTasksEnabled": IOSBackgroundPreferences.autoDailyTasksEnabled,
            "dailyTasksScheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.dailyTasks),
            "credentialPresent": credential != nil,
            // 凭据异常时给出可据以行动的原因码（null 表示没问题）。
            // 只报 credentialPresent=false 会让用户分不清是没授权还是读不到。
            "credentialIssue": issue?.rawValue ?? NSNull(),
            "credentialIssueText": issue.map { ZeehoCredentialIssueText.text($0.rawValue) } ?? "",
            // 授权了哪几个域：只有 app 域时签到会失败、只有 h5 域时采样会失败，
            // 界面据此提示「请补全授权」，而不是笼统说已授权。
            "credentialScopes": credential?.grantedScopes ?? [],
            "credentialCanSignIn": credential?.canSignIn ?? false,
            "credentialCanSample": credential?.canSampleVehicle ?? false,
            // 每日任务可跑的前提是 app 域 + 内部 uid，缺一个都会在界面上提示补全授权。
            "credentialCanRunTasks": credential?.canRunDailyTasks ?? false,
            "credentialVIN": credential?.vin ?? "",
            "credentialAccount": credential?.accountID ?? "",
            "credentialUpdatedAt": credential?.updatedAt ?? 0,
            "signInScheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.signIn),
            "refreshScheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.refresh),
            "pendingSamples": IOSBackgroundSampleQueue.count(),
            "signIn": reportJSON(signIn),
            "refresh": reportJSON(refresh),
            "dailyTasks": reportJSON(IOSBackgroundScheduler.report(IOSBackgroundTaskID.dailyTasks),
                                      currentOwnerID: credential?.ownerHash,
                                      currentDay: IOSBackgroundRunner.beijingDay(Date()))
        ]
    }

    /// 每日任务的状态回执。与 `background.status` 分开，因为网页只想刷进度时
    /// 不必把凭据域、调度状态一起拉一遍。
    private func tasksStatusPayload() -> [String: Any] {
        let outcome = IOSBackgroundCredentialStore.outcome()
        let credential = outcome.credential
        let report = IOSBackgroundScheduler.report(IOSBackgroundTaskID.dailyTasks)
        let today = IOSBackgroundRunner.beijingDay(Date())
        let signInToday = IOSBackgroundRunner.signInIsCurrent(ownerID: credential?.ownerHash, day: today)
        let dailyIsCurrent = report.day == today && report.ownerID == credential?.ownerHash
        return [
            "ok": true,
            "canRun": credential?.canRunDailyTasks ?? false,
            "credentialIssue": IOSBackgroundCredentialIssue.from(outcome)?.rawValue ?? NSNull(),
            "enabled": IOSBackgroundPreferences.autoDailyTasksEnabled,
            "scheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.dailyTasks),
            "lastRunAt": report.lastRunAt ?? 0,
            "lastResult": report.lastResult,
            "done": dailyIsCurrent ? (report.lastDailyDone ?? 0) : 0,
            "total": dailyIsCurrent ? (report.lastDailyTotal ?? 4) : 4,
            "summary": dailyIsCurrent ? (report.lastDailySummary ?? "") : "",
            "signInToday": signInToday,
            "runCount": report.runCount,
            "successCount": report.successCount
        ]
    }

    /// 网页主动跑一次每日任务（面板上的「立即执行」按钮）。
    ///
    /// 与快捷指令的区别：这里在前台，可以等到真实结果再回执，
    /// 所以预算给足 25s 并直接返回逐项明细。
    private func tasksRun(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count <= 1 else { throw BackgroundArgumentError("invalid_args") }
        let value = args.first as? [String: Any] ?? [:]
        let allowed: Set<String> = ["confirm"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        // 会真的往广场发一条动态，必须用户显式确认（网页已经弹过一次，这里是第二道）。
        guard (value["confirm"] as? Bool) == true else { throw BackgroundArgumentError("confirmation_required") }
        let ownerID = IOSBackgroundCredentialStore.load()?.ownerHash
        let signInToday = IOSBackgroundRunner.signInIsCurrent(ownerID: ownerID, day: IOSBackgroundRunner.beijingDay(Date()))
        let id = UUID()
        dailyTaskLock.lock()
        guard dailyTaskID == nil else { dailyTaskLock.unlock(); throw BackgroundArgumentError("task_already_running") }
        dailyTaskID = id
        dailyTaskLock.unlock()
        let task = Task { [weak self] in
            guard let self else { reply(nil, "service_closed"); return }
            let report = await IOSBackgroundRunner.runDailyTasks(force: true, signInDone: signInToday,
                budget: 25, ownerID: ownerID, source: .web(self.webOwner))
            let current = self.finishDailyTask(id)
            guard current, !Task.isCancelled, report.result != "cancelled" else { reply(nil, "cancelled"); return }
            if report.result == "task_already_running" { reply(nil, report.result); return }
            reply([
                "ok": true,
                "result": report.result,
                "done": report.doneCount,
                "total": report.totalCount,
                "completed": report.completed,
                "skipped": report.skipped,
                "failed": report.failed.map { ["name": $0.name, "reason": $0.reason] },
                "budgetExhausted": report.budgetExhausted,
                "summary": IOSBackgroundRunner.summary(report)
            ], nil)
        }
        installDailyTask(task, id: id)
    }

    private func reportJSON(_ value: IOSBackgroundTaskReport, currentOwnerID: String? = nil,
                            currentDay: String? = nil) -> [String: Any] {
        let dailyCurrent = currentOwnerID != nil && value.ownerID == currentOwnerID && value.day == currentDay
        var payload: [String: Any] = ["lastRunAt": value.lastRunAt ?? 0,
                                      "lastResult": value.lastResult,
                                      "runCount": value.runCount,
                                      "successCount": value.successCount]
        if let soc = value.lastSocPercent { payload["lastSocPercent"] = soc }
        if let charging = value.lastCharging { payload["lastCharging"] = charging }
        if let days = value.lastSignInDays { payload["lastSignInDays"] = days }
        if let done = value.lastDailyDone, dailyCurrent { payload["lastDailyDone"] = done }
        if let total = value.lastDailyTotal, dailyCurrent { payload["lastDailyTotal"] = total }
        if let summary = value.lastDailySummary, dailyCurrent { payload["lastDailySummary"] = summary }
        return payload
    }

    private func sampleJSON(_ sample: IOSBackgroundSampleQueue.Sample) -> [String: Any] {
        var payload: [String: Any] = ["vin": sample.vin, "capturedAt": sample.capturedAt,
                                      "socPercent": sample.socPercent]
        if let charging = sample.charging { payload["charging"] = charging }
        return payload
    }

    // MARK: - 授权凭据

    /// 把小组件取数需要的最小凭据投影进 App Group。
    ///
    /// 静默失败（App Group 未授权时容器为空），**绝不因此让后台授权失败**：
    /// 小组件自己拉是增强路径，拿不到就退回原来的「读宿主快照」。
    static func mirrorWidgetCredential(accountID: String, vin: String, token: String,
                                       appID: String, appSecret: String) {
        guard SystemSnapshotStore.isAvailable(),
              let owner = IOSSystemSurfacesService.widgetOwner(accountID: accountID, vin: vin) else { return }
        let value = WidgetCredential(ownerID: owner.ownerIdentifierString, vin: vin, token: token,
                                     appID: appID, appSecret: appSecret,
                                     updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        _ = WidgetCredentialStore.save(value)
    }

    private func syncCredential(_ args: [Any], reply: @escaping Reply) throws {
        guard UIApplication.shared.applicationState != .background,
              args.count == 1, let value = args[0] as? [String: Any],
              let selected = scopeProvider?(), selected.valid else { throw BackgroundArgumentError("authorized_vehicle_required") }
        let allowed: Set<String> = ["accountId", "vin", "token", "signinToken", "uid", "appId", "appSecret", "h5AppId", "h5Secret", "scope"]
        guard Set(value.keys).isSubset(of: allowed),
              let frame = value["scope"] as? [String: Any],
              frame["accountId"] as? String == selected.accountID,
              frame["vin"] as? String == selected.vin,
              String(IOSBridgePolicy.integer(frame["epoch"]) ?? -1) == selected.generation,
              value["accountId"] as? String == selected.accountID,
              value["vin"] as? String == selected.vin else { throw BackgroundArgumentError("stale_session") }
        let token = try text(value["token"], limit: 4096)
        let navigation = jobID
        let signinToken = try optionalText(value["signinToken"], limit: 4096) ?? token
        guard signinToken == token else { throw BackgroundArgumentError("stale_session") }
        let credential = IOSBackgroundCredential(accountID: selected.accountID, vin: selected.vin,
            token: token, signinToken: signinToken,
            appSecret: try optionalText(value["appSecret"], limit: 512) ?? "",
            h5Secret: try optionalText(value["h5Secret"], limit: 512) ?? "",
            appID: try optionalText(value["appId"], limit: 128) ?? "",
            h5AppID: try optionalText(value["h5AppId"], limit: 128) ?? "",
            uid: try optionalText(value["uid"], limit: 64) ?? "", updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        guard credential.isValid else { throw BackgroundArgumentError("credential_incomplete") }
        IOSStore.shared.snapshot { [weak self] snapshot in
            guard let self, self.jobID == navigation, self.scopeProvider?() == selected,
                  UIApplication.shared.applicationState != .background,
                  snapshot.readError == nil,
                  let text = snapshot.values["zeeho.accounts.v1"], let data = text.data(using: .utf8),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = document["accounts"] as? [[String: Any]],
                  let account = accounts.first(where: { $0["id"] as? String == selected.accountID }),
                  account["token"] as? String == token,
                  ((account["uid"] as? String).map { $0.isEmpty || $0 == credential.uid } ?? true),
                  (IOSBridgePolicy.integer(account["invalidAt"]) ?? 0) <= 0 else {
                reply(nil, "stale_session"); return
            }
            // 同一份材料不重复切换 epoch：快捷指令可能正执行，前台打开不能无故取消它。
            let previous = IOSBackgroundCredentialStore.load()
            let changed = previous?.accountID != credential.accountID || previous?.vin != credential.vin
                || previous?.token != credential.token || previous?.signinToken != credential.signinToken
                || previous?.uid != credential.uid || previous?.appID != credential.appID
                || previous?.appSecret != credential.appSecret || previous?.h5AppID != credential.h5AppID
                || previous?.h5Secret != credential.h5Secret
            // 2026-11-25：小组件那份最小投影**先写**，不等钥匙串。
            //
            // 重签环境下 keychain-access-group 经常对不上（自签描述文件不带我们的组），
            // replaceCredential 会失败并 `return`，于是后面这行镜像永远轮不到 ——
            // 扩展拿不到凭据就只能读宿主快照，新用户看到的就是「小组件没数据」，
            // 而钥匙串正常的设备一切正常（用户实测：自己能看、新用户看不到）。
            // 两份凭据职责不同：Keychain 那份给后台任务，App Group 这份只给小组件取数；
            // 前者失败不该连坐后者。镜像失败本身仍是静默的（App Group 不可用时 no-op）。
            Self.mirrorWidgetCredential(accountID: credential.accountID, vin: credential.vin,
                token: credential.token, appID: credential.appID, appSecret: credential.appSecret)
            if changed && !IOSBackgroundRunCoordinator.shared.replaceCredential(credential) {
                reply(nil, "keychain_unavailable"); return
            }
            IOSBackgroundScheduler.shared.scheduleAll()
            reply(self.statusPayload(), nil)
        }
    }

    private func grant(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count == 1, let value = args[0] as? [String: Any] else { throw BackgroundArgumentError("invalid_args") }
        let allowed: Set<String> = ["accountId", "vin", "token", "signinToken", "appId", "appSecret",
                                    "h5AppId", "h5Secret", "autoSignIn", "uid", "autoDailyTasks"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        let accountID = try text(value["accountId"], limit: 128)
        let vin = try text(value["vin"], limit: 128)
        let token = try optionalText(value["token"], limit: 4096) ?? ""
        let signinToken = try optionalText(value["signinToken"], limit: 4096) ?? ""
        // **每个域独立可选**：面板某一版本只导出 app 域密钥（或只有 h5 域）时，
        // 旧实现用 `try text(...)` 强取会让整个授权直接失败，用户只会看到
        // 「当前面板版本不支持后台授权」这种含糊结果。缺失的域按空串存，
        // 由 canSampleVehicle / canSignIn 分别判定，缺哪半就只影响那半的功能。
        let appID = try optionalText(value["appId"], limit: 128) ?? ""
        let appSecret = try optionalText(value["appSecret"], limit: 512) ?? ""
        let h5AppID = try optionalText(value["h5AppId"], limit: 128) ?? ""
        let h5Secret = try optionalText(value["h5Secret"], limit: 512) ?? ""
        // 内部 uid：每日任务的两个接口（积分任务列表 / 我的动态）只认它。
        // 前端在授权时会带上当前账号的 uid；老面板不带就存空串，
        // canRunDailyTasks 会因此为 false，界面提示补全授权——绝不猜一个 uid。
        let uid = try optionalText(value["uid"], limit: 64) ?? ""
        var credential = IOSBackgroundCredential(
            accountID: accountID, vin: vin, token: token, signinToken: signinToken,
            appSecret: appSecret, h5Secret: h5Secret, appID: appID, h5AppID: h5AppID,
            uid: uid, updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        // 至少要有一个域可用才值得存；两个都不行说明调用方传错了。
        guard credential.isValid else { throw BackgroundArgumentError("credential_incomplete") }
        // 只导入一半时明确回给调用方，界面可以立刻提示「签到仍不可用」，
        // 而不是等用户下次跑快捷指令才发现。
        let scopes = credential.grantedScopes

        // 长期凭据必须二次确认：网页可能被注入脚本，不能让它在启动时静默写入。
        // 文案必须把两件事都说清楚：这份凭据同时供「后台自动任务」与「桌面小组件自己刷新」，
        // 用户点确认就是在授权这两条链路（小组件那条只是读车况展示）。
        confirm(title: "授权凭据",
                message: "将把当前账号的登录凭据与签名密钥保存到系统钥匙串：用于在你不在时自动签到、补采电量，并让桌面小组件可以自己刷新车况。凭据只留在这台设备，可随时在面板里清除。") { [weak self] approved in
            guard let self = self else { return }
            guard approved else {
                credential.clear()
                reply(["ok": true, "granted": false, "reason": "user_cancelled"], nil)
                return
            }
            // 2026-11-25：小组件那份最小投影必须**先写**，不能等钥匙串成功。
            // 重签包（自签描述文件）里 keychain-access-group 常对不上，replaceCredential
            // 会失败；以前它一 return，后面这行就永远轮不到，小组件只能退回读宿主快照 ——
            // 新用户看到的就是「卡片没数据」。两份凭据职责不同，前者失败不该连坐后者。
            Self.mirrorWidgetCredential(accountID: accountID, vin: vin, token: token,
                                        appID: appID, appSecret: appSecret)
            guard IOSBackgroundRunCoordinator.shared.replaceCredential(credential) else {
                credential.clear()
                reply(nil, "keychain_unavailable")
                return
            }
            self.cancelDailyTask()
            let auto = (value["autoSignIn"] as? Bool) ?? IOSBackgroundPreferences.autoSignInEnabled
            IOSBackgroundPreferences.autoSignInEnabled = auto
            // 每日任务是写操作（会真发动态），默认沿用用户已开的状态，绝不因为
            // 「这次授权带了 uid」就替用户把自动发帖打开。
            if let tasks = value["autoDailyTasks"] as? Bool {
                IOSBackgroundPreferences.autoDailyTasksEnabled = tasks
            }
            IOSBackgroundScheduler.shared.scheduleAll()
            IOSBackgroundLog.write("后台凭据已保存 autoSignIn=\(auto) scopes=\(scopes.joined(separator: "+"))")
            credential.clear()
            var payload = self.statusPayload()
            // partial=true 时界面应立刻提示补全；两个域都齐才是完整授权。
            payload["grantedScopes"] = scopes
            payload["partial"] = scopes.count < 2
            reply(payload, nil)
        }
    }

    // MARK: - 调度与开关

    private func schedule(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count == 1, let value = args[0] as? [String: Any] else { throw BackgroundArgumentError("invalid_args") }
        let allowed: Set<String> = ["autoSignIn", "chargeNotify", "taskNotify", "reschedule", "autoDailyTasks"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        if let flag = value["autoSignIn"] as? Bool {
            IOSBackgroundPreferences.autoSignInEnabled = flag
            if flag { IOSBackgroundScheduler.shared.reschedule(IOSBackgroundTaskID.signIn) }
            else { IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.signIn) }
        }
        if let flag = value["autoDailyTasks"] as? Bool {
            IOSBackgroundPreferences.autoDailyTasksEnabled = flag
            if flag { IOSBackgroundScheduler.shared.reschedule(IOSBackgroundTaskID.dailyTasks) }
            else { IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.dailyTasks) }
        }
        if let flag = value["chargeNotify"] as? Bool { IOSBackgroundPreferences.chargeNotifyEnabled = flag }
        if let flag = value["taskNotify"] as? Bool { IOSBackgroundPreferences.taskNotifyEnabled = flag }
        if (value["reschedule"] as? Bool) == true { IOSBackgroundScheduler.shared.scheduleAll() }
        reply(statusPayload(), nil)
    }

    /// 网页主动要求发一条本地通知（任务完成之类）。
    /// 走同一个 `dashboard.local.` 命名空间，网页能用 notifications.cancel 撤掉。
    private func notify(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count == 1, let value = args[0] as? [String: Any] else { throw BackgroundArgumentError("invalid_args") }
        let allowed: Set<String> = ["id", "title", "body"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        let id = try text(value["id"], limit: 80)
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil else {
            throw BackgroundArgumentError("invalid_args")
        }
        guard IOSBackgroundPreferences.taskNotifyEnabled else {
            reply(["ok": true, "posted": false, "reason": "disabled"], nil); return
        }
        let title = try text(value["title"], limit: 256)
        let body = try text(value["body"], limit: 4096)
        IOSBackgroundNotifier.post(id: id, title: title, body: body)
        reply(["ok": true, "posted": true], nil)
    }

    // MARK: - 确认框

    private func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        guard let presenter = presenterProvider(), presenter.presentedViewController == nil else {
            completion(false); return
        }
        let token = UUID()
        jobID = token
        pendingConfirmation = { completion(true) }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self] _ in
            guard let self = self, self.jobID == token else { return }
            self.pendingConfirmation = nil
            completion(false)
        })
        alert.addAction(UIAlertAction(title: IOSStrings.continueButton, style: .default) { [weak self] _ in
            guard let self = self, self.jobID == token, let action = self.pendingConfirmation else {
                completion(false); return
            }
            self.pendingConfirmation = nil
            action()
        })
        presenter.present(alert, animated: true)
    }

    // MARK: - 参数校验

    private func requireEmpty(_ args: [Any]) throws {
        guard args.isEmpty else { throw BackgroundArgumentError("invalid_args") }
    }

    private func text(_ value: Any?, limit: Int) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= limit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BackgroundArgumentError("invalid_args")
        }
        return text
    }

    private func optionalText(_ value: Any?, limit: Int) throws -> String? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let text = value as? String, text.isEmpty { return nil }
        return try text(value, limit: limit)
    }
}
