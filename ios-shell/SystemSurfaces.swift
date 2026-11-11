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
        let old = Activity<ZeehoActivityAttributes>.activities.filter { $0.attributes.owner != next }
        for activity in old { await finish(activity) }
    }

    func running(owner expected: SystemSnapshotOwner?) -> [IOSRunningSystemActivity] {
        guard let expected = expected, owner == expected else { return [] }
        return Activity<ZeehoActivityAttributes>.activities.filter {
            $0.attributes.owner == expected && ($0.activityState == .active || $0.activityState == .stale)
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
                && ($0.activityState == .active || $0.activityState == .stale)
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
        owner = next.flatMap { $0.valid ? SystemSnapshotOwner(scopeID: UUID().uuidString.lowercased(), accountVINHash: $0.ownerHash) : nil }
        approved = false; revoking = false; latest = nil; nativeRide = nil; lastError = nil
        lastWidgetReload = -Double.infinity; lastWidgetEdge = ""
        let ticket = epoch
        let selected = owner
        // 同一串行队列让旧写结束后必定清理；新 owner 写不能越过这道清理，也不能复用旧的匿名 scope。
        worker.async { [weak self] in
            do {
                if let previous = previousOwner { try SystemSnapshotStore.clear(expectedOwner: previous) }
                else if let persisted = try SystemSnapshotStore.currentOwner() { try SystemSnapshotStore.clear(expectedOwner: persisted) }
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
                        self.approved = true
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
            "expiresAt": latest?.expiresAt as Any? ?? NSNull()]
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
        revoking = true; approved = false; latest = nil; nativeRide = nil
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
                    if #available(iOS 16.1, *) { _ = await self?.liveManager().end(owner: selected) }
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
                        if let job = job { self.finish(job, ["ok": true, "stored": true, "snapshot": self.snapshotJSON(value)]) }
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
        approved = true
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
    private static func code(_ error: Error) -> String { (error as? SystemSnapshotError)?.code ?? "snapshot_storage_unavailable" }
}
