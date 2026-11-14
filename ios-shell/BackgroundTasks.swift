import Foundation
import BackgroundTasks
import UIKit
import CryptoKit
import ZeehoSystemShared

// 后台定时任务的统一落点。
//
// ## 为什么需要这个文件
//
// iOS 没有任何「按固定间隔后台跑代码」的通用机制（Apple DTS 在 forums/thread/685525
// 里对这类需求的统一回答是 "You can't"）。能用的只有 BGAppRefreshTask：系统按用户
// 使用习惯决定何时跑、每次约 30 秒、并且**不保证**会跑（实测首次可能要等数小时）。
// 所以这里的定位是「尽力补一次」，所有用户可见的承诺都必须按「可能不跑」写。
//
// ## 为什么不能在后台跑网页
//
// WKWebView 的 JS 在 App 挂起后**完全停止执行**（Apple Frameworks Engineer 在
// forums/thread/64150 明确说是 by design；Cordova CB-10657 以 Won't Fix 关闭，并
// 指出 background modes 也换不来 JS 回调）。WebContent 是独立进程，App 挂起后
// WebKit 的进程断言失效，页面 timer 与 XHR 一起冻结。
// 因此后台任务**只做原生 HTTP + 原生签名**，结果写进 App Group 让网页/小组件读。
//
// ## 一条硬约束
//
// 后台任务拿不到网页递来的密钥：IOSSecretHandleService 的条目 TTL 只有 300 秒且只在
// 内存里。所以后台要发请求，必须有一份**用户显式授权后落盘**的凭据。这个文件只管
// 「调度 + 凭据存取」，具体的请求构造在 IOSBackgroundSignIn 里。

@available(iOS 13.0, *)
enum IOSBackgroundTaskID {
    /// 拉一次车况并采样电量。identifier 必须与 Info.plist 的
    /// BGTaskSchedulerPermittedIdentifiers 逐字一致，否则 submit 直接抛错。
    static let refresh = "io.github.lswlc33.dashboard.ios.refresh"
    /// 每日自动签到。
    static let signIn = "io.github.lswlc33.dashboard.ios.signin"
    /// 处理型任务（可跑几分钟，但只在设备空闲时）。留给以后的大批量回填，
    /// 现在不注册也不提交，避免占掉 10 个 processing 槽位。
}

/// 后台任务可用的凭据。
///
/// 只保存「已经能在后台独立发请求」的最小集合：
/// - `token`：用户登录态的 Bearer token；
/// - `accountID` / `vin`：请求路径与 owner 隔离必需；
/// - `signinToken`：h5 签到的 Bearer（与 app token 不是同一个域，官方接口对混用返回 401）。
///
/// 刻意不存 APP_SECRET：签名密钥是编译进 App 的常量（与 Android 侧 SignUtil 同源），
/// 落盘只会平白多一份可被读取的密钥副本。
struct IOSBackgroundCredential: Codable, Equatable, Sendable {
    var accountID: String
    var vin: String
    /// app 域 token（tapi.zeehoev.com）。
    var token: String
    /// h5 签到域 token。空表示这条账号还没拿到可用的签到凭据。
    var signinToken: String
    var updatedAt: Int64

    var isValid: Bool {
        [accountID, vin, token].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 512
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}

/// 后台任务的状态回执，写进 App Group 给网页读。
struct IOSBackgroundTaskReport: Codable, Equatable, Sendable {
    /// 最后一次跑完的绝对时间（Unix 毫秒）。从没跑过是 nil。
    var lastRunAt: Int64?
    /// 上次结果的机器码：ok / no_credential / http_401 / timeout / cancelled / failed:xxx
    var lastResult: String
    /// 上次采样到的电量（0-100）。只有 refresh 任务会写。
    var lastSocPercent: Double?
    /// 上次采样到的充电态。nil 表示接口没给，不是「未充电」。
    var lastCharging: Bool?
    /// 上次签到成功的连签天数。
    var lastSignInDays: Int?
    /// 累计成功次数，用来在界面上证明「确实跑过」。
    var runCount: Int
    var successCount: Int
}

/// 后台任务调度器。
///
/// 只管三件事：注册 handler、提交请求、维护「上次跑了什么」。
/// 不做任何网络或签名——那些在 IOSBackgroundSignIn。
@available(iOS 13.0, *)
final class IOSBackgroundScheduler {
    static let shared = IOSBackgroundScheduler()

    /// 任务必须在 didFinishLaunching 里就注册完（Apple 要求「在 App 启动结束前」），
    /// 否则系统唤起时找不到 handler，日志里只会看到 "No handler registered"。
    private var registered = false
    private var handlers: [String: (BGTask) -> Void] = [:]

    private static let defaults = UserDefaults.standard
    private static let reportPrefix = "io.github.lswlc33.dashboard.ios.bgtask.report."
    private static let scheduledPrefix = "io.github.lswlc33.dashboard.ios.bgtask.scheduled."

    private init() {}

    /// 在 AppDelegate.didFinishLaunching 调用一次。重复调用安全。
    func register(refresh: @escaping (@escaping (Bool) -> Void) -> Void,
                  signIn: @escaping (@escaping (Bool) -> Void) -> Void) {
        guard !registered else { return }
        registered = true
        handlers[IOSBackgroundTaskID.refresh] = { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.run(task: task, name: IOSBackgroundTaskID.refresh, reportKind: .refresh, body: refresh)
        }
        handlers[IOSBackgroundTaskID.signIn] = { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.run(task: task, name: IOSBackgroundTaskID.signIn, reportKind: .signIn, body: signIn)
        }
        for (identifier, handler) in handlers {
            // register 失败只可能是 Info.plist 缺 identifier 或已被别的 App 注册；
            // 这两种都不该在启动时崩掉，记录下来即可（能力缺失不等于必须崩溃）。
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                handler(task)
                // 注册回调每个 identifier 只走一次，进来就重排下一次。
                self.reschedule(identifier)
            }
            if !ok {
                IOSBackgroundLog.write("register 失败: \(identifier)（检查 BGTaskSchedulerPermittedIdentifiers）")
            }
        }
    }

    private enum ReportKind { case refresh, signIn }

    private static func run(task: BGAppRefreshTask, name: String, reportKind: ReportKind,
                            body: @escaping (@escaping (Bool) -> Void) -> Void) {
        IOSBackgroundLog.write("开始 \(name)")
        var finished = false
        let complete: (Bool) -> Void = { success in
            // 系统可能先触发 expirationHandler 再让我们回来；重复 setTaskCompleted 会崩。
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            IOSBackgroundLog.write("结束 \(name) success=\(success)")
        }
        task.expirationHandler = {
            // 到点没做完必须立刻收尾，否则系统会认为任务失控并减少后续调度。
            IOSBackgroundLog.write("超时 \(name)")
            complete(false)
        }
        body(complete)
    }

    /// 重排下一次。系统会自己决定什么时候真的跑，这里只是「再排一次」。
    func reschedule(_ identifier: String) {
        guard isEnabled(identifier) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // 15 分钟是最短的有意义粒度；再短系统也不会更频繁地答应。
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.defaults.set(true, forKey: Self.scheduledPrefix + identifier)
        } catch {
            // tooManyPendingTaskRequests 是唯一常见错误：同类任务已经有 1 个在排队。
            // 那不是失败，下一次执行时会自动重排，所以这里不打扰用户。
            IOSBackgroundLog.write("submit 失败 \(identifier): \(error)")
            Self.defaults.set(false, forKey: Self.scheduledPrefix + identifier)
        }
    }

    /// 提交两个任务（App 启动完成、以及用户开启相应功能时调用）。
    func scheduleAll() {
        reschedule(IOSBackgroundTaskID.refresh)
        reschedule(IOSBackgroundTaskID.signIn)
    }

    /// 取消某个任务的排队。用户关掉自动签到时要调用，否则后台还会继续跑。
    func cancel(_ identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        Self.defaults.set(false, forKey: Self.scheduledPrefix + identifier)
    }

    // MARK: - 状态读写（App Group，网页与小组件都能读）

    static func report(_ identifier: String) -> IOSBackgroundTaskReport {
        guard let data = SystemSnapshotStore.readBackgroundReport(identifier),
              let value = try? JSONDecoder().decode(IOSBackgroundTaskReport.self, from: data) else {
            return IOSBackgroundTaskReport(lastRunAt: nil, lastResult: "never", lastSocPercent: nil,
                                           lastCharging: nil, lastSignInDays: nil, runCount: 0, successCount: 0)
        }
        return value
    }

    static func record(_ update: (inout IOSBackgroundTaskReport) -> Void, identifier: String) {
        var value = report(identifier)
        update(&value)
        if let data = try? JSONEncoder().encode(value) {
            SystemSnapshotStore.writeBackgroundReport(data, identifier: identifier)
        }
    }

    /// 该 identifier 是否已排进队列。只表示「排过」，不代表系统会真的跑。
    func isScheduled(_ identifier: String) -> Bool {
        Self.defaults.bool(forKey: Self.scheduledPrefix + identifier)
    }

    private func isEnabled(_ identifier: String) -> Bool {
        // 签到任务受用户开关控制；refresh 默认开（只做采样与通知，不改任何云端状态）。
        if identifier == IOSBackgroundTaskID.signIn {
            return IOSBackgroundPreferences.autoSignInEnabled
        }
        return true
    }
}

/// 用户对后台功能的偏好，落在 standard UserDefaults（不是 App Group：
/// 这是用户在本 App 里的选择，扩展不需要知道）。
enum IOSBackgroundPreferences {
    private static let autoSignInKey = "io.github.lswlc33.dashboard.ios.bg.autoSignIn"
    private static let chargeNotifyKey = "io.github.lswlc33.dashboard.ios.bg.chargeNotify"
    private static let taskNotifyKey = "io.github.lswlc33.dashboard.ios.bg.taskNotify"

    static var autoSignInEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoSignInKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSignInKey) }
    }
    /// 充电开始/结束提醒。默认关：需要能后台拿到车况，做不到时不该给用户假承诺。
    static var chargeNotifyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: chargeNotifyKey) }
        set { UserDefaults.standard.set(newValue, forKey: chargeNotifyKey) }
    }
    /// 任务完成提醒。默认开：这个只依赖本地状态，不依赖后台唤醒。
    static var taskNotifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: taskNotifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: taskNotifyKey) }
    }
}

/// 后台任务日志。
///
/// 单独一个文件，不混进主诊断日志：主日志是 512KB 滚动，后台任务每次只写一两行，
/// 混在一起会让用户排查后台问题时反复被前台日志冲掉。
enum IOSBackgroundLog {
    private static let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.bg.log", qos: .utility)
    private static let fileName = "background-tasks.log"
    private static let maxBytes = 64 * 1024

    static var fileURL: URL? {
        guard let root = try? SystemSnapshotStore.containerURL() else { return nil }
        return root.appendingPathComponent(fileName, isDirectory: false)
    }

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        queue.async {
            guard let url = fileURL else { return }
            let existing = (try? Data(contentsOf: url)) ?? Data()
            var next = existing
            // 超限就整份丢弃重开：与 AppLog 相同的策略，避免半截文件里全是老日志。
            if next.count + text.utf8.count > maxBytes { next = Data() }
            next.append(Data(text.utf8))
            try? next.write(to: url, options: .atomic)
        }
    }

    static func read() -> String {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
