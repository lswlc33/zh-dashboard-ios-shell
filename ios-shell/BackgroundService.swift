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
// 授权必须**用户显式点按钮**才走到这里（网页用 ui.confirm 或自己的开关），
// 并且落 Keychain 前会再弹一次原生确认——后台凭据是长期有效的，不能由页面脚本
// 在启动时静默写入。
//
// 标 iOS 13：内部引用的 IOSBackgroundScheduler 是 13.0 起，同一份下限。
@available(iOS 13.0, *)
final class IOSBackgroundService: NSObject, IOSBridgeService, IOSBridgeCancellableService {
    let methods = ["background.status", "background.credential", "background.credential.clear",
                   "background.samples.take", "background.schedule", "background.notify"]

    // 不能用 `private typealias`：handle(method:args:reply:) 是协议要求的 internal
    // 方法，签名里出现 private 类型会被拒（CI 实测 "method must be declared private
    // because its parameter uses a private type"）。
    typealias Reply = (Any?, String?) -> Void
    private let presenterProvider: () -> UIViewController?
    private var pendingConfirmation: (() -> Void)?
    private var jobID = UUID()

    init(presenter: @escaping () -> UIViewController?) {
        presenterProvider = presenter
        super.init()
    }

    func navigationChanged() {
        // 换页面时撤销未完成的确认，避免用户在新页面里点确认却把旧页面的凭据写进去。
        pendingConfirmation = nil
    }

    func applicationBackgrounded() {
        pendingConfirmation = nil
    }

    func cancel(method: String, args: [Any]) {
        pendingConfirmation = nil
    }

    func handle(method: String, args: [Any], reply: @escaping Reply) {
        do {
            switch method {
            case "background.status":
                try requireEmpty(args)
                reply(statusPayload(), nil)
            case "background.credential":
                try grant(args, reply: reply)
            case "background.credential.clear":
                try requireEmpty(args)
                IOSBackgroundCredentialStore.remove()
                // 小组件那份投影必须一起清：只清 Keychain 会让扩展继续用旧 token 打接口，
                // 用户点了「清除凭据」却发现小组件还在联网，属于权限与预期双重不符。
                WidgetCredentialStore.clear()
                WidgetFetchCache.clear()
                IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.signIn)
                IOSBackgroundLog.write("凭据已清除，签到任务取消排队")
                reply(statusPayload(), nil)
            case "background.samples.take":
                try requireEmpty(args)
                let samples = IOSBackgroundSampleQueue.take()
                reply(["ok": true, "samples": samples.map { sampleJSON($0) }, "count": samples.count], nil)
            case "background.schedule":
                try schedule(args, reply: reply)
            case "background.notify":
                try notify(args, reply: reply)
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
            // 调度能力：BGTaskScheduler 存在不代表系统会跑，这里如实分开两个字段。
            "schedulerAvailable": true,
            "deliveryGuaranteed": false,
            "explain": "iOS 没有定时后台执行机制：系统按你的使用习惯决定何时唤醒，可能数小时才跑一次，也可能完全不跑。上滑关闭 App 后将不再后台运行。",
            "autoSignInEnabled": IOSBackgroundPreferences.autoSignInEnabled,
            "chargeNotifyEnabled": IOSBackgroundPreferences.chargeNotifyEnabled,
            "taskNotifyEnabled": IOSBackgroundPreferences.taskNotifyEnabled,
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
            "credentialVIN": credential?.vin ?? "",
            "credentialAccount": credential?.accountID ?? "",
            "credentialUpdatedAt": credential?.updatedAt ?? 0,
            "signInScheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.signIn),
            "refreshScheduled": IOSBackgroundScheduler.shared.isScheduled(IOSBackgroundTaskID.refresh),
            "pendingSamples": IOSBackgroundSampleQueue.count(),
            "signIn": reportJSON(signIn),
            "refresh": reportJSON(refresh)
        ]
    }

    private func reportJSON(_ value: IOSBackgroundTaskReport) -> [String: Any] {
        var payload: [String: Any] = ["lastRunAt": value.lastRunAt ?? 0,
                                      "lastResult": value.lastResult,
                                      "runCount": value.runCount,
                                      "successCount": value.successCount]
        if let soc = value.lastSocPercent { payload["lastSocPercent"] = soc }
        if let charging = value.lastCharging { payload["lastCharging"] = charging }
        if let days = value.lastSignInDays { payload["lastSignInDays"] = days }
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

    private func grant(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count == 1, let value = args[0] as? [String: Any] else { throw BackgroundArgumentError("invalid_args") }
        let allowed: Set<String> = ["accountId", "vin", "token", "signinToken", "appId", "appSecret",
                                    "h5AppId", "h5Secret", "autoSignIn"]
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
        var credential = IOSBackgroundCredential(
            accountID: accountID, vin: vin, token: token, signinToken: signinToken,
            appSecret: appSecret, h5Secret: h5Secret, appID: appID, h5AppID: h5AppID,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
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
            guard IOSBackgroundCredentialStore.save(credential) else {
                credential.clear()
                reply(nil, "keychain_unavailable")
                return
            }
            let auto = (value["autoSignIn"] as? Bool) ?? IOSBackgroundPreferences.autoSignInEnabled
            IOSBackgroundPreferences.autoSignInEnabled = auto
            IOSBackgroundScheduler.shared.scheduleAll()
            // 顺手把一份**最小投影**放进 App Group，让桌面小组件能自己拉车况
            // （官方 ZHWidgetExtension 的做法：扩展自带网络层，不依赖宿主存活）。
            // 两份凭据语义不同：Keychain 那份给后台任务用（长期、可被系统定时唤醒）；
            // App Group 这份只给小组件展示用（随前台会话刷新，清除时一起删）。
            // 必须在 credential.clear() 之前调用。
            Self.mirrorWidgetCredential(accountID: accountID, vin: vin, token: token,
                                        appID: appID, appSecret: appSecret)
            IOSBackgroundLog.write("后台凭据已保存 vin=\(vin) autoSignIn=\(auto) scopes=\(scopes.joined(separator: "+"))")
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
        let allowed: Set<String> = ["autoSignIn", "chargeNotify", "taskNotify", "reschedule"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        if let flag = value["autoSignIn"] as? Bool {
            IOSBackgroundPreferences.autoSignInEnabled = flag
            if flag { IOSBackgroundScheduler.shared.reschedule(IOSBackgroundTaskID.signIn) }
            else { IOSBackgroundScheduler.shared.cancel(IOSBackgroundTaskID.signIn) }
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
