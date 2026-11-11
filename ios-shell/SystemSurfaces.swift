import Foundation
import UIKit
import ActivityKit
import WidgetKit
import CoreFoundation
import ZeehoSystemShared

// 只有已由 Ride 的原生确认启动的记录才能发布；这个出口不启动 GPS、蓝牙、网络或后台定时任务。
protocol IOSSystemSurfacePublisher: AnyObject {
    func publishRide(_ value: SystemRideSnapshot, scope: IOSRideScope)
    func systemSurfacesDisconnected(scope: IOSRideScope)
}

private final class IOSSystemSurfaceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private struct IOSRunningSystemActivity: Sendable {
    let id: String
    let kind: ZeehoActivityKind
}
private struct IOSStartedSystemActivity: Sendable {
    let id: String
    let created: Bool
}

// actor 本身不可继承；只在 16.1+ 分支实例化，15.4 主 App 不加载 ActivityKit 的泛型类型。
@available(iOS 16.1, *)
private actor IOSLiveActivityManager {
    private var generation: UInt64 = 0
    private var owner: SystemSnapshotOwner?

    func setScope(_ next: SystemSnapshotOwner?, generation ticket: UInt64) async {
        guard ticket >= generation else { return }
        generation = ticket; owner = next
        // nil 表示「网页还没确认车辆」的未知状态，不是撤销：冷启动 installBridge 时
        // scopeProvider() 恒为 nil，这里若按 != next 结束活动，会把用户上次会话的
        // Live Activity 全部杀掉。撤销只能走显式的 clearScope()。
        guard let next = next else { return }
        let old = Activity<ZeehoActivityAttributes>.activities.filter { $0.attributes.owner != next }
        for activity in old { await finish(activity) }
    }

    /// 显式撤销（关闭系统显示）：结束本 App 的全部活动，并清掉当前 owner 引用。
    /// 与 `setScope(nil)` 的区别就是这里真的结束活动。
    func clearScope(generation ticket: UInt64) async -> Int {
        guard ticket >= generation else { return 0 }
        generation = ticket; owner = nil
        let all = Activity<ZeehoActivityAttributes>.activities
        for activity in all { await finish(activity) }
        return all.count
    }

    // .stale 是 iOS 16.2 才有的 ActivityState；deployment target 15.4 必须用可用性分支，
    // 否则整文件编译失败（CI 实测）。
    // fileprivate：同一文件里的 service 同步取「正在运行的活动」时也要用它。
    fileprivate static func isLive(_ state: ActivityState) -> Bool {
        if state == .active { return true }
        if #available(iOS 16.2, *) { return state == .stale }
        return false
    }

    func running(owner expected: SystemSnapshotOwner?) -> [IOSRunningSystemActivity] {
        guard let expected = expected, owner == expected else { return [] }
        return Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == expected && Self.isLive($0.activityState)
        }.map { IOSRunningSystemActivity(id: $0.id, kind: $0.attributes.kind) }
    }

    func start(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind, generation ticket: UInt64,
               lease: IOSSystemSurfaceLease) async throws -> IOSStartedSystemActivity {
        guard lease.valid, ticket == generation, owner == snapshot.owner else { throw SystemSnapshotError("stale_session") }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw SystemSnapshotError("live_activities_disabled") }
        guard !snapshot.isStale() else { throw SystemSnapshotError("snapshot_stale") }
        switch kind {
        case .charging:
            guard snapshot.vehicle?.visibleCharging() == true else { throw SystemSnapshotError("fresh_charging_data_required") }
        case .ride:
            guard let ride = snapshot.ride, ride.state != .ended else { throw SystemSnapshotError("native_recording_required") }
        case .vehicle:
            guard snapshot.vehicle != nil else { throw SystemSnapshotError("fresh_vehicle_data_required") }
        }
        if let existing = running(owner: snapshot.owner).first {
            guard existing.kind == kind else { throw SystemSnapshotError("another_activity_running") }
            // 复用已有活动时也要刷新内容：否则用户点「开始活动」拿到的还是上一次
            // 发布的旧电量/旧速度（created:false 曾直接返回 id，不更新任何内容）。
            // 用 try? 兜住「刚查到就结束」的竞态：活动确实存在过，仍如实回执 running。
            _ = try? await update(snapshot, id: existing.id, generation: ticket, lease: lease)
            return IOSStartedSystemActivity(id: existing.id, created: false)
        }
        let attributes = ZeehoActivityAttributes(owner: snapshot.owner, kind: kind)
        let state = ZeehoActivityAttributes.ContentState(snapshot: snapshot)
        let activity: Activity<ZeehoActivityAttributes>
        if #available(iOS 16.2, *) {
            activity = try Activity.request(attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(snapshot, kind: kind)),
                pushType: nil)
        } else {
            activity = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
        }
        // 原生确认后也可能立即换账号/导航或超时；只能结束这个精确 id，不能动新 owner 的活动。
        guard lease.valid, ticket == generation, owner == snapshot.owner else {
            await finish(activity)
            throw SystemSnapshotError("operation_cancelled")
        }
        return IOSStartedSystemActivity(id: activity.id, created: true)
    }

    func update(_ snapshot: SystemSnapshot, id: String?, generation ticket: UInt64,
                lease: IOSSystemSurfaceLease) async throws -> Int {
        guard lease.valid, ticket == generation, owner == snapshot.owner else { throw SystemSnapshotError("stale_session") }
        let targets = Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == snapshot.owner && (id == nil || $0.id == id)
                && !($0.attributes.kind == .ride && snapshot.ride?.state == .ended)
                && Self.isLive($0.activityState)
        }
        guard !targets.isEmpty else { throw SystemSnapshotError("live_activity_not_running") }
        for activity in targets {
            guard lease.valid, ticket == generation, owner == snapshot.owner else { throw SystemSnapshotError("stale_session") }
            let state = ZeehoActivityAttributes.ContentState(snapshot: snapshot)
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: staleDate(snapshot, kind: activity.attributes.kind)))
            } else { await activity.update(using: state) }
        }
        return targets.count
    }

    func end(owner expected: SystemSnapshotOwner, id: String? = nil, kind: ZeehoActivityKind? = nil) async -> Int {
        let targets = Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == expected && (id == nil || $0.id == id) && (kind == nil || $0.attributes.kind == kind)
        }
        for activity in targets { await finish(activity) }
        return targets.count
    }

    private func staleDate(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind) -> Date {
        var deadlines = [snapshot.expiresAt]
        if kind == .ride, let ride = snapshot.ride {
            deadlines.append(ride.updatedAt + 10_000)
            if ride.speedKph != nil, let timestamp = ride.speedUpdatedAt { deadlines.append(timestamp + 10_000) }
        } else if let vehicle = snapshot.vehicle {
            if vehicle.socPercent != nil, let timestamp = vehicle.socUpdatedAt { deadlines.append(timestamp + 180_000) }
            if vehicle.charging != nil, let timestamp = vehicle.chargingUpdatedAt { deadlines.append(timestamp + 180_000) }
            if vehicle.charging == true, vehicle.chargeProgressPercent != nil,
               let timestamp = vehicle.chargeProgressUpdatedAt { deadlines.append(timestamp + 180_000) }
        }
        return Date(timeIntervalSince1970: Double(deadlines.min() ?? snapshot.expiresAt) / 1000)
    }

    private func finish(_ activity: Activity<ZeehoActivityAttributes>) async {
        if #available(iOS 16.2, *) { await activity.end(nil, dismissalPolicy: .immediate) }
        else { await activity.end(using: nil, dismissalPolicy: .immediate) }
    }
}

final class IOSSystemSurfacesService: NSObject, IOSBridgeService, IOSBridgeCancellableService,
                                      IOSSystemSurfacePublisher, UIAdaptivePresentationControllerDelegate {
    let methods = ["system.surfaces.status", "system.snapshot", "liveActivity.start", "liveActivity.update", "liveActivity.end", "widgets.reload"]
    static let widgetKind = "ZeehoVehicleWidget"
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.system-surfaces", qos: .utility)
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var scope: IOSRideScope?
    private var owner: SystemSnapshotOwner?
    private var epoch: UInt64 = 0
    private var page: UInt64 = 0
    private var ownerLease = IOSSystemSurfaceLease()
    private var approved = false
    private var revoking = false
    private var latest: SystemSnapshot?
    private var nativeRide: SystemRideSnapshot?
    private var liveManagerObject: AnyObject?
    private var jobs: [UUID: Job] = [:]
    private var interactiveJob: Job?
    private var pendingWrites = 0
    private var publishWork: DispatchWorkItem?
    private var lastNativePublish = -Double.infinity
    private var lastWidgetReload = -Double.infinity
    private var lastWidgetEdge = ""
    private var lastError: String?

    private final class Job {
        let id = UUID()
        let method: String
        let args: NSArray
        let page: UInt64
        let scope: IOSRideScope?
        let owner: SystemSnapshotOwner?
        let lease = IOSSystemSurfaceLease()
        var reply: ((Any?, String?) -> Void)?
        var activityKind: ZeehoActivityKind?
        weak var alert: UIAlertController?
        init(method: String, args: [Any], page: UInt64, scope: IOSRideScope?, owner: SystemSnapshotOwner?,
             reply: @escaping (Any?, String?) -> Void) {
            self.method = method; self.args = args as NSArray; self.page = page
            self.scope = scope; self.owner = owner; self.reply = reply
        }
    }

    deinit { ownerLease.cancel(); publishWork?.cancel() }

    // MARK: - 持久化（scopeID / approved）
    //
    // 键里带 accountVINHash，换账号或换车时自然读不到旧值，不需要额外清理。
    // 为什么必须持久化：
    // 1) scopeID 每次启动随机生成，重启后 owner 必然与上一会话不等，旧 Live Activity
    //    会被 setScope 当作「别人的活动」结束掉——用户会觉得每次冷启动活动都消失；
    // 2) approved 是纯内存字段，scopeChanged 每次都置 false，于是「首次启用需确认」
    //    实际退化成「每次会话都要确认」，与文档不符，且普通前台采样会被静默拒绝。
    private static let scopeIDPrefix = "io.github.lswlc33.dashboard.ios.system.scope."
    private static let approvedPrefix = "io.github.lswlc33.dashboard.ios.system.approved."
    private static let defaults = UserDefaults.standard

    /// 读取（或首次生成并落盘）该账号+VIN 的稳定 scopeID。
    private static func stableScopeID(for hash: String) -> String {
        let key = scopeIDPrefix + hash
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    private static func loadApproved(for hash: String) -> Bool {
        defaults.bool(forKey: approvedPrefix + hash)
    }

    private static func saveApproved(_ value: Bool, for hash: String) {
        let key = approvedPrefix + hash
        if value { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// scopeChanged 时调用。
    ///
    /// - 有 owner：以持久化授权为准（同一账号+VIN 重启后仍然是「已启用」）；
    /// - 没有 owner（冷启动未握手 / 桥关闭 / 未登录）：内存里置 false，让 status 如实
    ///   显示「尚未授权」，但**不**删除 UserDefaults 里的值——下一次 sync.session 会读回来，
    ///   否则一次页面刷新就要用户重新确认一遍。
    private func adoptPersistedState(for hash: String?) {
        guard let hash = hash else { approved = false; return }
        approved = Self.loadApproved(for: hash)
    }

    /// 用户点了「启用」确认框：内存 + UserDefaults 同时置位，重启后不必再确认一次。
    private func grantApproval() {
        approved = true
        if let hash = owner?.accountVINHash { Self.saveApproved(true, for: hash) }
    }

    /// 用户点了「关闭系统显示」：撤销持久化授权，下次必须重新走原生确认。
    private func revokeApproval() {
        approved = false
        if let hash = owner?.accountVINHash { Self.saveApproved(false, for: hash) }
    }

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread)
        scopeProvider = provider
        scopeChanged(force: true)
    }
    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }

    func scopeChanged(force: Bool = false) {
        precondition(Thread.isMainThread)
        let next = scopeProvider?()
        guard force || next != scope else { return }
        let previousOwner = owner
        ownerLease.cancel(); ownerLease = IOSSystemSurfaceLease()
        cancelJobs("stale_session")
        publishWork?.cancel(); publishWork = nil
        epoch &+= 1
        scope = next
        // scopeID 改成按 accountVINHash 稳定的值（落 UserDefaults）：
        // 同一账号+VIN 重启后 owner 相等，上一会话的 Live Activity 能被接管而不是被结束。
        owner = next.flatMap {
            $0.valid ? SystemSnapshotOwner(scopeID: Self.stableScopeID(for: $0.ownerHash),
                                           accountVINHash: $0.ownerHash) : nil
        }
        revoking = false; latest = nil; nativeRide = nil; lastError = nil
        lastWidgetReload = -Double.infinity; lastWidgetEdge = ""
        // approved 也从持久化里取；没拿到 scope 的中间态保留当前内存值，
        // 否则一次导航刷新就把用户授权抹成「每次都要求确认」。
        adoptPersistedState(for: owner?.accountVINHash)
        let ticket = epoch
        let selected = owner
        // 只有「真的换账号/换 VIN」才清共享快照：
        // - previousOwner == nil（冷启动、桥关闭）时上一会话的快照是小组件唯一的数据，
        //   清掉就变成「每次启动小组件都空」；
        // - 同 hash（同一辆车、同一账号）重启也是同一份数据，没有理由删；
        // - scopeProvider 已被清空（bridgeClosed）表示不是用户的撤销动作，也保留。
        let providerAlive = scopeProvider != nil
        let shouldClearPrevious: Bool
        if let previous = previousOwner {
            if let next = selected { shouldClearPrevious = previous.accountVINHash != next.accountVINHash }
            // 桥还在但没有车辆 = 用户明确登出/切换成无车状态，这时才清旧快照。
            else { shouldClearPrevious = providerAlive }
        } else { shouldClearPrevious = false }
        let keepHash = selected?.accountVINHash
        // 同一串行队列让旧写结束后必定清理；新 owner 写不能越过这道清理。
        // previousOwner == nil 时（冷启动 / 桥关闭）只清「确定是别的账号」的遗留快照，
        // 且必须已知 keepHash，否则就把上一会话的数据留下了（这正是 ② 要修的）。
        worker.async { [weak self] in
            do {
                if let previous = previousOwner, shouldClearPrevious {
                    try SystemSnapshotStore.clear(expectedOwner: previous)
                } else if previousOwner == nil, let keepHash = keepHash,
                          let persisted = try SystemSnapshotStore.currentOwner(),
                          persisted.accountVINHash != keepHash {
                    try SystemSnapshotStore.clear(expectedOwner: persisted)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.epoch == ticket else { return }
                    self.lastError = Self.code(error)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.epoch == ticket else { return }
                self.reloadWidgets(force: true, snapshot: nil)
            }
        }
        if #available(iOS 16.1, *) {
            let manager = liveManager()
            Task { await manager.setScope(selected, generation: ticket) }
        }
    }

    func bridgeClosed() {
        precondition(Thread.isMainThread)
        scopeProvider = nil
        scopeChanged(force: true)
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        page &+= 1
        cancelJobs("stale_navigation")
        scopeChanged()
        // 纯网页刷新不撤销已由原生按钮启动的活动；真正的账号/VIN/credential epoch 改变才结束。
    }
    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        cancelJobs("foreground_required")
        scopeChanged()
    }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        for job in Array(jobs.values) where job.method == method && job.args.isEqual(to: args) {
            finish(job, failure("operation_cancelled"), cancel: true)
        }
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        scopeChanged()
        var operation: Job?
        do {
            guard args.count <= 1, args.isEmpty || args.first is [String: Any] else { throw SystemSnapshotError("invalid_args") }
            let options = args.first as? [String: Any] ?? [:]
            if method == "system.surfaces.status" {
                guard options.isEmpty else { throw SystemSnapshotError("invalid_args") }
                let job = try begin(method, args: args, reply: reply)
                operation = job
                status(job)
                return
            }
            guard UIApplication.shared.applicationState == .active else { throw SystemSnapshotError("foreground_required") }
            guard !revoking else { throw SystemSnapshotError("system_surfaces_busy") }
            let current = try checkedScope(options)
            let availability = runtimeAvailability()
            guard availability["supported"] as? Bool == true else {
                throw SystemSnapshotError(availability["reason"] as? String ?? "system_surfaces_unavailable")
            }
            let job = try begin(method, args: args, reply: reply)
            operation = job
            switch method {
            case "system.snapshot":
                if try optionalBoolean(options["enable"]) == false {
                    try validateSnapshotKeys(options)
                    confirm(job, title: IOSStrings.systemSnapshotDisableTitle, message: IOSStrings.systemSnapshotDisableMessage) { [weak self] in
                        self?.disableSystemSurfaces(job)
                    }
                    return
                }
                let vehicle = try vehicleSnapshot(options, scope: current)
                if approved { saveVehicle(vehicle, job: job) }
                else if try optionalBoolean(options["enable"]) == true {
                    confirm(job, title: IOSStrings.systemSnapshotTitle, message: IOSStrings.systemSnapshotMessage) { [weak self] in
                        guard let self = self, self.current(job) else { return }
                        self.grantApproval()
                        self.saveVehicle(vehicle, job: job)
                    }
                } else { finish(job, failure("snapshot_consent_required")) }
            case "liveActivity.start":
                try validateAction(options, allowing: ["kind"])
                guard availability["liveActivitiesSupported"] as? Bool == true else {
                    finish(job, failure(availability["liveActivitiesReason"] as? String ?? "live_activity_unavailable")); return
                }
                let value = try candidate()
                let kind = try activityKind(options["kind"], snapshot: value)
                job.activityKind = kind
                confirm(job, title: IOSStrings.liveActivityStartTitle, message: IOSStrings.liveActivityStartMessage) { [weak self] in
                    self?.startActivity(value, kind: kind, job: job)
                }
            case "liveActivity.update":
                try validateAction(options)
                guard approved, let value = latest, !value.isStale() else { finish(job, failure("fresh_snapshot_required")); return }
                updateActivity(value, id: try activityID(options), job: job)
            case "liveActivity.end":
                try validateAction(options)
                let id = try activityID(options)
                confirm(job, title: IOSStrings.liveActivityEndTitle, message: IOSStrings.liveActivityEndMessage) { [weak self] in
                    self?.endActivity(id: id, job: job)
                }
            case "widgets.reload":
                try validateAction(options, includeID: false)
                guard approved, let value = latest else { finish(job, failure("snapshot_consent_required")); return }
                let didReload = reloadWidgets(force: false, snapshot: value)
                finish(job, ["ok": true, "reloaded": didReload, "reason": didReload ? "reload_requested" : "reload_throttled"])
            default: finish(job, failure("unsupported_method"))
            }
        } catch {
            if let job = operation {
                finish(job, failure(Self.code(error)))
            } else { reply(failure(Self.code(error)), nil) }
        }
    }

    // runtime 元数据与容器检查不等于本会话已经做过 Apple 编译/真机验收；绝不请求系统权限来探测。
    func runtimeAvailability() -> [String: Any] {
        precondition(Thread.isMainThread)
        let plugin = Bundle.main.bundleURL.appendingPathComponent("PlugIns/DashboardWidgets.appex", isDirectory: true)
        let bundle = Bundle(url: plugin)
        let extensionInfo = bundle?.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let executable = plugin.appendingPathComponent("DashboardWidgets", isDirectory: false)
        let embedded = bundle?.bundleIdentifier == "io.github.lswlc33.dashboard.ios.widgets"
            && extensionInfo?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension"
            && FileManager.default.isExecutableFile(atPath: executable.path)
        let group = SystemSnapshotStore.isAvailable()
        let supported = embedded && group
        let declaredLive = Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true
        var liveSupported = false
        var authorization = false
        if #available(iOS 16.1, *) {
            liveSupported = supported && declaredLive
            authorization = liveSupported && ActivityAuthorizationInfo().areActivitiesEnabled
        }
        let reason: String? = !group ? "app_group_unavailable" : (!embedded ? "widget_extension_missing" : nil)
        let liveReason = reason ?? (!declaredLive ? "live_activities_not_declared" : (!liveSupported ? "ios_16_1_required" : (!authorization ? "live_activities_disabled" : "available")))
        return ["supported": supported, "embedded": embedded, "appGroupAvailable": group,
                "liveActivitiesSupported": liveSupported, "authorizationEnabled": authorization,
                "reason": reason as Any? ?? NSNull(), "liveActivitiesReason": liveReason,
                "verification": "runtime_bundle_check", "minimumLiveActivitiesIOS": "16.1"]
    }

    private func status(_ job: Job) {
        if #available(iOS 16.1, *) {
            let manager = liveManager(); let selected = owner; let ticket = epoch
            Task { @MainActor [weak self] in
                await manager.setScope(selected, generation: ticket)
                let running = await manager.running(owner: selected)
                guard let self = self, self.current(job) else { return }
                self.finish(job, self.statusValue(running))
            }
        } else { finish(job, statusValue([])) }
    }
    private func statusValue(_ running: [IOSRunningSystemActivity]) -> [String: Any] {
        let availability = runtimeAvailability()
        let supported = availability["supported"] as? Bool == true
        let liveSupported = availability["liveActivitiesSupported"] as? Bool == true
        let authorization = availability["authorizationEnabled"] as? Bool == true
        var live: [String: Any] = ["supported": liveSupported, "enabled": liveSupported && authorization,
            "authorizationEnabled": authorization, "running": !running.isEmpty,
            "minimumIOS": "16.1", "dynamicIsland": "os_managed", "reason": availability["liveActivitiesReason"] ?? NSNull()]
        if #available(iOS 16.2, *) { live["staleDateAutomatic"] = liveSupported }
        else { live["staleDateAutomatic"] = false }
        if let first = running.first { live["id"] = first.id; live["kind"] = first.kind.rawValue }
        var stored: [String: Any] = ["available": latest != nil && approved, "consentRequired": !approved,
            "stale": latest?.isStale() ?? true, "capturedAt": latest?.capturedAt as Any? ?? NSNull(),
            "expiresAt": latest?.expiresAt as Any? ?? NSNull(),
            // 网页读 state.status?.snapshot?.reason 显示失败原因；后台发布失败只写进顶层
            // lastError，网页不刷新就永远看不到，所以这里同时落到 snapshot 里。
            "reason": lastError as Any? ?? NSNull()]
        if let owner = owner { stored["owner"] = ownerJSON(owner) }
        return ["ok": true, "supported": supported, "enabled": supported && approved,
            "liveActivities": live, "widgets": ["supported": supported, "enabled": supported && approved && latest != nil,
                "appGroupAvailable": availability["appGroupAvailable"] ?? false, "embedded": availability["embedded"] ?? false,
                "kind": Self.widgetKind, "placement": "os_managed", "reason": availability["reason"] ?? NSNull()],
            "snapshot": stored, "scope": owner.map(ownerJSON) as Any? ?? NSNull(),
            "reason": lastError as Any? ?? availability["reason"] ?? NSNull(), "backgroundPolling": false,
            "pushNotifications": false, "verification": "runtime_bundle_check"]
    }

    private func checkedScope(_ options: [String: Any]) throws -> IOSRideScope {
        guard let current = scopeProvider?(), current.valid, current == scope, owner != nil else {
            throw SystemSnapshotError("authorized_vehicle_required")
        }
        if let account = options["accountId"] { guard account as? String == current.accountID else { throw SystemSnapshotError("stale_session") } }
        if let vin = options["vin"] { guard vin as? String == current.vin else { throw SystemSnapshotError("stale_session") } }
        if let generation = options["generation"] {
            let text = generation as? String ?? IOSBridgePolicy.integer(generation).map(String.init)
            guard text == current.generation else { throw SystemSnapshotError("stale_session") }
        }
        return current
    }
    private func validateAction(_ options: [String: Any], allowing extras: Set<String> = [], includeID: Bool = true) throws {
        var allowed: Set<String> = ["accountId", "vin", "generation"]
        if includeID { allowed.insert("id") }
        guard Set(options.keys).isSubset(of: allowed.union(extras)) else { throw SystemSnapshotError("invalid_args") }
    }
    private func validateSnapshotKeys(_ options: [String: Any]) throws {
        let allowed: Set<String> = ["accountId", "vin", "generation", "source", "capturedAt", "enable", "name",
            "socPercent", "socUpdatedAt", "charging", "chargingUpdatedAt", "chargeProgressPercent", "chargeProgressUpdatedAt"]
        guard Set(options.keys).isSubset(of: allowed) else { throw SystemSnapshotError("invalid_args") }
    }
    private func vehicleSnapshot(_ options: [String: Any], scope: IOSRideScope) throws -> SystemVehicleSnapshot {
        try validateSnapshotKeys(options)
        guard options["accountId"] as? String == scope.accountID,
              options["vin"] as? String == scope.vin, options["source"] as? String == "foreground",
              let captured = try timestamp(options["capturedAt"]) else { throw SystemSnapshotError("invalid_snapshot") }
        _ = try optionalBoolean(options["enable"])
        let soc = try number(options["socPercent"], range: 0...100)
        let socAt = try timestamp(options["socUpdatedAt"])
        let charging = try optionalBoolean(options["charging"])
        let chargingAt = try timestamp(options["chargingUpdatedAt"])
        // 充电进度只做范围校验（0...100），键保留：网页侧目前不写这个字段（恒为 null），
        // 但原生白名单与 Shared 的校验都已支持，网页补上采样后不需要再改壳。
        let progress = try number(options["chargeProgressPercent"], range: 0...100)
        let progressAt = try timestamp(options["chargeProgressUpdatedAt"])
        guard (soc == nil) == (socAt == nil), (charging == nil) == (chargingAt == nil),
              (progress == nil) == (progressAt == nil),
              [socAt, chargingAt, progressAt].allSatisfy({ $0.map { $0 <= captured } ?? true }) else {
            throw SystemSnapshotError("snapshot_timestamp_required")
        }
        var name: String?
        if let value = options["name"], !(value is NSNull) {
            guard let text = value as? String else { throw SystemSnapshotError("invalid_vehicle_name") }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 40, clean.utf8.count <= 160,
                  !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !clean.contains("@"), !clean.contains("://"),
                  clean.range(of: scope.vin, options: .caseInsensitive) == nil else { throw SystemSnapshotError("invalid_vehicle_name") }
            name = clean
        }
        guard soc != nil || charging != nil || progress != nil || name != nil else { throw SystemSnapshotError("snapshot_data_required") }
        let updated = [socAt, chargingAt, progressAt].compactMap { $0 }.max() ?? captured
        // 顶层时间跟真实字段同步时间走；不能靠页面刷新时间把旧车况变新。
        let suffix = scope.vin.utf8.count > 6 ? String(scope.vin.suffix(4)) : nil
        return SystemVehicleSnapshot(name: name, vinDisplaySuffix: suffix, socPercent: soc, socUpdatedAt: socAt,
            charging: charging, chargingUpdatedAt: chargingAt, chargeProgressPercent: progress,
            chargeProgressUpdatedAt: progressAt, updatedAt: updated)
    }
    private func timestamp(_ value: Any?) throws -> Int64? {
        guard let value = value, !(value is NSNull) else { return nil }
        guard let integer = IOSBridgePolicy.integer(value), integer >= 946_684_800_000 else { throw SystemSnapshotError("invalid_snapshot_time") }
        let date = Date(timeIntervalSince1970: Double(integer) / 1000)
        guard SystemSnapshotFreshness.isFresh(Int64(integer), at: Date(), maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds),
              date.timeIntervalSince1970.isFinite else { throw SystemSnapshotError("snapshot_stale") }
        return Int64(integer)
    }
    private func number(_ value: Any?, range: ClosedRange<Double>) throws -> Double? {
        guard let value = value, !(value is NSNull) else { return nil }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw SystemSnapshotError("invalid_snapshot_number") }
        return value.doubleValue
    }
    private func optionalBoolean(_ value: Any?) throws -> Bool? {
        guard let value = value, !(value is NSNull) else { return nil }
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw SystemSnapshotError("invalid_snapshot_boolean") }
        return value.boolValue
    }
    private func activityID(_ options: [String: Any]) throws -> String? {
        guard let value = options["id"] else { return nil }
        guard let value = value as? String, IOSBridgePolicy.identifier(value, limit: 128) else { throw SystemSnapshotError("invalid_activity_id") }
        return value
    }
    private func activityKind(_ value: Any?, snapshot: SystemSnapshot) throws -> ZeehoActivityKind {
        if let value = value {
            guard let text = value as? String, let kind = ZeehoActivityKind(rawValue: text) else { throw SystemSnapshotError("invalid_activity_kind") }
            return kind
        }
        return snapshot.ride.map({ $0.state != .ended }) == true ? .ride
            : (snapshot.vehicle?.visibleCharging() == true ? .charging : .vehicle)
    }
    private func candidate(vehicle: SystemVehicleSnapshot? = nil) throws -> SystemSnapshot {
        guard let owner = owner else { throw SystemSnapshotError("authorized_vehicle_required") }
        let vehicle = vehicle ?? latest?.vehicle
        let ride = nativeRide ?? latest?.ride
        let captured = [vehicle?.updatedAt, ride?.updatedAt].compactMap { $0 }.max()
        guard let captured = captured else { throw SystemSnapshotError("snapshot_data_required") }
        let expiry = max(vehicle.map { $0.updatedAt + 180_000 } ?? 0, ride.map { $0.updatedAt + 10_000 } ?? 0)
        return try SystemSnapshot(owner: owner, capturedAt: captured, expiresAt: max(captured + 1, expiry),
            vehicle: vehicle, ride: ride).validated(expectedOwner: owner)
    }

    private func disableSystemSurfaces(_ job: Job) {
        guard current(job), let selected = owner else { finish(job, failure("stale_session")); return }
        let ticket = epoch
        revoking = true; latest = nil; nativeRide = nil
        revokeApproval()
        ownerLease.cancel()
        publishWork?.cancel(); publishWork = nil
        for other in Array(jobs.values) where other !== job { finish(other, failure("system_surfaces_disabled"), cancel: true) }
        // clear 排在本服务所有旧写之后；未完成的 activity.start lease 已取消，不能在关闭之后复活。
        worker.async { [weak self] in
            let result: Result<Void, Error>
            do { try SystemSnapshotStore.clear(expectedOwner: selected); result = .success(()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                Task { @MainActor [weak self] in
                    // 这是唯一允许「结束全部活动」的显式撤销路径（clearScope），
                    // 与 setScope(nil) 的「未知状态」严格区分。
                    // 用撤销开始时抓的 ticket：期间换了账号/VIN 时新 epoch 更大，
                    // clearScope 会因 ticket < generation 直接跳过，不会杀新车的活动。
                    if #available(iOS 16.1, *) { _ = await self?.liveManager().clearScope(generation: ticket) }
                    guard let self = self, self.epoch == ticket, self.owner == selected else { return }
                    self.revoking = false; self.ownerLease = IOSSystemSurfaceLease()
                    self.reloadWidgets(force: true, snapshot: nil)
                    switch result {
                    case .success:
                        self.lastError = nil
                        if self.current(job) {
                            self.finish(job, ["ok": true, "enabled": false, "stored": false, "cleared": true,
                                              "surfaces": self.statusValue([])])
                        }
                    case .failure(let error):
                        self.lastError = Self.code(error)
                        if self.current(job) { self.finish(job, self.failure(Self.code(error))) }
                    }
                }
            }
        }
    }

    /// 成功落盘的统一回执。
    ///
    /// 除了 `snapshot`，还带上 `surfaces`（与 status 同一份结构）：网页在
    /// `system-surfaces.js` 里读 `reply.surfaces` 直接更新界面，缺了它就只能多发一次
    /// `system.surfaces.status`，而那一轮很可能又赶上页面隐藏被丢掉。
    private func finishStored(_ job: Job, value: SystemSnapshot) {
        finish(job, ["ok": true, "stored": true, "snapshot": snapshotJSON(value),
                     "surfaces": statusValue(runningValue())])
    }

    /// 当前 owner 下正在跑的活动。取不到（16.1 以下）就是空数组。
    private func runningValue() -> [IOSRunningSystemActivity] {
        guard #available(iOS 16.1, *), let selected = owner else { return [] }
        return Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == selected && IOSLiveActivityManager.isLive($0.activityState)
        }.map { IOSRunningSystemActivity(id: $0.id, kind: $0.attributes.kind) }
    }

    private func saveVehicle(_ value: SystemVehicleSnapshot, job: Job) {
        do {
            let value = try candidate(vehicle: value)
            guard !value.isStale() else { throw SystemSnapshotError("snapshot_stale") }
            try persist(value, job: job)
        } catch { finish(job, failure(Self.code(error))) }
    }
    private func persist(_ value: SystemSnapshot, job: Job?, completion: (() -> Void)? = nil) throws {
        guard approved, value.owner == owner, pendingWrites < 8 else { throw SystemSnapshotError("snapshot_store_busy") }
        let selectedScope = scope; let ticket = epoch; let lease = ownerLease
        pendingWrites += 1
        worker.async { [weak self] in
            let result: Result<Void, Error>
            do {
                guard lease.valid, job?.lease.valid != false else { throw SystemSnapshotError("operation_cancelled") }
                try SystemSnapshotStore.write(value, expectedOwner: value.owner)
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingWrites -= 1
                guard lease.valid, ticket == self.epoch, self.scopeProvider?() == selectedScope else { return }
                if let job = job, !self.current(job) { return }
                switch result {
                case .success:
                    self.latest = value; self.lastError = nil
                    self.reloadWidgets(force: false, snapshot: value)
                    if let completion = completion { completion() }
                    else {
                        self.publishExistingActivity(value)
                        if let job = job { self.finishStored(job, value: value) }
                    }
                case .failure(let error):
                    self.lastError = Self.code(error)
                    if let job = job { self.finish(job, self.failure(Self.code(error))) }
                }
            }
        }
    }

    func publishRide(_ value: SystemRideSnapshot, scope captured: IOSRideScope) {
        precondition(Thread.isMainThread)
        scopeChanged()
        guard captured == scope, captured == scopeProvider?() else { return }
        let edge = nativeRide?.state != value.state || nativeRide?.gapCount != value.gapCount
        guard nativeRide == nil || value.updatedAt >= nativeRide!.updatedAt else { return }
        nativeRide = value
        if value.state == .ended {
            for job in Array(jobs.values) where job.method == "liveActivity.update"
                || (job.method == "liveActivity.start" && job.activityKind == .ride) {
                finish(job, failure("native_recording_ended"), cancel: true)
            }
            if let owner = owner, #available(iOS 16.1, *) {
                let manager = liveManager()
                Task { _ = await manager.end(owner: owner, kind: .ride) }
            }
        }
        guard approved else { return }
        publishWork?.cancel()
        let delay = edge ? 0 : max(0, 5 - (ProcessInfo.processInfo.systemUptime - lastNativePublish))
        let ticket = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.epoch == ticket, self.scopeProvider?() == captured else { return }
            self.publishWork = nil
            do {
                let candidate = try self.candidate()
                guard candidate != self.latest else { return }
                try self.persist(candidate, job: nil)
                self.lastNativePublish = ProcessInfo.processInfo.systemUptime
            } catch { self.lastError = Self.code(error) }
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func systemSurfacesDisconnected(scope captured: IOSRideScope) {
        precondition(Thread.isMainThread)
        guard captured == scope, captured == scopeProvider?(), let owner = owner else { return }
        for job in Array(jobs.values) where job.method == "liveActivity.update"
            || (job.method == "liveActivity.start" && job.activityKind == .ride) {
            finish(job, failure("recording_source_disconnected"), cancel: true)
        }
        if #available(iOS 16.1, *) {
            let manager = liveManager()
            Task { _ = await manager.end(owner: owner, kind: .ride) }
        }
    }

    private func startActivity(_ value: SystemSnapshot, kind: ZeehoActivityKind, job: Job) {
        guard current(job) else { return }
        let availability = runtimeAvailability()
        guard availability["authorizationEnabled"] as? Bool == true else { finish(job, failure("live_activities_disabled")); return }
        guard !value.isStale() else { finish(job, failure("snapshot_stale")); return }
        // 用户在确认框点了继续：与 system.snapshot 的启用一样落盘，重启后不必重复确认。
        grantApproval()
        do {
            try persist(value, job: job) { [weak self] in
                guard let self = self, self.current(job), #available(iOS 16.1, *) else { return }
                let manager = self.liveManager(); let ticket = self.epoch
                Task { @MainActor [weak self] in
                    do {
                        await manager.setScope(value.owner, generation: ticket)
                        let started = try await manager.start(value, kind: kind, generation: ticket, lease: job.lease)
                        guard let self = self, self.current(job) else {
                            if started.created { _ = await manager.end(owner: value.owner, id: started.id) }
                            return
                        }
                        self.finish(job, ["ok": true, "id": started.id, "kind": kind.rawValue, "running": true])
                    } catch { self?.finish(job, self?.failure(Self.code(error)) ?? ["ok": false]) }
                }
            }
        } catch { finish(job, failure(Self.code(error))) }
    }
    private func updateActivity(_ value: SystemSnapshot, id: String?, job: Job) {
        guard #available(iOS 16.1, *) else { finish(job, failure("ios_16_1_required")); return }
        let manager = liveManager(); let ticket = epoch
        Task { @MainActor [weak self] in
            do {
                await manager.setScope(value.owner, generation: ticket)
                let count = try await manager.update(value, id: id, generation: ticket, lease: job.lease)
                guard let self = self, self.current(job) else { return }
                self.finish(job, ["ok": true, "updated": count])
            } catch { self?.finish(job, self?.failure(Self.code(error)) ?? ["ok": false]) }
        }
    }
    private func publishExistingActivity(_ value: SystemSnapshot) {
        guard !revoking, #available(iOS 16.1, *) else { return }
        let manager = liveManager(); let ticket = epoch; let lease = ownerLease
        Task {
            await manager.setScope(value.owner, generation: ticket)
            // 没有用户已授权活动时只落 Widget 快照，绝不因刷新/录制自动 request 新活动。
            _ = try? await manager.update(value, id: nil, generation: ticket, lease: lease)
        }
    }
    private func endActivity(id: String?, job: Job) {
        guard let owner = job.owner, current(job), #available(iOS 16.1, *) else { finish(job, failure("live_activity_unavailable")); return }
        let manager = liveManager()
        Task { @MainActor [weak self] in
            guard job.lease.valid else { return }
            let count = await manager.end(owner: owner, id: id)
            guard let self = self, self.current(job) else { return }
            guard count > 0 else { self.finish(job, self.failure("live_activity_not_running")); return }
            self.finish(job, ["ok": true, "ended": count, "running": false])
        }
    }
    @available(iOS 16.1, *)
    private func liveManager() -> IOSLiveActivityManager {
        if let manager = liveManagerObject as? IOSLiveActivityManager { return manager }
        let manager = IOSLiveActivityManager()
        liveManagerObject = manager
        return manager
    }

    @discardableResult private func reloadWidgets(force: Bool, snapshot: SystemSnapshot?) -> Bool {
        let available = runtimeAvailability()
        guard available["supported"] as? Bool == true else { return false }
        let edge = snapshot.map {
            "\($0.vehicle?.charging.map(String.init) ?? "unknown"):\($0.ride?.state.rawValue ?? "none"):\($0.ride?.gapCount ?? 0)"
        } ?? "cleared"
        let now = ProcessInfo.processInfo.systemUptime
        guard force || edge != lastWidgetEdge || now - lastWidgetReload >= 300 else { return false }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        lastWidgetEdge = edge; lastWidgetReload = now
        return true
    }

    private func begin(_ method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) throws -> Job {
        guard jobs.count < 8 else { throw SystemSnapshotError("system_surfaces_busy") }
        let job = Job(method: method, args: args, page: page, scope: scope, owner: owner, reply: reply)
        jobs[job.id] = job
        return job
    }
    private func current(_ job: Job) -> Bool {
        jobs[job.id] === job && job.reply != nil && job.lease.valid && job.page == page
            && job.scope == scope && job.scope == scopeProvider?() && job.owner == owner
    }
    private func finish(_ job: Job, _ value: [String: Any], cancel: Bool = false) {
        guard jobs[job.id] === job, let reply = job.reply else { return }
        job.reply = nil
        if cancel { job.lease.cancel() }
        jobs.removeValue(forKey: job.id)
        if interactiveJob === job { interactiveJob = nil }
        job.alert?.dismiss(animated: false); job.alert = nil
        reply(value, nil)
    }
    private func cancelJobs(_ code: String) {
        for job in Array(jobs.values) { finish(job, failure(code), cancel: true) }
    }
    private func confirm(_ job: Job, title: String, message: String, action: @escaping () -> Void) {
        guard current(job), UIApplication.shared.applicationState == .active else { finish(job, failure("foreground_required")); return }
        guard interactiveJob == nil, let presenter = presenterProvider?(), presenter.isViewLoaded,
              presenter.view.window != nil, presenter.presentedViewController == nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented else { finish(job, failure("system_surfaces_busy")); return }
        interactiveJob = job
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak job] _ in
            guard let self = self, let job = job else { return }
            self.finish(job, self.failure("user_cancelled"), cancel: true)
        })
        alert.addAction(UIAlertAction(title: IOSStrings.continueButton, style: .default) { [weak self, weak job] _ in
            guard let self = self, let job = job, self.current(job), UIApplication.shared.applicationState == .active else { return }
            job.alert = nil
            action()
        })
        job.alert = alert
        presenter.present(alert, animated: true)
        alert.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let job = interactiveJob else { return }
        finish(job, failure("user_cancelled"), cancel: true)
    }
    private func ownerJSON(_ value: SystemSnapshotOwner) -> [String: String] {
        ["scopeID": value.scopeID, "accountVINHash": value.accountVINHash]
    }
    private func snapshotJSON(_ value: SystemSnapshot) -> [String: Any] {
        // 编码的只是 Shared 白名单；绝不回显桥凭据、原始 VIN 或 Ride 的 rawGPS。
        guard let data = try? JSONEncoder().encode(value), data.count <= SystemSnapshotStore.maxSnapshotBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private func failure(_ code: String) -> [String: Any] { IOSBridgePolicy.failure(method: "system.surfaces", code: code) }

    /// 错误码归一。
    ///
    /// `Activity.request` / `update` 抛的 `ActivityAuthorizationError`（`.denied`、
    /// `.targetMaximumExceeded`、`.attributesTooLarge` …）原来一律被映射成
    /// `snapshot_storage_unavailable`，把「用户关了实时活动」「活动数超限」「属性超 4KB」
    /// 全误报成存储问题。这里单独识别，给网页可区分的稳定错误码。
    ///
    /// 用 `error as? ActivityAuthorizationError` 而不是匹配 NSError code：ActivityKit 的
    /// 错误只有 iOS 16.1+ 才有类型，deployment target 15.4 必须先过可用性分支，
    /// 且用 `as NSError` 的 domain/code 在真机与模拟器上不保证一致。
    private static func code(_ error: Error) -> String {
        if let value = error as? SystemSnapshotError { return value.code }
        if #available(iOS 16.1, *), let value = error as? ActivityAuthorizationError {
            switch value {
            case .denied: return "live_activities_denied"
            case .targetMaximumExceeded, .globalMaximumExceeded: return "live_activity_limit"
            case .attributesTooLarge: return "live_activity_attributes_too_large"
            case .unsupported, .unsupportedTarget, .unentitled: return "live_activity_unavailable"
            case .visibility: return "foreground_required"
            case .persistenceFailure: return "live_activity_persistence_failed"
            @unknown default: return "live_activity_failed"
            }
        }
        return "snapshot_storage_unavailable"
    }
}
