import Foundation
import UIKit

// 后台能力对网页暴露的桥。
//
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

    private typealias Reply = (Any?, String?) -> Void
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
        let credential = IOSBackgroundCredentialStore.load()
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

    private func grant(_ args: [Any], reply: @escaping Reply) throws {
        guard args.count == 1, let value = args[0] as? [String: Any] else { throw BackgroundArgumentError("invalid_args") }
        let allowed: Set<String> = ["accountId", "vin", "token", "signinToken", "appId", "appSecret",
                                    "h5AppId", "h5Secret", "autoSignIn"]
        guard Set(value.keys).isSubset(of: allowed) else { throw BackgroundArgumentError("invalid_args") }
        let accountID = try text(value["accountId"], limit: 128)
        let vin = try text(value["vin"], limit: 128)
        let token = try text(value["token"], limit: 4096)
        let signinToken = try optionalText(value["signinToken"], limit: 4096) ?? ""
        let appID = try text(value["appId"], limit: 128)
        let appSecret = try text(value["appSecret"], limit: 512)
        let h5AppID = try text(value["h5AppId"], limit: 128)
        let h5Secret = try text(value["h5Secret"], limit: 512)
        var credential = IOSBackgroundCredential(
            accountID: accountID, vin: vin, token: token, signinToken: signinToken,
            appSecret: appSecret, h5Secret: h5Secret, appID: appID, h5AppID: h5AppID,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        guard credential.isValid else { throw BackgroundArgumentError("invalid_args") }

        // 长期凭据必须二次确认：网页可能被注入脚本，不能让它在启动时静默写入。
        confirm(title: "启用后台自动任务",
                message: "将把当前账号的登录凭据与签名密钥保存到系统钥匙串，用于在你不在时自动签到、补采电量。凭据只留在这台设备，可随时在面板里清除。") { [weak self] approved in
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
            IOSBackgroundLog.write("后台凭据已保存 vin=\(vin) autoSignIn=\(auto)")
            credential.clear()
            reply(self.statusPayload(), nil)
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

    private struct BackgroundArgumentError: Error { let code: String; init(_ code: String) { self.code = code } }

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
