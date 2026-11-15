import Foundation
import AppIntents
import UIKit

// 凭据问题的**用户可读翻译** + 「在快捷指令里直接授权」的 intent。
//
// ## 为什么需要这个文件
//
// 旧版本的经验：用户在快捷指令里跑「签到 + 采样」，得到一句
// 「车况采样失败（后台未导入后台凭据）」，但他在面板里明明点过授权。
// 三个独立原因被压成同一句话：
//
// 1. **旧 schema**：早版本存 Keychain 的 JSON 没有 `signinToken`/`h5Secret`/`h5AppID`，
//    合成的 `Codable` 解码整体失败 → 读出来是 nil → 报「未导入」；
// 2. **只导入一个域**：采样只需要 app 域密钥，旧 `isValid` 却要求 h5 域也齐；
// 3. **钥匙串访问被拒**：重签后 entitlement 变了，`SecItemCopyMatching` 返回
//    `errSecAuthFailed` / `errSecInteractionNotAllowed`，同样被当成「没有」。
//
// 现在这三类各自有独立错误码（`IOSBackgroundCredentialIssue`），这里负责把它们
// 翻译成「用户下一步该做什么」，而不是让用户对着一个机器码反复点授权。
//
// ## 为什么授权也做成 intent
//
// 用户配「个人自动化 → 特定时间」时，最常见的失败是「忘了先在面板里授权」。
// 如果授权只能在面板里点，那么每次换账号/重装后自动化都会静默失效，
// 用户还得回头翻设置。把授权做成一个 intent，可以直接放进自动化第一步，
// 或者让 Siri 一句话完成。**但授权必须在前台**：它要弹确认框，
// 而且凭据来自当前网页会话（`openAppWhenRun = true`）。

/// 把凭据错误码翻译成人话 + 下一步动作。
///
/// 单独成 enum 而不是塞进 intent：面板侧的 `background.js` 也要用同一套
/// 说法（它有自己的 `resultText`），两边文案必须对得上，否则用户会看到
/// 「快捷指令说 A、面板说 B」。
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
            return "还没授权后台任务。打开面板 → 后台任务 → 授权，或先运行一次「授权后台任务」快捷指令"
        case "credential_decode_failed":
            // 旧版本凭据 schema 变了。新版已能兼容解码，走到这里说明数据真的坏了。
            return "后台凭据格式无法识别，请在面板里清除后重新授权"
        case "credential_incomplete":
            return "后台凭据不完整，请在面板里重新授权一次"
        case "credential_partial":
            // 只有单一域可用：采样或签到其中一个会一直失败。
            return "后台凭据只导入了部分权限，请在面板里重新授权补全"
        case "keychain_locked":
            // 常见于锁屏后台唤醒：设备还没解锁过一次，钥匙串读不到。
            // 不是用户操作问题，下次解锁后会自己好。
            return "设备锁屏中暂时读不到后台凭据，解锁后再试即可"
        case "keychain_unavailable":
            return "系统拒绝了钥匙串访问（重装或重签后常见），请在面板里重新授权"
        default:
            return code
        }
    }
}

// MARK: - 授权 intent

/// 在快捷指令 / Siri 里完成后台任务授权。
///
/// 这条必须把 App 拉到前台：授权要弹系统确认框，凭据也来自当前网页会话
/// （`background.credential` 是网页侧收集的，原生不自己拼密钥）。
@available(iOS 17.0, *)
struct ZeehoGrantBackgroundIntent: AppIntent {
    static var title: LocalizedStringResource = "授权后台任务"
    static var description = IntentDescription(
        "打开几何面板并进入后台任务页，为自动签到与车况补采授权。授权需要你在面板里确认。")
    /// 必须前台：网页要点授权按钮，原生弹确认框。
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 这里**不自己写凭据**：凭据只能由网页侧的 `background.credential` 提交
        // （密钥在 sign.js 里，原生拿不到，也不该拿）。intent 的职责只是
        // 把用户送到那个页面，避免他去翻三层设置。
        //
        // 不做 URL scheme 自唤起：后台语境会被系统拒绝（"neither visible nor entitled"），
        // openAppWhenRun 已经由系统负责拉起 App。
        return .result(dialog: IntentDialog(stringLiteral:
            "已打开几何面板。请进入「后台任务」页点击授权，或直接在面板里点一次「启用后台自动任务」。"))
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
