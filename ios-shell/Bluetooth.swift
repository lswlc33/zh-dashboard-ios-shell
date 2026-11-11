import Foundation
import CoreBluetooth
import UIKit
import ZeehoShared

// 保留真实的数值与各自采样时刻，不保留认证帧、云材料或未知 bytes 字段。
struct IOSBLETelemetrySample {
    let sequence: Int64
    let at: Int64
    let receivedUptime: TimeInterval
    let connectionGeneration: UUID
    let scope: IOSRideScope
    let source: String
    let values: [String: Any]
    let fields: [String: Any]
}

final class IOSBluetoothService: NSObject, IOSBridgeService, IOSBridgeCancellableService, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = IOSBluetoothService()
    static let restorationIdentifier = "io.github.lswlc33.dashboard.ble.read.v1"
    static let serviceUUID = CBUUID(string: "0000B354-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let writeUUID = CBUUID(string: "0000B356-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let notifyUUID = CBUUID(string: "0000B357-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    // 通知连续失败到这个次数才判定链路失效；单次错误只记到快照里。
    private static let notifyFailureLimit = 3
    // 系统断开/取消连接的回调可能丢失；超过这个时长就让 UUID 允许重新连接。
    private static let retiringStaleAfter: TimeInterval = 5

    let methods = ["ble.status", "ble.scan", "ble.stopScan", "ble.connect", "ble.disconnect",
                   "ble.services", "ble.read", "ble.subscribe", "ble.write", "ble.poll"]

    private final class Call {
        let page: UInt64
        var reply: ((Any?, String?) -> Void)?
        var timeout: DispatchWorkItem?
        init(page: UInt64, reply: @escaping (Any?, String?) -> Void) { self.page = page; self.reply = reply }
    }

    private struct Seen {
        let peripheral: CBPeripheral
        let name: String?
        let rssi: Int?
        let connectable: Bool?
        let seenAt: TimeInterval
        let restored: Bool
    }

    private enum Kind { case connect, services, characteristics, initialNotify, subscribe, write }
    private final class Operation {
        let kind: Kind
        let epoch: UUID
        let characteristic: CBCharacteristic?
        var timeout: DispatchWorkItem?
        init(_ kind: Kind, epoch: UUID, characteristic: CBCharacteristic? = nil) {
            self.kind = kind; self.epoch = epoch; self.characteristic = characteristic
        }
    }

    private final class Request {
        let kind: Kind
        let call: Call
        let characteristic: CBCharacteristic
        let enabled: Bool
        let data: Data
        var offset = 0
        var chunkBytes = 0
        var chunks = 0
        var timeout: DispatchWorkItem?
        init(kind: Kind, call: Call, characteristic: CBCharacteristic, enabled: Bool = false, data: Data = Data()) {
            self.kind = kind; self.call = call; self.characteristic = characteristic
            self.enabled = enabled; self.data = data
        }
    }

    // 待排空的旧连接：带时间戳，回调丢失时可以按时间兜底清理。
    private struct Retiring {
        let peripheral: CBPeripheral
        let at: TimeInterval
    }

    private struct Observer {
        let sample: (IOSBLETelemetrySample) -> Void
        let state: ([String: Any]) -> Void
    }

    private var central: CBCentralManager?
    private let protocolCodec = SharedProtocol()
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var foregroundObserver: NSObjectProtocol?
    private var observers: [UUID: Observer] = [:]
    private var page: UInt64 = 0
    private var epoch = UUID()
    private var state = "uninitialized"
    private var reason = ""
    private var seen: [UUID: Seen] = [:]
    private var restoredIdentifiers = Set<UUID>()
    private var retiring: [UUID: Retiring] = [:]
    private var scanCall: Call?
    private var scanRequested = false
    private var scanDeadline: TimeInterval = 0
    private var connectCall: Call?
    private var peripheral: CBPeripheral?
    private var connectionScope: IOSRideScope?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var operation: Operation?
    private var currentRequest: Request?
    private var requests: [Request] = []
    private var confirmationCall: Call?
    private weak var confirmationAlert: UIAlertController?
    private var recordingID: UUID?
    private var recordingBackground = false
    private var recordingScope: IOSRideScope?
    private var telemetry: [String: Any] = [:]
    private var telemetryTimes: [String: Int64] = [:]
    private var telemetryUptime: [String: TimeInterval] = [:]
    private var telemetryFields: [String: Any] = [:]
    private var values: [[String: Any]] = []
    private var lastNotifyValue: [String: Any]?
    private var notifyFailures = 0
    private var lastNotifyError = ""
    private var sequence: Int64 = 0
    private var droppedValues = 0
    private var streamRejected: Int64 = 0
    private var streamSkipped: Int64 = 0
    private var streamBuffered = 0

    override init() {
        super.init()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.checkScope()
            // 蓝牙授权框期间系统会先变 .inactive：那时 startScan 主动放弃，回到前台必须补扫，
            // 否则首次扫描整段空转到 deadline。didBecomeActive 时 applicationState 已是 .active。
            self.startScan()
            self.publish()
        }
    }

    deinit {
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
        central?.stopScan()
        if let value = peripheral { central?.cancelPeripheralConnection(value) }
        central?.delegate = nil
    }

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread)
        scopeProvider = provider
        scopeChanged()
    }

    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }

    // AppDelegate 只有收到系统 bluetoothCentrals launchOptions 才调用，普通启动不弹蓝牙授权。
    func restoreIfRequested(_ identifiers: [String]) {
        precondition(Thread.isMainThread)
        guard identifiers.contains(Self.restorationIdentifier) else { return }
        _ = manager()
    }

    func scopeChanged() {
        precondition(Thread.isMainThread)
        checkScope()
    }

    @discardableResult
    func addObserver(onSample: @escaping (IOSBLETelemetrySample) -> Void,
                     onState: @escaping ([String: Any]) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let id = UUID()
        observers[id] = Observer(sample: onSample, state: onState)
        return id
    }

    func removeObserver(_ id: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: id)
    }

    func setRecordingContext(id: UUID?, background: Bool, scope: IOSRideScope?) {
        precondition(Thread.isMainThread)
        recordingID = id
        recordingBackground = id != nil && background
        recordingScope = scope
        if UIApplication.shared.applicationState != .active && !canKeepInBackground {
            closeConnection("background_interrupted")
        }
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(method: method, args: args, reply: reply) }
            return
        }
        checkScope()
        let options = args.first as? [String: Any] ?? [:]
        switch method {
        case "ble.status": reply(snapshot(), nil)
        case "ble.poll":
            if !validID(options, optional: true) { reply(failure("unknown_identifier"), nil); return }
            var result = snapshot()
            result["values"] = values
            result["droppedValues"] = droppedValues
            values.removeAll(keepingCapacity: true)
            reply(result, nil)
        case "ble.scan": scan(options, reply: reply)
        case "ble.stopScan":
            finishScan(reason: "user_stop")
            reply(["ok": true, "state": "scan_stopped", "devices": devices()], nil)
        case "ble.connect": connect(options, reply: reply)
        case "ble.disconnect":
            guard validID(options, optional: true) else { reply(failure("unknown_identifier"), nil); return }
            closeConnection("user_disconnect")
            reply(["ok": true, "state": "disconnected", "reason": "user_disconnect"], nil)
        case "ble.services":
            guard validID(options, optional: true), connected else {
                reply(failure("not_connected"), nil); return
            }
            reply(["ok": true, "id": peripheral!.identifier.uuidString.lowercased(), "services": serviceList()], nil)
        case "ble.read", "ble.subscribe":
            if method == "ble.read" {
                // 只读仪表的 notify 特征一直订阅着，而 CoreBluetooth 的通知和 GATT read 走同一个回调，
                // 真做 readValue 也无法区分回执是不是旧通知。这里把语义定为「取最近一次通知缓存」，
                // 不临时停订阅、不伪造一次 read 回执；没收到过通知就如实报 no_cached_value。
                guard let characteristic = resolve(options, fallback: Self.notifyUUID) else {
                    reply(failure("characteristic_unavailable"), nil); return
                }
                guard characteristic === notifyCharacteristic else { reply(failure("read_not_supported"), nil); return }
                guard let cached = lastNotifyValue else { reply(failure("no_cached_value"), nil); return }
                var value = snapshot()
                value["source"] = "notify_cache"
                value["valueB64"] = cached["valueB64"] as Any? ?? NSNull()
                value["at"] = cached["at"] as Any? ?? NSNull()
                value["service"] = cached["service"] as Any? ?? Self.serviceUUID.uuidString.lowercased()
                value["characteristic"] = cached["characteristic"] as Any? ?? Self.notifyUUID.uuidString.lowercased()
                reply(value, nil)
                return
            }
            guard let characteristic = resolve(options, fallback: Self.notifyUUID) else {
                reply(failure("characteristic_unavailable"), nil); return
            }
            guard userAction(options) else { reply(failure("user_action_required"), nil); return }
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                reply(failure("notify_not_supported"), nil); return
            }
            let enabled = options["enabled"] as? Bool ?? true
            enqueue(Request(kind: .subscribe, call: Call(page: page, reply: reply), characteristic: characteristic, enabled: enabled))
        case "ble.write": confirmWrite(options, reply: reply)
        default: reply(nil, "unsupported_method")
        }
    }

    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        if method == "ble.scan" { finishScan(reason: "operation_cancelled", ok: false) }
        if method == "ble.write" { cancelConfirmation("operation_cancelled") }
        // ble.read 现在只读通知缓存、同步返回，不占用连接；撤销它不该顺手关掉别人的连接。
        if ["ble.connect", "ble.subscribe", "ble.write"].contains(method),
           connectCall != nil || currentRequest != nil || !requests.isEmpty {
            closeConnection("operation_cancelled")
        }
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        page &+= 1
        finishScan(reason: "stale_navigation", validPage: false)
        cancelConfirmation("stale_navigation")
        // 新页面没有旧 IO 票据。仅已明确录制的现存只读订阅可保留，不能保留任何待发 write。
        if operation != nil || currentRequest != nil || !requests.isEmpty || connectCall != nil {
            closeConnection("stale_navigation")
        } else if recordingID == nil {
            closeConnection("navigation_changed")
        }
        values.removeAll()
        lastNotifyValue = nil
    }

    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        // 后台打断不等于扫到 deadline：ok:false，网页才能把「中途中止」和正常收尾区分开。
        finishScan(reason: "background_interrupted", ok: false)
        cancelConfirmation("foreground_required")
        if operation != nil || currentRequest != nil || !requests.isEmpty || connectCall != nil || !canKeepInBackground {
            closeConnection("background_interrupted")
        }
        publish()
    }

    var connected: Bool {
        peripheral?.state == .connected && state == "connected" && connectionScope != nil
    }

    func snapshot() -> [String: Any] {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        var fresh: [String: Any] = [:]
        var times: [String: Int64] = [:]
        if connected {
            for (key, value) in telemetry {
                if let stamped = telemetryUptime[key], now >= stamped, now - stamped < 10 {
                    fresh[key] = value
                    times[key] = telemetryTimes[key]
                }
            }
        }
        return [
            "ok": true, "state": state, "reason": reason, "authorization": authorizationName,
            "power": powerName, "initialized": central != nil, "scanning": central?.isScanning ?? false,
            "connected": connected, "id": peripheral?.identifier.uuidString.lowercased() as Any? ?? NSNull(),
            "identifierKind": "corebluetooth_uuid", "authenticated": false,
            "authenticationState": "not_attempted", "registrationVerified": false,
            "automaticUnlock": false, "readOnly": true,
            "supportedRoles": [1], "supported2": false,
            "protocol": "captured_ble1_small_frames", "iosVehicleVerification": "not_performed",
            "maxWriteBytes": peripheral.map { $0.maximumWriteValueLength(for: .withResponse) as Any } ?? NSNull(),
            "attMTU": NSNull(), "notifyEnabled": notifyCharacteristic?.isNotifying ?? false,
            // 通知错误不再只写 reason：连续失败计数和最后一条错误都要能在轮询里看到，网页才好显示异常。
            "notifyFailures": notifyFailures, "lastNotifyError": lastNotifyError,
            "lastNotifyAt": lastNotifyValue?["at"] as Any? ?? NSNull(),
            "devices": devices(), "telemetry": fresh, "telemetryTimes": times,
            "fields": telemetryFields, "seq": sequence,
            "stream": ["buffered": streamBuffered, "rejected": streamRejected, "skipped": streamSkipped],
            "backgroundEnabled": canKeepInBackground, "backgroundGuaranteed": false,
            "restoredCount": restoredIdentifiers.count
        ]
    }

    private var canKeepInBackground: Bool {
        recordingID != nil && recordingBackground && recordingScope == connectionScope && connectionScope != nil
            && (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("bluetooth-central")
    }

    private func manager() -> CBCentralManager {
        if let value = central { return value }
        let value = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
        central = value
        state = "initializing"
        return value
    }

    private var authorizationName: String {
        switch CBCentralManager.authorization {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowed"
        @unknown default: return "unknown"
        }
    }

    private var powerName: String {
        guard let value = central else { return "unknown" }
        switch value.state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "not_authorised"
        case .poweredOff: return "powered_off"
        case .poweredOn: return "powered_on"
        @unknown default: return "unknown"
        }
    }

    private func userAction(_ options: [String: Any]) -> Bool {
        options["confirmed"] as? Bool == true && UIApplication.shared.applicationState == .active
    }

    private func scan(_ options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard userAction(options) else { reply(failure("user_action_required"), nil); return }
        guard scanCall == nil else { reply(failure("scan_busy"), nil); return }
        let timeout = (options["timeoutMs"] as? NSNumber)?.doubleValue ?? 10000
        guard timeout.isFinite, timeout >= 1000, timeout <= 15000 else { reply(failure("invalid_timeout"), nil); return }
        if let filters = options["services"] as? [String], !filters.isEmpty,
           filters.contains(where: { !matchesUUID($0, expected: Self.serviceUUID) }) {
            reply(failure("unsupported_service_filter"), nil); return
        }
        pruneSeen()
        let call = Call(page: page, reply: reply)
        scanCall = call
        scanRequested = true
        scanDeadline = ProcessInfo.processInfo.systemUptime + timeout / 1000
        let timer = DispatchWorkItem { [weak self, weak call] in
            guard let self = self, let call = call, self.scanCall === call else { return }
            self.finishScan(reason: "timeout")
        }
        call.timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout / 1000, execute: timer)
        let value = manager()
        if value.state == .poweredOn { startScan() }
        else if value.state == .unauthorized || value.state == .unsupported || value.state == .poweredOff {
            finishScan(reason: powerName, ok: false)
        }
    }

    private func startScan() {
        guard scanRequested, scanCall != nil, central?.state == .poweredOn,
              UIApplication.shared.applicationState == .active,
              ProcessInfo.processInfo.systemUptime < scanDeadline else { return }
        // iOS 不提供 MAC；只扫真实车辆服务，默认不重复广播，无无界附近设备收集。
        if central?.isScanning != true {
            central?.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        if !connected { state = "scanning"; reason = "" }
        publish()
    }

    private func finishScan(reason code: String, ok: Bool = true, validPage: Bool = true) {
        scanRequested = false
        central?.stopScan()
        guard let call = scanCall else { return }
        scanCall = nil
        if !connected { state = central == nil ? "uninitialized" : "disconnected"; reason = code }
        finish(call, ["ok": ok, "state": ok ? "scan_completed" : "scan_failed", "reason": code, "devices": devices()], validPage: validPage)
        publish()
    }

    private func connect(_ options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard userAction(options) else { reply(failure("user_action_required"), nil); return }
        guard let scope = scopeProvider?(), scope.valid else { reply(failure("authorized_vehicle_required"), nil); return }
        guard let text = options["id"] as? String, let id = UUID(uuidString: text) else {
            reply(failure("uuid_required_not_mac"), nil); return
        }
        if let role = options["role"] as? NSNumber, role.intValue != 1 { reply(failure("unsupported_ble2"), nil); return }
        if connected && peripheral?.identifier == id && connectionScope == scope { reply(snapshot(), nil); return }
        guard peripheral == nil, connectCall == nil else { reply(failure("connection_busy"), nil); return }
        pruneSeen()
        if retiring[id] != nil {
            // 必须等 didDisconnect/didFailToConnect 排空旧连接，不能只看 state 后复用同一对象。
            // pruneSeen 里会按 5 秒兜底清掉回调丢失的条目，所以这里不会永久卡住。
            reply(failure("connection_closing"), nil); return
        }
        guard let known = seen[id], known.restored || ProcessInfo.processInfo.systemUptime - known.seenAt <= 60 else {
            reply(failure("identifier_not_seen_or_restored"), nil); return
        }
        guard known.connectable != false else { reply(failure("not_connectable"), nil); return }
        let value = manager()
        guard value.state == .poweredOn else { reply(failure(powerName), nil); return }
        finishScan(reason: "connect_requested")
        epoch = UUID()
        peripheral = known.peripheral
        connectionScope = scope
        writeCharacteristic = nil
        notifyCharacteristic = nil
        clearTelemetry()
        // 新连接从零开始统计通知失败，避免上次连接的错误影响新会话。
        notifyFailures = 0
        lastNotifyError = ""
        known.peripheral.delegate = self
        connectCall = Call(page: page, reply: reply)
        state = "connecting"
        reason = ""
        beginOperation(.connect, seconds: 15)
        value.connect(known.peripheral, options: nil)
        publish()
    }

    private func matchesUUID(_ text: String, expected: CBUUID) -> Bool {
        // CoreBluetooth 对非法 UUID 文本可能抛 ObjC 异常；先用可失败的 Foundation parser 校验。
        guard text.utf8.count <= 36, UUID(uuidString: text) != nil else { return false }
        return CBUUID(string: text) == expected
    }

    // 服务/特征本来就在类常量里写死，网页不需要（也从不）传 UUID：
    // 缺省时按调用方语义回落到固定 UUID（写路径 writeUUID / 通知路径 notifyUUID），
    // 只有网页显式给出时才做严格匹配，避免悄悄接受别的特征。
    private func resolve(_ options: [String: Any], fallback: CBUUID) -> CBCharacteristic? {
        guard connected, validID(options, optional: true), checkScope() else { return nil }
        if let service = options["service"] as? String, !matchesUUID(service, expected: Self.serviceUUID) { return nil }
        let characteristic: CBCharacteristic?
        if let text = options["characteristic"] as? String {
            if matchesUUID(text, expected: Self.writeUUID) { characteristic = writeCharacteristic }
            else if matchesUUID(text, expected: Self.notifyUUID) { characteristic = notifyCharacteristic }
            else { return nil }
        } else if fallback == Self.writeUUID {
            characteristic = writeCharacteristic
        } else {
            characteristic = notifyCharacteristic
        }
        return characteristic
    }

    private func validID(_ options: [String: Any], optional: Bool) -> Bool {
        guard let text = options["id"] as? String else { return optional }
        guard let id = UUID(uuidString: text) else { return false }
        return peripheral?.identifier == id || (peripheral == nil && seen[id] != nil)
    }

    private func confirmWrite(_ options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard userAction(options) else { reply(failure("user_action_required"), nil); return }
        guard options["withResponse"] as? Bool != false else { reply(failure("write_response_required"), nil); return }
        // 网页只传 { command, payloadHex }，不带 UUID；写路径缺省回落到固定的写特征。
        guard let target = resolve(options, fallback: Self.writeUUID),
              target.uuid == Self.writeUUID, target.properties.contains(.write) else {
            reply(failure("write_characteristic_unavailable"), nil); return
        }
        // 不提供任意 raw 车辆写入。124 的开/关周期遥测是 Android 实捕的安全只读请求；
        // AUTH/RESPONSE/BIND/广播/114/锁控等均不在 iOS 首次取证白名单里。
        let onHex = protocolCodec.encodeFrameHex(command: 124, payloadHex: "0801")
        let offHex = protocolCodec.encodeFrameHex(command: 124, payloadHex: "")
        guard !onHex.hasPrefix("error:"), !offHex.hasPrefix("error:"),
              let on = Data(strictHex: onHex), let off = Data(strictHex: offHex) else {
            reply(failure("protocol_encode_failed"), nil); return
        }
        let encoded: Data
        if let b64 = options["valueB64"] as? String {
            guard b64.utf8.count <= 660, let supplied = Data(base64Encoded: b64), supplied == on || supplied == off else {
                reply(failure("read_only_command_required"), nil); return
            }
            encoded = supplied
        } else if let command = options["command"] as? NSNumber, command.intValue == 124,
                  let payload = options["payloadHex"] as? String, payload.lowercased() == "0801" || payload.isEmpty {
            encoded = payload.isEmpty ? off : on
        } else { reply(failure("read_only_command_required"), nil); return }
        guard confirmationCall == nil, requests.count + (currentRequest == nil ? 0 : 1) < 16 else {
            reply(failure("operation_busy"), nil); return
        }
        guard let presenter = presenterProvider?(), presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else { reply(failure("confirmation_unavailable"), nil); return }
        let call = Call(page: page, reply: reply)
        confirmationCall = call
        let capturedEpoch = epoch
        let capturedScope = connectionScope
        let alert = UIAlertController(title: IOSStrings.bluetoothReadTitle, message: IOSStrings.bluetoothReadMessage, preferredStyle: .alert)
        confirmationAlert = alert
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak call] _ in
            guard let self = self, let call = call, self.confirmationCall === call else { return }
            self.confirmationCall = nil
            self.confirmationAlert = nil
            self.finish(call, self.failure("user_cancelled"))
        })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self, weak call] _ in
            guard let self = self, let call = call, self.confirmationCall === call else { return }
            self.confirmationCall = nil
            self.confirmationAlert = nil
            guard self.page == call.page, self.epoch == capturedEpoch, self.connectionScope == capturedScope,
                  self.connected, self.checkScope(), UIApplication.shared.applicationState == .active else {
                self.finish(call, self.failure("stale_session")); return
            }
            self.enqueue(Request(kind: .write, call: call, characteristic: target, data: encoded))
        })
        let timer = DispatchWorkItem { [weak self, weak call] in
            guard let self = self, let call = call, self.confirmationCall === call else { return }
            self.cancelConfirmation("confirmation_timeout")
        }
        call.timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
        presenter.present(alert, animated: true)
    }

    private func cancelConfirmation(_ code: String) {
        guard let call = confirmationCall else { return }
        confirmationCall = nil
        confirmationAlert?.dismiss(animated: false)
        confirmationAlert = nil
        finish(call, failure(code))
    }

    private func enqueue(_ request: Request) {
        guard connected, checkScope(), UIApplication.shared.applicationState == .active else {
            finish(request.call, failure("not_connected")); return
        }
        guard requests.count + (currentRequest == nil ? 0 : 1) < 16 else {
            finish(request.call, failure("queue_full")); return
        }
        // 超时不在这里起算：排队等待的时间不算执行超时，否则第 16 条会被队伍自己耗死。
        // 但要清掉 write 确认框留下的旧定时器，执行期超时改由 pump 重新 arm。
        request.call.timeout?.cancel()
        request.call.timeout = nil
        requests.append(request)
        pumpLater()
    }

    private func pumpLater() {
        let generation = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.epoch == generation else { return }
            self.pump()
        }
    }

    // 请求真正开始执行时才 arm 超时；到期只结束这一条，不关闭连接影响队头其他请求。
    private func armRequestTimeout(_ request: Request) {
        request.timeout?.cancel()
        let timer = DispatchWorkItem { [weak self, weak request] in
            guard let self = self, let request = request, self.currentRequest === request else { return }
            self.clearOperation()
            self.currentRequest = nil
            self.finish(request.call, self.failure("operation_timeout"))
            self.pumpLater()
        }
        request.timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
    }

    private func pump() {
        guard connected, checkScope(), operation == nil, let value = peripheral else { return }
        guard UIApplication.shared.applicationState == .active else { closeConnection("foreground_required"); return }
        if currentRequest == nil, !requests.isEmpty {
            let next = requests.removeFirst()
            currentRequest = next
            armRequestTimeout(next)
        }
        guard let request = currentRequest else { return }
        guard request.call.page == page else { completeRequest(failure("stale_navigation")); return }
        switch request.kind {
        case .subscribe:
            if request.characteristic.isNotifying == request.enabled {
                completeRequest(["ok": true, "enabled": request.enabled, "state": "connected"])
            } else {
                beginOperation(.subscribe, seconds: 6, characteristic: request.characteristic)
                value.setNotifyValue(request.enabled, for: request.characteristic)
            }
        case .write:
            let maxValue = value.maximumWriteValueLength(for: .withResponse)
            guard maxValue > 0, maxValue <= 512, request.offset < request.data.count else {
                closeConnection("invalid_write_length"); return
            }
            let bytes = min(maxValue, request.data.count - request.offset)
            request.chunkBytes = bytes
            // maximumWriteValueLength 已经是 ATT 应用载荷长度，不再错误地减去 3。
            let chunk = request.data.subdata(in: request.offset..<(request.offset + bytes))
            beginOperation(.write, seconds: 6, characteristic: request.characteristic)
            value.writeValue(chunk, for: request.characteristic, type: .withResponse)
        default: completeRequest(failure("invalid_operation"))
        }
    }

    private func completeRequest(_ value: [String: Any]) {
        guard let request = currentRequest else { return }
        currentRequest = nil
        request.timeout?.cancel()
        request.timeout = nil
        clearOperation()
        finish(request.call, value)
        pumpLater()
    }

    private func beginOperation(_ kind: Kind, seconds: Double, characteristic: CBCharacteristic? = nil) {
        precondition(operation == nil)
        let pending = Operation(kind, epoch: epoch, characteristic: characteristic)
        operation = pending
        let timer = DispatchWorkItem { [weak self, weak pending] in
            guard let self = self, let pending = pending, self.operation === pending, self.epoch == pending.epoch else { return }
            let code: String
            switch pending.kind {
            case .connect: code = "connect_timeout"
            case .services, .characteristics: code = "discovery_timeout"
            case .initialNotify, .subscribe: code = "subscription_timeout"
            case .write: code = "write_timeout"
            }
            self.closeConnection(code)
        }
        pending.timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func clearOperation() {
        operation?.timeout?.cancel()
        operation = nil
    }

    private func finish(_ call: Call, _ value: [String: Any], validPage: Bool = true) {
        call.timeout?.cancel()
        call.timeout = nil
        guard let reply = call.reply else { return }
        call.reply = nil
        if !validPage || call.page != page { reply(nil, "stale_navigation") }
        else { reply(value, nil) }
    }

    private func closeConnection(_ code: String) {
        let old = peripheral
        let connect = connectCall
        let current = currentRequest
        let queued = requests
        connectCall = nil
        currentRequest = nil
        current?.timeout?.cancel()
        requests.forEach { $0.timeout?.cancel() }
        requests.removeAll()
        epoch = UUID()
        clearOperation()
        peripheral = nil
        connectionScope = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        clearTelemetry()
        state = central == nil ? "uninitialized" : "disconnected"
        reason = code
        if let old = old {
            if old.state != .disconnected {
                retiring[old.identifier] = Retiring(peripheral: old, at: ProcessInfo.processInfo.systemUptime)
                central?.cancelPeripheralConnection(old)
            }
            // 不调用移除 bond/配对/解绑；iOS 本来就没有面向 App 的 MAC/bond 管理接口。
            old.delegate = nil
        }
        cancelConfirmation(code)
        let result = failure(code)
        if let connect = connect { finish(connect, result) }
        if let current = current { finish(current.call, result) }
        for request in queued { finish(request.call, result) }
        publish()
    }

    @discardableResult
    private func checkScope() -> Bool {
        guard let expected = connectionScope else { return false }
        guard let current = scopeProvider?(), current.valid, current == expected else {
            closeConnection("stale_session"); return false
        }
        return true
    }

    private func failure(_ code: String) -> [String: Any] {
        ["ok": false, "state": state, "reason": code, "valueB64": NSNull(), "at": NSNull()]
    }

    private func clearTelemetry() {
        protocolCodec.clearStream()
        telemetry.removeAll()
        telemetryTimes.removeAll()
        telemetryUptime.removeAll()
        telemetryFields.removeAll()
        values.removeAll()
        // 通知缓存与连接同生命周期；失败计数不在这里清，断开后仍要让网页看到上次的 lastNotifyError。
        lastNotifyValue = nil
        streamBuffered = 0
    }

    // 系统断开/取消连接的回调不保证每次都到；超过时限的条目按已排空处理，
    // 否则一个丢掉的回调会让该 UUID 在本次进程内再也连不上。
    private func pruneRetiring() {
        guard !retiring.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        retiring = retiring.filter { now - $0.value.at < Self.retiringStaleAfter }
    }

    // 通知错误先累计到快照；连续到阈值才判定链路失效并断开，让网页能显示异常、骑行也能记 gap。
    private func noteNotifyFailure() {
        protocolCodec.clearStream()
        notifyFailures += 1
        lastNotifyError = "notification_failed"
        if notifyFailures >= Self.notifyFailureLimit {
            closeConnection("notification_failed")
        } else {
            publish()
        }
    }

    private func pruneSeen() {
        pruneRetiring()
        let now = ProcessInfo.processInfo.systemUptime
        seen = seen.filter { $0.value.restored || now - $0.value.seenAt <= 60 || $0.key == peripheral?.identifier }
        if seen.count > 64 {
            let remove = seen.values.filter { !$0.restored && $0.peripheral !== peripheral }
                .sorted { $0.seenAt < $1.seenAt }.prefix(seen.count - 64)
            for value in remove { seen.removeValue(forKey: value.peripheral.identifier) }
        }
    }

    private func devices() -> [[String: Any]] {
        pruneSeen()
        return seen.values.sorted { $0.seenAt > $1.seenAt }.prefix(32).map {
            ["id": $0.peripheral.identifier.uuidString.lowercased(), "identifierKind": "corebluetooth_uuid",
             "name": $0.name as Any? ?? NSNull(), "rssi": $0.rssi as Any? ?? NSNull(),
             "connectable": $0.connectable as Any? ?? NSNull(), "restored": $0.restored]
        }
    }

    private func serviceList() -> [[String: Any]] {
        (peripheral?.services ?? []).filter { $0.uuid == Self.serviceUUID }.map { service in
            ["uuid": service.uuid.uuidString.lowercased(), "characteristics": (service.characteristics ?? []).map { item in
                var properties: [String] = []
                if item.properties.contains(.read) { properties.append("read") }
                if item.properties.contains(.write) { properties.append("write") }
                if item.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
                if item.properties.contains(.notify) { properties.append("notify") }
                if item.properties.contains(.indicate) { properties.append("indicate") }
                return ["uuid": item.uuid.uuidString.lowercased(), "properties": properties, "notifying": item.isNotifying] as [String: Any]
            }]
        }
    }

    private func publish() {
        let value = snapshot()
        for observer in Array(observers.values) { observer.state(value) }
    }

    private func owned(_ value: CBPeripheral) -> Bool {
        value === peripheral && value.state == .connected && checkScope()
    }

    private func receive(_ data: Data, characteristic: CBCharacteristic) {
        guard data.count <= 2048, connected, let scope = connectionScope, checkScope() else {
            protocolCodec.clearStream(); return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let text = protocolCodec.feedFramesJSON(fragmentHex: data.hexString, at: now)
        guard let decoded = IOSRideJSON.object(text), decoded["ok"] as? Bool == true else {
            protocolCodec.clearStream(); streamRejected += 1; return
        }
        streamBuffered = (decoded["buffered"] as? NSNumber)?.intValue ?? 0
        streamRejected = (decoded["rejected"] as? NSNumber)?.int64Value ?? streamRejected
        streamSkipped = (decoded["skipped"] as? NSNumber)?.int64Value ?? streamSkipped
        for frame in (decoded["frames"] as? [[String: Any]] ?? []).prefix(64) {
            guard let command = (frame["command"] as? NSNumber)?.intValue, command == 0xfd || command == 0xf3,
                  let fields = frame["fields"] as? [String: Any], fields["error"] == nil,
                  fields["ambiguous"] as? Bool != true,
                  let raw = frame["telemetry"] as? [String: Any] else { continue }
            // Shared 可能保留 rawFields 供平台归档；认证/未知 bytes 绝不通过网页桥输出。
            let clean = IOSRideJSON.telemetry(raw)
            guard !clean.isEmpty else { continue }
            sequence += 1
            let uptime = ProcessInfo.processInfo.systemUptime
            for (key, value) in clean { telemetry[key] = value; telemetryTimes[key] = now; telemetryUptime[key] = uptime }
            telemetryFields = IOSRideJSON.fields(fields)
            let sample = IOSBLETelemetrySample(sequence: sequence, at: now, receivedUptime: uptime,
                connectionGeneration: epoch, scope: scope, source: command == 0xfd ? "ble_period" : "ble_dash",
                values: clean, fields: telemetryFields)
            if let hex = frame["frameHex"] as? String, let bytes = Data(strictHex: hex), safeRaw(frame) {
                appendValue(["service": Self.serviceUUID.uuidString.lowercased(),
                             "characteristic": characteristic.uuid.uuidString.lowercased(),
                             "valueB64": bytes.base64EncodedString(), "at": now, "seq": sequence])
            }
            for observer in Array(observers.values) { observer.sample(sample) }
        }
        publish()
    }

    private func safeRaw(_ frame: [String: Any]) -> Bool {
        guard frame["ok"] as? Bool == true,
              let command = (frame["command"] as? NSNumber)?.intValue, command == 0xfd || command == 0xf3,
              let fields = frame["fields"] as? [String: Any], fields["error"] == nil, fields["ambiguous"] as? Bool != true,
              let raw = frame["rawFields"] as? [[String: Any]] else { return false }
        return raw.allSatisfy { field in
            let wire = (field["wire"] as? NSNumber)?.intValue ?? -1
            return wire == 0 || wire == 1 || wire == 5
        }
    }

    private func appendValue(_ value: [String: Any]) {
        // 最近一条安全原始帧同时作为 ble.read 的缓存来源；ble.poll 清队列时不清它。
        lastNotifyValue = value
        if values.count >= 64 { values.removeFirst(); droppedValues += 1 }
        values.append(value)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            if peripheral == nil && !scanRequested { state = "disconnected"; reason = "" }
            startScan()
        case .unauthorized, .unsupported, .poweredOff:
            finishScan(reason: powerName, ok: false)
            closeConnection(powerName)
            state = powerName
            reason = powerName
        case .resetting:
            closeConnection("bluetooth_resetting")
            state = "resetting"
        case .unknown: state = "initializing"
        @unknown default: state = "unknown"; reason = "bluetooth_unavailable"
        }
        publish()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard central === self.central || self.central == nil else { return }
        // 系统可在初始化返回之前回调。采用实际 manager，并撤销未被当前用户/账号确认的恢复连接。
        self.central = central
        central.stopScan()
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []).prefix(32)
        for value in restored {
            restoredIdentifiers.insert(value.identifier)
            seen[value.identifier] = Seen(peripheral: value, name: value.name.map { String($0.prefix(80)) },
                rssi: nil, connectable: nil, seenAt: ProcessInfo.processInfo.systemUptime, restored: true)
            if value.state != .disconnected {
                retiring[value.identifier] = Retiring(peripheral: value, at: ProcessInfo.processInfo.systemUptime)
                central.cancelPeripheralConnection(value)
            }
            value.delegate = nil
        }
        state = "disconnected"
        reason = "restored_requires_confirmation"
        publish()
    }

    func centralManager(_ central: CBCentralManager, didDiscover value: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, scanRequested, central.isScanning,
              ProcessInfo.processInfo.systemUptime <= scanDeadline else { return }
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? value.name
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        if seen.count >= 64 && seen[value.identifier] == nil { return }
        seen[value.identifier] = Seen(peripheral: value, name: advertisedName.map { String($0.prefix(80)) },
            rssi: rssi, connectable: connectable, seenAt: ProcessInfo.processInfo.systemUptime, restored: false)
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect value: CBPeripheral) {
        guard central === self.central else { return }
        if retiring[value.identifier] != nil { central.cancelPeripheralConnection(value); return }
        guard value === peripheral, operation?.kind == .connect, checkScope() else { central.cancelPeripheralConnection(value); return }
        clearOperation()
        state = "discovering"
        beginOperation(.services, seconds: 10)
        value.discoverServices([Self.serviceUUID])
        publish()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect value: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        retiring.removeValue(forKey: value.identifier)
        if value === peripheral { closeConnection("connect_failed") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral value: CBPeripheral, error: Error?) {
        guard central === self.central else { return }
        retiring.removeValue(forKey: value.identifier)
        if value === peripheral { closeConnection(error == nil ? "disconnected" : "connection_lost") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard owned(peripheral), operation?.kind == .services else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            closeConnection(error == nil ? "missing_service" : "service_discovery_failed"); return
        }
        clearOperation()
        beginOperation(.characteristics, seconds: 10)
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owned(peripheral), service.uuid == Self.serviceUUID, operation?.kind == .characteristics else { return }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == Self.writeUUID }), write.properties.contains(.write),
              let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID }),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            closeConnection(error == nil ? "missing_characteristic" : "characteristic_discovery_failed"); return
        }
        clearOperation()
        writeCharacteristic = write
        notifyCharacteristic = notify
        beginOperation(.initialNotify, seconds: 6, characteristic: notify)
        // CoreBluetooth 负责 CCCD 实际写入，只有 didUpdateNotificationState 成功才宣布 ready。
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard owned(peripheral), let pending = operation, pending.characteristic === characteristic else { return }
        if pending.kind == .initialNotify {
            guard error == nil, characteristic.isNotifying else { closeConnection("subscription_failed"); return }
            clearOperation()
            state = "connected"
            reason = ""
            if let call = connectCall { connectCall = nil; finish(call, snapshot()) }
            publish()
            pumpLater()
        } else if pending.kind == .subscribe, let request = currentRequest {
            guard error == nil, characteristic.isNotifying == request.enabled else { closeConnection("subscription_failed"); return }
            completeRequest(["ok": true, "id": peripheral.identifier.uuidString.lowercased(),
                             "enabled": characteristic.isNotifying, "state": "connected"])
            publish()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owned(peripheral) else { return }
        // 不再有 GATT read 操作：这个回调只承载通知。错误时累计失败次数，
        // 连续到阈值才断开（进骑行 gap、网页能看到断开），单次错误只记进快照。
        guard characteristic === notifyCharacteristic, characteristic.isNotifying, connected else { return }
        // 单条异常（error 或拿不到值）只累计；超大帧仍交给 receive 按既有规则丢弃。
        guard error == nil, let data = characteristic.value else {
            noteNotifyFailure(); return
        }
        notifyFailures = 0
        lastNotifyError = ""
        receive(Data(data), characteristic: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owned(peripheral), let observed = operation, observed.kind == .write,
              observed.characteristic === characteristic else { return }
        // 固定此回调的操作槽，下一块延后入栈，迟到/重复回调不能确认下一帧。
        DispatchQueue.main.async { [weak self, weak observed] in
            guard let self = self, let observed = observed, self.operation === observed,
                  observed.epoch == self.epoch, let request = self.currentRequest else { return }
            guard error == nil else { self.closeConnection("write_failed"); return }
            self.clearOperation()
            request.offset += request.chunkBytes
            request.chunks += 1
            if request.offset == request.data.count {
                self.completeRequest(["ok": true, "state": "connected", "bytes": request.data.count,
                                      "chunks": request.chunks, "acknowledgement": "gatt_only",
                                      "authenticated": false, "vehicleActionConfirmed": false])
            } else { self.pumpLater() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral else { return }
        if invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) {
            // 不自动重连/认证/重放旧周期写入。
            closeConnection("services_invalidated")
        }
    }
}

private extension Data {
    init?(strictHex text: String) {
        guard text.utf8.count % 2 == 0, text.utf8.count <= 4096 else { return nil }
        let digits = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        func digit(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        for at in stride(from: 0, to: digits.count, by: 2) {
            guard let a = digit(digits[at]), let b = digit(digits[at + 1]) else { return nil }
            bytes.append((a << 4) | b)
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
