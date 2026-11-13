import Foundation
import CoreBluetooth
import UIKit
import ZeehoShared

struct IOSNativeRecording {
    let id: UUID
    let scope: IOSRideScope
    let startedUptime: TimeInterval
    let background: Bool
}

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

struct IOSBLEPipeFailure: Error {
    let code: String
    init(_ code: String) { self.code = code }
}
struct IOSBLEPipeAuthorizationInput {
    let navID: String
    let vin: String
    let frame: String
    let purpose: String
}
struct IOSBLEPipeAuthorization {
    let scope: IOSRideScope
    let navID: String
    let frame: String
    let expiresUptime: TimeInterval
    let isCurrent: () -> Bool
}
struct IOSBLEPipeConsentInput {
    let scope: IOSRideScope
    let purpose: String
    let peripheralID: String
    let service: String
    let writeCharacteristic: String
    let notifyCharacteristic: String
}
typealias IOSBLEPipeAuthorizationProvider = (IOSBLEPipeAuthorizationInput,
    @escaping (Result<IOSBLEPipeAuthorization, IOSBLEPipeFailure>) -> Void) -> (() -> Void)?
typealias IOSBLEPipeConsentProvider = (IOSBLEPipeConsentInput, @escaping (Bool) -> Void) -> (() -> Void)?

final class IOSBluetoothService: NSObject, IOSBridgeService, IOSBridgeCancellableService, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = IOSBluetoothService()
    static let restorationIdentifier = "io.github.lswlc33.dashboard.ble.read.v1"
    static let serviceUUID = CBUUID(string: "0000B354-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let writeUUID = CBUUID(string: "0000B356-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let notifyUUID = CBUUID(string: "0000B357-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    static let diagnosticServiceUUID = CBUUID(string: "0000B555-D6D8-C7EC-BDF0-EAB1BFC6BCBC")
    private static let hidUUID = CBUUID(string: "1812")
    private static let hidReportUUID = CBUUID(string: "2A4D")
    // 通知连续失败到这个次数才判定链路失效；单次错误只记到快照里。
    private static let notifyFailureLimit = 3
    // 系统断开/取消连接的回调可能丢失；超过这个时长就让 UUID 允许重新连接。
    private static let retiringStaleAfter: TimeInterval = 5

    let methods = ["ble.status", "ble.scan", "ble.stopScan", "ble.connect", "ble.disconnect",
                   "ble.services", "ble.read", "ble.subscribe", "ble.write", "ble.poll",
                   "ble.open", "ble.exchange", "ble.close", "ble.identity", "ble.systemPairing",
                   "ble.diagnostic.open", "ble.diagnostic.poll", "ble.diagnostic.close", "ble.renew.prepare"]

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
        let roles: [Int]
        let manufacturerID: Int?
    }

    private enum Kind { case connect, services, characteristics, initialNotify, subscribe, write, securityRead }
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
        var data: Data
        var offset = 0
        var chunkBytes = 0
        var chunks = 0
        var onStart: (() -> Void)?
        // 只有 fresh cloud material callback 创建的 capability 能进入录制后台写路径。
        var renewalCapability: UUID?
        var onRenewalReply: ((Bool) -> Void)?
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
    private var protocolSequence: Int64 = 0
    private var connectionRole = 1
    private var scanRoles: [Int] = [1]
    private var scanServices: [CBUUID] = [IOSBluetoothService.serviceUUID]
    private var scanNamePrefix: String?
    private var selectedServiceUUID = IOSBluetoothService.serviceUUID
    private var selectedWriteUUID = IOSBluetoothService.writeUUID
    private var selectedNotifyUUID = IOSBluetoothService.notifyUUID
    private var securityReply: ((Bool, String) -> Void)?
    private var securityReport: CBCharacteristic?
    private var peripheralRSSI: Int?
    private var peripheralRSSIAt: Int64?
    private var diagnosticRSSIRequestedAt: TimeInterval = -1
    private var pipeAuthorizationProvider: IOSBLEPipeAuthorizationProvider?
    private var pipeConsentProvider: IOSBLEPipeConsentProvider?
    private var pipeLease: PipeLease?
    private var pipeOpenCall: Call?
    private var pipeOpenID = UUID()
    private var pipeOpenPhase = "idle"
    private var pipeProviderCancel: (() -> Void)?
    private var pipeConsentCancel: (() -> Void)?
    private var pipePairCall: Call?
    private var identityCalls: [UUID: Call] = [:]
    private var opaqueNotifications: [[String: Any]] = []
    private var notificationEvictions = 0
    // 主动清掉旧 lease/认证窗口是安全边界，不是读者漏读。游标不能跨这个边界续拼帧。
    private var windowResetSeq: Int64 = 0
    private var windowResetReason = "lease_opened"
    private var pipeExchange: PipeExchange?
    private var pipeWatch: DispatchWorkItem?
    private var pipeRateStarted: TimeInterval = 0
    private var pipeRateCount = 0
    private var pipeRateBytes = 0
    private var actualRecordingProvider: (() -> IOSNativeRecording?)?
    private var renewalActivate: ((UUID) -> Bool)?
    private var renewalObserve: ((UUID, IOSRideScope, String) -> Bool)?
    private var renewalEnded: ((UUID) -> Void)?
    private var recipe: IOSBLERecipe?
    private var recipeJSON: Data?
    private var recipeLeaseID: UUID?
    private var recordingLease: IOSSessionRenewalLease?
    private var recordingOwnerLease: PipeLease?
    private var legacyObservationLease: PipeLease?
    private var renewalBoundRecordingID: UUID?
    private var recordingEpoch = UUID()
    private var renewalCapability: UUID?
    private var renewalExecutor: IOSBLERecipeExecutor?
    private var authorizationDeadline: DispatchWorkItem?
    private var cloudAuthorizationCurrent = false
    private var admissionReason = "native_authorization_required"

    private final class PipeLease {
        let id = UUID()
        let authorization: IOSBLEPipeAuthorization
        let issuedUptime = ProcessInfo.processInfo.systemUptime
        let page: UInt64
        let purpose: String
        let peripheralID: String
        let service: CBUUID
        let write: CBUUID
        let notify: CBUUID
        let generation: UUID
        init(authorization: IOSBLEPipeAuthorization, page: UInt64, purpose: String,
             peripheralID: String, service: CBUUID, write: CBUUID, notify: CBUUID, generation: UUID) {
            self.authorization = authorization; self.page = page; self.purpose = purpose
            self.peripheralID = peripheralID; self.service = service; self.write = write
            self.notify = notify; self.generation = generation
        }
    }
    private final class PipeExchange {
        let id: String
        let call: Call
        let lease: UUID
        var startSeq: Int64 = 0
        var started: TimeInterval = 0
        var written = false
        var writeResult: [String: Any] = [:]
        let prefix: Data?
        let wait: Bool
        let timeout: Double
        var timer: DispatchWorkItem?
        init(id: String, call: Call, lease: UUID, prefix: Data?, wait: Bool, timeout: Double) {
            self.id = id; self.call = call; self.lease = lease; self.prefix = prefix; self.wait = wait; self.timeout = timeout
        }
    }

    private var activeServiceUUID: CBUUID { selectedServiceUUID }

    func configurePipeAuthorizationProvider(_ provider: @escaping IOSBLEPipeAuthorizationProvider) {
        precondition(Thread.isMainThread); pipeAuthorizationProvider = provider
    }
    func configurePipeConsentProvider(_ provider: @escaping IOSBLEPipeConsentProvider) {
        precondition(Thread.isMainThread); pipeConsentProvider = provider
    }

    func configureRecordingProvider(_ provider: @escaping () -> IOSNativeRecording?) {
        precondition(Thread.isMainThread); actualRecordingProvider = provider
    }
    // 主 Dashboard 适配 service 的 typed callbacks；不引入另一套云续租协议。
    func configureRenewalProvider(activate: @escaping (UUID) -> Bool,
                                  observe: @escaping (UUID, IOSRideScope, String) -> Bool,
                                  ended: @escaping (UUID) -> Void) {
        precondition(Thread.isMainThread)
        renewalActivate = activate; renewalObserve = observe; renewalEnded = ended
    }
    func currentRecordingLease() -> IOSSessionRenewalLease? {
        precondition(Thread.isMainThread)
        guard let lease = recordingLease, actualOwns(lease) else { return nil }
        return lease
    }
    private func actualOwns(_ lease: IOSSessionRenewalLease) -> Bool {
        guard let run = actualRecordingProvider?(), run.id == recordingID, run.id == lease.recordingID,
              run.scope == lease.scope, run.scope.valid, recordingScope == run.scope,
              scopeProvider?() == run.scope, connectionScope == run.scope, connected,
              lease.connectionGeneration == epoch.uuidString.lowercased(),
              let owner = recordingOwnerLease, owner.generation == epoch, owner.purpose == "telemetry",
              recipeLeaseID == owner.id else { return false }
        return true
    }
    var canAcceptTelemetry: Bool {
        precondition(Thread.isMainThread)
        guard let lease = recordingLease, actualOwns(lease), cloudAuthorizationCurrent,
              lease.nativeAuthenticated, renewalExecutor == nil,
              ProcessInfo.processInfo.systemUptime < lease.authorizedUntil else { return false }
        return true
    }
    // 兼容未准备续租的既有只读观察，不是车辆认证，也不能打开后台写权限。
    // 一旦 run 绑定了续租，任何失败都不能跌回这个较弱路径。
    var canObserveTelemetry: Bool {
        precondition(Thread.isMainThread)
        if canAcceptTelemetry { return true }
        guard renewalBoundRecordingID == nil, let lease = legacyObservationLease,
              let run = actualRecordingProvider?(), run.id == recordingID, run.scope == recordingScope,
              run.scope == connectionScope, scopeProvider?() == run.scope, run.scope.valid, connected,
              lease.generation == epoch, lease.purpose == "telemetry",
              ProcessInfo.processInfo.systemUptime < min(lease.authorization.expiresUptime, lease.issuedUptime + 300),
              UIApplication.shared.applicationState == .active, lease.authorization.isCurrent() else { return false }
        return true
    }
    func canObserveTelemetry(recordingId: UUID, scope: IOSRideScope, connectionGeneration: UUID) -> Bool {
        precondition(Thread.isMainThread)
        return canObserveTelemetry && recordingID == recordingId && recordingScope == scope && epoch == connectionGeneration
    }
    func canAcceptTelemetry(recordingId: UUID, scope: IOSRideScope, connectionGeneration: UUID) -> Bool {
        precondition(Thread.isMainThread)
        return canAcceptTelemetry && recordingLease?.recordingID == recordingId && recordingLease?.scope == scope
            && epoch == connectionGeneration
    }
    func observeRecordingEvent(id: UUID, scope: IOSRideScope) {
        precondition(Thread.isMainThread)
        guard let lease = currentRecordingLease(), lease.recordingID == id, lease.scope == scope else { return }
        if ProcessInfo.processInfo.systemUptime >= lease.authorizedUntil {
            invalidateRecordingAuthorization(id: id, scope: scope, connectionGeneration: lease.connectionGeneration,
                                              reason: "authorization_expired")
        }
        let admitted = renewalObserve?(id, scope, lease.connectionGeneration) ?? false
        if !admitted && cloudAuthorizationCurrent {
            invalidateRecordingAuthorization(id: id, scope: scope, connectionGeneration: lease.connectionGeneration,
                                              reason: "native_authorization_required")
        }
    }
    @discardableResult
    func renewRecordingLease(id: UUID, scope: IOSRideScope, connectionGeneration: String, expiresUptime: Double) -> Bool {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        guard let old = recordingLease, actualOwns(old), old.recordingID == id, old.scope == scope,
              old.connectionGeneration == connectionGeneration, old.nativeAuthenticated, cloudAuthorizationCurrent,
              renewalExecutor == nil, now < old.authorizedUntil,
              expiresUptime.isFinite, expiresUptime > now, expiresUptime - now <= 300.001 else { return false }
        // 续期只更新授权时刻。连接、GATT 序列、generation、遥测 sourceTimes 一个都不刷新。
        recordingLease = IOSSessionRenewalLease(recordingID: id, scope: scope, connectionGeneration: connectionGeneration,
            authorizedAt: max(0, expiresUptime - 300), authorizedUntil: expiresUptime, nativeAuthenticated: true)
        armAuthorizationDeadline(); admissionReason = ""; publish(); return true
    }
    func invalidateRecordingAuthorization(id: UUID, scope: IOSRideScope, connectionGeneration: String, reason: String) {
        precondition(Thread.isMainThread)
        guard let old = recordingLease, old.recordingID == id, old.scope == scope,
              old.connectionGeneration == connectionGeneration else { return }
        let mustDrain = currentRequest?.renewalCapability != nil || requests.contains(where: { $0.renewalCapability != nil })
        cloudAuthorizationCurrent = false; admissionReason = reason
        recordingLease = IOSSessionRenewalLease(recordingID: id, scope: scope, connectionGeneration: connectionGeneration,
            authorizedAt: old.authorizedAt, authorizedUntil: old.authorizedUntil, nativeAuthenticated: false)
        let executor = renewalExecutor; renewalExecutor = nil; renewalCapability = nil
        authorizationDeadline?.cancel(); authorizationDeadline = nil
        executor?.cancel(); clearTelemetry(); publish()
        if mustDrain { closeConnection(reason) } // 超时写的迟到 GATT 回执不能确认后续握手。
    }
    private func armAuthorizationDeadline() {
        authorizationDeadline?.cancel()
        guard let lease = recordingLease else { return }
        let context = recordingEpoch
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.recordingEpoch == context,
                  let current = self.recordingLease, current.recordingID == lease.recordingID,
                  ProcessInfo.processInfo.systemUptime >= current.authorizedUntil else { return }
            self.invalidateRecordingAuthorization(id: current.recordingID, scope: current.scope,
                connectionGeneration: current.connectionGeneration, reason: "authorization_expired")
        }
        authorizationDeadline = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, lease.authorizedUntil - ProcessInfo.processInfo.systemUptime), execute: timer)
    }
    @discardableResult
    func prepareRenewalRecipe(_ options: [String: Any]) -> Bool {
        precondition(Thread.isMainThread)
        guard let lease = pipeTicket(options), lease.purpose == "telemetry",
              operation == nil, currentRequest == nil, requests.isEmpty, pipeExchange == nil,
              options["generation"] as? String == lease.generation.uuidString.lowercased(),
              renewalActivate != nil, renewalObserve != nil, let parsed = IOSBLERecipe(options["recipe"]),
              let json = options["recipe"] as? [String: Any], JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), data.count <= 32768 else { return false }
        if let id = recordingID {
            guard let run = actualRecordingProvider?(), run.id == id, run.scope == lease.authorization.scope,
                  options["recordingId"] as? String == id.uuidString.lowercased() else { return false }
        }
        guard recordingOwnerLease == nil || recordingOwnerLease === lease else { return false }
        recipe = parsed; recipeJSON = data; recipeLeaseID = lease.id
        if let id = recordingID {
            renewalBoundRecordingID = id
            if let scope = recordingScope { setRecordingContext(id: id, background: recordingBackground, scope: scope) }
        }
        return true
    }
    func reauthenticate(_ change: IOSSessionRenewalMaterialChange, secretResolver: @escaping (String) -> Data?,
                        completion: @escaping (IOSSessionRenewalLease?) -> Void) {
        precondition(Thread.isMainThread)
        guard let old = recordingLease, actualOwns(old), old.recordingID == change.recordingID, old.scope == change.scope,
              old.connectionGeneration == change.previousConnectionGeneration else { completion(nil); return }
        // 对应当前 run 的材料变化一到就撤旧认证；配方缺失/无效也绝不保留旧授权。
        cloudAuthorizationCurrent = false; admissionReason = change.reason; clearTelemetry()
        recordingLease = IOSSessionRenewalLease(recordingID: old.recordingID, scope: old.scope,
            connectionGeneration: old.connectionGeneration, authorizedAt: old.authorizedAt,
            authorizedUntil: old.authorizedUntil, nativeAuthenticated: false)
        guard let recipe = recipe,
              let prepared = recipeJSON, JSONSerialization.isValidJSONObject(change.reauthenticationRecipe),
              let submitted = try? JSONSerialization.data(withJSONObject: change.reauthenticationRecipe, options: [.sortedKeys]),
              submitted == prepared, renewalExecutor == nil, operation == nil, currentRequest == nil, requests.isEmpty,
              ProcessInfo.processInfo.systemUptime < old.authorizedUntil else { completion(nil); return }
        var handles: [String: String] = [:]
        for material in recipe.materials {
            let matches = change.materials.filter { $0.requestIndex == material.requestIndex && $0.path == material.path && $0.type == material.type }
            guard matches.count == 1 else { completion(nil); return }
            handles[material.slot] = matches[0].handle
        }
        // fresh native cloud 对比后先撤销旧认证；只有这个调用可以铸造内部续认证 capability。
        cloudAuthorizationCurrent = false; admissionReason = change.reason; clearTelemetry()
        recordingLease = IOSSessionRenewalLease(recordingID: old.recordingID, scope: old.scope,
            connectionGeneration: old.connectionGeneration, authorizedAt: old.authorizedAt,
            authorizedUntil: old.authorizedUntil, nativeAuthenticated: false)
        let context = recordingEpoch; let capability = UUID(); renewalCapability = capability
        let checkedAt = ProcessInfo.processInfo.systemUptime
        let executor = IOSBLERecipeExecutor(recipe: recipe, generation: old.connectionGeneration, handles: handles,
            isCurrent: { [weak self] in
                guard let self = self, self.recordingEpoch == context, self.renewalCapability == capability,
                      let lease = self.recordingLease, self.actualOwns(lease) else { return false }
                return ProcessInfo.processInfo.systemUptime < old.authorizedUntil
            }, secret: secretResolver, writer: { [weak self] bytes, operationID, started, reply in
                self?.writeRenewal(bytes, operationID: operationID, capability: capability, started: started, reply: reply)
            }, completion: { [weak self] success in
                guard let self = self, self.recordingEpoch == context, self.renewalCapability == capability,
                      let current = self.recordingLease, self.actualOwns(current),
                      ProcessInfo.processInfo.systemUptime < old.authorizedUntil else { completion(nil); return }
                self.renewalExecutor = nil; self.renewalCapability = nil
                guard success else {
                    self.invalidateRecordingAuthorization(id: old.recordingID, scope: old.scope,
                        connectionGeneration: old.connectionGeneration, reason: "native_authentication_failed")
                    completion(nil); return
                }
                let renewed = IOSSessionRenewalLease(recordingID: old.recordingID, scope: old.scope,
                    connectionGeneration: old.connectionGeneration, authorizedAt: checkedAt,
                    authorizedUntil: checkedAt + 300, nativeAuthenticated: true)
                self.recordingLease = renewed; self.cloudAuthorizationCurrent = true; self.admissionReason = ""
                self.armAuthorizationDeadline(); self.publish(); completion(renewed)
            })
        renewalExecutor = executor; publish(); executor.start()
    }
    private func writeRenewal(_ bytes: Data, operationID: String, capability: UUID,
                              started: @escaping (IOSBLERecipeExecutor.Receipt) -> Void, reply: @escaping (Bool) -> Void) {
        guard renewalCapability == capability, let lease = currentRecordingLease(), renewalExecutor != nil,
              ProcessInfo.processInfo.systemUptime < lease.authorizedUntil,
              operation == nil, currentRequest == nil, requests.isEmpty, let target = writeCharacteristic,
              target.properties.contains(.write), bytes.count <= 263 else { reply(false); return }
        let call = Call(page: page) { _, _ in } // 不经过网页回执或前台 page 票据。
        let request = Request(kind: .write, call: call, characteristic: target, data: bytes)
        request.renewalCapability = capability; request.onRenewalReply = reply
        request.onStart = { [weak self] in
            guard let self = self, self.renewalCapability == capability else { reply(false); return }
            started(IOSBLERecipeExecutor.Receipt(operationID: operationID, startSequence: self.protocolSequence,
                startedUptime: ProcessInfo.processInfo.systemUptime, generation: self.epoch.uuidString.lowercased()))
        }
        enqueue(request)
    }
    private func detachRecordingAuthorization() {
        let id = recordingLease?.recordingID
        recordingEpoch = UUID(); recordingLease = nil; recordingOwnerLease = nil; legacyObservationLease = nil
        cloudAuthorizationCurrent = false
        let executor = renewalExecutor; renewalExecutor = nil; renewalCapability = nil
        authorizationDeadline?.cancel(); authorizationDeadline = nil; executor?.cancel()
        if let id = id { renewalEnded?(id) }
        admissionReason = "native_authorization_required"
    }

    // CoreBluetooth 没有 bond 查询/创建 API。公开的 HID read 可以让系统处理安全升级；
    // 读成功只说明访问成功，不代表已 bond。
    private func requestSystemPairing(completion: @escaping (Bool, String) -> Void) {
        guard connected, checkScope(), UIApplication.shared.applicationState == .active,
              operation == nil, currentRequest == nil, requests.isEmpty, securityReply == nil,
              let value = peripheral else { completion(false, "system_pairing_not_ready"); return }
        securityReply = completion; securityReport = nil
        beginOperation(.securityRead, seconds: 25)
        value.discoverServices([Self.hidUUID])
    }
    private func finishSecurityRead(_ success: Bool, _ code: String) {
        let callback = securityReply; securityReply = nil; securityReport = nil
        clearOperation(); callback?(success, code); pumpLater()
    }

    private func pipeUUID(_ value: Any?) -> CBUUID? {
        guard let text = value as? String else { return nil }
        if text.utf8.count == 4 || text.utf8.count == 8 {
            guard text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
            return CBUUID(string: text)
        }
        guard text.utf8.count == 36, UUID(uuidString: text) != nil else { return nil }
        return CBUUID(string: text)
    }

    private func pipeCurrent(_ lease: PipeLease, foreground: Bool = true) -> Bool {
        let auth = lease.authorization
        let now = ProcessInfo.processInfo.systemUptime
        if recordingOwnerLease === lease, let issued = recordingLease, actualOwns(issued) {
            return pipeLease === lease && now < issued.authorizedUntil
                && (!foreground || UIApplication.shared.applicationState == .active)
        }
        return pipeLease === lease && lease.page == page && lease.generation == epoch && connected
            && connectionScope == auth.scope && scopeProvider?() == auth.scope && auth.scope.valid
            && ProcessInfo.processInfo.systemUptime < auth.expiresUptime && auth.isCurrent()
            && (!foreground || UIApplication.shared.applicationState == .active)
    }

    private func pipeTicket(_ options: [String: Any]) -> PipeLease? {
        guard let lease = pipeLease, options["leaseId"] as? String == lease.id.uuidString.lowercased(),
              options["navId"] as? String == lease.authorization.navID,
              options["vin"] as? String == lease.authorization.scope.vin,
              pipeFrame(options["frame"]) == lease.authorization.frame, pipeCurrent(lease) else { return nil }
        return lease
    }
    private func pipeFrame(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty, text.utf8.count <= 128 { return text }
        if let n = IOSRideJSON.integer(value) { return String(n) }
        return nil
    }
    private func pipeSnapshot(_ lease: PipeLease, after: Int64? = nil) -> [String: Any] {
        // ring 不消费，避免 poll 抢走 exchange 的早到通知。正常淘汰已读历史不算本读者缺口。
        let requestedAfter = after ?? protocolSequence
        let effectiveAfter = max(requestedAfter, windowResetSeq)
        let windowStart = opaqueNotifications.first.flatMap { IOSRideJSON.integer($0["seq"]) } ?? (protocolSequence + 1)
        let gapCount = max(Int64(0), min(protocolSequence, windowStart - 1) - effectiveAfter)
        var result: [String: Any] = ["ok": true, "leaseId": lease.id.uuidString.lowercased(),
            "generation": lease.generation.uuidString.lowercased(), "connected": connected,
            "id": lease.peripheralID, "identifierKind": "corebluetooth_uuid", "purpose": lease.purpose,
            "systemBondState": "unknown_os_managed", "osManaged": true,
            "authenticated": false, "vehicleActionConfirmed": false,
            "maxWriteBytes": peripheral.map { $0.maximumWriteValueLength(for: .withResponse) as Any } ?? NSNull(),
            "notifySeq": protocolSequence, "windowStart": windowStart, "afterSeq": requestedAfter,
            "gapCount": gapCount, "droppedNotifications": gapCount,
            "notificationEvictions": notificationEvictions, "windowResetSeq": windowResetSeq,
            "windowResetReason": windowResetReason, "cursorReset": requestedAfter < windowResetSeq,
            "services": serviceList(), "role": connectionRole,
            "rssi": peripheralRSSI as Any? ?? NSNull(), "rssiAt": peripheralRSSIAt as Any? ?? NSNull()]
        if after != nil {
            result["notifications"] = opaqueNotifications.filter { (IOSRideJSON.integer($0["seq"]) ?? 0) > effectiveAfter }
        }
        return result
    }

    private func diagnosticSnapshot(_ lease: PipeLease, requestRSSI: Bool = false) -> [String: Any] {
        precondition(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        let readRequested = requestRSSI && pipeCurrent(lease) && (diagnosticRSSIRequestedAt < 0 || now - diagnosticRSSIRequestedAt >= 2)
        if readRequested {
            diagnosticRSSIRequestedAt = now
            peripheral?.readRSSI()
        }
        return ["ok": true, "leaseId": lease.id.uuidString.lowercased(), "generation": lease.generation.uuidString.lowercased(),
            "id": lease.peripheralID, "identifierKind": "corebluetooth_uuid", "connected": connected,
            "purpose": "diagnostic", "role": 2, "diagnosticOnly": true, "readOnly": true, "canWrite": false,
            "supportedRoles": [1, 2], "role2ReadOnly": true, "supported2": false,
            "authenticated": false, "registrationVerified": false, "automaticUnlock": false,
            "systemBondState": "unknown_os_managed", "iosVehicleVerification": "not_performed",
            "services": serviceList(), "rssi": peripheralRSSI as Any? ?? NSNull(),
            "rssiAt": peripheralRSSIAt as Any? ?? NSNull(), "rssiReadRequested": readRequested]
    }

    private func openPipe(_ options: [String: Any], diagnostic: Bool = false, reply: @escaping (Any?, String?) -> Void) {
        guard UIApplication.shared.applicationState == .active else { reply(failure("foreground_required"), nil); return }
        guard pipeOpenCall == nil, pipePairCall == nil, pipeExchange == nil, operation == nil,
              currentRequest == nil, requests.isEmpty, connectCall == nil, confirmationCall == nil else {
            reply(failure("operation_busy"), nil); return
        }
        guard let navID = options["navId"] as? String, !navID.isEmpty, navID.utf8.count <= 128,
              let vin = options["vin"] as? String, let frame = pipeFrame(options["frame"]),
              let id = options["id"] as? String, UUID(uuidString: id) != nil,
              let service = pipeUUID(options["service"]),
              let authorizer = pipeAuthorizationProvider, let consent = pipeConsentProvider else {
            reply(failure("pipe_authorization_required"), nil); return
        }
        let purpose: String
        let write: CBUUID
        let notify: CBUUID
        if diagnostic {
            guard service == Self.diagnosticServiceUUID, options["writeCharacteristic"] == nil,
                  options["notifyCharacteristic"] == nil, options["valueB64"] == nil else {
                reply(failure("diagnostic_service_required"), nil); return
            }
            // 仅用 service 占内部类型槽，不发现、读写或订阅任何假想 HMI 特征。
            purpose = "diagnostic"; write = service; notify = service
        } else {
            guard service != Self.diagnosticServiceUUID,
                  let selectedWrite = pipeUUID(options["writeCharacteristic"]),
                  let selectedNotify = pipeUUID(options["notifyCharacteristic"]),
                  let selectedPurpose = options["purpose"] as? String, ["telemetry", "provisioning"].contains(selectedPurpose) else {
                reply(failure("diagnostic_api_required"), nil); return
            }
            purpose = selectedPurpose; write = selectedWrite; notify = selectedNotify
        }
        if let old = pipeLease {
            if old.purpose == purpose && pipeTicket(options) === old {
                reply(diagnostic ? diagnosticSnapshot(old) : pipeSnapshot(old), nil)
            } else { reply(failure("lease_busy"), nil) }
            return
        }
        if diagnostic && (recordingID != nil || peripheral != nil || connectCall != nil) {
            reply(failure("diagnostic_connection_busy"), nil); return
        }
        if recordingID != nil && (purpose != "telemetry" || peripheral?.identifier != UUID(uuidString: id)
            || selectedServiceUUID != service || selectedWriteUUID != write || selectedNotifyUUID != notify) {
            reply(failure("recording_connection_busy"), nil); return
        }
        let call = Call(page: page, reply: reply); pipeOpenCall = call
        let openID = UUID(); pipeOpenID = openID; pipeOpenPhase = "authorization"
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.pipeOpenID == openID, self.pipeOpenCall === call else { return }
            self.retirePipe("authorization_timeout", disconnect: self.recordingID == nil)
        }
        call.timeout = timer; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timer)
        let input = IOSBLEPipeAuthorizationInput(navID: navID, vin: vin, frame: frame, purpose: purpose)
        pipeProviderCancel = authorizer(input) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.pipeOpenID == openID, self.pipeOpenCall === call,
                      self.pipeOpenPhase == "authorization" else { return }
                self.pipeOpenPhase = "consent"
                self.pipeProviderCancel = nil
                guard case .success(let auth) = result, auth.scope.valid, self.scopeProvider?() == auth.scope,
                      auth.scope.vin == vin, auth.navID == navID, auth.frame == frame, auth.isCurrent(),
                      auth.expiresUptime.isFinite, auth.expiresUptime > ProcessInfo.processInfo.systemUptime,
                      self.page == call.page, UIApplication.shared.applicationState == .active else {
                    self.retirePipe("stale_session", disconnect: false); return
                }
                let prompt = IOSBLEPipeConsentInput(scope: auth.scope, purpose: purpose, peripheralID: id,
                    service: service.uuidString, writeCharacteristic: diagnostic ? "" : write.uuidString,
                    notifyCharacteristic: diagnostic ? "" : notify.uuidString)
                self.pipeConsentCancel = consent(prompt) { [weak self] approved in
                    DispatchQueue.main.async {
                        guard let self = self, self.pipeOpenID == openID, self.pipeOpenCall === call,
                              self.pipeOpenPhase == "consent" else { return }
                        self.pipeOpenPhase = "connection"
                        self.pipeConsentCancel = nil
                        guard approved, auth.isCurrent(), self.scopeProvider?() == auth.scope,
                              ProcessInfo.processInfo.systemUptime < auth.expiresUptime,
                              self.page == call.page, UIApplication.shared.applicationState == .active else {
                            self.retirePipe(approved ? "stale_session" : "user_cancelled", disconnect: false); return
                        }
                        if diagnostic && (self.recordingID != nil || self.peripheral != nil) {
                            self.retirePipe("diagnostic_connection_busy", disconnect: false); return
                        }
                        if self.connected {
                            guard self.peripheral?.identifier == UUID(uuidString: id), self.connectionScope == auth.scope,
                                  self.selectedServiceUUID == service, self.selectedWriteUUID == write, self.selectedNotifyUUID == notify else {
                                self.retirePipe("connection_busy", disconnect: false); return
                            }
                        } else {
                            self.selectedServiceUUID = service; self.selectedWriteUUID = write; self.selectedNotifyUUID = notify
                        }
                        self.connect(["confirmed": true, "id": id, "role": service == Self.diagnosticServiceUUID ? 2 : 1]) { [weak self] result, error in
                            guard let self = self, self.pipeOpenID == openID, self.pipeOpenCall === call else { return }
                            guard error == nil, (result as? [String: Any])?["ok"] as? Bool == true,
                                  auth.isCurrent(), self.scopeProvider?() == auth.scope,
                                  ProcessInfo.processInfo.systemUptime < auth.expiresUptime else {
                                let code = (result as? [String: Any])?["reason"] as? String ?? "connect_failed"
                                self.retirePipe(code, disconnect: self.recordingID == nil); return
                            }
                            let lease = PipeLease(authorization: auth, page: self.page, purpose: purpose, peripheralID: id.lowercased(),
                                service: service, write: write, notify: notify, generation: self.epoch)
                            self.pipeLease = lease; self.pipeOpenCall = nil
                            self.resetOpaqueWindow("lease_opened"); self.notificationEvictions = 0
                            self.pipeRateStarted = ProcessInfo.processInfo.systemUptime; self.pipeRateCount = 0; self.pipeRateBytes = 0
                            self.finish(call, diagnostic ? self.diagnosticSnapshot(lease) : self.pipeSnapshot(lease))
                            self.watchPipe(lease)
                        }
                    }
                }
            }
        }
    }

    private func watchPipe(_ lease: PipeLease) {
        pipeWatch?.cancel()
        let timer = DispatchWorkItem { [weak self, weak lease] in
            guard let self = self, let lease = lease, self.pipeLease === lease else { return }
            let systemPrompt = self.pipePairCall != nil && UIApplication.shared.applicationState != .background
            guard self.pipeCurrent(lease, foreground: self.recordingOwnerLease !== lease && !systemPrompt) else {
                self.retirePipe("stale_session", disconnect: self.recordingID == nil); return
            }
            self.watchPipe(lease)
        }
        pipeWatch = timer; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timer)
    }

    private func exchangePipe(_ options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let lease = pipeTicket(options) else { reply(failure("stale_lease"), nil); return }
        guard lease.purpose != "diagnostic", connectionRole != 2 else { reply(failure("diagnostic_read_only"), nil); return }
        guard recordingID == nil else { reply(failure("recording_read_only_lease"), nil); return }
        guard pipeExchange == nil, pipePairCall == nil, operation == nil, currentRequest == nil,
              requests.isEmpty, let target = writeCharacteristic, target.properties.contains(.write) else {
            reply(failure("operation_busy"), nil); return
        }
        guard let id = options["operationId"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let b64 = options["valueB64"] as? String, b64.utf8.count <= 4096,
              let data = Data(base64Encoded: b64), !data.isEmpty, data.count <= 2048 else {
            reply(failure("invalid_exchange"), nil); return
        }
        let ms = (options["timeoutMs"] as? NSNumber)?.doubleValue ?? 6000
        guard ms.isFinite, ms >= 1000, ms <= 15000 else { reply(failure("invalid_timeout"), nil); return }
        var prefix: Data?
        if let text = options["responsePrefixB64"] as? String {
            guard text.utf8.count <= 88, let bytes = Data(base64Encoded: text), !bytes.isEmpty, bytes.count <= 64 else {
                reply(failure("invalid_response_prefix"), nil); return
            }
            prefix = bytes
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - pipeRateStarted >= 1 { pipeRateStarted = now; pipeRateCount = 0; pipeRateBytes = 0 }
        guard pipeRateCount < 8, pipeRateBytes + data.count <= 8192 else { reply(failure("write_rate_limited"), nil); return }
        pipeRateCount += 1; pipeRateBytes += data.count
        let call = Call(page: page, reply: reply)
        let exchange = PipeExchange(id: id, call: call, lease: lease.id, prefix: prefix,
            wait: options["waitForNotify"] as? Bool ?? false, timeout: ms / 1000)
        pipeExchange = exchange
        let writeCall = Call(page: page) { [weak self, weak exchange] result, error in
            guard let self = self, let exchange = exchange, self.pipeExchange === exchange else { return }
            guard self.pipeCurrent(lease), error == nil, let result = result as? [String: Any], result["ok"] as? Bool == true else {
                self.finishExchange(exchange, ok: false, reason: error ?? (result as? [String: Any])?["reason"] as? String ?? "write_failed"); return
            }
            exchange.written = true; exchange.writeResult = result
            if !exchange.wait || self.exchangeHasNotify(exchange) { self.finishExchange(exchange, ok: true); return }
            let timeout = DispatchWorkItem { [weak self, weak exchange] in
                guard let self = self, let exchange = exchange, self.pipeExchange === exchange else { return }
                self.finishExchange(exchange, ok: false, reason: "notification_timeout")
            }
            exchange.timer = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + exchange.timeout, execute: timeout)
        }
        let request = Request(kind: .write, call: writeCall, characteristic: target, data: data)
        request.onStart = { [weak self, weak exchange] in
            guard let self = self, let exchange = exchange, self.pipeExchange === exchange else { return }
            exchange.startSeq = self.protocolSequence; exchange.started = ProcessInfo.processInfo.systemUptime
        }
        enqueue(request)
    }

    private func exchangeHasNotify(_ exchange: PipeExchange) -> Bool {
        opaqueNotifications.contains { item in
            guard (IOSRideJSON.integer(item["seq"]) ?? 0) > exchange.startSeq,
                  (item["receivedUptime"] as? Double ?? 0) >= exchange.started else { return false }
            guard let prefix = exchange.prefix else { return true }
            guard let b64 = item["valueB64"] as? String, let bytes = Data(base64Encoded: b64) else { return false }
            return bytes.starts(with: prefix)
        }
    }
    private func finishExchange(_ exchange: PipeExchange, ok: Bool, reason: String = "") {
        guard pipeExchange === exchange else { return }
        pipeExchange = nil; exchange.timer?.cancel()
        var result = pipeLease.map { pipeSnapshot($0, after: exchange.startSeq) } ?? failure(reason)
        if !ok { result["notifications"] = [] }
        result["ok"] = ok; result["reason"] = reason; result["operationId"] = exchange.id
        result["bytes"] = exchange.writeResult["bytes"] ?? 0; result["chunks"] = exchange.writeResult["chunks"] ?? 0
        result["acknowledgement"] = exchange.wait ? "notification_window" : "gatt_only"
        result["vehicleActionConfirmed"] = false
        finish(exchange.call, result)
    }

    private func resetOpaqueWindow(_ reason: String) {
        opaqueNotifications.removeAll(keepingCapacity: false)
        windowResetSeq = protocolSequence
        windowResetReason = reason
    }

    private func receiveOpaque(_ data: Data, characteristic: CBCharacteristic) {
        guard let lease = pipeLease, pipeCurrent(lease, foreground: recordingOwnerLease !== lease), characteristic.uuid == lease.notify,
              !data.isEmpty, data.count <= 2048 else { return }
        if recordingID != nil {
            if let executor = renewalExecutor {
                protocolSequence &+= 1
                executor.consume(data, sequence: protocolSequence, uptime: ProcessInfo.processInfo.systemUptime,
                                 generation: epoch.uuidString.lowercased())
            }
            return // 认证响应不进 public ring，即使在后台也不能泄漏到网页。
        }
        protocolSequence &+= 1
        if opaqueNotifications.count >= 64 { opaqueNotifications.removeFirst(); notificationEvictions += 1 }
        opaqueNotifications.append(["valueB64": data.base64EncodedString(), "seq": protocolSequence,
            "at": Int64(Date().timeIntervalSince1970 * 1000), "receivedUptime": ProcessInfo.processInfo.systemUptime,
            "generation": lease.generation.uuidString.lowercased(), "characteristic": characteristic.uuid.uuidString.lowercased(),
            "fragment": true])
        if let exchange = pipeExchange, exchange.written, exchangeHasNotify(exchange) {
            finishExchange(exchange, ok: true)
        }
    }

    private func systemPairPipe(_ options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let lease = pipeTicket(options), let consent = pipeConsentProvider else { reply(failure("stale_lease"), nil); return }
        guard lease.purpose == "provisioning", recordingID == nil, pipePairCall == nil, pipeExchange == nil,
              operation == nil, currentRequest == nil else { reply(failure("operation_busy"), nil); return }
        let call = Call(page: page, reply: reply); pipePairCall = call
        let input = IOSBLEPipeConsentInput(scope: lease.authorization.scope, purpose: "system_pairing", peripheralID: lease.peripheralID,
            service: lease.service.uuidString, writeCharacteristic: lease.write.uuidString, notifyCharacteristic: lease.notify.uuidString)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.pipePairCall === call else { return }
            self.retirePipe("confirmation_timeout", disconnect: false)
        }
        call.timeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)
        pipeConsentCancel = consent(input) { [weak self] approved in
            DispatchQueue.main.async {
                guard let self = self, self.pipePairCall === call else { return }
                self.pipeConsentCancel = nil
                guard approved, self.pipeCurrent(lease) else {
                    self.pipePairCall = nil; self.finish(call, self.failure(approved ? "stale_lease" : "user_cancelled")); return
                }
                self.requestSystemPairing { [weak self] accessed, code in
                    guard let self = self, self.pipePairCall === call else { return }
                    self.pipePairCall = nil
                    var result = self.pipeSnapshot(lease)
                    result["ok"] = self.pipeCurrent(lease, foreground: false) && UIApplication.shared.applicationState != .background
                    result["approved"] = approved
                    result["accessObserved"] = accessed; result["manualRequired"] = !accessed
                    result["reason"] = code; result["osManaged"] = true; result["systemBondState"] = "unknown_os_managed"
                    self.finish(call, result)
                }
            }
        }
    }

    private func retirePipe(_ code: String, disconnect: Bool) {
        pipeWatch?.cancel(); pipeWatch = nil; pipeOpenID = UUID(); pipeOpenPhase = "idle"
        let opened = pipeOpenCall; pipeOpenCall = nil
        let paired = pipePairCall; pipePairCall = nil
        let authCancel = pipeProviderCancel; pipeProviderCancel = nil
        let consentCancel = pipeConsentCancel; pipeConsentCancel = nil
        authCancel?(); consentCancel?()
        if let exchange = pipeExchange { finishExchange(exchange, ok: false, reason: code) }
        pipeLease = nil; opaqueNotifications.removeAll(keepingCapacity: false)
        if recordingOwnerLease == nil {
            recipe = nil; recipeJSON = nil; recipeLeaseID = nil
        }
        let identities = Array(identityCalls.values); identityCalls.removeAll()
        if let opened = opened { finish(opened, failure(code)) }
        if let paired = paired { finish(paired, failure(code)) }
        identities.forEach { finish($0, failure(code)) }
        if disconnect && (peripheral != nil || connectCall != nil) { closeConnection(code) }
    }

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
        if recordingID != id || recordingScope != scope {
            detachRecordingAuthorization(); renewalBoundRecordingID = nil
            if id != nil {
                resetOpaqueWindow("recording_handoff")
                if let exchange = pipeExchange { finishExchange(exchange, ok: false, reason: "recording_handoff") }
            }
        }
        recordingID = id
        recordingBackground = id != nil && background
        recordingScope = scope
        if legacyObservationLease == nil, let id = id, let scope = scope, let lease = pipeLease,
           pipeCurrent(lease), lease.purpose == "telemetry", lease.authorization.scope == scope,
           let run = actualRecordingProvider?(), run.id == id, run.scope == scope {
            legacyObservationLease = lease
        }
        if recordingLease == nil, let id = id, let scope = scope, let lease = pipeLease,
           lease.purpose == "telemetry", lease.authorization.scope == scope, pipeCurrent(lease),
           recipe != nil, recipeLeaseID == lease.id, let run = actualRecordingProvider?(), run.id == id, run.scope == scope {
            recordingOwnerLease = lease; renewalBoundRecordingID = id
            // 初始 metadata 是 native issuer 的云窗口，但还不是 BLE ACK 证明。
            recordingLease = IOSSessionRenewalLease(recordingID: id, scope: scope,
                connectionGeneration: epoch.uuidString.lowercased(), authorizedAt: lease.issuedUptime,
                authorizedUntil: min(lease.authorization.expiresUptime, lease.issuedUptime + 300), nativeAuthenticated: false)
            admissionReason = "native_authorization_required"; armAuthorizationDeadline()
            _ = renewalActivate?(id)
        }
        if id == nil, renewalExecutor == nil, currentRequest?.renewalCapability != nil {
            closeConnection("recording_ended")
        } else if UIApplication.shared.applicationState != .active && !canKeepInBackground {
            closeConnection("background_interrupted")
        }
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(method: method, args: args, reply: reply) }
            return
        }
        checkScope()
        if recordingID != nil && ["ble.write", "ble.exchange", "ble.subscribe", "ble.disconnect", "ble.close"].contains(method) {
            reply(failure("recording_read_only_lease"), nil); return
        }
        let options = args.first as? [String: Any] ?? [:]
        if pipeLease?.purpose == "diagnostic" {
            guard ["ble.status", "ble.diagnostic.open", "ble.diagnostic.poll", "ble.diagnostic.close"].contains(method) else {
                reply(failure("diagnostic_read_only"), nil); return
            }
        }
        if pipeLease != nil || pipeOpenCall != nil {
            let allowed = ["ble.status", "ble.poll", "ble.read", "ble.services", "ble.write", "ble.open", "ble.exchange", "ble.close", "ble.identity", "ble.systemPairing",
                           "ble.diagnostic.open", "ble.diagnostic.poll", "ble.diagnostic.close", "ble.renew.prepare"]
            guard allowed.contains(method) else { reply(failure("lease_busy"), nil); return }
        }
        switch method {
        case "ble.renew.prepare":
            let prepared = prepareRenewalRecipe(options)
            reply(["ok": prepared, "prepared": prepared, "recipeComplete": prepared,
                   "leaseId": pipeLease?.id.uuidString.lowercased() as Any? ?? NSNull(),
                   "generation": epoch.uuidString.lowercased(), "recordingId": recordingID?.uuidString.lowercased() as Any? ?? NSNull(),
                   "reason": prepared ? "" : "renewal_recipe_rejected", "authenticated": false, "backgroundGuaranteed": false], nil)
        case "ble.diagnostic.open": openPipe(options, diagnostic: true, reply: reply)
        case "ble.diagnostic.poll":
            guard let lease = pipeTicket(options), lease.purpose == "diagnostic" else {
                reply(failure("stale_diagnostic_lease"), nil); return
            }
            reply(diagnosticSnapshot(lease, requestRSSI: true), nil)
        case "ble.diagnostic.close":
            guard let lease = pipeTicket(options), lease.purpose == "diagnostic",
                  peripheral?.identifier.uuidString.lowercased() == lease.peripheralID,
                  connectionScope == lease.authorization.scope else { reply(failure("stale_diagnostic_lease"), nil); return }
            retirePipe("diagnostic_closed", disconnect: true)
            reply(["ok": true, "state": "diagnostic_closed", "leaseId": lease.id.uuidString.lowercased(), "diagnosticOnly": true], nil)
        case "ble.open": openPipe(options, reply: reply)
        case "ble.exchange": exchangePipe(options, reply: reply)
        case "ble.close":
            guard pipeTicket(options) != nil else { reply(failure("stale_lease"), nil); return }
            // 在途 GATT 写无法单独取消，退役连接排空旧回执；录制期间不能抢占这种写。
            let mustDrain = currentRequest != nil || operation != nil
            retirePipe("user_close", disconnect: recordingID == nil || mustDrain)
            reply(["ok": true, "state": "lease_closed", "recordingPreserved": recordingID != nil && !mustDrain], nil)
        case "ble.identity":
            guard let lease = pipeTicket(options) else { reply(failure("stale_lease"), nil); return }
            guard identityCalls.count < 4 else { reply(failure("identity_busy"), nil); return }
            let call = Call(page: page, reply: reply), callID = UUID()
            identityCalls[callID] = call
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self, self.identityCalls.removeValue(forKey: callID) === call else { return }
                self.finish(call, self.failure("identity_timeout"))
            }
            call.timeout = timer; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timer)
            IOSInductiveIdentity.load(scope: lease.authorization.scope) { [weak self] result in
                guard let self = self, self.identityCalls.removeValue(forKey: callID) === call else { return }
                guard self.pipeCurrent(lease) else { self.finish(call, self.failure("stale_lease")); return }
                switch result {
                case .success(let bytes): self.finish(call, ["ok": true, "identityB64": bytes.base64EncodedString(), "bytes": 8,
                                                "source": "local_random_scoped", "leaseId": lease.id.uuidString.lowercased()])
                case .failure: self.finish(call, self.failure("identity_storage_failed"))
                }
            }
        case "ble.systemPairing": systemPairPipe(options, reply: reply)
        case "ble.status": reply(snapshot(), nil)
        case "ble.poll":
            if options["leaseId"] != nil {
                guard let lease = pipeTicket(options) else { reply(failure("stale_lease"), nil); return }
                let after = options["afterSeq"] == nil ? windowResetSeq : IOSRideJSON.integer(options["afterSeq"])
                guard let after = after, after <= protocolSequence else { reply(failure("invalid_notification_cursor"), nil); return }
                reply(pipeSnapshot(lease, after: after), nil); return
            }
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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.cancel(method: method, args: args) }; return
        }
        if ["ble.open", "ble.exchange", "ble.close", "ble.identity", "ble.systemPairing",
            "ble.diagnostic.open", "ble.diagnostic.poll", "ble.diagnostic.close"].contains(method) || pipeLease != nil {
            retirePipe("operation_cancelled", disconnect: recordingID == nil); return
        }
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
        if recordingOwnerLease == nil { retirePipe("stale_navigation", disconnect: false) }
        page &+= 1
        finishScan(reason: "stale_navigation", validPage: false)
        cancelConfirmation("stale_navigation")
        // 新页面没有旧 IO 票据。仅已明确录制的现存只读订阅可保留，不能保留任何待发 write。
        if (operation != nil || currentRequest != nil || !requests.isEmpty || connectCall != nil) && renewalCapability == nil {
            closeConnection("stale_navigation")
        } else if recordingID == nil {
            closeConnection("navigation_changed")
        }
        values.removeAll()
        lastNotifyValue = nil
    }

    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        if recordingOwnerLease == nil { retirePipe("background_interrupted", disconnect: false) }
        // 后台打断不等于扫到 deadline：ok:false，网页才能把「中途中止」和正常收尾区分开。
        finishScan(reason: "background_interrupted", ok: false)
        cancelConfirmation("foreground_required")
        let unsafeIO = (operation != nil || currentRequest != nil || !requests.isEmpty || connectCall != nil) && renewalCapability == nil
        if unsafeIO || !canKeepInBackground {
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
        if connected && (recordingID == nil || canObserveTelemetry) {
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
            "authenticationState": "not_evaluated_by_transport", "registrationVerified": false,
            "automaticUnlock": false, "readOnly": true,
            "systemBondState": "unknown_os_managed", "supportedRoles": [1, 2], "supported2": false,
            "role2ReadOnly": true, "diagnosticReady": pipeAuthorizationProvider != nil && pipeConsentProvider != nil,
            "diagnosticAvailable": pipeAuthorizationProvider != nil && pipeConsentProvider != nil && recordingID == nil
                && pipeLease == nil && pipeOpenCall == nil && peripheral == nil && operation == nil && central?.state == .poweredOn,
            "role": connectionRole, "role2": "read_only_service_diagnostic",
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
            "backgroundAuthRenewalSupported": renewalActivate != nil && renewalObserve != nil && recipe != nil && currentRecordingLease() != nil,
            "nativeCloudAuthorization": cloudAuthorizationCurrent && canAcceptTelemetry,
            "canObserveTelemetry": canObserveTelemetry, "telemetryAuthentication": canAcceptTelemetry ? "native_verified" : "unverified_observed",
            "canAcceptTelemetry": canAcceptTelemetry, "renewing": renewalExecutor != nil, "renewReason": admissionReason,
            "nativeAuthenticated": canAcceptTelemetry, "authorizationFresh": canAcceptTelemetry,
            "connectionGeneration": epoch.uuidString.lowercased(),
            "protocolManagedBy": renewalExecutor == nil ? "trusted_panel" : "native_bounded_recipe",
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
        let serviceTexts = options["services"] as? [String] ?? [Self.serviceUUID.uuidString]
        guard !serviceTexts.isEmpty, serviceTexts.count <= 8 else { reply(failure("invalid_service_filter"), nil); return }
        let services = serviceTexts.compactMap { pipeUUID($0) }
        guard services.count == serviceTexts.count else { reply(failure("invalid_service_filter"), nil); return }
        scanNamePrefix = nil
        if let name = options["namePrefix"] as? String {
            guard !name.isEmpty, name.utf8.count <= 80 else { reply(failure("invalid_name_filter"), nil); return }
            scanNamePrefix = name
        }
        scanServices = services
        scanRoles = [1, 2].filter { services.contains($0 == 1 ? Self.serviceUUID : Self.diagnosticServiceUUID) }
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
            central?.scanForPeripherals(withServices: scanServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        let wantedRole = (options["role"] as? NSNumber)?.intValue ?? 1
        guard wantedRole == 1 || (wantedRole == 2 && pipeOpenCall != nil && selectedServiceUUID == Self.diagnosticServiceUUID) else {
            reply(failure("unsupported_ble2"), nil); return
        }
        if connected && peripheral?.identifier == id && connectionScope == scope && connectionRole == wantedRole { reply(snapshot(), nil); return }
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
        guard known.restored || wantedRole == 1 || known.roles.contains(wantedRole) else {
            reply(failure("role_not_advertised"), nil); return
        }
        connectionRole = wantedRole
        if pipeOpenCall == nil && pipeLease == nil {
            selectedServiceUUID = Self.serviceUUID; selectedWriteUUID = Self.writeUUID; selectedNotifyUUID = Self.notifyUUID
        }
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
        // 旧 RPC 保留，但写入也必须持原生授权并确认过类别的 lease。厂商编帧与业务 ACK 属于私有协议层。
        guard pipeTicket(options) != nil else { reply(failure("authorized_lease_required"), nil); return }
        exchangePipe(options, reply: reply)
    }

    private func cancelConfirmation(_ code: String) {
        guard let call = confirmationCall else { return }
        confirmationCall = nil
        confirmationAlert?.dismiss(animated: false)
        confirmationAlert = nil
        finish(call, failure(code))
    }

    private func enqueue(_ request: Request) {
        let internalRenewal = request.renewalCapability != nil && request.renewalCapability == renewalCapability
            && renewalExecutor != nil && currentRecordingLease() != nil
        func rejected(_ code: String) {
            if let callback = request.onRenewalReply { request.onRenewalReply = nil; callback(false) }
            else { finish(request.call, failure(code)) }
        }
        guard connected, checkScope(), UIApplication.shared.applicationState == .active || internalRenewal else {
            rejected("not_connected"); return
        }
        guard requests.count + (currentRequest == nil ? 0 : 1) < 16 else {
            rejected("queue_full"); return
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

    // GATT 回执没有操作 ID：执行超时后必须退役连接排空，不能让迟到回执确认下一条。
    private func armRequestTimeout(_ request: Request) {
        request.timeout?.cancel()
        let timer = DispatchWorkItem { [weak self, weak request] in
            guard let self = self, let request = request, self.currentRequest === request else { return }
            self.closeConnection("operation_timeout")
        }
        request.timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timer)
    }

    private func pump() {
        guard connected, checkScope(), operation == nil, let value = peripheral else { return }
        // 排队为空时不触发前台闸门；录制的后台 notify 不能被空 pump 误断开。
        guard currentRequest != nil || !requests.isEmpty else { return }
        let candidate = currentRequest ?? requests.first
        let internalRenewal = candidate?.renewalCapability != nil && candidate?.renewalCapability == renewalCapability
            && renewalExecutor != nil && currentRecordingLease() != nil
        if let lease = pipeLease, !pipeCurrent(lease, foreground: !internalRenewal) { retirePipe("stale_session", disconnect: recordingID == nil); return }
        guard UIApplication.shared.applicationState == .active || internalRenewal else { closeConnection("foreground_required"); return }
        if currentRequest == nil, !requests.isEmpty {
            let next = requests.removeFirst()
            currentRequest = next
            let started = next.onStart; next.onStart = nil; started?()
            guard currentRequest === next, connected else { return }
            armRequestTimeout(next)
        }
        guard let request = currentRequest else { return }
        if let capability = request.renewalCapability {
            guard capability == renewalCapability, let lease = currentRecordingLease(),
                  ProcessInfo.processInfo.systemUptime < lease.authorizedUntil else { closeConnection("stale_renewal"); return }
        } else if request.call.page != page { completeRequest(failure("stale_navigation")); return }
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
        // Swift Data 是 COW，尽力擦除自己的缓冲；不宣称系统/调用栈里绝无副本。
        request.data.resetBytes(in: 0..<request.data.count); request.data.removeAll()
        clearOperation()
        if let callback = request.onRenewalReply {
            request.onRenewalReply = nil; request.call.reply = nil; callback(value["ok"] as? Bool == true)
        } else { finish(request.call, value) }
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
            case .securityRead:
                self.finishSecurityRead(false, "system_pairing_timeout"); return
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
        detachRecordingAuthorization()
        retirePipe(code, disconnect: false)
        connectCall = nil
        currentRequest = nil
        current?.timeout?.cancel()
        if let current = current {
            current.data.resetBytes(in: 0..<current.data.count); current.data.removeAll()
        }
        requests.forEach {
            $0.timeout?.cancel(); $0.data.resetBytes(in: 0..<$0.data.count); $0.data.removeAll()
        }
        requests.removeAll()
        epoch = UUID()
        clearOperation()
        peripheral = nil
        connectionScope = nil
        peripheralRSSI = nil; peripheralRSSIAt = nil; diagnosticRSSIRequestedAt = -1
        writeCharacteristic = nil
        notifyCharacteristic = nil
        let security = securityReply; securityReply = nil; securityReport = nil
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
        if let current = current {
            if let callback = current.onRenewalReply { current.onRenewalReply = nil; callback(false) }
            else { finish(current.call, result) }
        }
        for request in queued {
            if let callback = request.onRenewalReply { request.onRenewalReply = nil; callback(false) }
            else { finish(request.call, result) }
        }
        security?(false, code)
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
             "connectable": $0.connectable as Any? ?? NSNull(), "restored": $0.restored,
             "roles": $0.roles, "manufacturerID": $0.manufacturerID as Any? ?? NSNull(),
             "identityVerified": false]
        }
    }

    private func serviceList() -> [[String: Any]] {
        (peripheral?.services ?? []).filter { $0.uuid == activeServiceUUID }.map { service in
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
        if recordingID != nil {
            if let id = recordingID { observeRecordingEvent(id: id, scope: scope) }
            guard canObserveTelemetry else { protocolCodec.clearStream(); return }
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
                if recordingID != nil, let lease = pipeLease, pipeCurrent(lease, foreground: false), canAcceptTelemetry {
                    protocolSequence &+= 1
                    if opaqueNotifications.count >= 64 { opaqueNotifications.removeFirst(); notificationEvictions += 1 }
                    opaqueNotifications.append(["valueB64": bytes.base64EncodedString(), "seq": protocolSequence, "at": now,
                        "receivedUptime": uptime, "generation": epoch.uuidString.lowercased(),
                        "characteristic": characteristic.uuid.uuidString.lowercased(), "fragment": false, "safeTelemetry": true])
                }
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
                rssi: nil, connectable: nil, seenAt: ProcessInfo.processInfo.systemUptime, restored: true,
                roles: [], manufacturerID: nil)
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
        if let prefix = scanNamePrefix, advertisedName?.hasPrefix(prefix) != true { return }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        if seen.count >= 64 && seen[value.identifier] == nil { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let roles = [1, 2].filter { services.contains($0 == 1 ? Self.serviceUUID : Self.diagnosticServiceUUID) }
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturerID = manufacturer.flatMap { data -> Int? in
            guard data.count >= 2 else { return nil }
            return Int(data[data.startIndex]) | (Int(data[data.startIndex + 1]) << 8)
        }
        seen[value.identifier] = Seen(peripheral: value, name: advertisedName.map { String($0.prefix(80)) },
            rssi: rssi, connectable: connectable, seenAt: ProcessInfo.processInfo.systemUptime, restored: false,
            roles: roles.isEmpty ? scanRoles : roles, manufacturerID: manufacturerID)
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect value: CBPeripheral) {
        guard central === self.central else { return }
        if retiring[value.identifier] != nil { central.cancelPeripheralConnection(value); return }
        guard value === peripheral, operation?.kind == .connect, checkScope() else { central.cancelPeripheralConnection(value); return }
        clearOperation()
        state = "discovering"
        beginOperation(.services, seconds: 10)
        value.discoverServices([activeServiceUUID])
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
        guard owned(peripheral) else { return }
        if operation?.kind == .securityRead {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.hidUUID }) else {
                finishSecurityRead(false, "system_pairing_manual_required"); return
            }
            peripheral.discoverCharacteristics([Self.hidReportUUID], for: service)
            return
        }
        guard operation?.kind == .services else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == activeServiceUUID }) else {
            closeConnection(error == nil ? "missing_service" : "service_discovery_failed"); return
        }
        clearOperation()
        beginOperation(.characteristics, seconds: 10)
        // BLE2 只读发现属性，不猜复用 BLE1 特征、不订阅未知通道。
        peripheral.discoverCharacteristics(connectionRole == 2 ? nil : [selectedWriteUUID, selectedNotifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard owned(peripheral) else { return }
        if operation?.kind == .securityRead, service.uuid == Self.hidUUID {
            guard error == nil,
                  let report = service.characteristics?.first(where: { $0.uuid == Self.hidReportUUID && $0.properties.contains(.read) }) else {
                finishSecurityRead(false, "system_pairing_manual_required"); return
            }
            securityReport = report
            peripheral.readValue(for: report)
            return
        }
        guard service.uuid == activeServiceUUID, operation?.kind == .characteristics else { return }
        if connectionRole == 2 {
            guard error == nil else { closeConnection("characteristic_discovery_failed"); return }
            clearOperation(); state = "connected"; reason = "ble2_diagnostic_only"
            diagnosticRSSIRequestedAt = ProcessInfo.processInfo.systemUptime
            peripheral.readRSSI()
            if let call = connectCall { connectCall = nil; finish(call, snapshot()) }
            publish(); return
        }
        guard error == nil,
              let write = service.characteristics?.first(where: { $0.uuid == selectedWriteUUID }), write.properties.contains(.write),
              let notify = service.characteristics?.first(where: { $0.uuid == selectedNotifyUUID }),
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
        if operation?.kind == .securityRead, characteristic === securityReport {
            // 丢弃 HID report 原文；访问成功不是可查询的系统 bond 证据。
            finishSecurityRead(error == nil && characteristic.value != nil,
                               error == nil ? "system_access_observed" : "system_pairing_manual_required")
            return
        }
        // 不再有 GATT read 操作：这个回调只承载通知。错误时累计失败次数，
        // 连续到阈值才断开（进骑行 gap、网页能看到断开），单次错误只记进快照。
        guard characteristic === notifyCharacteristic, characteristic.isNotifying, connected else { return }
        // 单条异常（error 或拿不到值）只累计；超大帧仍交给 receive 按既有规则丢弃。
        guard error == nil, let data = characteristic.value else {
            noteNotifyFailure(); return
        }
        notifyFailures = 0
        lastNotifyError = ""
        // 认证完成不能追认同一通知里更早到达的 F3/FD；先固定到达时的 admission 与 owner。
        let arrivalAdmitted = recordingID == nil || canObserveTelemetry
        let arrivalGeneration = epoch; let arrivalRecordingEpoch = recordingEpoch; let arrivalScope = connectionScope
        if let id = recordingID, let scope = connectionScope { observeRecordingEvent(id: id, scope: scope) }
        receiveOpaque(Data(data), characteristic: characteristic)
        let stillAdmitted = recordingID == nil || canObserveTelemetry
        guard arrivalAdmitted, stillAdmitted, arrivalGeneration == epoch,
              arrivalRecordingEpoch == recordingEpoch, arrivalScope == connectionScope else {
            protocolCodec.clearStream(); return
        }
        // 只读采集保留旧 SharedProtocol F3/FD 路径，不把认证/未知帧归档。
        if activeServiceUUID == Self.serviceUUID && selectedNotifyUUID == Self.notifyUUID {
            receive(Data(data), characteristic: characteristic)
        }
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

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard owned(peripheral), error == nil, RSSI.intValue != 127 else { return }
        peripheralRSSI = RSSI.intValue
        peripheralRSSIAt = Int64(Date().timeIntervalSince1970 * 1000)
        publish()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral else { return }
        if invalidatedServices.contains(where: { $0.uuid == activeServiceUUID }) {
            // 不自动重连/认证/重放旧周期写入。
            closeConnection("services_invalidated")
        }
    }
}

extension Data {
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
