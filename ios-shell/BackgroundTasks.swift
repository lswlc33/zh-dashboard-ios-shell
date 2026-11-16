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
    /// 每日任务（发帖/点赞/分享）。与签到分开一个 identifier，因为：
    /// 两者的用户开关、凭据要求（任务还要内部 uid）、失败后果都不一样；
    /// 合成一条的话「只签到不跑任务」的用户就没法选了。
    static let dailyTasks = "io.github.lswlc33.dashboard.ios.tasks"
    /// 处理型任务（可跑几分钟，但只在设备空闲时）。留给以后的大批量回填，
    /// 现在不注册也不提交，避免占掉 10 个 processing 槽位。
}

/// 后台任务可用的凭据定义在 BackgroundSigning.swift（那里也管 Keychain 存取）：
/// 签名密钥与 token 必须成对存在，分开两个文件会让「谁能读密钥」变得模糊。
///
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
    /// 明确成功的签到时间；失败时清空，不与上次连签天数混用。
    var lastSignInAt: Int64?
    /// 每日任务所属匿名 owner/date，用来防止旧账号或旧日期凑进度。
    var ownerID: String?
    var day: String?
    /// 每日任务：今日已完成项数（含签到）。只有 dailyTasks 任务会写。
    var lastDailyDone: Int?
    /// 每日任务：今日可执行项总数（签到 + 发帖/点赞/分享）。
    var lastDailyTotal: Int?
    /// 每日任务：上次逐项结果的极简描述，例如「签到、点赞、分享｜发帖失败」。
    /// 只放**已完成项的名字**，不放失败原因以外的任何内容。
    var lastDailySummary: String?
    /// 累计成功次数，用来在界面上证明「确实跑过」。
    var runCount: Int
    var successCount: Int

    /// 缺键兼容：App Group 里已经躺着老版本写下的报告（没有 lastDaily* 三个字段）。
    /// 合成 Codable 遇到缺键会整份解码失败 → `report()` 回落到「从未运行」，
    /// 用户会看到明明跑过的任务显示「从未运行」。所以这里统一按缺键=空值解码。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        lastRunAt = try? box.decodeIfPresent(Int64.self, forKey: .lastRunAt)
        lastResult = (try? box.decodeIfPresent(String.self, forKey: .lastResult)) ?? "never"
        lastSocPercent = try? box.decodeIfPresent(Double.self, forKey: .lastSocPercent)
        lastCharging = try? box.decodeIfPresent(Bool.self, forKey: .lastCharging)
        lastSignInDays = try? box.decodeIfPresent(Int.self, forKey: .lastSignInDays)
        lastSignInAt = try? box.decodeIfPresent(Int64.self, forKey: .lastSignInAt)
        ownerID = try? box.decodeIfPresent(String.self, forKey: .ownerID)
        day = try? box.decodeIfPresent(String.self, forKey: .day)
        lastDailyDone = try? box.decodeIfPresent(Int.self, forKey: .lastDailyDone)
        lastDailyTotal = try? box.decodeIfPresent(Int.self, forKey: .lastDailyTotal)
        lastDailySummary = try? box.decodeIfPresent(String.self, forKey: .lastDailySummary)
        runCount = (try? box.decodeIfPresent(Int.self, forKey: .runCount)) ?? 0
        successCount = (try? box.decodeIfPresent(Int.self, forKey: .successCount)) ?? 0
    }

    init(lastRunAt: Int64? = nil, lastResult: String, lastSocPercent: Double? = nil,
         lastCharging: Bool? = nil, lastSignInDays: Int? = nil, lastSignInAt: Int64? = nil,
         ownerID: String? = nil, day: String? = nil,
         lastDailyDone: Int? = nil, lastDailyTotal: Int? = nil, lastDailySummary: String? = nil,
         runCount: Int, successCount: Int) {
        self.lastRunAt = lastRunAt; self.lastResult = lastResult
        self.lastSocPercent = lastSocPercent; self.lastCharging = lastCharging
        self.lastSignInDays = lastSignInDays; self.lastSignInAt = lastSignInAt
        self.ownerID = ownerID; self.day = day
        self.lastDailyDone = lastDailyDone; self.lastDailyTotal = lastDailyTotal
        self.lastDailySummary = lastDailySummary
        self.runCount = runCount; self.successCount = successCount
    }
}

/// 后台任务调度器。
///
/// 只管三件事：注册 handler、提交请求、维护「上次跑了什么」。
/// 不做任何网络或签名——那些在 IOSBackgroundSignIn。
/// expiration 可先于 Task 安装；把「已结束」和 handle 一起保护，晚安装的 Task 也立即取消。
@available(iOS 13.0, *)
private final class IOSBackgroundScheduledRun {
    private let lock = NSLock()
    private var finished = false
    private var operation: Task<Void, Never>?
    private let task: BGAppRefreshTask
    private let name: String

    init(task: BGAppRefreshTask, name: String) { self.task = task; self.name = name }

    func install(_ value: Task<Void, Never>) {
        lock.lock()
        let ended = finished
        if !ended { operation = value }
        lock.unlock()
        if ended { value.cancel() }
    }

    func complete(_ success: Bool, cancel: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let current = operation
        operation = nil
        lock.unlock()
        if cancel {
            IOSBackgroundRunCoordinator.shared.cancelSystem(name)
            current?.cancel()
        }
        task.setTaskCompleted(success: success)
        IOSBackgroundLog.write("结束 \(name) success=\(success)")
    }
}

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
    ///
    /// `dailyTasks` 是**可选**的：老调用点（不传这个参数）仍然只注册两个任务，
    /// 不会因为 Info.plist 里还没加 identifier 就在启动时报错。
    /// 注意闭包类型不能再写 `@escaping`——可选闭包类型参数本身已是 escaping，
    /// 再标一次会被 Swift 直接拒（CI 实测 "closure is already escaping in optional type argument"）。
    func register(refresh: @escaping (@escaping (Bool) -> Void) -> Task<Void, Never>,
                  signIn: @escaping (@escaping (Bool) -> Void) -> Task<Void, Never>,
                  dailyTasks: (() async -> Bool)? = nil) {
        guard !registered else { return }
        registered = true
        handlers[IOSBackgroundTaskID.refresh] = { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.run(task: task, name: IOSBackgroundTaskID.refresh, body: refresh)
        }
        handlers[IOSBackgroundTaskID.signIn] = { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Self.run(task: task, name: IOSBackgroundTaskID.signIn, body: signIn)
        }
        if let dailyTasks = dailyTasks {
            handlers[IOSBackgroundTaskID.dailyTasks] = { task in
                guard let task = task as? BGAppRefreshTask else { return }
                Self.run(task: task, name: IOSBackgroundTaskID.dailyTasks, asyncBody: dailyTasks)
            }
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

    private static func run(task: BGAppRefreshTask, name: String,
                            asyncBody: @escaping () async -> Bool) {
        run(task: task, name: name) { completion in
            Task {
                guard !Task.isCancelled else { completion(false); return }
                let success = await asyncBody()
                completion(success && !Task.isCancelled)
            }
        }
    }

    private static func run(task: BGAppRefreshTask, name: String,
                            body: @escaping (@escaping (Bool) -> Void) -> Task<Void, Never>) {
        IOSBackgroundLog.write("开始 \(name)")
        let state = IOSBackgroundScheduledRun(task: task, name: name)
        task.expirationHandler = {
            IOSBackgroundLog.write("超时 \(name)")
            state.complete(false, cancel: true)
        }
        let operation = body { state.complete($0) }
        state.install(operation)
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

    /// 提交全部任务（App 启动完成、以及用户开启相应功能时调用）。
    func scheduleAll() {
        reschedule(IOSBackgroundTaskID.refresh)
        reschedule(IOSBackgroundTaskID.signIn)
        reschedule(IOSBackgroundTaskID.dailyTasks)
    }

    /// 取消某个任务的排队。用户关掉自动签到时要调用，否则后台还会继续跑。
    func cancel(_ identifier: String) {
        IOSBackgroundRunCoordinator.shared.cancelSystem(identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        Self.defaults.set(false, forKey: Self.scheduledPrefix + identifier)
    }

    // MARK: - 状态读写（App Group，网页与小组件都能读）

    static func report(_ identifier: String) -> IOSBackgroundTaskReport {
        guard let data = SystemSnapshotStore.readBackgroundReport(identifier),
              let value = try? JSONDecoder().decode(IOSBackgroundTaskReport.self, from: data) else {
            return IOSBackgroundTaskReport(lastResult: "never", runCount: 0, successCount: 0)
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
        // 签到与每日任务都受各自开关控制；refresh 默认开（只做采样与通知，不改任何云端状态）。
        if identifier == IOSBackgroundTaskID.signIn {
            return IOSBackgroundPreferences.autoSignInEnabled
        }
        if identifier == IOSBackgroundTaskID.dailyTasks {
            return IOSBackgroundPreferences.autoDailyTasksEnabled
        }
        return true
    }
}

/// 用户对后台功能的偏好，落在 standard UserDefaults（不是 App Group：
/// 这是用户在本 App 里的选择，扩展不需要知道）。
enum IOSBackgroundPreferences {
    private static let autoSignInKey = "io.github.lswlc33.dashboard.ios.bg.autoSignIn"
    private static let autoDailyTasksKey = "io.github.lswlc33.dashboard.ios.bg.autoDailyTasks"
    private static let chargeNotifyKey = "io.github.lswlc33.dashboard.ios.bg.chargeNotify"
    private static let taskNotifyKey = "io.github.lswlc33.dashboard.ios.bg.taskNotify"

    static var autoSignInEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoSignInKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSignInKey) }
    }
    /// 后台自动跑每日任务（发帖/点赞/分享）。
    ///
    /// 默认关：这些是**写操作**（会真的发一条动态到广场），不能因为用户授权了凭据
    /// 就默认替他发内容。想要的话由用户显式打开，或直接用快捷指令主动触发
    /// （主动触发走 force 路径，不看这个开关）。
    static var autoDailyTasksEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoDailyTasksKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDailyTasksKey) }
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
