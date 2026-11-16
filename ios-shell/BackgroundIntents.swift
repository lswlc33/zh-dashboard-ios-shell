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
//    `openAppWhenRun = false` 保证不把 App 拉到前台。
// 2. `ZeehoOpenPanelIntent`：如果用户想要「打开面板顺便补跑」，用这条更直观。

/// 后台任务的动作类型。
///
/// 统一标 17.0 是为了**不在低版本上踩半实现**：这些 intent 的用途是给用户配
/// 「个人自动化」，而个人自动化的「无需确认自动运行」在 17 上才稳定。
/// 16.x 用户仍然可以用 App 内的设置页手动触发同一套后台逻辑。
@available(iOS 17.0, *)
enum IOSBackgroundIntentAction: String, AppEnum {
    case signIn = "signin"
    case sample = "sample"
    case tasks = "tasks"
    case both = "both"
    case all = "all"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "后台任务")
    static var caseDisplayRepresentations: [IOSBackgroundIntentAction: DisplayRepresentation] = [
        .signIn: DisplayRepresentation(title: "自动签到"),
        .sample: DisplayRepresentation(title: "补采车况与电量"),
        .tasks: DisplayRepresentation(title: "每日任务（发帖/点赞/分享）"),
        .both: DisplayRepresentation(title: "签到 + 采样"),
        .all: DisplayRepresentation(title: "全部（签到 + 任务 + 采样）"),
    ]

    /// 是否要跑签到。
    var wantsSignIn: Bool { self == .signIn || self == .both || self == .all }
    /// 是否要跑车况采样。
    var wantsSample: Bool { self == .sample || self == .both || self == .all }
    /// 是否要跑每日任务（发帖/点赞/分享）。
    var wantsDailyTasks: Bool { self == .tasks || self == .all }
}

/// 在快捷指令/自动化里执行一次后台任务。
///
/// **注意平台限制**：任务体受 iOS 后台时间预算约束（约 30 秒）。
/// 签到是一次 HTTP，采样也是一次 HTTP，都远在预算内。
///
/// 只用 `openAppWhenRun = false` 表达「不要拉起 App」：它是 AppIntents 首发就有
/// 的属性，全版本可用。`supportedModes` / `IntentModes` 是 iOS 26 的新 API，
/// 在 17/18 的 SDK 里根本不存在（CI 实测 `cannot find type 'IntentModes'`），
/// 不能用在这里——deployment target 是 15.4，编译用的是当前 Xcode 的 SDK。
/// 「自动化里不需要确认就运行」由用户在快捷指令里勾选，与本 intent 无关。
@available(iOS 17.0, *)
struct ZeehoRunBackgroundTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "运行几何面板后台任务"
    static var description = IntentDescription("在你的快捷指令自动化里补跑一次签到或车况采样。iOS 不允许 App 自己定时唤醒，所以这是唯一可靠的定时方式。")
    /// 不拉起 App：自动化里应该静默完成。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "动作", default: .both)
    var action: IOSBackgroundIntentAction

    init() {}
    init(action: IOSBackgroundIntentAction) { self.action = action }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let requested = action
        let parts: [String]
        do {
            parts = try await IOSBackgroundRunner.withRun(source: .shortcut, budget: 25) { context in
                var parts: [String] = []
                var signInDone = false
                if requested.wantsSignIn {
                    try context.check()
                    let report = await IOSBackgroundRunner.runSignIn(force: true, context: context)
                    try context.check()
                    let daysPart = report.lastSignInDays.map { "（连签 \($0) 天）" } ?? ""
                    switch report.lastResult {
                    case "already_signed", "signed":
                        signInDone = true
                        parts.append((report.lastResult == "already_signed" ? "今日已签到" : "签到成功") + daysPart)
                    case _ where ZeehoCredentialIssueText.isCredentialIssue(report.lastResult):
                        parts.append("签到失败（" + ZeehoCredentialIssueText.text(report.lastResult) + "）")
                    default: parts.append("签到失败（\(report.lastResult)）")
                    }
                }
                if requested.wantsDailyTasks {
                    try context.check()
                    let report = await IOSBackgroundRunner.runDailyTasks(force: true, signInDone: signInDone, context: context)
                    try context.check()
                    parts.append(IOSBackgroundRunner.summary(report))
                    for item in report.failed { parts.append("\(item.name)失败（\(item.reason)）") }
                    if report.result == "credential_partial" { parts.append("请在面板里重新授权后台任务以补全账号 id") }
                }
                if requested.wantsSample {
                    // 共用一开始领取的期限；前面耗尽时间就不会再发起采样请求。
                    try context.check()
                    let report = await IOSBackgroundRunner.runRefresh(context: context)
                    try context.check()
                    switch report.lastResult {
                    case "ok": parts.append("车况已更新")
                    case _ where ZeehoCredentialIssueText.isCredentialIssue(report.lastResult):
                        parts.append("车况采样失败（" + ZeehoCredentialIssueText.text(report.lastResult) + "）")
                    default: parts.append("车况采样失败（\(report.lastResult)）")
                    }
                }
                return parts
            }
        } catch {
            // 不读取旧的持久回执冒充本轮结果；取消/预算耗尽按本轮真实码返回。
            parts = ["后台任务未完成（\(IOSDailyTasksClient.code(of: error))）"]
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.isEmpty ? "没有要执行的动作" : parts.joined(separator: "；")))
    }
}

/// 打开面板（自动化里最直观的一条：定时把 App 唤起，页面一开就会补跑）。
@available(iOS 17.0, *)
struct ZeehoOpenPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "打开几何面板"
    static var description = IntentDescription("在自动化里打开几何面板。面板每次进入前台都会立刻刷新车况并合并后台补采的电量点。")
    /// 这条必须在前台：它的目的就是让面板可见。`openAppWhenRun` 是唯一跨版本的
    /// 表达方式（`supportedModes` 是 iOS 26 API，见上面 ZeehoRunBackgroundTaskIntent 的注释）。
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        // openAppWhenRun 已经由系统负责把 App 拉到前台，这里不需要再做任何事。
        // 不做 URL scheme 自唤起：后台语境会被系统拒绝（"neither visible nor entitled"）。
        return .result()
    }
}

/// 把 intent 暴露给快捷指令 App 的「App 快捷指令」列表。
///
/// 分成两类：
/// 1. **后台任务类**（签到/采样）—— iOS 上唯一有系统保证的定时入口；
/// 2. **车况查询类**（车况/电量/充电/锁状态）—— 见 `VehicleIntents.swift`，
///    纯只读本地快照，可以安全地放进自动化里反复跑。
///
/// 短语必须包含 `\(.applicationName)`，否则系统不会把它收进「App 快捷指令」面板。
/// 每条短语按用户真的会说的话写（Siri 匹配靠短语，不是靠 shortTitle）。
@available(iOS 17.0, *)
struct ZeehoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ZeehoRunBackgroundTaskIntent(action: .all),
            phrases: ["用 \(.applicationName) 跑每日任务", "用 \(.applicationName) 签到和做任务",
                      "让 \(.applicationName) 完成今天全部任务"],
            shortTitle: "每日任务",
            systemImageName: "checklist")
        AppShortcut(
            intent: ZeehoRunBackgroundTaskIntent(action: .signIn),
            phrases: ["用 \(.applicationName) 签到"],
            shortTitle: "自动签到",
            systemImageName: "bolt.badge.clock")
        AppShortcut(
            intent: ZeehoRunBackgroundTaskIntent(action: .sample),
            phrases: ["让 \(.applicationName) 补采车况"],
            shortTitle: "补采车况",
            systemImageName: "gauge")
        AppShortcut(
            intent: ZeehoBackgroundStatusIntent(),
            phrases: ["用 \(.applicationName) 查后台任务", "问 \(.applicationName) 自动签到生效了吗"],
            shortTitle: "后台状态",
            systemImageName: "checkmark.seal")
        AppShortcut(
            intent: ZeehoGrantBackgroundIntent(),
            phrases: ["用 \(.applicationName) 授权后台任务", "让 \(.applicationName) 打开后台授权"],
            shortTitle: "授权后台",
            systemImageName: "key.horizontal")
        AppShortcut(
            intent: ZeehoVehicleStatusIntent(),
            phrases: ["用 \(.applicationName) 查车况", "问问 \(.applicationName) 车怎么样了"],
            shortTitle: "查询车况",
            systemImageName: "car.side")
        AppShortcut(
            intent: ZeehoBatteryIntent(),
            phrases: ["用 \(.applicationName) 查电量", "问 \(.applicationName) 还有多少电"],
            shortTitle: "剩余电量",
            systemImageName: "battery.75")
        AppShortcut(
            intent: ZeehoChargingStatusIntent(),
            phrases: ["用 \(.applicationName) 查充电", "问 \(.applicationName) 在充电吗"],
            shortTitle: "充电状态",
            systemImageName: "bolt.car")
        AppShortcut(
            intent: ZeehoLockStateIntent(),
            phrases: ["用 \(.applicationName) 查车锁", "问 \(.applicationName) 锁车了吗"],
            shortTitle: "车锁状态",
            systemImageName: "lock.shield")
        AppShortcut(
            intent: ZeehoOpenPanelIntent(),
            phrases: ["打开 \(.applicationName)"],
            shortTitle: "打开面板",
            systemImageName: "square.grid.2x2")
    }
}
