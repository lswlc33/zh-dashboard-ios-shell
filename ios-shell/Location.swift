import Foundation
import CoreLocation
import UIKit

// GPS 与骑行服务共享此实例；页面轮询不创建第二个 CLLocationManager。
// 坐标只进入用户主动开始的录制/详情，绝不写诊断日志。
struct IOSGPSFix {
    let at: Int64
    let sequence: Int64
    let receivedUptime: TimeInterval
    let ageAtReceipt: TimeInterval
    let latitude: Double?
    let longitude: Double?
    let accuracy: Double?
    let speedKph: Double?
    let speedAccuracy: Double?
    let course: Double?

    var age: TimeInterval {
        ageAtReceipt + max(0, ProcessInfo.processInfo.systemUptime - receivedUptime)
    }

    var fresh: Bool { age >= 0 && age < 10 }

    func json(includeCoordinates: Bool) -> [String: Any] {
        let valid = fresh
        return [
            "provider": "corelocation", "at": at, "seq": sequence,
            "ageMs": valid ? Int64(age * 1000) as Any : NSNull(),
            "lat": includeCoordinates && valid ? latitude.map { $0 as Any } ?? NSNull() : NSNull(),
            "lng": includeCoordinates && valid ? longitude.map { $0 as Any } ?? NSNull() : NSNull(),
            "accuracy": valid ? accuracy.map { $0 as Any } ?? NSNull() : NSNull(),
            "speedKph": valid ? speedKph.map { $0 as Any } ?? NSNull() : NSNull(),
            "speedAccuracyMps": valid ? speedAccuracy.map { $0 as Any } ?? NSNull() : NSNull(),
            "course": valid ? course.map { $0 as Any } ?? NSNull() : NSNull()
        ]
    }
}

final class IOSLocationService: NSObject, IOSBridgeService, IOSBridgeCancellableService, CLLocationManagerDelegate {
    static let shared = IOSLocationService()
    let methods = ["gps.begin", "gps.poll", "gps.end"]
    // 近似位置（精度差于 100m）会把轨迹连成飞线，直接按无效 fix 丢弃。
    private static let maxHorizontalAccuracy: Double = 100

    private struct Observer {
        let fix: (IOSGPSFix) -> Void
        let state: ([String: Any]) -> Void
    }

    // 延迟初始化：仅探测桥能力/轮询状态不会触发位置权限弹窗。
    private var locationManager: CLLocationManager?
    private var observers: [UUID: Observer] = [:]
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var presenterProvider: (() -> UIViewController?)?
    private var page: UInt64 = 0
    private var consentReply: ((Any?, String?) -> Void)?
    private var consentID: UUID?
    private var consentPage: UInt64 = 0
    private var consentTimeout: DispatchWorkItem?
    private weak var consentAlert: UIAlertController?
    private var foregroundWanted = false
    private var foregroundTicket: UUID?
    private var recordingOwner: UUID?
    private var recordingPaused = false
    private var backgroundWanted = false
    private var updating = false
    private var systemPaused = false
    // 两步授权只主动请求一次 Always，避免每次授权回调都重复调用。
    private var alwaysPromptRequested = false
    // locationServicesEnabled()/UIBackgroundModes 不在每次回调里读，避免 1 Hz 轮询的开销。
    private var locationServicesEnabled = true
    private var backgroundModeAvailable = false
    private var state = "disabled"
    private var reason = ""
    private var sequence: Int64 = 0
    private var latest: IOSGPSFix?
    private var registrationStartedAt: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0

    override init() {
        super.init()
        // Bundle 读取很便宜，先缓存；locationServicesEnabled() 可能阻塞主线程，
        // 推迟到真正创建 manager（用户开始用定位）时再读。
        backgroundModeAvailable = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [])
            .contains("location")
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 从系统设置回来可能改过定位服务/后台能力，回前台刷新一次缓存。
            self.refreshEnvironment()
            // 授权回调若在 App 非 active 时错过补请求的窗口，回前台时再补一次 Always。
            if self.backgroundWanted { self.requestAlwaysIfNeeded() }
            // 不恢复已退出的页面监听；显式录制的拥有者仍在才恢复系统采样。
            self.reconcile()
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshEnvironment()
        }
    }

    deinit {
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(method: method, args: args, reply: reply) }
            return
        }
        let options = args.first as? [String: Any] ?? [:]
        switch method {
        case "gps.begin":
            guard options["confirmed"] as? Bool == true else {
                reply(failure("user_action_required"), nil); return
            }
            guard UIApplication.shared.applicationState == .active else {
                reply(failure("foreground_required"), nil); return
            }
            confirmForegroundBegin(options: options, reply: reply)
        case "gps.poll":
            reply(snapshot(), nil)
        case "gps.end":
            cancelConsent("operation_cancelled")
            if let ticket = options["ticket"] as? String, let active = foregroundTicket,
               ticket.lowercased() != active.uuidString.lowercased() {
                reply(failure("stale_ticket"), nil); return
            }
            detachForeground()
            reply(["ok": true, "state": state, "recording": recordingOwner != nil], nil)
        default:
            reply(nil, "unsupported_method")
        }
    }

    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }

    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        if method == "gps.begin" { cancelConsent("operation_cancelled") }
    }

    private func confirmForegroundBegin(options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard consentReply == nil, let presenter = presenterProvider?(),
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            reply(failure("confirmation_unavailable"), nil); return
        }
        consentReply = reply
        let id = UUID()
        consentID = id
        consentPage = page
        let alert = UIAlertController(title: IOSStrings.gpsReadTitle, message: IOSStrings.gpsReadMessage, preferredStyle: .alert)
        consentAlert = alert
        alert.addAction(UIAlertAction(title: IOSStrings.cancelButton, style: .cancel) { [weak self] _ in
            guard let self = self, self.consentID == id else { return }
            self.cancelConsent("user_cancelled")
        })
        alert.addAction(UIAlertAction(title: IOSStrings.continueButton, style: .default) { [weak self] _ in
            guard let self = self, self.consentID == id, let complete = self.consentReply else { return }
            self.consentReply = nil
            self.consentID = nil
            self.consentAlert = nil
            self.consentTimeout?.cancel(); self.consentTimeout = nil
            guard self.consentPage == self.page, UIApplication.shared.applicationState == .active else {
                complete(nil, "stale_navigation"); return
            }
            // 真实原生按钮确认后才登记本次采样意图，已有系统授权也不能绕过该按钮。
            if self.foregroundTicket == nil { self.foregroundTicket = UUID() }
            self.foregroundWanted = true
            _ = self.manager()
            if options["requestPermission"] as? Bool != false { self.requestWhenInUseIfNeeded() }
            self.reconcile()
            var value = self.snapshot()
            value["ticket"] = self.foregroundTicket?.uuidString.lowercased() ?? ""
            value["accepted"] = true
            complete(value, nil)
        })
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.consentID == id else { return }
            self.cancelConsent("confirmation_timeout")
        }
        consentTimeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
        presenter.present(alert, animated: true)
    }

    private func cancelConsent(_ reason: String) {
        consentTimeout?.cancel(); consentTimeout = nil
        consentAlert?.dismiss(animated: false)
        consentAlert = nil
        guard let reply = consentReply else { return }
        consentReply = nil
        consentID = nil
        if consentPage == page { reply(failure(reason), nil) }
        else { reply(nil, "stale_navigation") }
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        page &+= 1
        cancelConsent("stale_navigation")
        // 服务没有持有 WKWebView/KVO；撤销页面 GPS 所有权，录制观察者由 Ride 单独持有。
        detachForeground()
    }

    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        cancelConsent("foreground_required")
        foregroundWanted = false
        foregroundTicket = nil
        reconcile()
    }

    @discardableResult
    func addObserver(onFix: @escaping (IOSGPSFix) -> Void,
                     onState: @escaping ([String: Any]) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let id = UUID()
        observers[id] = Observer(fix: onFix, state: onState)
        return id
    }

    func removeObserver(_ id: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: id)
    }

    // 只由 Ride 在显式用户录制之后调用；不会因 BLE 连接自动打开 GPS。
    @discardableResult
    func beginRecording(id: UUID, background: Bool, requestPermission: Bool) -> [String: Any] {
        precondition(Thread.isMainThread)
        guard recordingOwner == nil || recordingOwner == id else { return failure("recording_busy") }
        recordingOwner = id
        recordingPaused = false
        backgroundWanted = background
        _ = manager()
        if requestPermission && UIApplication.shared.applicationState == .active {
            requestWhenInUseIfNeeded()
        }
        reconcile()
        return snapshot()
    }

    func pauseRecording(id: UUID) {
        precondition(Thread.isMainThread)
        guard recordingOwner == id else { return }
        recordingPaused = true
        reconcile()
    }

    @discardableResult
    func resumeRecording(id: UUID, requestPermission: Bool) -> [String: Any] {
        precondition(Thread.isMainThread)
        guard recordingOwner == id else { return failure("stale_ticket") }
        recordingPaused = false
        if requestPermission && UIApplication.shared.applicationState == .active {
            requestWhenInUseIfNeeded()
        }
        reconcile()
        return snapshot()
    }

    func endRecording(id: UUID) {
        precondition(Thread.isMainThread)
        guard recordingOwner == id else { return }
        recordingOwner = nil
        recordingPaused = false
        backgroundWanted = false
        // 完成记录即销毁最后坐标，不让后续页面轮询取得旧路线位置。
        latest = nil
        reconcile()
    }

    @discardableResult
    func setBackgroundRecording(id: UUID, enabled: Bool, requestPermission: Bool) -> [String: Any] {
        precondition(Thread.isMainThread)
        guard recordingOwner == id else { return failure("stale_ticket") }
        guard UIApplication.shared.applicationState == .active else { return failure("foreground_required") }
        backgroundWanted = enabled
        if enabled && requestPermission {
            let authorization = permissionStatus()
            // 两步升级：第一次永远是 WhenInUse（系统限制），拿到 WhenInUse 后由授权回调补请求 Always；
            // notDetermined 时只先记下 backgroundWanted，等授权回调再补，避免又弹一次 WhenInUse。
            if authorization == .notDetermined {
                requestWhenInUseIfNeeded()
            } else if authorization == .authorizedWhenInUse {
                requestAlwaysIfNeeded()
            }
        }
        if !enabled { alwaysPromptRequested = false }
        reconcile()
        var value = snapshot()
        if enabled && !backgroundAllowed {
            value["reason"] = permissionStatus() == .authorizedWhenInUse
                ? "always_permission_required" : backgroundReason
        }
        return value
    }

    // 只在真的还需要 Always 时请求一次；系统拒绝后不会再反复弹窗。
    private func requestAlwaysIfNeeded() {
        guard !alwaysPromptRequested, backgroundWanted,
              permissionStatus() == .authorizedWhenInUse,
              UIApplication.shared.applicationState == .active else { return }
        alwaysPromptRequested = true
        manager().requestAlwaysAuthorization()
    }

    var backgroundAllowed: Bool {
        recordingOwner != nil && !recordingPaused && backgroundWanted && backgroundModeAvailable
            && permissionStatus() == .authorizedAlways && locationServicesEnabled
    }

    var backgroundReason: String {
        if !backgroundWanted { return "background_recording_disabled" }
        if !backgroundModeAvailable { return "background_mode_missing" }
        if permissionStatus() != .authorizedAlways { return "always_permission_required" }
        return "background_interrupted"
    }

    func snapshot() -> [String: Any] {
        precondition(Thread.isMainThread)
        let permission = permissionName
        var displayState = state
        var displayReason = reason
        let wanted = foregroundWanted || (recordingOwner != nil && !recordingPaused)
        let fix = wanted && updating && !systemPaused && latest?.fresh == true ? latest : nil
        if state == "fresh" && fix == nil {
            displayState = updating ? "stale" : state
            displayReason = updating ? "stale_fix" : reason
        }
        var out: [String: Any] = [
            "ok": true, "enabled": wanted, "state": displayState, "reason": displayReason,
            "provider": "corelocation", "permission": permission,
            "permissionGranted": permissionStatus() == .authorizedAlways || permissionStatus() == .authorizedWhenInUse,
            "accuracyAuthorization": accuracyPermission, "updating": updating,
            // 只给 accuracyAuthorization == "reduced" 时的显式布尔，网页判断「用户选了近似位置」更直白。
            "reducedAccuracy": (locationManager?.accuracyAuthorization ?? .fullAccuracy) == .reducedAccuracy,
            "recording": recordingOwner != nil && !recordingPaused,
            "backgroundRequested": backgroundWanted, "backgroundEnabled": backgroundAllowed,
            "backgroundGuaranteed": false, "seq": sequence,
            "at": NSNull(), "ageMs": NSNull(), "speedKph": NSNull(),
            "lat": NSNull(), "lng": NSNull(), "accuracy": NSNull(),
            "speedAccuracyMps": NSNull(), "course": NSNull()
        ]
        if let fix = fix {
            for (key, value) in fix.json(includeCoordinates: recordingOwner != nil && !recordingPaused) {
                out[key] = value
            }
        }
        return out
    }

    // 缓存系统环境：这两个值在每次定位回调和 1 Hz 轮询里都会用到，读 Bundle 太贵。
    private func refreshEnvironment() {
        locationServicesEnabled = CLLocationManager.locationServicesEnabled()
        backgroundModeAvailable = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [])
            .contains("location")
    }

    private func manager() -> CLLocationManager {
        if let value = locationManager { return value }
        // 首次真正使用定位时刷新系统环境缓存，供后续 reconcile / backgroundAllowed 判断。
        refreshEnvironment()
        let value = CLLocationManager()
        value.delegate = self
        // 骑行不是机动车导航：.automotiveNavigation 会放大自动暂停和道路吸附，轨迹反而失真。
        value.activityType = .fitness
        value.desiredAccuracy = kCLLocationAccuracyBest
        value.distanceFilter = 3
        // 录制中禁止系统自动暂停（自动暂停不会可靠地恢复，轨迹会永久断），非录制时才省电。
        value.pausesLocationUpdatesAutomatically = !(recordingOwner != nil && !recordingPaused)
        locationManager = value
        return value
    }

    private func permissionStatus() -> CLAuthorizationStatus {
        locationManager?.authorizationStatus ?? CLLocationManager.authorizationStatus()
    }

    private var permissionName: String {
        switch permissionStatus() {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedWhenInUse: return "when_in_use"
        case .authorizedAlways: return "always"
        @unknown default: return "unknown"
        }
    }

    private var accuracyPermission: String {
        guard let value = locationManager else { return "unknown" }
        switch value.accuracyAuthorization {
        case .fullAccuracy: return "full"
        case .reducedAccuracy: return "reduced"
        @unknown default: return "unknown"
        }
    }

    private func requestWhenInUseIfNeeded() {
        guard UIApplication.shared.applicationState == .active,
              foregroundWanted || (recordingOwner != nil && !recordingPaused),
              permissionStatus() == .notDetermined else { return }
        manager().requestWhenInUseAuthorization()
    }

    private func detachForeground() {
        foregroundWanted = false
        foregroundTicket = nil
        if recordingOwner == nil { latest = nil }
        reconcile()
    }

    private func stopUpdates() {
        if updating { locationManager?.stopUpdatingLocation() }
        updating = false
        systemPaused = false
        locationManager?.allowsBackgroundLocationUpdates = false
        locationManager?.showsBackgroundLocationIndicator = false
        latest = nil
        lastTimestamp = 0
    }

    private func reconcile() {
        // 状态机只在启动/暂停/前后台切换时走，这里刷新一次缓存即可；
        // 1 Hz 的 snapshot() 轮询只读缓存，不在热路径读系统值。
        refreshEnvironment()
        let wanted = foregroundWanted || (recordingOwner != nil && !recordingPaused)
        guard wanted else {
            stopUpdates()
            state = recordingOwner != nil ? "paused" : "disabled"
            reason = ""
            publish()
            return
        }
        guard locationServicesEnabled else {
            stopUpdates(); state = "unavailable"; reason = "location_services_disabled"; publish(); return
        }
        let authorization = permissionStatus()
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            stopUpdates()
            state = "permission_required"
            reason = authorization == .denied ? "permission_denied"
                : authorization == .restricted ? "permission_restricted" : "permission_required"
            publish(); return
        }
        // 录制中的自动暂停开关跟随录制状态，避免系统在骑行中途停掉更新且不再恢复。
        let recording = recordingOwner != nil && !recordingPaused
        locationManager?.pausesLocationUpdatesAutomatically = !recording
        guard UIApplication.shared.applicationState == .active || backgroundAllowed else {
            stopUpdates(); state = "interrupted"; reason = backgroundReason; publish(); return
        }
        let value = manager()
        // manifest 没有 location 时绝不设为 true，否则 iOS 会抛出异常。
        value.allowsBackgroundLocationUpdates = backgroundAllowed
        value.showsBackgroundLocationIndicator = backgroundAllowed
        if !updating {
            registrationStartedAt = Date().timeIntervalSince1970
            lastTimestamp = 0
            latest = nil
            systemPaused = false
            state = "waiting"
            reason = "waiting_fix"
            updating = true
            value.startUpdatingLocation()
            // 两步授权：WhenInUse 拿到后且用户要后台录制，补请求 Always。
            requestAlwaysIfNeeded()
        }
        publish()
    }

    private func publish() {
        let value = snapshot()
        for observer in Array(observers.values) { observer.state(value) }
    }

    private func failure(_ code: String) -> [String: Any] {
        var value = snapshot()
        value["ok"] = false
        value["reason"] = code
        return value
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        // 授权变化只推进仍持有的用户意图；导航/结束后收到旧授权回调也不会开定位。
        // 两步升级的第二步在这里补：刚拿到 WhenInUse 且用户要后台录制时请求 Always，
        // 否则 ride.begin 那次请求只停在 WhenInUse，Always 永远不会弹。
        if permissionStatus() == .authorizedWhenInUse && backgroundWanted {
            requestAlwaysIfNeeded()
        }
        // reconcile 内部会刷新系统环境缓存。
        reconcile()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager, updating,
              foregroundWanted || (recordingOwner != nil && !recordingPaused) else { return }
        let authorization = permissionStatus()
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            reconcile(); return
        }
        guard UIApplication.shared.applicationState == .active || backgroundAllowed else { reconcile(); return }
        var accepted = 0
        var invalid = 0
        for location in locations.suffix(32) {
            let timestamp = location.timestamp.timeIntervalSince1970
            let age = Date().timeIntervalSince(location.timestamp)
            // startUpdatingLocation 可能先给缓存 fix；按原始 timestamp/年龄拒绝，不以 poll 续命。
            guard timestamp.isFinite, timestamp >= registrationStartedAt, timestamp > lastTimestamp,
                  age.isFinite, age >= 0, age < 10 else { continue }
            let accuracy = location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
                ? location.horizontalAccuracy : nil
            // 近似位置（例如系统给的 5000 米精度）会把轨迹连成飞线：整条 fix 丢弃，不当作有效点。
            if let accuracy = accuracy, accuracy > Self.maxHorizontalAccuracy {
                invalid += 1
                continue
            }
            let coordinateValid = CLLocationCoordinate2DIsValid(location.coordinate) && accuracy != nil
            let speed = location.speed.isFinite && location.speed >= 0 && location.speed * 3.6 <= 400
                ? location.speed * 3.6 : nil
            guard coordinateValid || speed != nil else {
                invalid += 1
                continue
            }
            sequence += 1
            lastTimestamp = timestamp
            systemPaused = false
            let fix = IOSGPSFix(
                at: Int64(timestamp * 1000), sequence: sequence,
                receivedUptime: ProcessInfo.processInfo.systemUptime, ageAtReceipt: age,
                latitude: coordinateValid ? location.coordinate.latitude : nil,
                longitude: coordinateValid ? location.coordinate.longitude : nil,
                accuracy: accuracy, speedKph: speed,
                speedAccuracy: location.speedAccuracy.isFinite && location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
                course: location.course.isFinite && location.course >= 0 && location.course < 360 ? location.course : nil
            )
            latest = fix
            reason = speed == nil ? "no_speed" : accuracy == nil ? "accuracy_unavailable" : ""
            accepted += 1
            for observer in Array(observers.values) { observer.fix(fix) }
        }
        // 状态在循环后统一决定：一批里最后一条无效时不能把已接受点的 fresh 覆盖成 waiting。
        if accepted > 0 {
            state = "fresh"
        } else if invalid > 0 {
            state = "waiting"
            reason = "invalid_fix"
        }
        publish()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationManager, updating else { return }
        let code = (error as? CLError)?.code
        if code == .denied {
            stopUpdates(); state = "permission_required"; reason = "permission_denied"
        } else if code == .locationUnknown {
            // 暂时定位不到时保留仍然新鲜的 fix，让 age 自然过期，界面不会闪成「—」。
            state = "waiting"; reason = "no_fix"
        } else {
            state = "error"; reason = "location_failed"
        }
        // 不回传 localizedDescription，其中可能含平台细节或位置。
        publish()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager, updating else { return }
        if recordingOwner != nil && !recordingPaused {
            // 录制中属性已设为 false；万一系统仍暂停（切换有时序竞争）就自己重启更新，
            // 否则骑行轨迹会永久中断。
            systemPaused = false
            manager.startUpdatingLocation()
            state = "waiting"
            reason = "system_paused"
        } else {
            // 非录制场景保留系统的自动暂停，省电；保留最新 fix 由 age 自然过期。
            systemPaused = true
            state = "interrupted"
            reason = "system_paused"
        }
        publish()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager, updating else { return }
        systemPaused = false
        // 只清暂停标记：仍然新鲜的 fix 直接回到 fresh，不必等下一帧让界面闪「—」。
        if latest?.fresh == true {
            state = "fresh"
        } else {
            state = "waiting"
            reason = "waiting_fix"
        }
        publish()
    }
}
