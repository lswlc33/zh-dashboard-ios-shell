import Foundation
import AppIntents
import ZeehoSystemShared

// 后台任务不启动网页，所有请求共用一次运行租约与绝对期限。
@available(iOS 17.0, *)
struct ZeehoRunBackgroundTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "运行后台任务"
    static var description = IntentDescription("执行签到、发帖、点赞和分享，并回查今日任务结果。")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parts: [String]
        do {
            parts = try await IOSBackgroundRunner.withRun(source: .shortcut, budget: 25) { context in
                // 两条独立请求链并行，签到慢时不挤掉社交任务的写入时间。
                async let signIn = IOSBackgroundRunner.runSignIn(force: true, context: context)
                async let daily = IOSBackgroundRunner.runDailyTasks(force: true, signInDone: false, context: context)
                let (signed, completed) = await (signIn, daily)
                var report = completed
                report.signInDone = ["signed", "already_signed"].contains(signed.lastResult)
                var result = [IOSBackgroundRunner.summary(report)]
                if report.signInDone {
                    result.append(signed.lastResult == "already_signed" ? "今日已签到" : "签到成功")
                } else {
                    result.append("签到未完成（" + ZeehoCredentialIssueText.text(signed.lastResult) + "）")
                }
                for failure in report.failed {
                    result.append("\(failure.name)未完成（\(failure.reason)）")
                }
                if !["ok", "verification_failed"].contains(report.result) {
                    result.append(ZeehoCredentialIssueText.text(report.result))
                }
                return result
            }
        } catch {
            parts = ["后台任务未完成（\(IOSDailyTasksClient.code(of: error))）"]
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: "；")))
    }
}

@available(iOS 17.0, *)
struct ZeehoUnlockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "开锁"
    static var description = IntentDescription("打开面板并向当前已选车辆发送开锁命令。")
    static var openAppWhenRun: Bool = true
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleShortcut.submit("unlock")))
    }
}

@available(iOS 17.0, *)
struct ZeehoLockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "关锁"
    static var description = IntentDescription("打开面板并向当前已选车辆发送关锁命令。")
    static var openAppWhenRun: Bool = true
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleShortcut.submit("lock")))
    }
}

@available(iOS 17.0, *)
struct ZeehoOpenSeatIntent: AppIntent {
    static var title: LocalizedStringResource = "打开坐垫"
    static var description = IntentDescription("打开面板并向当前已选车辆发送打开坐垫命令。")
    static var openAppWhenRun: Bool = true
    init() {}
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: ZeehoVehicleShortcut.submit("seat")))
    }
}

private enum ZeehoVehicleShortcut {
    static func submit(_ action: String) -> String {
        guard let owner = try? SystemSnapshotStore.currentOwner(),
              ZeehoWidgetCommandMailbox.post(action, ownerID: owner.ownerIdentifierString) else {
            return "当前车辆不可用，请打开面板选择车辆后重试。"
        }
        // 只报告排队，实际下发与失败原因仍由面板车控回执确认。
        return "车控命令已排队，请查看面板回执并确认车辆响应。"
    }
}

@available(iOS 17.0, *)
struct ZeehoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ZeehoRunBackgroundTaskIntent(),
                    phrases: ["用 \(.applicationName) 跑后台任务", "用 \(.applicationName) 完成每日任务"],
                    shortTitle: "后台任务", systemImageName: "checklist")
        AppShortcut(intent: ZeehoUnlockVehicleIntent(),
                    phrases: ["用 \(.applicationName) 开锁"],
                    shortTitle: "开锁", systemImageName: "lock.open")
        AppShortcut(intent: ZeehoLockVehicleIntent(),
                    phrases: ["用 \(.applicationName) 关锁"],
                    shortTitle: "关锁", systemImageName: "lock")
        AppShortcut(intent: ZeehoOpenSeatIntent(),
                    phrases: ["用 \(.applicationName) 打开坐垫"],
                    shortTitle: "打开坐垫", systemImageName: "car.rear")
    }
}
