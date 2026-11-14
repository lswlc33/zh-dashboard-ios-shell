import Foundation
import UIKit
import ActivityKit
import WidgetKit
import CoreFoundation
import CryptoKit
import ZeehoSystemShared

// 只有已由 Ride 的原生确认启动的记录才能发布；这个出口不启动 GPS、蓝牙、网络或后台定时任务。
protocol IOSSystemSurfacePublisher: AnyObject {
    func publishRide(_ value: SystemRideSnapshot, scope: IOSRideScope)
    func systemSurfacesDisconnected(scope: IOSRideScope)
    func publishGauge(_ value: SystemGaugeSnapshot, scope: IOSRideScope)
    func systemGaugeDisconnected(scope: IOSRideScope)
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
        for activity in old {
            guard ticket == generation, owner == next else { return }
            await finish(activity)
        }
    }

    /// 显式撤销（关闭系统显示）：结束本 App 的全部活动，并清掉当前 owner 引用。
    /// 与 `setScope(nil)` 的区别就是这里真的结束活动。
    func clearScope(generation ticket: UInt64) async -> Int {
        guard ticket >= generation else { return 0 }
        generation = ticket; owner = nil
        let all = Activity<ZeehoActivityAttributes>.activities
        var ended = 0
        for activity in all {
            guard ticket == generation, owner == nil else { return ended }
            await finish(activity); ended += 1
        }
        return ended
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
            guard let ride = snapshot.ride, ride.state != .ended,
                  SystemSnapshotFreshness.isFresh(ride.updatedAt, maxAgeSeconds: SystemSnapshotFreshness.rideSpeedMaxAgeSeconds) else {
                throw SystemSnapshotError("native_recording_required")
            }
        case .vehicle:
            guard let vehicle = snapshot.vehicle,
                  SystemSnapshotFreshness.isFresh(vehicle.updatedAt, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds) else {
                throw SystemSnapshotError("fresh_vehicle_data_required")
            }
        case .gauge:
            guard snapshot.gauge?.visibleSpeedKph() != nil else { throw SystemSnapshotError("native_gauge_sample_required") }
        }
        if let existing = running(owner: snapshot.owner).first {
            guard existing.kind == kind else { throw SystemSnapshotError("another_activity_running") }
            // 复用已有活动时也要刷新内容：否则用户点「开始活动」拿到的还是上一次
            // 发布的旧电量/旧速度（created:false 曾直接返回 id，不更新任何内容）。
            // 复用也必须成功更新；取消/已结束的竞态不能被 try? 吞掉并骗报 running。
            _ = try await update(snapshot, id: existing.id, generation: ticket, lease: lease)
            guard lease.valid, ticket == generation, owner == snapshot.owner else {
                throw SystemSnapshotError("operation_cancelled")
            }
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
            // actor 在 await 时允许换 scope；不能用已经失效的样本确认成功或留下旧活动。
            guard lease.valid, ticket == generation, owner == snapshot.owner else {
                if owner != snapshot.owner { await finish(activity) }
                throw SystemSnapshotError("operation_cancelled")
            }
        }
        return targets.count
    }

    func end(owner expected: SystemSnapshotOwner, id: String? = nil, kind: ZeehoActivityKind? = nil,
             generation ticket: UInt64? = nil) async -> Int {
        if let ticket = ticket, ticket != generation { return 0 }
        let targets = Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == expected && (id == nil || $0.id == id) && (kind == nil || $0.attributes.kind == kind)
        }
        var ended = 0
        for activity in targets {
            if let ticket = ticket, ticket != generation { return ended }
            await finish(activity); ended += 1
        }
        return ended
    }

    private func staleDate(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind) -> Date {
        var deadlines = [snapshot.expiresAt]
        if kind == .gauge, let gauge = snapshot.gauge {
            deadlines.append(gauge.updatedAt + 10_000)
        } else if kind == .ride, let ride = snapshot.ride {
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
    // latest 可由 Gauge 提前更新给活动；只有 worker 写成功才更新 persistedSnapshot。
    private var persistedSnapshot: SystemSnapshot?
    private var nativeWritePending = false
    private var nativeRide: SystemRideSnapshot?
    private var nativeGauge: SystemGaugeSnapshot?
    private var lastGaugePublish = -Double.infinity
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
    // 2) 用户显式关闭过系统显示这件事必须跨会话记住，否则重启后又开始往共享区写快照。
    private static let scopeIDPrefix = "io.github.lswlc33.dashboard.ios.system.scope."
    // 小组件默认共享：只有用户显式点过「关闭系统显示」才落一个 disabled 标记。
    // 旧版用 approved 白名单（默认 false，必须先点「启用」并确认），结果新装用户
    // 加完桌面小组件永远只有「车况暂无数据」——现在改成默认开启、可显式关闭。
    private static let disabledPrefix = "io.github.lswlc33.dashboard.ios.system.disabled."
    private static let legacyApprovedPrefix = "io.github.lswlc33.dashboard.ios.system.approved."
    private static let defaults = UserDefaults.standard

    /// 读取（或首次生成并落盘）该账号+VIN 的稳定 scopeID。
    private static func stableScopeID(for hash: String) -> String {
        let key = scopeIDPrefix + hash
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    /// 默认开启，只有显式关闭过才是 false。
    private static func loadApproved(for hash: String) -> Bool {
        !defaults.bool(forKey: disabledPrefix + hash)
    }

    private static func saveApproved(_ value: Bool, for hash: String) {
        let key = disabledPrefix + hash
        if value { defaults.removeObject(forKey: key) } else { defaults.set(true, forKey: key) }
        // 旧白名单键已无意义，顺手清掉，避免以后又有人按它判断。
        defaults.removeObject(forKey: legacyApprovedPrefix + hash)
    }

    /// scopeChanged 时调用。
    ///
    /// - 有 owner：以持久化的「是否被显式关闭」为准（默认开启）；
    /// - 没有 owner（冷启动未握手 / 桥关闭 / 未登录）：内存里置 false，让 status 如实
    ///   显示「当前车辆范围未确认」，但**不**删除 UserDefaults 里的关闭标记——
    ///   下一次 sync.session 会读回来，否则一次页面刷新就把用户的关闭选择抹掉。
    private func adoptPersistedState(for hash: String?) {
        guard let hash = hash else { approved = false; return }
        approved = Self.loadApproved(for: hash)
    }

    /// 用户主动开启系统显示（或首次添加小组件触发的隐式共享）。
    private func grantApproval() {
        approved = true
        if let hash = owner?.accountVINHash { Self.saveApproved(true, for: hash) }
    }

    /// 用户点了「关闭系统显示」：撤销持久化授权，下次启动也不会自动写入。
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
                                           accountVINHash: $0.ownerHash,
                                           accountHash: Self.anonymousAccount($0.accountID)) : nil
        }
        revoking = false; latest = nil; persistedSnapshot = nil; nativeWritePending = false
        nativeRide = nil; nativeGauge = nil; lastError = nil
        lastNativePublish = -Double.infinity; lastGaugePublish = -Double.infinity
        lastWidgetReload = -Double.infinity; lastWidgetEdge = ""
        // approved 也从持久化里取；没拿到 scope 的中间态保留当前内存值，
        // 否则一次导航刷新就把用户的关闭选择抹掉。
        adoptPersistedState(for: owner?.accountVINHash)
        let ticket = epoch
        let selected = owner
        // 同账号选车保留匿名目录；换账号/显式登出清账号摘要，桥关闭的未知状态不作撤销。
        let providerAlive = scopeProvider != nil
        worker.async { [weak self] in
            do {
                if let previous = previousOwner,
                   (selected.map { !previous.sharesAccount(with: $0) } ?? providerAlive) {
                    try SystemSnapshotStore.clearAccount(expectedOwner: previous)
                }
                if let selected = selected { try SystemSnapshotStore.activate(selected) }
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
            Task {
                await manager.setScope(selected, generation: ticket)
                if selected == nil, providerAlive, let previous = previousOwner {
                    _ = await manager.end(owner: previous, generation: ticket)
                }
            }
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
            // 判据用「不是 background」而不是「== .active」：`.inactive` 是短暂过渡态
            // （下拉通知中心、切换 App 途中、来电横幅），此时页面还在前台跑，
            // 按 .active 硬拒会把这一帧的前台采样和偏好写入白白丢掉。
            guard UIApplication.shared.applicationState != .background else {
                throw SystemSnapshotError("foreground_required")
            }
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
                // 小组件零门槛：前台采样直接落盘，不再要求先去设置页点「启用」并确认。
                // 用户显式关闭过系统显示时 approved 为 false，这里如实跳过（不写快照、不弹框）。
                // enable:true 仍保留为「显式重新开启」，供设置页的启用按钮使用。
                if approved { saveVehicle(vehicle, job: job) }
                else if try optionalBoolean(options["enable"]) == true {
                    grantApproval()
                    saveVehicle(vehicle, job: job)
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
                try validateAction(options, allowing: ["kind"])
                let id = try activityID(options)
                let kind: ZeehoActivityKind?
                if let value = options["kind"] {
                    guard let text = value as? String, let parsed = ZeehoActivityKind(rawValue: text) else {
                        throw SystemSnapshotError("invalid_activity_kind")
                    }
                    kind = parsed
                } else { kind = nil }
                confirm(job, title: IOSStrings.liveActivityEndTitle, message: IOSStrings.liveActivityEndMessage) { [weak self] in
                    self?.endActivity(id: id, kind: kind, job: job)
                }
            case "widgets.reload":
                try validateAction(options, includeID: false)
                // 刷新只是请求 WidgetKit 重读；就算本会话还没有最新样本也允许触发，
                // 让用户手动刷一下就能看到磁盘上已有的快照（冷启动后 latest 是空的）。
                let didReload = reloadWidgets(force: true, snapshot: latest)
                finish(job, ["ok": true, "reloaded": didReload, "requested": didReload, "displayed": false,
                    "budget": "os_managed", "reason": didReload ? "reload_requested" : "reload_throttled"])
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
        // 重签工具改扩展 bundle ID 的规则不止一种（原样保留 / 主ID+.widgets /
        // 主ID.原组件名 都见过），任何写死或按后缀推断的比对都会误报
        // widget_extension_missing。改为按 WidgetKit 的 NSExtensionPointIdentifier
        // 在 PlugIns 里认出真正的扩展，并把每项检查结果回传，便于侧载场景定位。
        let plugins = Bundle.main.bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        var widgetPlugin: (url: URL, info: [String: Any])?
        var appexNames: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: plugins.path))?.sorted() ?? [] {
            guard name.hasSuffix(".appex") else { continue }
            appexNames.append(name)
            let url = plugins.appendingPathComponent(name, isDirectory: true)
            guard let info = Bundle(url: url)?.infoDictionary else { continue }
            let extensionInfo = info["NSExtension"] as? [String: Any]
            guard extensionInfo?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension" else { continue }
            if widgetPlugin == nil { widgetPlugin = (url, info) }
        }
        var executableName: String?
        var executableExists = false
        var executableIsExecutable = false
        if let plugin = widgetPlugin {
            let name = plugin.info[kCFBundleExecutableKey as String] as? String ?? ""
            executableName = name.isEmpty ? nil : name
            if !name.isEmpty {
                let path = plugin.url.appendingPathComponent(name, isDirectory: false).path
                executableExists = FileManager.default.fileExists(atPath: path)
                executableIsExecutable = FileManager.default.isExecutableFile(atPath: path)
            }
        }
        // 扩展可执行文件必须真的在；bundle ID 只作诊断，不作判据。
        let embedded = widgetPlugin != nil && executableIsExecutable
        let group = SystemSnapshotStore.isAvailable()
        let supported = embedded && group
        // 侧载诊断：全能签等 P12 工具会把组名换成证书团队的，原始码 app_group_unavailable
        // 看不出签成了什么。把解析结果与来源一起回给设置页，便于用户截图定位。
        let groupInfo = AppGroup.resolution()
        let widgetInfo: [String: Any] = [
            "found": embedded,
            "appexNames": appexNames,
            "bundleIdentifier": widgetPlugin?.info[kCFBundleIdentifierKey as String] as? String ?? NSNull(),
            "hostBundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(),
            "executableName": executableName ?? NSNull(),
            "executableExists": executableExists,
            "executableIsExecutable": executableIsExecutable]
        let declaredLive = Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true
        var liveSupported = false
        var authorization = false
        if #available(iOS 16.1, *) {
            liveSupported = supported && declaredLive
            authorization = liveSupported && ActivityAuthorizationInfo().areActivitiesEnabled
        }
        // 当前只用 StaticConfiguration：不再暴露「每实例选车」能力，避免声称一个没有注册的配置。
        let configurable = false
        let reason: String? = !group ? "app_group_unavailable" : (!embedded ? "widget_extension_missing" : nil)
        let liveReason = reason ?? (!declaredLive ? "live_activities_not_declared" : (!liveSupported ? "ios_16_1_required" : (!authorization ? "live_activities_disabled" : "available")))
        return ["supported": supported, "embedded": embedded, "appGroupAvailable": group,
                "appGroup": groupInfo, "widgetExtension": widgetInfo,
                "liveActivitiesSupported": liveSupported, "authorizationEnabled": authorization,
                "reason": reason as Any? ?? NSNull(), "liveActivitiesReason": liveReason,
                "verification": "runtime_bundle_check", "minimumLiveActivitiesIOS": "16.1",
                "perInstanceVehicleMinimumIOS": NSNull(), "perInstanceVehicleSelection": configurable,
                "backgroundPolling": false, "refreshBudget": "os_managed"]
    }

    private func status(_ job: Job) {
        // 冷启动时 persistedSnapshot 只在内存里，磁盘上可能已经有上次写入的快照
        // （小组件就是读那份）。回读一次，否则设置页会显示「没有快照」而桌面却显示着数据。
        // 读盘放 worker：这里带着跨进程 flock，不能占主线程。
        let ticket = epoch
        let enabled = approved
        worker.async { [weak self] in
            let stored = enabled ? try? SystemSnapshotStore.readCurrent() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.epoch == ticket, self.current(job) else { return }
                if self.persistedSnapshot == nil, let stored = stored { self.persistedSnapshot = stored }
                self.finishStatus(job)
            }
        }
    }

    private func finishStatus(_ job: Job) {
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
        // consentRequired 现在只在「用户显式关闭过系统显示」时为 true。
        // 默认开启后它不再是首次使用门槛：没有 owner（未登录/未握手）属于范围未确认，
        // 不该被网页解读成「要用户点启用」。
        let consentRequired = owner != nil && !approved
        var stored: [String: Any] = ["available": persistedSnapshot != nil && approved, "consentRequired": consentRequired,
            "stale": persistedSnapshot?.isStale() ?? true, "capturedAt": persistedSnapshot?.capturedAt as Any? ?? NSNull(),
            "expiresAt": persistedSnapshot?.expiresAt as Any? ?? NSNull(),
            // 网页读 state.status?.snapshot?.reason 显示失败原因；后台发布失败只写进顶层
            // lastError，网页不刷新就永远看不到，所以这里同时落到 snapshot 里。
            "reason": lastError as Any? ?? NSNull()]
        if let owner = owner { stored["owner"] = ownerJSON(owner) }
        let configurable = availability["perInstanceVehicleSelection"] as? Bool == true
        return ["ok": true, "supported": supported, "enabled": supported && approved,
            "liveActivities": live, "widgets": ["supported": supported, "enabled": supported && approved && persistedSnapshot != nil,
                "appGroupAvailable": availability["appGroupAvailable"] ?? false, "embedded": availability["embedded"] ?? false,
                "appGroup": availability["appGroup"] ?? NSNull(),
                "widgetExtension": availability["widgetExtension"] ?? NSNull(),
                "kind": Self.widgetKind, "placement": "os_managed", "reason": availability["reason"] ?? NSNull(),
                "perInstanceVehicleSelection": configurable, "perInstanceMinimumIOS": NSNull(),
                "supportedFamilies": ["systemSmall", "systemMedium", "systemLarge"], "refreshBudget": "os_managed", "displayed": false],
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
        // 不复用已断开的 latest.gauge；只有 native 服务本会话再次接受样本才能提供车速。
        let gauge = nativeGauge
        let captured = [vehicle?.updatedAt, ride?.updatedAt, gauge?.updatedAt].compactMap { $0 }.max()
        guard let captured = captured else { throw SystemSnapshotError("snapshot_data_required") }
        let expiry = [vehicle.map { $0.updatedAt + 180_000 }, ride.map { $0.updatedAt + 10_000 },
                      gauge.map { $0.updatedAt + 10_000 }].compactMap { $0 }.max() ?? captured + 1
        return try SystemSnapshot(owner: owner, capturedAt: captured, expiresAt: max(captured + 1, expiry),
            vehicle: vehicle, ride: ride, gauge: gauge).validated(expectedOwner: owner)
    }

    private func disableSystemSurfaces(_ job: Job) {
        guard current(job), let selected = owner else { finish(job, failure("stale_session")); return }
        let ticket = epoch
        revoking = true; latest = nil; persistedSnapshot = nil; nativeWritePending = false
        nativeRide = nil; nativeGauge = nil
        revokeApproval()
        ownerLease.cancel()
        publishWork?.cancel(); publishWork = nil
        for other in Array(jobs.values) where other !== job { finish(other, failure("system_surfaces_disabled"), cancel: true) }
        // clear 排在本服务所有旧写之后；未完成的 activity.start lease 已取消，不能在关闭之后复活。
        worker.async { [weak self] in
            let result: Result<Void, Error>
            do { try SystemSnapshotStore.clearAccount(expectedOwner: selected); result = .success(()) }
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
    private func persist(_ value: SystemSnapshot, job: Job?, didPersist: ((Bool) -> Void)? = nil,
                         completion: (() -> Void)? = nil) throws {
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
                    self.persistedSnapshot = value
                    // 写回调不能让活动车速倒退到排队前；车况沿用本次成功值，原生源使用最新已接受样本。
                    self.latest = (try? self.candidate(vehicle: value.vehicle)) ?? value
                    self.lastError = nil
                    self.reloadWidgets(force: false, snapshot: value)
                    if let completion = completion { completion() }
                    else {
                        self.publishExistingActivity(self.latest ?? value)
                        if let job = job { self.finishStored(job, value: value) }
                    }
                    didPersist?(true)
                case .failure(let error):
                    self.lastError = Self.code(error)
                    if let job = job { self.finish(job, self.failure(Self.code(error))) }
                    didPersist?(false)
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
        scheduleNativePersistence(scope: captured, immediate: edge)
    }

    // Native Ride/Gauge 同 tick 共用一个待办；只能对比成功落盘值，不能以实时内存 latest 当已写。
    private func scheduleNativePersistence(scope captured: IOSRideScope, immediate: Bool) {
        guard approved, !revoking, !nativeWritePending else { return }
        publishWork?.cancel()
        let delay = immediate ? 0 : max(0, 5 - (ProcessInfo.processInfo.systemUptime - lastNativePublish))
        let ticket = epoch
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.epoch == ticket, self.scopeProvider?() == captured,
                  !self.nativeWritePending, self.approved, !self.revoking else { return }
            self.publishWork = nil
            do {
                let candidate = try self.candidate()
                guard candidate != self.persistedSnapshot else { return }
                self.nativeWritePending = true
                try self.persist(candidate, job: nil, didPersist: { [weak self] saved in
                    guard let self = self, self.epoch == ticket, self.scopeProvider?() == captured else { return }
                    self.nativeWritePending = false
                    // 失败不消费节流时间，不自动无限重试；下个真实样本可再次尝试。
                    guard saved else { return }
                    self.lastNativePublish = ProcessInfo.processInfo.systemUptime
                    if let next = try? self.candidate(), next != self.persistedSnapshot {
                        self.scheduleNativePersistence(scope: captured, immediate: false)
                    }
                })
            } catch {
                self.nativeWritePending = false
                self.lastError = Self.code(error)
            }
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    // 只供 BLE/GPS 原生服务在其自身接受样本之后调用；没有 RPC 能伪造 recording 或原生车速。
    func publishGauge(_ value: SystemGaugeSnapshot, scope captured: IOSRideScope) {
        precondition(Thread.isMainThread)
        scopeChanged()
        guard captured == scope, captured == scopeProvider?(), value.speedKph.isFinite,
              (0...400).contains(value.speedKph), value.visibleSpeedKph() != nil,
              nativeGauge.map({ value.updatedAt >= $0.updatedAt }) ?? true else { return }
        nativeGauge = value
        if nativeRide != nil { scheduleNativePersistence(scope: captured, immediate: false) }
        guard approved, !revoking, ProcessInfo.processInfo.systemUptime - lastGaugePublish >= 2 else { return }
        do {
            let value = try candidate()
            // 活动车速采用有限频率；Widget 不随每个速度样本重写，避免系统预算与共享 IO 浪费。
            latest = value
            publishExistingActivity(value)
            lastGaugePublish = ProcessInfo.processInfo.systemUptime
        } catch { lastError = Self.code(error) }
    }

    func systemGaugeDisconnected(scope captured: IOSRideScope) {
        precondition(Thread.isMainThread)
        guard captured == scope, captured == scopeProvider?(), let selected = owner else { return }
        nativeGauge = nil
        for job in Array(jobs.values) where job.method == "liveActivity.update"
            || (job.method == "liveActivity.start" && job.activityKind == .gauge) {
            finish(job, failure("gauge_source_disconnected"), cancel: true)
        }
        if #available(iOS 16.1, *) {
            let manager = liveManager()
            Task { _ = await manager.end(owner: selected, kind: .gauge) }
        }
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
    private func endActivity(id: String?, kind: ZeehoActivityKind? = nil, job: Job) {
        guard let owner = job.owner, current(job), #available(iOS 16.1, *) else { finish(job, failure("live_activity_unavailable")); return }
        let manager = liveManager(); let ticket = epoch
        Task { @MainActor [weak self] in
            guard job.lease.valid else { return }
            let count = await manager.end(owner: owner, id: id, kind: kind, generation: ticket)
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
        // 清 delegate 再 dismiss：服务对象可能先于弹窗释放，残留 delegate 会断言。
        job.alert?.presentationController?.delegate = nil
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
            job.alert?.presentationController?.delegate = nil
            job.alert = nil
            action()
        })
        job.alert = alert
        presenter.present(alert, animated: true)
        // delegate 是弱引用且指向本服务（非 VC 对象）；弹窗被系统收走后残留 delegate
        // 会在 setDelegate/释放时触发断言（真机崩溃栈在 confirm 的 setDelegate）。
        // NativeFileStream 同款手法：消失即清，不留悬空引用。
        alert.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        presentationController.delegate = nil
        guard let job = interactiveJob else { return }
        finish(job, failure("user_cancelled"), cancel: true)
    }
    // MARK: - 统一 Widget / Android 方法适配出口

    static func anonymousAccount(_ accountID: String) -> String {
        let data = Data(("ios-system-summary-account-v1\u{0}" + accountID).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func compatibilityScopeOptions() throws -> [String: Any] {
        precondition(Thread.isMainThread)
        scopeChanged()
        let current = try checkedScope([:])
        return ["accountId": current.accountID, "vin": current.vin, "generation": current.generation]
    }

    // 返回对象供主 router 依赖；操作仍使用本服务的 scope/导航/lease，不能另开一套后台状态。
    func handleWidgetCompatibility(method: String, args: [Any], operation: String,
                                   options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        scopeChanged()
        var pending: Job?
        do {
            // 同样的「不是 background」判据：`.inactive` 过渡态也要放行，否则设置页
            // 在切回 App 的瞬间读小组件配置会被拒（表现为「偏好未能保存」）。
            guard UIApplication.shared.applicationState != .background else {
                throw SystemSnapshotError("foreground_required")
            }
            guard !revoking else { throw SystemSnapshotError("system_surfaces_busy") }
            let currentScope = try checkedScope([:])
            guard let selected = owner else { throw SystemSnapshotError("authorized_vehicle_required") }
            let availability = runtimeAvailability()
            guard availability["supported"] as? Bool == true else {
                throw SystemSnapshotError(availability["reason"] as? String ?? "system_surfaces_unavailable")
            }
            let job = try begin(method, args: args, reply: reply)
            pending = job
            switch operation {
            case "pin":
                // iOS 没有 requestPinAppWidget。真正展示原生指引，不伪造 queued/requested/bound。
                confirm(job, title: CompatibilityStrings.widgetTitle, message: CompatibilityStrings.widgetInstructions) { [weak self] in
                    guard let self = self, self.current(job) else { return }
                    self.finish(job, ["ok": true, "supported": true, "pinSupported": false, "queued": false,
                        "requested": false, "added": false, "state": "instructions_presented", "placement": "os_managed"])
                }
            case "reload":
                let didReload = reloadWidgets(force: false, snapshot: latest)
                finish(job, ["ok": true, "reloaded": didReload, "requested": didReload, "displayed": false,
                    "reason": didReload ? "reload_requested" : "reload_throttled", "budget": "os_managed"])
            case "settings", "set", "reset":
                let expected = selected
                worker.async { [weak self] in
                    let result: Result<[String: Any], Error>
                    do {
                        guard job.lease.valid else { throw SystemSnapshotError("operation_cancelled") }
                        var settings = try SystemSnapshotStore.widgetSettings(expectedOwner: expected)
                        if operation == "reset" {
                            settings = SystemWidgetSettings(accountHash: expected.accountHash ?? expected.accountVINHash)
                        } else if operation == "set" {
                            switch options["key"] as? String {
                            case "showName": settings.showName = options["value"] as? Bool ?? settings.showName
                            case "showTime": settings.showTime = options["value"] as? Bool ?? settings.showTime
                            case "vin", "vehicleID":
                                // iOS 小组件只显示主页当前车辆，不支持按实例指定别的车。
                                // 传空串等于「跟随当前车辆」，等价于清掉旧选择；传具体车则明确拒绝，
                                // 让网页知道这是能力边界而不是保存失败。
                                guard (options["value"] as? String ?? "").isEmpty else {
                                    throw SystemSnapshotError("system_widget_follows_current_vehicle")
                                }
                                settings.vehicleID = nil
                            default: throw SystemSnapshotError("system_widget_style_managed")
                            }
                        }
                        if operation != "settings" {
                            guard job.lease.valid else { throw SystemSnapshotError("operation_cancelled") }
                            try SystemSnapshotStore.writeWidgetSettings(settings, expectedOwner: expected)
                        }
                        // 只读当前 owner 的快照，和小组件本身完全同一条路径。
                        let snapshot = try SystemSnapshotStore.readCurrent()
                        let snapshotData = try snapshot.map { try JSONEncoder().encode($0) }
                        let snapshotObject = try snapshotData.map { try JSONSerialization.jsonObject(with: $0) }
                        // 只回当前这一辆：网页据此知道「没有别的车可选」，不会渲染出无效列表。
                        let vehicles: [[String: Any]] = snapshot.map { value in
                            [["id": expected.accountVINHash + "." + expected.scopeID,
                              "name": value.vehicle?.name ?? "",
                              "suffix": value.vehicle?.vinDisplaySuffix ?? ""]]
                        } ?? []
                        var value: [String: Any] = ["ok": true, "id": 0, "ids": [], "instances": [],
                            // iOS 只有「跟随主页当前车辆」一种模式：vehicleID 恒为 nil，
                            // effectiveVehicleID 就是当前 owner。
                            "vehicleID": NSNull(), "currentVin": currentScope.vin,
                            // vin 留空 = 「跟随当前车辆」。填当前车架号会让网页以为已经选定某辆车，
                            // 于是渲染出选择器，而选具体车现在会被明确拒绝（iOS 只跟随主页车辆）。
                            "vin": "",
                            "effectiveVehicleID": expected.accountVINHash + "." + expected.scopeID,
                            "name": snapshot?.vehicle?.name ?? "", "vehicleName": snapshot?.vehicle?.name ?? "",
                            "showName": settings.showName, "showTime": settings.showTime, "dark": -1, "timeMode": 0, "tap": 0,
                            "statFields": [], "statSlots": 0, "stats": [], "statsDefault": true,
                            "provider": Self.widgetKind, "configuration": "system_widget_editor", "instanceIDsSupported": false,
                            "vehicles": vehicles,
                            "followsCurrentVehicle": true,
                            "extraLimit": 1, "extraRoundRobin": false,
                            "backgroundPolling": false, "budget": "os_managed", "displayed": false]
                        if let snapshotObject = snapshotObject { value["snapshot"] = snapshotObject }
                        result = .success(value)
                    } catch { result = .failure(error) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.current(job) else { return }
                        switch result {
                        case .failure(let error): self.finish(job, self.failure(Self.code(error)))
                        case .success(var value):
                            if operation != "settings" { value["reloadRequested"] = self.reloadWidgets(force: true, snapshot: self.latest) }
                            value["perInstanceVehicleSelection"] = self.runtimeAvailability()["perInstanceVehicleSelection"] as? Bool == true
                            value["perInstanceMinimumIOS"] = NSNull()
                            WidgetCenter.shared.getCurrentConfigurations { result in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self, self.current(job) else { return }
                                    switch result {
                                    case .success(let infos):
                                        let actual = infos.filter { $0.kind == Self.widgetKind }
                                        value["bound"] = !actual.isEmpty
                                        value["instances"] = actual.map { ["kind": $0.kind, "family": Self.familyName($0.family),
                                            "configuration": "system_widget_editor", "mutableID": false] as [String: Any] }
                                        value["installedCount"] = actual.count
                                    case .failure: value["bound"] = false; value["configurationQueryReason"] = "widget_configuration_query_failed"
                                    }
                                    self.finish(job, value)
                                }
                            }
                        }
                    }
                }
            default: finish(job, failure("unsupported_method"))
            }
        } catch {
            if let job = pending { finish(job, failure(Self.code(error))) }
            else { reply(failure(Self.code(error)), nil) }
        }
    }

    private static func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: return "systemSmall"
        case .systemMedium: return "systemMedium"
        case .systemLarge: return "systemLarge"
        default: return "unsupported"
        }
    }
    private enum CompatibilityStrings {
        static let widgetTitle = "添加车辆小组件"
        static let widgetInstructions = "请长按桌面，选择添加小组件并搜索几何面板。添加后长按小组件，选择编辑小组件，可为每个小组件选择车辆（iOS 17 或更高版本）。系统决定显示与刷新时间。"
    }

    private func ownerJSON(_ value: SystemSnapshotOwner) -> [String: String] {
        var result = ["scopeID": value.scopeID, "accountVINHash": value.accountVINHash]
        if let hash = value.accountHash { result["accountHash"] = hash }
        return result
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
