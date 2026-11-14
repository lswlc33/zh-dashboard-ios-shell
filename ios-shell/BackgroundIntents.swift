import Foundation
import AppIntents
import UIKit

// 快捷指令用的 App Intent：这是 iOS 上**唯一有系统保证的定时入口**。
//
// 背景（为什么必须有它）：
// Apple DTS 在 forums/thread/685525 里明确说 iOS 没有「按固定间隔后台跑代码」的机制，
// BGAppRefreshTask 只是「系统觉得合适时跑」。而快捷指令的**个人自动化 → 特定时间**
// 属于「无需确认即可自动运行」的触发器（Apple 支持文档列在可自动运行清单里），
// 这是普通用户能拿到的、真正的定时器。
//
// 两条用法：
// 1. `ZeehoRunBackgroundTaskIntent`：在自动化里直接调用，跑一次签到/采样；
//    `supportedModes` 含 `.background`，所以不必把 App 拉到前台。
// 2. `ZeehoOpenPanelIntent`：如果用户想要「打开面板顺便补跑」，用这条更直观。

/// 后台任务的动作类型。
///
/// `AppEnum` 是 iOS 16.0 的协议，但 `AppShortcutsProvider` 与 `IntentModes`
/// 的可用性在 16.x 各小版本间漂移过（AppIntents 在 16.0 首发后连着补了几个版本）。
/// 统一标 17.0 是为了**不在低版本上踩半实现**：这些 intent 的用途是给用户配
/// 「个人自动化」，而个人自动化的「无需确认自动运行」在 17 上才稳定。
/// 16.x 用户仍然可以用 App 内的设置页手动触发同一套后台逻辑。
@available(iOS 17.0, *)
enum IOSBackgroundIntentAction: String, AppEnum {
    case signIn = "signin"
    case sample = "sample"
    case both = "both"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "后台任务")
    static var caseDisplayRepresentations: [IOSBackgroundIntentAction: DisplayRepresentation] = [
        .signIn: DisplayRepresentation(title: "自动签到"),
        .sample: DisplayRepresentation(title: "补采车况与电量"),
        .both: DisplayRepresentation(title: "签到 + 采样"),
    ]
}

/// 在快捷指令/自动化里执行一次后台任务。
///
/// **注意平台限制**：`supportedModes: .background` 让它在自动化里不必起前台 UI，
/// 但任务体本身仍受 iOS 后台时间预算约束（约 30 秒）。签到是一次 HTTP，
/// 采样也是一次 HTTP，都远在预算内。
@available(iOS 17.0, *)
struct ZeehoRunBackgroundTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "运行几何面板后台任务"
    static var description = IntentDescription("在你的快捷指令自动化里补跑一次签到或车况采样。iOS 不允许 App 自己定时唤醒，所以这是唯一可靠的定时方式。")
    /// 不拉起 App：自动化里应该静默完成。
    static var openAppWhenRun: Bool = false
    /// iOS 16+ 的替代属性：明确允许在后台执行。
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "动作", default: .both)
    var action: IOSBackgroundIntentAction

    init() {}
    init(action: IOSBackgroundIntentAction) { self.action = action }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let wantsSignIn = action == .signIn || action == .both
        let wantsSample = action == .sample || action == .both
        var parts: [String] = []
        if wantsSample {
            let ok = await withCheckedContinuation { continuation in
                IOSBackgroundRunner.runRefresh { success in continuation.resume(returning: success) }
            }
            let report = IOSBackgroundScheduler.report(IOSBackgroundTaskID.refresh)
            parts.append(ok ? "车况已更新" : "车况采样失败（\(report.lastResult)）")
        }
        if wantsSignIn {
            guard IOSBackgroundPreferences.autoSignInEnabled else {
                parts.append("自动签到未开启")
                return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: "；")))
            }
            let ok = await withCheckedContinuation { continuation in
                IOSBackgroundRunner.runSignIn { success in continuation.resume(returning: success) }
            }
            let report = IOSBackgroundScheduler.report(IOSBackgroundTaskID.signIn)
            if ok {
                let days = report.lastSignInDays.map { "（连签 \($0) 天）" } ?? ""
                parts.append((report.lastResult == "already_signed" ? "今日已签到" : "签到成功") + days)
            } else {
                parts.append("签到失败（\(report.lastResult)）")
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.isEmpty ? "没有要执行的动作" : parts.joined(separator: "；")))
    }
}

/// 打开面板（自动化里最直观的一条：定时把 App 唤起，页面一开就会补跑）。
@available(iOS 17.0, *)
struct ZeehoOpenPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "打开几何面板"
    static var description = IntentDescription("在自动化里打开几何面板。面板每次进入前台都会立刻刷新车况并合并后台补采的电量点。")
    /// 这条必须在前台：它的目的就是让面板可见。
    static var openAppWhenRun: Bool = true
    static var supportedModes: IntentModes { [.foreground] }

    init() {}

    func perform() async throws -> some IntentResult {
        // openAppWhenRun 已经由系统负责把 App 拉到前台，这里不需要再做任何事。
        // 不做 URL scheme 自唤起：后台语境会被系统拒绝（"neither visible nor entitled"）。
        return .result()
    }
}

/// 把两个 intent 暴露给快捷指令 App 的「App 快捷指令」列表。
@available(iOS 17.0, *)
struct ZeehoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ZeehoRunBackgroundTaskIntent(action: .both),
            phrases: ["用 \(.applicationName) 签到", "让 \(.applicationName) 补采车况"],
            shortTitle: "后台任务",
            systemImageName: "bolt.badge.clock")
        AppShortcut(
            intent: ZeehoOpenPanelIntent(),
            phrases: ["打开 \(.applicationName)"],
            shortTitle: "打开面板",
            systemImageName: "square.grid.2x2")
    }
}
