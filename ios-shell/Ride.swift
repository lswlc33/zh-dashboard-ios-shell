import Foundation
import UIKit
import CoreLocation
import CryptoKit
import CoreFoundation
import Darwin
import ZeehoSystemShared

// 长期归属是稳定账号 + VIN；generation 只撤销在途采样，不让重登/重启隐藏旧记录。
// 只接核心桥的原生会话 provider，从不接收网页 token 或用网页布尔值证明车辆所有权。
struct IOSRideScope: Equatable {
    let accountID: String
    let vin: String
    let generation: String

    var valid: Bool {
        [accountID, vin, generation].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }

    var ownerHash: String {
        var data = Data()
        for value in [accountID, vin] {
            let part = Data(value.utf8)
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(part)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum IOSRideJSON {
    static func object(_ text: String) -> [String: Any]? {
        guard text.utf8.count <= 8 * 1024 * 1024, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func integer(_ value: Any?, minimum: Int64 = 0, maximum: Int64 = Int64.max) -> Int64? {
        guard let n = number(value), n.rounded(.towardZero) == n, n >= Double(minimum), n < Double(Int64.max) else { return nil }
        let result = Int64(n)
        return result <= maximum ? result : nil
    }

    static func telemetry(_ source: [String: Any]) -> [String: Any] {
        let bounds: [String: ClosedRange<Double>] = [
            "speedKph": 0...400, "socPercent": 0...100, "voltageV": 0...200,
            "tempC": -50...150, "headLockState": 0...2,
            "socRaw": 0...4294967295, "powerRaw": 0...100000,
            "powerDeltaRaw": -1500...98500, "odometerRaw": 0...4294967295,
            "modeRaw": 0...4294967295, "lightRaw": 0...4294967295
        ]
        var result: [String: Any] = [:]
        for (key, range) in bounds {
            if let value = number(source[key]), range.contains(value) { result[key] = value }
        }
        return result
    }

    static func fields(_ source: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        let statuses: Set<String> = ["captured_small_frame", "static_schema_unverified", "unsupported_command"]
        let reasons: Set<String> = ["wrong_wire", "out_of_range", "half_step_unverified", "unit_unverified",
                                   "field_unverified", "static_schema_unverified", "proto3_default", "non_finite", "duplicate_field"]
        if let status = source["status"] as? String, statuses.contains(status) { result["status"] = status }
        if let verified = source["unitsVerified"] as? Bool { result["unitsVerified"] = verified }
        if let command = integer(source["command"], maximum: 255) { result["command"] = command }
        if let length = integer(source["payloadLength"], maximum: 240) { result["payloadLength"] = length }
        if let unsupported = source["unsupported"] as? [String: Any] {
            result["unsupported"] = unsupported.filter { _, value in
                if let reason = value as? String { return reasons.contains(reason) }
                return false
            }
        }
        for index in 1...64 {
            guard let raw = source["field\(index)"] as? [String: Any] else { continue }
            var field: [String: Any] = [:]
            if let wire = integer(raw["wire"], maximum: 5) { field["wire"] = wire }
            if let numeric = number(raw["numeric"]) { field["numeric"] = numeric }
            if let present = raw["present"] as? Bool { field["present"] = present }
            if let reason = raw["reason"] as? String, reasons.contains(reason) { field["reason"] = reason }
            // 未知 bytes 可能含身份/认证物料，不复制 bytes/digest/summary。
            if !field.isEmpty { result["field\(index)"] = field }
        }
        return result
    }
}

private enum IOSRideDisk {
    static let maxSamples = 20000
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxOwnerBytes = 64 * 1024 * 1024
    static let maxTotalBytes = 256 * 1024 * 1024
    static let maxFiles = 100
    static let maxOwners = 64
    static let parseBudget = 16 * 1024 * 1024

    struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    private static func directory(owner: String, create: Bool) throws -> URL {
        guard owner.count == 64, owner.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure("invalid_scope") }
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure("storage_unavailable")
        }
        let root = support.appendingPathComponent("zeeho-rides-v1", isDirectory: true)
        let target = root.appendingPathComponent(owner, isDirectory: true)
        if create {
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: root.path) { try manager.createDirectory(at: root, withIntermediateDirectories: false) }
            let owners = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            if !manager.fileExists(atPath: target.path) {
                guard owners.count < maxOwners else { throw Failure("storage_limit_reached") }
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
            }
            try manager.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            var protected = target
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try protected.setResourceValues(resources)
        }
        for url in [root, target] where manager.fileExists(atPath: url.path) {
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        }
        return target
    }

    static func url(owner: String, id: UUID, create: Bool = false) throws -> URL {
        try directory(owner: owner, create: create).appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private static func files(owner: String) throws -> [URL] {
        let target = try directory(owner: owner, create: false)
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: target,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        guard entries.count <= maxFiles + 1 else { throw Failure("storage_limit_reached") }
        return try entries.filter { item in
            guard item.pathExtension == "json", let uuid = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  item.lastPathComponent == uuid.uuidString.lowercased() + ".json" else { return false }
            let attributes = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else { throw Failure("unsafe_storage_path") }
            return true
        }
    }

    static func save(_ record: [String: Any], owner: String, id: UUID) throws -> Int {
        guard JSONSerialization.isValidJSONObject(record) else { throw Failure("invalid_record") }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard data.count <= maxFileBytes else { throw Failure("record_limit_reached") }
        let target = try url(owner: owner, id: id, create: true)
        let siblings = try files(owner: owner)
        guard siblings.contains(target) || siblings.count < maxFiles else { throw Failure("storage_limit_reached") }
        var bytes = 0
        for item in siblings where item != target {
            bytes += try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        guard bytes + data.count <= maxOwnerBytes else { throw Failure("storage_limit_reached") }
        let root = target.deletingLastPathComponent().deletingLastPathComponent()
        var total = 0
        let scopes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard scopes.count <= maxOwners else { throw Failure("storage_limit_reached") }
        for scope in scopes {
            let attributes = try scope.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
            let entries = try FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            guard entries.count <= maxFiles + 1 else { throw Failure("storage_limit_reached") }
            for item in entries where item != target {
                total += try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard total + data.count <= maxTotalBytes else { throw Failure("storage_limit_reached") }
            }
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        }
        // 非凭据文件不用 Keychain；原子替换 + 首次解锁后的文件保护允许获准的锁屏录制落盘。
        // .atomic 不代表最后 fsync 必然成功，末次 synchronize/close 都成功后才报告 completed。
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        let handle = try FileHandle(forUpdating: target)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw Failure("save_sync_failed") }
        let descriptor = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure("save_sync_failed") }
        let synced = fsync(descriptor)
        let closed = Darwin.close(descriptor)
        guard synced == 0, closed == 0 else { throw Failure("save_sync_failed") }
        return data.count
    }

    static func read(owner: String, id: UUID) throws -> [String: Any] {
        let target = try url(owner: owner, id: id)
        let attributes = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maxFileBytes else { throw Failure("invalid_record") }
        let data = try Data(contentsOf: target)
        guard data.count <= maxFileBytes,
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              IOSRideJSON.integer(record["version"]) == 1, record["owner"] as? String == owner,
              record["id"] as? String == id.uuidString.lowercased(),
              let gps = record["rawGPS"] as? [[String: Any]], let telemetry = record["telemetry"] as? [[String: Any]],
              let gaps = record["gaps"] as? [[String: Any]], gps.count + telemetry.count <= maxSamples, gaps.count <= 1024,
              IOSRideJSON.integer(record["samples"]) == Int64(gps.count + telemetry.count),
              IOSRideJSON.integer(record["startedAt"], minimum: 1) != nil else { throw Failure("invalid_record") }
        for sample in gps {
            guard sample["provider"] as? String == "corelocation",
                  IOSRideJSON.integer(sample["at"], minimum: 1) != nil,
                  IOSRideJSON.integer(sample["seq"], minimum: 1) != nil,
                  IOSRideJSON.integer(sample["elapsedMs"]) != nil else { throw Failure("invalid_record") }
            if let lat = IOSRideJSON.number(sample["lat"]), let lng = IOSRideJSON.number(sample["lng"]) {
                guard (-90...90).contains(lat), (-180...180).contains(lng) else { throw Failure("invalid_record") }
            }
            if let speed = IOSRideJSON.number(sample["speedKph"]), !(0...400).contains(speed) { throw Failure("invalid_record") }
        }
        for sample in telemetry {
            guard let values = sample["values"] as? [String: Any], !values.isEmpty,
                  IOSRideJSON.telemetry(values).count == values.count,
                  let times = sample["times"] as? [String: Any], times.count == values.count,
                  times.values.allSatisfy({ IOSRideJSON.integer($0, minimum: 1) != nil }),
                  ["ble_period", "ble_dash"].contains(sample["source"] as? String ?? ""),
                  IOSRideJSON.integer(sample["at"], minimum: 1) != nil else { throw Failure("invalid_record") }
        }
        return record
    }

    static func summary(_ record: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["id", "startedAt", "endedAt", "state", "reason", "durationMs", "elapsedMs", "samples", "report"] {
            result[key] = record[key] ?? NSNull()
        }
        if record["endedAt"] is NSNull || record["endedAt"] == nil {
            result["state"] = "interrupted"
            result["reason"] = "unfinished_record"
            result["incomplete"] = true
        } else { result["incomplete"] = false }
        return result
    }

    static func list(owner: String) throws -> [String: Any] {
        let entries = try files(owner: owner).sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
        var remaining = parseBudget
        var summaries: [[String: Any]] = []
        var error = ""
        var used = 0
        for item in entries {
            let size = try item.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            used += size
            guard summaries.count < 30 else { continue }
            guard size <= remaining else { if error.isEmpty { error = "records_parse_limit" }; continue }
            remaining -= size
            guard let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent) else { continue }
            do { summaries.append(summary(try read(owner: owner, id: id))) }
            // catch 的隐式变量名是 error，会遮蔽外层同名的 String 变量；显式命名避免歧义。
            catch let failure { if error.isEmpty { error = (failure as? Failure)?.code ?? "records_read_failed" } }
        }
        return ["ok": error.isEmpty, "records": summaries, "recordsReady": true, "recordsError": error,
                "storage": ["files": entries.count, "bytes": used, "maxFiles": maxFiles,
                            "maxOwnerBytes": maxOwnerBytes, "maxFileBytes": maxFileBytes, "maxSamples": maxSamples],
                "partial": !error.isEmpty]
    }

    static func delete(owner: String, id: UUID) throws {
        let target = try url(owner: owner, id: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return } // 幂等，不写另一份墓碑/假记录。
        let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure("unsafe_storage_path") }
        try FileManager.default.removeItem(at: target)
    }
}

final class IOSRideService: NSObject, IOSBridgeService, IOSBridgeCancellableService {
    let methods = ["ride.begin", "ride.poll", "ride.end", "ride.action", "ride.list", "ride.detail", "ride.delete", "ride.share"]
    private static weak var leaseOwner: IOSRideService?
    private let gps = IOSLocationService.shared
    private let bluetooth = IOSBluetoothService.shared
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.rides.io", qos: .utility)
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private weak var optionalSystemSurfacePublisher: IOSSystemSurfacePublisher?
    private var page: UInt64 = 0
    private var active: Run?
    private var finals: [UUID: Run] = [:]
    private var gpsObserver: UUID?
    private var bleObserver: UUID?
    private var foregroundObserver: NSObjectProtocol?
    private var clock: Timer?
    private var pendingIO = 0
    private var confirmation: Consent?
    private weak var confirmationAlert: UIAlertController?
    private var sharing: Consent?
    private weak var activity: UIActivityViewController?

    private final class Consent {
        let page: UInt64
        let scope: IOSRideScope
        let method: String
        let id: UUID?
        var reply: ((Any?, String?) -> Void)?
        var timeout: DispatchWorkItem?
        init(page: UInt64, scope: IOSRideScope, method: String, id: UUID?, reply: @escaping (Any?, String?) -> Void) {
            self.page = page; self.scope = scope; self.method = method; self.id = id; self.reply = reply
        }
    }

    private final class Run {
        let id = UUID()
        let scope: IOSRideScope
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var gpsWanted: Bool
        var backgroundWanted: Bool
        var state = "waiting"
        var recordState = "waiting"
        var reason = "waiting_fix"
        var rawGPS: [[String: Any]] = []
        var telemetry: [[String: Any]] = []
        var gaps: [[String: Any]] = []
        var samples = 0
        var gpsSamples = 0
        var bleSamples = 0
        var lastGPSSequence: Int64 = 0
        var lastBLESequence: Int64 = 0
        var lastGPSUptime: TimeInterval?
        var lastBLEUptime: TimeInterval?
        var gapReasons: [String: String] = [:]
        var activeSince: TimeInterval?
        var activeDuration: TimeInterval = 0
        var endedAt: Int64?
        var endedUptime: TimeInterval?
        var ending = false
        var completed = false
        var targetState = "completed"
        var targetReason = "user_stop"
        var estimatedBytes = 2048
        var checkpointing = false
        var checkpointDirty = false
        var lastCheckpoint: TimeInterval = 0
        var saveInFlight = false
        var userPaused = false
        var saveFailed = false
        var savedBytes = 0
        var saveWaiters: [(UInt64, IOSRideScope?, (Any?, String?) -> Void)] = []
        var lastRoute: IOSGPSFix?
        var distanceM = 0.0
        var distanceSegments = 0
        var maxGPSSpeed: Double?
        var systemUpdatedAt: Int64 = 0
        var systemElapsedSeconds: Double? = 0
        var systemBLEConnected = false

        init(scope: IOSRideScope, gps: Bool, background: Bool) {
            self.scope = scope; gpsWanted = gps; backgroundWanted = background
            systemUpdatedAt = startedAt
        }

        var elapsedMs: Int64 {
            Int64(max(0, (endedUptime ?? ProcessInfo.processInfo.systemUptime) - startedUptime) * 1000)
        }

        var durationMs: Int64 {
            let current = activeSince.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
            return Int64(max(0, activeDuration + current) * 1000)
        }
    }

    override init() {
        super.init()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, let run = self.active, !run.ending, !run.userPaused else { return }
            self.checkScope()
            guard self.active === run else { return }
            if run.gpsWanted { _ = self.gps.resumeRecording(id: run.id, requestPermission: false) }
            self.updateBLEContext(run)
            self.tick()
        }
    }

    deinit {
        if let token = foregroundObserver { NotificationCenter.default.removeObserver(token) }
        clock?.invalidate()
        if let token = gpsObserver { gps.removeObserver(token) }
        if let token = bleObserver { bluetooth.removeObserver(token) }
        if let run = active { gps.endRecording(id: run.id); bluetooth.setRecordingContext(id: nil, background: false, scope: nil) }
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

    func configureSystemSurfacePublisher(_ publisher: IOSSystemSurfacePublisher?) {
        precondition(Thread.isMainThread)
        optionalSystemSurfacePublisher = publisher
        if let run = active, owns(run) { publishSystemSurface(run) }
    }

    func scopeChanged() {
        precondition(Thread.isMainThread)
        cancelConsent("stale_session")
        cancelShare("stale_session")
        checkScope()
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        page &+= 1
        cancelConsent("stale_navigation")
        cancelShare("stale_navigation")
        // 没有 WK observer；已明确录制与页面生命周期分离，仍由 scope/系统权限守护。
        checkScope()
    }

    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        cancelConsent("foreground_required")
        cancelShare("foreground_required")
        guard let run = active, !run.ending else { return }
        if run.gpsWanted && !gps.backgroundAllowed {
            markGap(run, source: "gps", reason: gps.backgroundReason)
            pauseDuration(run)
            run.state = "interrupted"
            run.recordState = "interrupted"
            run.reason = gps.backgroundReason
        }
        updateBLEContext(run)
        checkpoint(run, force: true)
    }

    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        if confirmation?.method == method { cancelConsent("operation_cancelled") }
        if method == "ride.share" { cancelShare("operation_cancelled") }
        // 已受理 stop/save 要继续安全落盘；取消的只是旧页面回执，不能再把 ending 复活为 recording。
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(method: method, args: args, reply: reply) }
            return
        }
        checkScope()
        let options = args.first as? [String: Any] ?? [:]
        guard let scope = scopeProvider?(), scope.valid else { reply(failure("authorized_vehicle_required"), nil); return }
        if let vin = options["vin"] as? String, vin != scope.vin { reply(failure("stale_session"), nil); return }
        switch method {
        case "ride.begin": begin(scope: scope, options: options, reply: reply)
        case "ride.poll":
            if let id = requestedID(options) {
                guard let run = active?.id == id ? active : finals[id], run.scope.ownerHash == scope.ownerHash else {
                    reply(failure("stale_ticket"), nil); return
                }
                reply(snapshot(run), nil)
            } else if let run = active, run.scope == scope { reply(snapshot(run), nil) }
            else { reply(["ok": true, "state": "idle", "samples": 0, "gps": gps.snapshot()], nil) }
        case "ride.end": end(scope: scope, options: options, reply: reply)
        case "ride.action": action(scope: scope, options: options, reply: reply)
        case "ride.list": list(scope: scope, reply: reply)
        case "ride.detail": detail(scope: scope, options: options, reply: reply)
        case "ride.delete": delete(scope: scope, options: options, reply: reply)
        case "ride.share": share(scope: scope, options: options, reply: reply)
        default: reply(nil, "unsupported_method")
        }
    }

    private func begin(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
        if let run = active, !run.completed {
            reply(run.scope == scope ? snapshot(run) : failure("recording_busy"), nil); return
        }
        if let owner = Self.leaseOwner, owner !== self { reply(failure("recording_busy"), nil); return }
        guard pendingSaveCapacity else { reply(failure("pending_save_limit"), nil); return }
        let wantedGPS = options["gps"] as? Bool ?? true
        guard wantedGPS || bluetooth.connected else { reply(failure("no_data_source"), nil); return }
        let background = options["backgroundRecording"] as? Bool == true
        confirm(method: "ride.begin", id: nil, scope: scope, title: IOSStrings.rideRecordTitle,
                message: IOSStrings.rideRecordMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            guard self.active == nil || self.active?.completed == true,
                  Self.leaseOwner == nil || Self.leaseOwner === self else {
                self.finish(consent, self.failure("recording_busy")); return
            }
            guard self.pendingSaveCapacity else { self.finish(consent, self.failure("pending_save_limit")); return }
            let run = Run(scope: scope, gps: wantedGPS, background: background)
            run.systemBLEConnected = self.bluetooth.connected
            self.active = run
            Self.leaseOwner = self
            self.installObservers()
            self.startClock()
            let status = wantedGPS ? self.gps.beginRecording(id: run.id, background: background, requestPermission: true) : self.gps.snapshot()
            if wantedGPS && background {
                // 原生按钮确认了背景选项；已有 WhenInUse 时才请求 Always，否则等用户再次点背景授权。
                _ = self.gps.setBackgroundRecording(id: run.id, enabled: true, requestPermission: true)
            }
            self.updateBLEContext(run)
            if status["state"] as? String == "permission_required" {
                run.state = "permission_required"; run.recordState = "permission_required"
                run.reason = status["reason"] as? String ?? "permission_required"
            }
            var response = self.snapshot(run)
            response["accepted"] = true
            self.publishSystemSurface(run, eventAt: run.startedAt, elapsedSeconds: 0)
            self.finish(consent, response)
        }
    }

    private func installObservers() {
        if gpsObserver == nil {
            gpsObserver = gps.addObserver(onFix: { [weak self] fix in self?.recordGPS(fix) },
                onState: { [weak self] value in self?.gpsState(value) })
        }
        if bleObserver == nil {
            bleObserver = bluetooth.addObserver(onSample: { [weak self] sample in self?.recordBLE(sample) },
                onState: { [weak self] value in self?.bleState(value) })
        }
    }

    private func removeObservers() {
        if let id = gpsObserver { gps.removeObserver(id); gpsObserver = nil }
        if let id = bleObserver { bluetooth.removeObserver(id); bleObserver = nil }
    }

    private func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkScope() {
        guard let run = active, !run.ending else { return }
        guard scopeProvider?() == run.scope else {
            stop(run, state: "interrupted", reason: "stale_session", reply: nil); return
        }
    }

    private func owns(_ run: Run) -> Bool {
        active === run && !run.ending && !run.completed && scopeProvider?() == run.scope
    }

    private func recordGPS(_ fix: IOSGPSFix) {
        guard let run = active, owns(run), !run.userPaused, run.gpsWanted, fix.fresh,
              fix.sequence > run.lastGPSSequence,
              fix.at >= run.startedAt,
              UIApplication.shared.applicationState == .active || gps.backgroundAllowed else { return }
        guard admit(run, bytes: 480) else { return }
        run.lastGPSSequence = fix.sequence
        var point = fix.json(includeCoordinates: true)
        point["elapsedMs"] = Int64(max(0, fix.receivedUptime - run.startedUptime - fix.ageAtReceipt) * 1000)
        run.rawGPS.append(point)
        run.gpsSamples += 1
        run.lastGPSUptime = fix.receivedUptime - fix.ageAtReceipt
        run.gapReasons.removeValue(forKey: "gps")
        if let speed = fix.speedKph { run.maxGPSSpeed = max(run.maxGPSSpeed ?? speed, speed) }
        if let previous = run.lastRoute, let lat = fix.latitude, let lng = fix.longitude,
           let previousLat = previous.latitude, let previousLng = previous.longitude,
           let accuracy = fix.accuracy, let previousAccuracy = previous.accuracy,
           accuracy <= 50, previousAccuracy <= 50 {
            let seconds = Double(fix.at - previous.at) / 1000
            if seconds > 0 && seconds <= 10 {
                let distance = CLLocation(latitude: lat, longitude: lng).distance(from: CLLocation(latitude: previousLat, longitude: previousLng))
                if distance.isFinite && distance >= 0 && distance / seconds * 3.6 <= 400 {
                    run.distanceM += distance; run.distanceSegments += 1
                }
            }
        }
        run.lastRoute = fix
        sampleAccepted(run)
    }

    private func recordBLE(_ sample: IOSBLETelemetrySample) {
        guard let run = active, owns(run), !run.userPaused, sample.scope == run.scope, bluetooth.connected,
              sample.sequence > run.lastBLESequence, sample.at >= run.startedAt,
              sample.receivedUptime >= run.startedUptime,
              UIApplication.shared.applicationState == .active || run.backgroundWanted else { return }
        let clean = IOSRideJSON.telemetry(sample.values)
        guard !clean.isEmpty, admit(run, bytes: 1000) else { return }
        run.lastBLESequence = sample.sequence
        let times = Dictionary(uniqueKeysWithValues: clean.keys.map { ($0, sample.at) })
        run.telemetry.append(["at": sample.at, "seq": sample.sequence,
            "elapsedMs": Int64(max(0, sample.receivedUptime - run.startedUptime) * 1000),
            "source": sample.source, "connectionGeneration": sample.connectionGeneration.uuidString.lowercased(),
            "values": clean, "times": times, "fields": IOSRideJSON.fields(sample.fields)])
        run.bleSamples += 1
        run.lastBLEUptime = sample.receivedUptime
        run.gapReasons.removeValue(forKey: "ble")
        sampleAccepted(run)
    }

    private func admit(_ run: Run, bytes: Int) -> Bool {
        guard run.samples < IOSRideDisk.maxSamples, run.estimatedBytes + bytes + 4096 <= IOSRideDisk.maxFileBytes else {
            stop(run, state: "interrupted", reason: "record_limit_reached", reply: nil)
            return false
        }
        run.samples += 1
        run.estimatedBytes += bytes
        return true
    }

    private func sampleAccepted(_ run: Run) {
        let now = ProcessInfo.processInfo.systemUptime
        if run.activeSince == nil { run.activeSince = now }
        run.state = "recording"
        run.recordState = run.saveFailed ? "save_failed" : "recording"
        if !run.saveFailed { run.reason = "" }
        run.checkpointDirty = true
        checkpoint(run, force: run.samples == 1)
        let timestamps = [IOSRideJSON.integer(run.rawGPS.last?["at"]), IOSRideJSON.integer(run.telemetry.last?["at"])]
        let elapsed = [IOSRideJSON.number(run.rawGPS.last?["elapsedMs"]), IOSRideJSON.number(run.telemetry.last?["elapsedMs"])]
            .compactMap { $0 }.max().map { $0 / 1000 }
        publishSystemSurface(run, eventAt: timestamps.compactMap { $0 }.max(), elapsedSeconds: elapsed)
    }

    private func gpsState(_ value: [String: Any]) {
        guard let run = active, owns(run), run.gpsWanted else { return }
        let state = value["state"] as? String ?? "unknown"
        if ["permission_required", "interrupted", "unavailable", "error", "stale"].contains(state) {
            markGap(run, source: "gps", reason: value["reason"] as? String ?? "gps_unavailable")
            run.lastRoute = nil
            if !bleFresh(run) {
                pauseDuration(run)
                run.state = state
                run.recordState = state
                run.reason = value["reason"] as? String ?? "gps_unavailable"
            }
        }
    }

    private func bleState(_ value: [String: Any]) {
        guard let run = active, owns(run) else { return }
        if value["connected"] as? Bool != true, run.bleSamples > 0 {
            markGap(run, source: "ble", reason: value["reason"] as? String ?? "connection_lost")
        }
        // GPS-only 与 BLE 分离；蓝牙断开不会伪造电池，也不会停止获准的 GPS 录制。
        let connected = value["connected"] as? Bool == true
        let disconnected = run.systemBLEConnected && !connected
        run.systemBLEConnected = connected
        // GPS-only 的 false 状态不是断连；真实 BLE 断连也不能结束独立获准的 GPS 活动。
        if disconnected && !run.gpsWanted {
            optionalSystemSurfacePublisher?.systemSurfacesDisconnected(scope: run.scope)
        }
        if disconnected { publishSystemSurface(run) }
    }

    private func tick() {
        checkScope()
        guard let run = active, owns(run), !run.userPaused else { return }
        if run.gpsWanted, !gpsFresh(run), run.gpsSamples > 0 {
            markGap(run, source: "gps", reason: "stale_fix")
            run.lastRoute = nil
        }
        if !bleFresh(run), run.bleSamples > 0 { markGap(run, source: "ble", reason: "sample_gap") }
        if !gpsFresh(run) && !bleFresh(run) && run.samples > 0 {
            pauseDuration(run)
            run.state = "interrupted"
            run.recordState = run.saveFailed ? "save_failed" : "gap"
            if !run.saveFailed { run.reason = "sample_gap" }
        }
        checkpoint(run, force: false)
        // tick 只撤销过期速度；最后更新时间和时长仍保留真实接受事件，不能用轮询伪造新观测。
        publishSystemSurface(run)
    }

    private func gpsFresh(_ run: Run) -> Bool {
        guard run.gpsWanted, let last = run.lastGPSUptime else { return false }
        let age = ProcessInfo.processInfo.systemUptime - last
        return age >= 0 && age < 10 && gps.snapshot()["updating"] as? Bool == true
    }

    private func bleFresh(_ run: Run) -> Bool {
        guard bluetooth.connected, let last = run.lastBLEUptime else { return false }
        let age = ProcessInfo.processInfo.systemUptime - last
        return age >= 0 && age < 10
    }

    private func markGap(_ run: Run, source: String, reason: String) {
        guard run.samples > 0, run.gaps.count < 1024, run.gapReasons[source] != reason else { return }
        run.gapReasons[source] = reason
        run.gaps.append(["at": Int64(Date().timeIntervalSince1970 * 1000), "elapsedMs": run.elapsedMs,
                         "source": source, "reason": safeReason(reason)])
        run.estimatedBytes += 180
        run.checkpointDirty = true
        publishSystemSurface(run, eventAt: IOSRideJSON.integer(run.gaps.last?["at"]), elapsedSeconds: Double(run.elapsedMs) / 1000)
    }

    private func safeReason(_ value: String) -> String {
        let codes: Set<String> = ["waiting_fix", "permission_required", "permission_denied", "permission_restricted", "system_paused",
            "location_services_disabled", "stale_fix", "sample_gap", "connection_lost", "disconnected", "user_disconnect",
            "background_recording_disabled", "background_mode_missing", "always_permission_required", "background_interrupted",
            "stale_session", "record_limit_reached", "user_pause", "gps_disabled", "navigation_changed",
            "subscription_failed", "notification_failed", "services_invalidated", "powered_off", "not_authorised",
            "bluetooth_resetting", "write_timeout", "read_timeout", "discovery_timeout", "location_failed", "no_fix"]
        return codes.contains(value) ? value : "source_unavailable"
    }

    private func pauseDuration(_ run: Run) {
        if let since = run.activeSince { run.activeDuration += max(0, ProcessInfo.processInfo.systemUptime - since) }
        run.activeSince = nil
    }

    private func updateBLEContext(_ run: Run) {
        if run.userPaused { bluetooth.setRecordingContext(id: nil, background: false, scope: nil) }
        else { bluetooth.setRecordingContext(id: run.id, background: run.backgroundWanted, scope: run.scope) }
    }

    private func publishSystemSurface(_ run: Run, eventAt: Int64? = nil, elapsedSeconds: Double? = nil) {
        guard let publisher = optionalSystemSurfacePublisher else { return }
        if let eventAt = eventAt, eventAt >= run.systemUpdatedAt {
            run.systemUpdatedAt = eventAt
            if let elapsedSeconds = elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0 {
                run.systemElapsedSeconds = elapsedSeconds
            }
        }
        let state: SystemRideState = run.ending ? .ended : (run.userPaused ? .paused :
            (run.state == "recording" ? .recording : (run.samples > 0 ? .interrupted : .waiting)))
        let gpsAt = IOSRideJSON.integer(run.rawGPS.last?["at"])
        let bleAt = IOSRideJSON.integer(run.telemetry.last?["at"])
        let speed = state == .recording && gpsFresh(run) ? IOSRideJSON.number(run.rawGPS.last?["speedKph"]) : nil
        let age = gpsAt.map { max(0, Double(run.systemUpdatedAt - $0) / 1000) }
        let value = SystemRideSnapshot(state: state, startedAt: run.startedAt, updatedAt: run.systemUpdatedAt,
            speedKph: speed, speedUpdatedAt: gpsAt, lastLocationAt: gpsAt,
            lastSignalAt: [gpsAt, bleAt].compactMap { $0 }.max(), locationAgeSeconds: age,
            elapsedSeconds: run.systemElapsedSeconds, gapCount: run.gaps.count)
        // 不复制 rawGPS/串号/owner 身份，也不由 GPS 推导充电；scope 是开始录制时原生捕获的那一份。
        publisher.publishRide(value, scope: run.scope)
    }

    private func snapshot(_ run: Run) -> [String: Any] {
        let gpsValue = active === run && !run.ending ? gps.snapshot() : ["ok": true, "state": "disabled", "speedKph": NSNull(), "lat": NSNull(), "lng": NSNull()]
        let ble = active === run && !run.ending ? bluetooth.snapshot() : ["connected": false, "telemetry": [:], "telemetryTimes": [:]]
        return ["ok": true, "id": run.id.uuidString.lowercased(), "ticket": run.id.uuidString.lowercased(),
            "recordingId": run.id.uuidString.lowercased(), "state": run.state, "recordState": run.recordState,
            "reason": run.reason, "startedAt": run.startedAt, "endedAt": run.endedAt as Any? ?? NSNull(),
            "samples": run.samples, "recordedSamples": run.samples, "elapsedMs": run.elapsedMs, "durationMs": run.durationMs,
            "gps": gpsValue, "gpsEnabled": run.gpsWanted, "connected": ble["connected"] ?? false,
            "telemetry": ble["telemetry"] ?? [:], "telemetryTimes": ble["telemetryTimes"] ?? [:], "fields": ble["fields"] ?? [:],
            "authenticated": false, "automaticUnlock": false, "backgroundRequested": run.backgroundWanted,
            "backgroundEnabled": active === run && !run.ending && gps.backgroundAllowed, "backgroundGuaranteed": false,
            "saved": run.completed && !run.saveFailed, "retryAvailable": run.saveFailed, "savedBytes": run.savedBytes,
            "report": report(run)]
    }

    private func report(_ run: Run) -> [String: Any] {
        ["gpsSamples": run.gpsSamples, "bleSamples": run.bleSamples, "gaps": run.gaps.count,
         "distanceM": run.distanceSegments > 0 ? run.distanceM as Any : NSNull(), "distanceSource": "gps_observed_segments",
         "maxGPSSpeedKph": run.maxGPSSpeed as Any? ?? NSNull(), "batterySource": "visible_ble_only",
         "charging": NSNull(), "chargeState": "unknown", "energyKWh": NSNull(),
         "maxSamples": IOSRideDisk.maxSamples, "maxFileBytes": IOSRideDisk.maxFileBytes]
    }

    private func record(_ run: Run, final: Bool) -> [String: Any] {
        ["version": 1, "id": run.id.uuidString.lowercased(), "owner": run.scope.ownerHash,
         "generation": run.scope.generation, "startedAt": run.startedAt,
         "endedAt": final ? run.endedAt as Any? ?? NSNull() : NSNull(),
         "state": final ? run.targetState : run.state, "reason": final ? run.targetReason : run.reason,
         "samples": run.samples, "elapsedMs": run.elapsedMs, "durationMs": run.durationMs,
         "rawGPS": run.rawGPS, "telemetry": run.telemetry, "gaps": run.gaps, "report": report(run)]
    }

    private func checkpoint(_ run: Run, force: Bool) {
        guard active === run, !run.ending, run.samples > 0, run.checkpointDirty, !run.checkpointing, !run.saveFailed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - run.lastCheckpoint >= 15 else { return }
        run.checkpointing = true
        run.checkpointDirty = false
        run.lastCheckpoint = now
        let value = record(run, final: false)
        worker.async { [weak self, weak run] in
            guard let run = run else { return }
            let result: Result<Int, Error>
            do { result = .success(try IOSRideDisk.save(value, owner: run.scope.ownerHash, id: run.id)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                run.checkpointing = false
                switch result {
                case .success(let bytes): run.savedBytes = bytes
                case .failure(let error):
                    run.saveFailed = true
                    run.recordState = "save_failed"
                    run.reason = (error as? IOSRideDisk.Failure)?.code ?? "save_write_failed"
                    if !run.ending { self.markGap(run, source: "storage", reason: "source_unavailable") }
                }
            }
        }
    }

    private func end(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let id = requestedID(options) else { reply(failure("invalid_recording_id"), nil); return }
        if let run = active, run.id == id, run.scope == scope {
            stop(run, state: "completed", reason: "user_stop", reply: reply)
        } else if let run = finals[id], run.scope.ownerHash == scope.ownerHash {
            reply(snapshot(run), nil)
        } else { reply(failure("stale_ticket"), nil) }
    }

    private func stop(_ run: Run, state: String, reason: String, reply: ((Any?, String?) -> Void)?) {
        if let reply = reply {
            guard run.saveWaiters.count < 16 else { reply(failure("save_busy"), nil); return }
            run.saveWaiters.append((page, scopeProvider?(), reply))
        }
        guard !run.ending else { return }
        run.ending = true
        run.targetState = state
        run.targetReason = reason
        run.endedAt = Int64(Date().timeIntervalSince1970 * 1000)
        run.endedUptime = ProcessInfo.processInfo.systemUptime
        pauseDuration(run)
        publishSystemSurface(run, eventAt: run.endedAt, elapsedSeconds: Double(run.elapsedMs) / 1000)
        gps.endRecording(id: run.id)
        bluetooth.setRecordingContext(id: nil, background: false, scope: nil)
        removeObservers()
        clock?.invalidate(); clock = nil
        if run.samples == 0 {
            run.state = "not_recorded"
            run.recordState = "not_recorded"
            run.reason = "no_samples"
            run.completed = false
            retire(run)
            replySaved(run)
            return
        }
        run.state = "saving"
        run.recordState = "saving"
        saveFinal(run)
    }

    private func saveFinal(_ run: Run) {
        guard !run.saveInFlight else { return }
        run.saveInFlight = true
        let value = record(run, final: true)
        worker.async { [weak self, weak run] in
            guard let run = run else { return }
            let result: Result<Int, Error>
            do { result = .success(try IOSRideDisk.save(value, owner: run.scope.ownerHash, id: run.id)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                run.saveInFlight = false
                switch result {
                case .success(let bytes):
                    run.savedBytes = bytes
                    run.saveFailed = false
                    run.completed = true
                    run.state = run.targetState
                    run.recordState = run.targetState
                    run.reason = run.targetReason
                case .failure(let error):
                    run.saveFailed = true
                    run.completed = false
                    run.state = "save_failed"
                    run.recordState = "save_failed"
                    run.reason = (error as? IOSRideDisk.Failure)?.code ?? "save_write_failed"
                }
                self.retire(run)
                self.replySaved(run)
            }
        }
    }

    private var pendingSaveCapacity: Bool {
        let failed = finals.values.filter { $0.saveFailed || $0.saveInFlight }
        // 为下一轮预留整份 8 MiB，失败已占四份时不再启动，不能静默牺牲唯一的重试数据。
        return failed.count < 4 && failed.reduce(0, { $0 + $1.estimatedBytes }) + IOSRideDisk.maxFileBytes <= 32 * 1024 * 1024
    }

    private func retire(_ run: Run) {
        if active === run { active = nil; if Self.leaseOwner === self { Self.leaseOwner = nil } }
        finals[run.id] = run
        while finals.count > 4 {
            guard let remove = finals.values.filter({ !$0.saveFailed && !$0.saveInFlight && $0 !== run })
                .sorted(by: { $0.startedAt < $1.startedAt }).first else { break }
            finals.removeValue(forKey: remove.id)
        }
    }

    private func replySaved(_ run: Run) {
        let waiters = run.saveWaiters
        run.saveWaiters.removeAll()
        for (revision, captured, reply) in waiters {
            guard revision == page, captured != nil, scopeProvider?() == captured else { reply(nil, "stale_navigation"); continue }
            var value = snapshot(run)
            value["ok"] = !run.saveFailed
            value["accepted"] = true
            reply(value, nil)
        }
    }

    private func action(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let action = options["action"] as? String else { reply(failure("invalid_action"), nil); return }
        if action == "records" { list(scope: scope, reply: reply); return }
        if action == "stop" { end(scope: scope, options: options, reply: reply); return }
        guard let id = requestedID(options) else { reply(failure("invalid_recording_id"), nil); return }
        if action == "retry" || action == "retry_save" {
            guard let run = finals[id], run.scope.ownerHash == scope.ownerHash, run.saveFailed else {
                reply(failure("retry_unavailable"), nil); return
            }
            guard run.state != "saving" else { reply(failure("save_busy"), nil); return }
            run.state = "saving"
            run.recordState = "saving"
            run.saveWaiters.append((page, scopeProvider?(), reply))
            saveFinal(run) // 同一 UUID 原子替换，不追加第二条历史。
            return
        }
        guard let run = active, run.id == id, run.scope == scope, !run.ending else { reply(failure("stale_ticket"), nil); return }
        switch action {
        case "pause", "gps_off":
            markGap(run, source: "gps", reason: action == "pause" ? "user_pause" : "gps_disabled")
            if action == "pause" { run.userPaused = true }
            else { run.gpsWanted = false }
            run.lastRoute = nil
            gps.pauseRecording(id: run.id)
            if action == "pause" {
                pauseDuration(run)
                run.state = "paused"
                run.recordState = "paused"
                run.reason = "user_pause"
                bluetooth.setRecordingContext(id: nil, background: false, scope: nil)
            }
            checkpoint(run, force: true)
            publishSystemSurface(run, eventAt: Int64(Date().timeIntervalSince1970 * 1000), elapsedSeconds: Double(run.elapsedMs) / 1000)
            reply(snapshot(run), nil)
        case "resume", "gps_on", "background_on":
            guard options["confirmed"] as? Bool == true else { reply(failure("user_action_required"), nil); return }
            confirm(method: "ride.action", id: id, scope: scope, title: IOSStrings.rideRecordTitle,
                    message: IOSStrings.rideRecordMessage, reply: reply) { [weak self, weak run] consent in
                guard let self = self, let run = run, self.owns(run) else { return }
                if action == "background_on" {
                    run.backgroundWanted = true
                    if run.gpsWanted { _ = self.gps.setBackgroundRecording(id: run.id, enabled: true, requestPermission: true) }
                } else {
                    run.userPaused = false
                    run.gpsWanted = true
                    _ = self.gps.beginRecording(id: run.id, background: run.backgroundWanted, requestPermission: true)
                    _ = self.gps.resumeRecording(id: run.id, requestPermission: true)
                    run.state = "waiting"; run.recordState = "waiting"; run.reason = "waiting_fix"
                }
                self.updateBLEContext(run)
                self.publishSystemSurface(run, eventAt: Int64(Date().timeIntervalSince1970 * 1000), elapsedSeconds: Double(run.elapsedMs) / 1000)
                self.finish(consent, self.snapshot(run))
            }
        case "background_off":
            run.backgroundWanted = false
            _ = gps.setBackgroundRecording(id: run.id, enabled: false, requestPermission: false)
            updateBLEContext(run)
            reply(snapshot(run), nil)
        default: reply(failure("invalid_action"), nil)
        }
    }

    private func requestedID(_ options: [String: Any]) -> UUID? {
        guard let text = options["id"] as? String ?? options["ticket"] as? String ?? options["recordingId"] as? String else { return nil }
        return UUID(uuidString: text)
    }

    private func list(scope: IOSRideScope, reply: @escaping (Any?, String?) -> Void) {
        io(scope: scope, reply: reply) {
            try IOSRideDisk.list(owner: scope.ownerHash)
        }
    }

    private func detail(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let id = requestedID(options) else { reply(failure("invalid_recording_id"), nil); return }
        let offset = IOSRideJSON.integer(options["offset"] ?? 0, maximum: Int64(IOSRideDisk.maxSamples))
        let limit = IOSRideJSON.integer(options["limit"] ?? 500, minimum: 1, maximum: 2000)
        guard let start = offset, let count = limit else { reply(failure("invalid_page"), nil); return }
        io(scope: scope, reply: reply) {
            let record = try IOSRideDisk.read(owner: scope.ownerHash, id: id)
            let gps = record["rawGPS"] as? [[String: Any]] ?? []
            let ble = record["telemetry"] as? [[String: Any]] ?? []
            var result = IOSRideDisk.summary(record)
            result["ok"] = true
            result["version"] = 1
            result["rawGPS"] = Array(gps.dropFirst(Int(start)).prefix(Int(count)))
            result["telemetry"] = Array(ble.dropFirst(Int(start)).prefix(Int(count)))
            result["gaps"] = Array((record["gaps"] as? [[String: Any]] ?? []).prefix(256))
            result["offset"] = start
            result["limit"] = count
            result["moreGPS"] = gps.count > Int(start + count)
            result["moreTelemetry"] = ble.count > Int(start + count)
            return result
        }
    }

    private func delete(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true, let id = requestedID(options) else {
            reply(failure("user_action_required"), nil); return
        }
        guard active?.id != id, finals[id]?.saveInFlight != true else { reply(failure("recording_busy"), nil); return }
        confirm(method: "ride.delete", id: id, scope: scope, title: IOSStrings.rideDeleteTitle,
                message: IOSStrings.rideDeleteMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            self.io(scope: scope, reply: { [weak self] value, error in
                guard let self = self else { return }
                if error == nil, (value as? [String: Any])?["ok"] as? Bool == true { self.finals.removeValue(forKey: id) }
                self.finish(consent, value as? [String: Any] ?? self.failure(error ?? "delete_failed"))
            }) {
                try IOSRideDisk.delete(owner: scope.ownerHash, id: id)
                return ["ok": true, "id": id.uuidString.lowercased(), "deleted": true]
            }
        }
    }

    private func share(scope: IOSRideScope, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard options["confirmed"] as? Bool == true, let id = requestedID(options) else {
            reply(failure("user_action_required"), nil); return
        }
        guard active?.id != id, sharing == nil else { reply(failure("recording_busy"), nil); return }
        confirm(method: "ride.share", id: id, scope: scope, title: IOSStrings.rideShareTitle,
                message: IOSStrings.rideShareMessage, reply: reply) { [weak self] consent in
            guard let self = self else { return }
            self.sharing = consent
            self.worker.async { [weak self, weak consent] in
                guard let self = self, let consent = consent else { return }
                let result: Result<URL, Error>
                do {
                    _ = try IOSRideDisk.read(owner: scope.ownerHash, id: id)
                    result = .success(try IOSRideDisk.url(owner: scope.ownerHash, id: id))
                } catch { result = .failure(error) }
                DispatchQueue.main.async {
                    guard self.sharing === consent else { return }
                    guard self.live(consent) else { self.cancelShare("stale_navigation"); return }
                    guard case .success(let url) = result else { self.cancelShare("records_read_failed"); return }
                    guard let presenter = self.presenterProvider?(), presenter.viewIfLoaded?.window != nil,
                          presenter.presentedViewController == nil else { self.cancelShare("share_unavailable"); return }
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    self.activity = activity
                    activity.popoverPresentationController?.sourceView = presenter.view
                    activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    activity.completionWithItemsHandler = { [weak self, weak consent] _, completed, _, error in
                        guard let self = self, let consent = consent, self.sharing === consent else { return }
                        self.sharing = nil
                        self.activity = nil
                        self.finish(consent, ["ok": completed && error == nil, "id": id.uuidString.lowercased(),
                            "shared": completed && error == nil, "cancelled": !completed,
                            "reason": error == nil ? completed ? "" : "user_cancelled" : "share_failed"])
                    }
                    presenter.present(activity, animated: true)
                }
            }
        }
    }

    private func io(scope: IOSRideScope, reply: @escaping (Any?, String?) -> Void,
                    work: @escaping () throws -> [String: Any]) {
        guard pendingIO < 8 else { reply(failure("records_busy"), nil); return }
        pendingIO += 1
        let revision = page
        worker.async { [weak self] in
            let result: Result<[String: Any], Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingIO -= 1
                guard self.page == revision, self.scopeProvider?() == scope else { reply(nil, "stale_navigation"); return }
                switch result {
                case .success(let value): reply(value, nil)
                case .failure(let error): reply(self.failure((error as? IOSRideDisk.Failure)?.code ?? "records_failed"), nil)
                }
            }
        }
    }

    private func confirm(method: String, id: UUID?, scope: IOSRideScope, title: String, message: String,
                         reply: @escaping (Any?, String?) -> Void, accepted: @escaping (Consent) -> Void) {
        guard UIApplication.shared.applicationState == .active else { reply(failure("foreground_required"), nil); return }
        guard confirmation == nil, sharing == nil, let presenter = presenterProvider?(),
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            reply(failure("confirmation_unavailable"), nil); return
        }
        let consent = Consent(page: page, scope: scope, method: method, id: id, reply: reply)
        confirmation = consent
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        confirmationAlert = alert
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak consent] _ in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.cancelConsent("user_cancelled")
        })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self, weak consent] _ in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.confirmation = nil
            self.confirmationAlert = nil
            consent.timeout?.cancel(); consent.timeout = nil
            guard self.live(consent) else { self.finish(consent, self.failure("stale_session")); return }
            accepted(consent)
        })
        let timeout = DispatchWorkItem { [weak self, weak consent] in
            guard let self = self, let consent = consent, self.confirmation === consent else { return }
            self.cancelConsent("confirmation_timeout")
        }
        consent.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        presenter.present(alert, animated: true)
    }

    private func live(_ consent: Consent) -> Bool {
        consent.reply != nil && consent.page == page && scopeProvider?() == consent.scope
            && UIApplication.shared.applicationState == .active
    }

    private func finish(_ consent: Consent, _ value: [String: Any]) {
        consent.timeout?.cancel(); consent.timeout = nil
        guard let reply = consent.reply else { return }
        consent.reply = nil
        if consent.page != page || scopeProvider?() != consent.scope { reply(nil, "stale_navigation") }
        else { reply(value, nil) }
    }

    private func cancelConsent(_ code: String) {
        guard let consent = confirmation else { return }
        confirmation = nil
        confirmationAlert?.dismiss(animated: false)
        confirmationAlert = nil
        finish(consent, failure(code))
    }

    private func cancelShare(_ code: String) {
        guard let consent = sharing else { return }
        sharing = nil
        activity?.dismiss(animated: false)
        activity = nil
        finish(consent, failure(code))
    }

    private func failure(_ code: String) -> [String: Any] {
        ["ok": false, "state": "error", "reason": code]
    }
}
