import Foundation
import AppIntents
import UIKit

// 凭据问题的用户可读说明，以及打开 App 自动同步凭据的授权 intent。
//
// 旧 schema、权限不完整与钥匙串访问失败使用不同错误码，
// 让快捷指令能说明下一步操作。凭据来自当前网页会话；
// 打开 App 后由网页自动同步，无需进入后台任务页或再次确认。

/// 把凭据错误码翻译成人话 + 下一步动作。
///
/// 供快捷指令与原生状态回执共用，统一说明打开 App 自动同步凭据的恢复方式。
enum ZeehoCredentialIssueText {
    /// 哪些码属于「凭据问题」而不是「网络/服务端问题」。
    static func isCredentialIssue(_ code: String) -> Bool {
        switch code {
        case "no_credential", "credential_decode_failed", "credential_incomplete",
             "credential_partial", "keychain_locked", "keychain_unavailable":
            return true
        default:
            return false
        }
    }

    /// 一句「是什么 + 怎么办」。**每条都要能指导动作**，不能只描述现象。
    static func text(_ code: String) -> String {
        switch code {
        case "no_credential":
            return "还没同步后台凭据。打开几何面板，登录并选择车辆后会自动同步，也可运行「授权后台任务」快捷指令打开 App"
        case "credential_decode_failed":
            // 旧版本凭据 schema 变了。新版已能兼容解码，走到这里说明数据真的坏了。
            return "后台凭据格式无法识别，请打开几何面板，登录并选择车辆后会自动重新同步"
        case "credential_incomplete":
            return "后台凭据不完整，请打开几何面板，登录并选择车辆后会自动补全"
        case "credential_partial":
            // 只有单一域可用：采样或签到其中一个会一直失败。
            return "后台凭据只同步了部分权限，请打开几何面板自动补全"
        case "keychain_locked":
            // 常见于锁屏后台唤醒：设备还没解锁过一次，钥匙串读不到。
            // 不是用户操作问题，下次解锁后会自己好。
            return "设备锁屏中暂时读不到后台凭据，解锁后再试即可"
        case "keychain_unavailable":
            return "系统拒绝了钥匙串访问（重装或重签后常见），请解锁并打开几何面板自动重新同步"
        default:
            return code
        }
    }
}

// MARK: - 授权 intent

/// 在快捷指令 / Siri 里打开 App，自动同步当前账号与车辆的后台凭据。
///
/// 凭据由前台网页会话交给原生保存；打开 App 本身不会执行签到或每日任务。
@available(iOS 17.0, *)
struct ZeehoGrantBackgroundIntent: AppIntent {
    static var title: LocalizedStringResource = "授权后台任务"
    static var description = IntentDescription(
        "打开几何面板，登录并选择车辆后会自动同步后台凭据，无需再次确认。打开 App 不会执行签到或每日任务。")
    /// 必须前台：凭据来自当前网页会话。
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 网页通过 background.credential.sync 自动提交凭据；intent 只负责打开 App。
        // openAppWhenRun 由系统拉起 App，不做后台 URL scheme 自唤起。
        return .result(dialog: IntentDialog(stringLiteral:
            "已打开几何面板。登录并选择车辆后会自动同步后台凭据，无需再次确认；本次打开不会执行签到或每日任务。"))
    }
}

// MARK: - 后台状态查询

/// 查询后台任务的实际状态（是否已授权、上次跑得怎么样、下次该怎么修）。
///
/// 这条补上了「用户配了自动化但不知道有没有生效」的空白：
/// 面板能看，但自动化跑完的那一刻用户不在面板里。
@available(iOS 17.0, *)
struct ZeehoBackgroundStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "查询后台任务状态"
    static var description = IntentDescription(
        "查看自动签到与车况补采是否已授权、上次运行结果。只读本地记录，不会联网。")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var parts: [String] = []
        // 凭据状态优先说：它决定了后面两条任务能不能跑。
        let outcome = IOSBackgroundCredentialStore.outcome()
        switch outcome {
        case .ready(let credential):
            let scopes = credential.grantedScopes
            let scopeText = scopes.contains("app") && scopes.contains("h5")
                ? "已授权"
                : (scopes.isEmpty ? "未授权" : "只授权了" + scopes.joined(separator: "/"))
            parts.append(scopeText)
        case .missing:
            parts.append("尚未授权后台任务")
        case .unusable:
            // 直接用 outcome 映射，不再手工重建一个 .unusable 包回去。
            let issue = IOSBackgroundCredentialIssue.from(outcome)
            parts.append("凭据不可用：" + ZeehoCredentialIssueText.text(issue?.rawValue ?? "credential_incomplete"))
        }
        // 两条任务各说一句上次结果；从没跑过就说「还没跑过」，不编时间。
        for (identifier, label) in [(IOSBackgroundTaskID.signIn, "签到"),
                                    (IOSBackgroundTaskID.refresh, "车况补采")] {
            let report = IOSBackgroundScheduler.report(identifier)
            switch report.lastResult {
            case "never":
                parts.append("\(label)还没跑过")
            case "ok", "signed", "already_signed":
                parts.append("\(label)上次成功")
            default:
                let detail = ZeehoCredentialIssueText.isCredentialIssue(report.lastResult)
                    ? ZeehoCredentialIssueText.text(report.lastResult)
                    : report.lastResult
                parts.append("\(label)上次失败：\(detail)")
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: "，")))
    }
}
