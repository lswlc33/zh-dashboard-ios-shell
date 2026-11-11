import Foundation
import CoreFoundation
import UIKit
import CryptoKit
import Darwin
import ZeehoShared

// iOS 只做真实前台样本的系统 IO。采样 admission、积分、缺口和充电段全部交给 KMP。
final class IOSHistoryService: IOSBridgeService {
    let methods = ["history.record", "history.battery", "history.charge", "history.clear", "history.status"]

    private typealias Object = [String: Any]
    private typealias Reply = (Any?, String?) -> Void
    private enum Limit {
        static let fileBytes = 16 * 1024 * 1024
        static let records = 100_000       // 与 SharedBattery 的真实 cap 相同，不在 Swift 另写保留算法。
        static let owners = 12
        static let diskBytes = (owners + 1) * fileBytes    // 包括崩溃遗留临时文件，不能无限增长。
        static let pending = 32
        static let requestBytes = 24 * 1024
        static let safeInteger: Int64 = 9_007_199_254_740_991
    }
    private struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }
    private struct Owner {
        let stableID: String
        var shared: Object { ["ownerId": stableID, "ownerUid": "", "vin": stableID] }
    }
    private final class Request {
        let scope: IOSRideScope
        let owner: Owner
        let epoch: UInt64
        let frame: Any
        let ownerUID: String
        let reply: Reply
        var finished = false             // 只在主线程读取/写入。
        init(scope: IOSRideScope, owner: Owner, epoch: UInt64, frame: Any,
             ownerUID: String, reply: @escaping Reply) {
            self.scope = scope; self.owner = owner; self.epoch = epoch
            self.frame = frame; self.ownerUID = ownerUID; self.reply = reply
        }
    }
    private struct StoreState {
        let battery: SharedBattery
        let snapshot: String
        let ledger: String
        let revision: Int64
    }
    private struct Loaded {
        let state: StoreState?
        let fingerprint: String?
        let exists: Bool
        let readError: String?
    }
    private final class ClearPrompt {
        let request: Request
        let arguments: Object
        let loaded: Loaded
        let target: String
        var alert: UIAlertController?
        var timer: DispatchWorkItem?
        init(_ request: Request, _ arguments: Object, _ loaded: Loaded, _ target: String) {
            self.request = request; self.arguments = arguments; self.loaded = loaded; self.target = target
        }
    }

    private let worker = DispatchQueue(label: "io.github.lswlc33.zeeho.history", qos: .utility)
    // core 在发布新 scope 前同步 navigationChanged；磁盘提交的最后一个 rename 与此短锁互斥。
    private let commitGate = NSLock()
    private var epoch: UInt64 = 0
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var requests: [ObjectIdentifier: Request] = [:]     // 主线程。
    private var queuedWork = 0                                 // 旧导航被撤销的排队任务也计入 cap。
    private var prompt: ClearPrompt?                            // 主线程。
    private var lastWriteError: String?                         // 仅 worker。
    private var lastWriteOwner = ""                             // 不保存原账号/VIN。

    init() {}

    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread)
        navigationChanged()
        scopeProvider = provider
    }

    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        commitGate.lock(); epoch &+= 1; commitGate.unlock()
        if let prompt = prompt {
            prompt.timer?.cancel()
            prompt.alert?.dismiss(animated: false)
            self.prompt = nil
        }
        let obsolete = Array(requests.values)
        obsolete.forEach { finish($0, error: "history_scope_changed") }
    }

    func applicationBackgrounded() {
        // 不在后台发任何 API/定时任务。尚未提交的前台工作也失效，不能迟到写入旧车主。
        navigationChanged()
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard methods.contains(method) else { reply(nil, "history_unsupported_method"); return }
        guard UIApplication.shared.applicationState == .active else {
            reply(nil, "history_foreground_required"); return
        }
        guard args.count == 1, let arguments = args.first as? Object else {
            reply(nil, "history_invalid_arguments"); return
        }
        do {
            guard let scope = scopeProvider?(), validScope(scope),
                  arguments["accountId"] as? String == scope.accountID,
                  arguments["vin"] as? String == scope.vin else { throw Failure("history_scope_changed") }
            try validateScopeEcho(arguments, scope)
            guard try jsonData(arguments).count <= Limit.requestBytes else { throw Failure("history_request_too_large") }
            guard requests.count < Limit.pending, queuedWork < Limit.pending else { throw Failure("history_queue_full") }
            if method == "history.clear", prompt != nil { throw Failure("history_busy") }
            let owner = try makeOwner(scope)
            let scopeEcho = arguments["scope"] as? Object
            let frame = try frameValue(arguments["frame"] ?? scopeEcho?["frame"])
            let uid = arguments["ownerUid"] as? String ?? ""
            guard uid.utf8.count <= 128 else { throw Failure("history_invalid_arguments") }
            let request = Request(scope: scope, owner: owner, epoch: epoch,
                                  frame: frame, ownerUID: uid, reply: reply)
            requests[ObjectIdentifier(request)] = request
            queuedWork += 1
            worker.async { [self] in
                defer { DispatchQueue.main.async { [self] in queuedWork -= 1 } }
                autoreleasepool {
                    do {
                        try requireCurrent(request)
                        let loaded = try load(owner, now: nowMillis())
                        if method == "history.status" {
                            complete(request, status(loaded, request)); return
                        }
                        if method == "history.clear" {
                            let target = arguments["target"] as? String ?? "charge"
                            guard ["charge", "battery", "all"].contains(target) else {
                                throw Failure("history_invalid_clear_target")
                            }
                            try checkExpectedWatermark(arguments, loaded)
                            DispatchQueue.main.async { [self] in presentClear(request, arguments, loaded, target) }
                            return
                        }
                        guard loaded.readError == nil, let state = loaded.state else {
                            throw Failure(loaded.readError ?? "history_read_failed")
                        }
                        switch method {
                        case "history.record": try record(arguments, state, loaded, request)
                        case "history.battery":
                            let range = arguments["range"] as? String ?? "24h"
                            guard ["24h", "3d", "7d", "30d"].contains(range) else {
                                throw Failure("history_invalid_range")
                            }
                            complete(request, try batteryResponse(state, range, request))
                        case "history.charge": complete(request, try chargeResponse(state, request))
                        default: throw Failure("history_unsupported_method")
                        }
                    } catch {
                        complete(request, nil, code(error))
                    }
                }
            }
        } catch { reply(nil, code(error)) }
    }

    // MARK: - 主线程身份与回执

    private func validScope(_ scope: IOSRideScope) -> Bool {
        [scope.accountID, scope.vin, scope.generation].allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 128
                && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }

    private func validateScopeEcho(_ arguments: Object, _ scope: IOSRideScope) throws {
        if let generation = arguments["generation"] {
            guard text(generation) == scope.generation else { throw Failure("history_scope_changed") }
        }
        guard let value = arguments["scope"] else { return }
        guard let echoed = value as? Object else { throw Failure("history_invalid_scope") }
        if let id = echoed["accountId"] { guard id as? String == scope.accountID else { throw Failure("history_scope_changed") } }
        if let vin = echoed["vin"] { guard vin as? String == scope.vin else { throw Failure("history_scope_changed") } }
        // sync.session.generation 是导航代次，epoch 才是 IOSRideScope 的业务代次。
        if let generation = echoed["epoch"] {
            guard text(generation) == scope.generation else { throw Failure("history_scope_changed") }
        } else if let generation = echoed["generation"] {
            guard text(generation) == scope.generation else { throw Failure("history_scope_changed") }
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        precondition(Thread.isMainThread)
        guard !request.finished, request.epoch == epoch,
              UIApplication.shared.applicationState == .active, let scope = scopeProvider?() else { return false }
        return scope.accountID == request.scope.accountID && scope.vin == request.scope.vin
            && scope.generation == request.scope.generation
    }

    private func requireCurrent(_ request: Request) throws {
        dispatchPrecondition(condition: .onQueue(worker))
        let current = DispatchQueue.main.sync { isCurrent(request) }
        guard current else { throw Failure("history_scope_changed") }
    }

    private func complete(_ request: Request, _ value: Any?, _ error: String? = nil) {
        DispatchQueue.main.async { [self] in
            guard isCurrent(request) else { finish(request, error: "history_scope_changed"); return }
            finish(request, value: value, error: error)
        }
    }

    private func finish(_ request: Request, value: Any? = nil, error: String? = nil) {
        precondition(Thread.isMainThread)
        guard !request.finished else { return }
        request.finished = true
        requests.removeValue(forKey: ObjectIdentifier(request))
        request.reply(value, error)
    }

    private func makeOwner(_ scope: IOSRideScope) throws -> Owner {
        // JSON 数组消除 account/VIN 拼接碰撞；路径只含64位hex，不接收网页路径。
        Owner(stableID: digest(try jsonData([scope.accountID, scope.vin])))
    }

    private func metadata(_ request: Request) -> Object {
        ["accountId": request.scope.accountID, "vin": request.scope.vin,
         "generation": request.scope.generation, "frame": request.frame,
         "frameSource": "request-correlation", "frameVerified": false, "scopeVerified": true,
         "ownerStableId": request.owner.stableID, "sampling": "foreground-only", "backgroundPolling": false]
    }

    // MARK: - 真实样本 → KMP 候选状态 → 整体事务

    private func record(_ arguments: Object, _ previous: StoreState, _ loaded: Loaded, _ request: Request) throws {
        guard arguments["accepted"] as? Bool == true, let snapshot = arguments["snapshot"] as? Object,
              !synthetic(arguments), !synthetic(snapshot),
              let source = arguments["source"] as? String, ["battery", "vehicle"].contains(source) else {
            throw Failure("history_unaccepted_sample")
        }
        let now = nowMillis()
        let sampleAt = integer(arguments["sampleAt"])
        let batteryAt = integer(snapshot["batteryAt"])
        let vehicleAt = integer(snapshot["vehicleAt"])
        guard let at = sampleAt, at > 0, at <= now else { throw Failure("history_invalid_sample_time") }
        let savedLedger = try sharedObject(previous.ledger)
        let clearAt = integer(savedLedger["clearAt"]) ?? 0
        if at <= clearAt {
            // 系统清除水位是事务闸门：确认前的迟到样本不能让已清历史重新出现。
            complete(request, ["ok": true, "accepted": false, "persisted": false,
                               "status": "cleared", "clearAt": clearAt, "metadata": metadata(request)])
            return
        }
        var battery = previous.battery
        var nextSnapshot = previous.snapshot
        var nextLedger = previous.ledger
        var result: Object
        if source == "battery" {
            guard snapshot["batteryFresh"] as? Bool == true, batteryAt == at,
                  let sample = snapshot["sample"] as? Object, integer(sample["batteryAt"]) == at,
                  !synthetic(sample) else { throw Failure("history_unaccepted_sample") }
            let freshVehicle = snapshot["vehicleFresh"] as? Bool == true
            let rawVehicleAt: Int64 = freshVehicle ? (vehicleAt ?? 0) : 0
            let suppliedSampleVehicleAt: Int64 = freshVehicle ? (integer(sample["vehicleAt"]) ?? 0) : 0
            var inputSample: Object = [:]
            for key in ["soc", "voltage", "current", "power", "chargedMin"] {
                inputSample[key] = numericValue(sample[key])
            }
            inputSample["charging"] = integer(sample["charging"]) ?? -1
            inputSample["chargeSource"] = boundedText(sample["chargeSource"], limit: 16) ?? "unknown"
            inputSample["chargeCode"] = boundedText(sample["chargeCode"], limit: 32) ?? ""
            let chargeSource = inputSample["chargeSource"] as? String ?? "unknown"
            let chargeCode = inputSample["chargeCode"] as? String ?? ""
            if !["battery", "vehicle"].contains(chargeSource) || chargeCode.isEmpty || chargeCode == "-1"
                || (chargeSource == "vehicle" && !freshVehicle) {
                // 不接共享兼容旧协议的无来源捷径；本服务要求网页本轮真实码证据。
                inputSample["chargeSource"] = "unknown"
                inputSample["chargeCode"] = ""
                inputSample["charging"] = -1
            }
            inputSample["batteryAt"] = at
            inputSample["vehicleAt"] = suppliedSampleVehicleAt
            var input: Object = ["vin": request.owner.stableID, "batteryAt": at,
                                 "vehicleAt": rawVehicleAt, "sample": inputSample]
            // odo 在网页与 KMP 都是米；不得再乘/除1000。无 fresh 车况只传未知。
            input["totalMile"] = freshVehicle ? integerValue(snapshot["odo"]) : NSNull()
            input["chargedMin"] = freshVehicle ? integerValue(snapshot["chargedMin"]) : NSNull()
            input["lock"] = freshVehicle ? integerValue(snapshot["lock"]) : NSNull()
            let candidate = SharedBattery()
            _ = try sharedObject(candidate.restoreJSON(json: previous.snapshot, now: now))
            result = try sharedObject(candidate.acceptSampleJSON(json: try jsonString(input), now: now))
            if result["accepted"] as? Bool != true {
                result["persisted"] = false
                result["metadata"] = metadata(request)
                result["vin"] = request.scope.vin
                complete(request, result); return
            }
            guard let point = result["sample"] as? Object, integer(point["t"]) == at else {
                throw Failure("history_invalid_shared_result")
            }
            nextSnapshot = candidate.snapshotJSON()
            _ = try validatedSnapshot(nextSnapshot, owner: request.owner)
            let state = integer(point["state"]) ?? -1
            nextLedger = try reduce(previous.ledger,
                                    event: ["type": "state", "state": state, "at": at],
                                    owner: request.owner, now: now)
            battery = candidate
        } else {
            guard snapshot["vehicleFresh"] as? Bool == true, vehicleAt == at,
                  let chargeCode = boundedText(snapshot["vehicleChargeCode"], limit: 32),
                  !chargeCode.isEmpty, chargeCode != "-1",
                  let state = integer(snapshot["vehicleCharging"]), (0...2).contains(state),
                  (chargeCode == "1") == (state == 1) else { throw Failure("history_unknown_vehicle_state") }
            // 仅真实车况改变账本水位，不借旧电池读数拼一条新采样。
            nextLedger = try reduce(previous.ledger, event: ["type": "state", "state": state, "at": at],
                                    owner: request.owner, now: now)
            result = ["ok": true, "accepted": nextLedger != previous.ledger,
                      "status": nextLedger == previous.ledger ? "out_of_order" : "accepted", "sampleAt": at]
            if nextLedger == previous.ledger {
                result["persisted"] = false; result["metadata"] = metadata(request)
                complete(request, result); return
            }
        }
        let revision = try nextRevision(previous.revision, now)
        let candidate = StoreState(battery: battery, snapshot: nextSnapshot, ledger: nextLedger, revision: revision)
        do {
            try save(candidate, request: request, expectedFingerprint: loaded.fingerprint, existed: loaded.exists)
            lastWriteError = nil; lastWriteOwner = request.owner.stableID
        } catch {
            lastWriteError = code(error); lastWriteOwner = request.owner.stableID
            throw error                     // candidate 未发布；相同真实样本可以重新提交。
        }
        result["persisted"] = true; result["storageRevision"] = revision
        result["vin"] = request.scope.vin; result["metadata"] = metadata(request)
        complete(request, result)
    }

    private func reduce(_ ledger: String, event: Object, owner: Owner, now: Int64) throws -> String {
        var bound = event
        owner.shared.forEach { bound[$0.key] = $0.value }
        let reduced = SharedChargeLog().reduceJSON(ledgerJSON: ledger, eventJSON: try jsonString(bound), now: now)
        _ = try validatedLedger(reduced, owner: owner)
        return reduced
    }

    private func batteryResponse(_ state: StoreState, _ range: String, _ request: Request) throws -> Object {
        var report = try sharedObject(state.battery.reportJSON(range: range, now: nowMillis()))
        guard report["points"] is [Object], report["summary"] is Object else {
            throw Failure("history_invalid_shared_report")
        }
        report["vin"] = request.scope.vin
        // state 保留给现网页；st 是旧适配器别名，仅字段映射，不重新推测未知/充电。
        report["points"] = (report["points"] as? [Object] ?? []).map { point -> Object in
            var mapped = point
            if let value = point["state"] { mapped["st"] = value }
            return mapped
        }
        report["metadata"] = metadata(request)
        report["sampling"] = "foreground-only"; report["backgroundPolling"] = false
        report["degraded"] = writeError(request.owner) != nil
        var result = report
        result["report"] = report; result["storageRevision"] = state.revision
        return result
    }

    private func chargeResponse(_ state: StoreState, _ request: Request) throws -> Object {
        let now = nowMillis()
        var history = try sharedObject(SharedChargeLog().hydrateJSON(ledgerJSON: state.ledger,
                                                                    samplesJSON: state.snapshot, now: now))
        guard integer(history["version"]) == 2, history["sessions"] is [Object],
              history["current"] is NSNull || history["current"] is Object else {
            throw Failure("history_invalid_shared_report")
        }
        history["vin"] = request.scope.vin; history["ownerId"] = request.scope.accountID
        history["ownerUid"] = request.ownerUID                 // 只回显，不持久化或赋予权限。
        history["metadata"] = metadata(request)
        history["sampling"] = "foreground-only"; history["backgroundPolling"] = false
        history["degraded"] = writeError(request.owner) != nil
        // 完整原生后台健康度/估算修复本轮并未实现，不能用接口存在宣称支持。
        history["healthEstimator"] = "not-implemented"
        var result = history
        result["history"] = history; result["storageRevision"] = state.revision
        return result
    }

    // MARK: - 原生清除确认与持久化墓碑

    private func presentClear(_ request: Request, _ arguments: Object, _ loaded: Loaded, _ target: String) {
        precondition(Thread.isMainThread)
        guard isCurrent(request) else { finish(request, error: "history_scope_changed"); return }
        guard prompt == nil, let controller = presenterProvider?(), controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil else { finish(request, error: "history_presenter_unavailable"); return }
        let destructiveAll = target != "charge" || loaded.readError != nil
        let title = destructiveAll ? "清除本车本地历史？" : "清除本车充电记录？"
        let message = loaded.readError != nil
            ? "这份本地历史无法读取。不会自动覆盖原文件；只有在你确认后，才会删除损坏的历史内容并保存新的清除水位。此操作无法撤销。"
            : destructiveAll
                ? "只清除当前账号、当前车辆的电池采样和充电记录，并保存清除水位。不影响其他账号或车辆，也不会向服务器发送删除请求。此操作无法撤销。"
                : "只清除当前账号、当前车辆的充电记录，并保存清除水位。电池采样仍保留，不影响其他账号或车辆，也不会向服务器发送删除请求。此操作无法撤销。"
        let clear = ClearPrompt(request, arguments, loaded, destructiveAll ? "all" : target)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        clear.alert = alert; prompt = clear
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self, weak clear] _ in
            guard let self = self, let clear = clear, self.prompt === clear else { return }
            clear.timer?.cancel(); self.prompt = nil
            self.finish(request, error: "history_clear_cancelled")
        })
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self, weak clear] _ in
            guard let self = self, let clear = clear, self.prompt === clear else { return }
            clear.timer?.cancel(); self.prompt = nil
            guard self.isCurrent(request) else { self.finish(request, error: "history_scope_changed"); return }
            guard self.queuedWork < Limit.pending else { self.finish(request, error: "history_queue_full"); return }
            self.queuedWork += 1
            self.worker.async { [self] in
                defer { DispatchQueue.main.async { [self] in queuedWork -= 1 } }
                autoreleasepool {
                    do { try commitClear(clear) }
                    catch {
                        lastWriteError = code(error); lastWriteOwner = request.owner.stableID
                        complete(request, nil, code(error))
                    }
                }
            }
        })
        let timer = DispatchWorkItem { [weak self, weak clear] in
            guard let self = self, let clear = clear, self.prompt === clear else { return }
            clear.alert?.dismiss(animated: false); self.prompt = nil
            self.finish(request, error: "history_clear_timeout")
        }
        clear.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 240, execute: timer)
        controller.present(alert, animated: true)
    }

    private func checkExpectedWatermark(_ arguments: Object, _ loaded: Loaded) throws {
        if let expected = arguments["storageRevision"] {
            guard integer(expected) == loaded.state?.revision else { throw Failure("history_clear_changed") }
        }
        guard let ledger = loaded.state?.ledger else { return }
        let object = try sharedObject(ledger)
        for key in ["revision", "clearAt"] where arguments[key] != nil {
            guard integer(arguments[key]) == integer(object[key]) else { throw Failure("history_clear_changed") }
        }
    }

    private func commitClear(_ clear: ClearPrompt) throws {
        let request = clear.request
        try requireCurrent(request)
        let now = nowMillis()
        let actual = try load(request.owner, now: now)
        guard actual.exists == clear.loaded.exists, actual.fingerprint == clear.loaded.fingerprint,
              !actual.exists || actual.fingerprint != nil else {
            throw Failure("history_clear_changed")         // 用户确认期间有新样本，不误清新记录。
        }
        try checkExpectedWatermark(clear.arguments, actual)
        let previous: StoreState
        if let saved = actual.state { previous = saved }
        else { previous = try emptyState(request.owner, now: now) }
        let ledger = try reduce(previous.ledger, event: ["type": "clear"], owner: request.owner, now: now)
        let battery: SharedBattery
        let snapshot: String
        if clear.target == "charge" {
            battery = previous.battery; snapshot = previous.snapshot
        } else {
            battery = SharedBattery()
            _ = try sharedObject(battery.restoreJSON(json: previous.snapshot, now: now))
            battery.clear()
            // SharedBattery.clear 解除VIN绑定；恢复同hash空状态，不在Swift实现裁剪或记账。
            var empty = try sharedObject(battery.snapshotJSON())
            empty["vin"] = request.owner.stableID
            _ = try sharedObject(battery.restoreJSON(json: try jsonString(empty), now: now))
            snapshot = battery.snapshotJSON()
        }
        let candidate = StoreState(battery: battery, snapshot: snapshot, ledger: ledger,
                                   revision: try nextRevision(previous.revision, now))
        try save(candidate, request: request, expectedFingerprint: actual.fingerprint, existed: actual.exists)
        lastWriteError = nil; lastWriteOwner = request.owner.stableID
        var response = try chargeResponse(candidate, request)
        response["cleared"] = true; response["target"] = clear.target; response["persisted"] = true
        response["status"] = status(Loaded(state: candidate, fingerprint: nil, exists: true, readError: nil), request)
        complete(request, response)
    }

    // MARK: - 私有目录、只读损坏保护与整体原子提交（仅 worker）

    private func historyDirectory() throws -> URL {
        dispatchPrecondition(condition: .onQueue(worker))
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure("history_directory_unavailable")
        }
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        let directory = support.appendingPathComponent("history", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                     .posixPermissions: NSNumber(value: 0o700)])
        }
        var info = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Failure("history_unsafe_directory") }
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                   .posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return directory
    }

    private func historyFile(_ owner: Owner, in directory: URL) -> URL {
        directory.appendingPathComponent(owner.stableID + ".json", isDirectory: false)
    }

    private func readFile(_ file: URL) throws -> Data? {
        var info = stat()
        let status = file.path.withCString { Darwin.lstat($0, &info) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw Failure("history_read_failed")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            throw Failure("history_unsafe_file")
        }
        guard info.st_size >= 0, info.st_size <= off_t(Limit.fileBytes) else { throw Failure("history_file_too_large") }
        let fd = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw Failure("history_read_failed") }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              opened.st_size == info.st_size else { throw Failure("history_file_changed") }
        var data = Data(count: Int(opened.st_size))
        let readOK = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard readOK else { throw Failure("history_read_failed") }
        var end = UInt8(0)
        guard Darwin.read(fd, &end, 1) == 0 else { throw Failure("history_file_changed") }
        return data
    }

    private func load(_ owner: Owner, now: Int64) throws -> Loaded {
        let directory = try historyDirectory()
        let file = historyFile(owner, in: directory)
        let data: Data?
        do { data = try readFile(file) }
        catch { return Loaded(state: nil, fingerprint: nil, exists: true, readError: code(error)) }
        guard let bytes = data else {
            return Loaded(state: try emptyState(owner, now: now), fingerprint: nil, exists: false, readError: nil)
        }
        let fingerprint = digest(bytes)
        do {
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? Object,
                  integer(root["version"]) == 1, root["ownerStableId"] as? String == owner.stableID,
                  let revision = integer(root["storageRevision"]), revision >= 0,
                  let rawBattery = root["battery"] as? Object, let rawLedger = root["ledger"] as? Object else {
                throw Failure("history_invalid_file")
            }
            let batteryJSON = try jsonString(rawBattery)
            _ = try validatedSnapshot(batteryJSON, owner: owner)
            let ledgerJSON = try jsonString(rawLedger)
            _ = try validatedLedger(ledgerJSON, owner: owner)
            let battery = SharedBattery()
            _ = try sharedObject(battery.restoreJSON(json: batteryJSON, now: now))
            // hydrate 同时验证账本和全部真实样本；坏源文件从不被空状态覆盖。
            _ = try sharedObject(SharedChargeLog().hydrateJSON(ledgerJSON: ledgerJSON, samplesJSON: batteryJSON, now: now))
            return Loaded(state: StoreState(battery: battery, snapshot: battery.snapshotJSON(), ledger: ledgerJSON,
                                            revision: revision), fingerprint: fingerprint, exists: true, readError: nil)
        } catch { return Loaded(state: nil, fingerprint: fingerprint, exists: true, readError: code(error)) }
    }

    private func emptyState(_ owner: Owner, now: Int64) throws -> StoreState {
        let battery = SharedBattery()
        let input: Object = ["ok": true, "version": 4, "vin": owner.stableID, "revision": 0, "records": [Any]()]
        _ = try sharedObject(battery.restoreJSON(json: try jsonString(input), now: now))
        let ledger = SharedChargeLog().createJSON(ownerJSON: try jsonString(owner.shared))
        _ = try validatedLedger(ledger, owner: owner)
        return StoreState(battery: battery, snapshot: battery.snapshotJSON(), ledger: ledger, revision: 0)
    }

    private func save(_ state: StoreState, request: Request, expectedFingerprint: String?, existed: Bool) throws {
        dispatchPrecondition(condition: .onQueue(worker))
        let snapshot = try validatedSnapshot(state.snapshot, owner: request.owner)
        let ledger = try validatedLedger(state.ledger, owner: request.owner)
        let root: Object = ["version": 1, "ownerStableId": request.owner.stableID,
                            "storageRevision": state.revision, "battery": snapshot, "ledger": ledger]
        let bytes = try jsonData(root)
        guard bytes.count <= Limit.fileBytes else { throw Failure("history_file_full") }
        let directory = try historyDirectory()
        let file = historyFile(request.owner, in: directory)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let ownerFiles = contents.filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }
        if !existed && ownerFiles.count >= Limit.owners { throw Failure("history_owner_limit") }
        var diskBytes: Int64 = 0
        for entry in contents {
            var info = stat()
            guard entry.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                  info.st_size >= 0, info.st_size <= Int64(Limit.diskBytes) - diskBytes else {
                throw Failure("history_directory_full")
            }
            diskBytes += info.st_size
        }
        guard diskBytes <= Int64(Limit.diskBytes - bytes.count) else { throw Failure("history_directory_full") }
        let currentBytes = try readFile(file)
        guard (currentBytes != nil) == existed,
              currentBytes.map(digest) == expectedFingerprint else { throw Failure("history_file_changed") }
        let temporary = directory.appendingPathComponent("." + request.owner.stableID + "." + UUID().uuidString + ".tmp")
        let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw Failure("history_write_failed") }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(fd) }
            // 仅清理本次自己创建的临时文件，不动损坏原件/他人文件。
            _ = temporary.path.withCString { Darwin.unlink($0) }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                               .posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
        let written = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard written, Darwin.fsync(fd) == 0 else { throw Failure("history_write_failed") }
        guard Darwin.close(fd) == 0 else { descriptorOpen = false; throw Failure("history_write_failed") }
        descriptorOpen = false
        try requireCurrent(request)            // 不在主线程做磁盘 IO。
        commitGate.lock()
        let renamed: Int32
        if request.epoch == epoch {
            renamed = temporary.path.withCString { from in file.path.withCString { to in Darwin.rename(from, to) } }
        } else { renamed = -1 }
        let stale = request.epoch != epoch
        commitGate.unlock()
        guard !stale else { throw Failure("history_scope_changed") }
        guard renamed == 0 else { throw Failure("history_rename_failed") }
        let directoryFD = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw Failure("history_durability_unconfirmed") }
        defer { _ = Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else {
            // rename可能已经完成，但不把未确认durability包装成成功；下次读仍保留实际文件。
            throw Failure("history_durability_unconfirmed")
        }
    }

    private func status(_ loaded: Loaded, _ request: Request) -> Object {
        let snapshot = loaded.state.flatMap { try? sharedObject($0.snapshot) }
        let ledger = loaded.state.flatMap { try? sharedObject($0.ledger) }
        let records = snapshot?["records"] as? [Object]
        let last = records?.last.flatMap { integer($0["t"]) }
        let write = writeError(request.owner)
        var result: Object = ["ok": true, "available": loaded.readError == nil,
            "sampling": "foreground-only", "backgroundPolling": false,
            "recordCount": records.map { $0.count as Any } ?? NSNull(), "lastAt": last.map { $0 as Any } ?? NSNull(),
            "degraded": loaded.readError != nil || write != nil, "readError": loaded.readError.map { $0 as Any } ?? NSNull(),
            "writeError": write.map { $0 as Any } ?? NSNull(), "persisted": loaded.exists && loaded.readError == nil,
            "storageRevision": loaded.state.map { $0.revision as Any } ?? NSNull(),
            "clearAt": ledger?["clearAt"] ?? NSNull(), "revision": ledger?["revision"] ?? NSNull(),
            "retentionDays": 31, "maxRecords": Limit.records, "maxFileBytes": Limit.fileBytes,
            "maxOwners": Limit.owners, "maxDiskBytes": Limit.diskBytes,
            "metadata": metadata(request), "initialized": true,
            "algorithm": "KMP-SharedBattery-SharedChargeLog", "healthEstimator": "not-implemented",
            "backgroundHealth": false, "interpolation": false]
        result["ledgerState"] = ledger?["state"] ?? NSNull()
        return result
    }

    private func writeError(_ owner: Owner) -> String? { lastWriteOwner == owner.stableID ? lastWriteError : nil }

    // MARK: - JSON 边界（仅字段校验/映射，不复制电池或记账算法）

    private func validatedSnapshot(_ value: String, owner: Owner) throws -> Object {
        let object = try sharedObject(value)
        guard integer(object["version"]) == 4, object["vin"] as? String == owner.stableID,
              let records = object["records"] as? [Object], records.count <= Limit.records,
              let revision = integer(object["revision"]), revision >= 0,
              Set(object.keys).isSubset(of: ["ok", "version", "vin", "revision", "records"]) else {
            throw Failure("history_invalid_shared_snapshot")
        }
        let keys: Set<String> = ["t", "soc", "v", "a", "w", "state", "pwr", "odo", "cf", "temp"]
        for point in records {
            guard Set(point.keys).isSubset(of: keys), point.values.allSatisfy({ number($0) != nil }) else {
                throw Failure("history_invalid_shared_snapshot")
            }
        }
        return object
    }

    private func validatedLedger(_ value: String, owner: Owner) throws -> Object {
        let object = try sharedObject(value)
        guard integer(object["version"]) == 3, object["ownerId"] as? String == owner.stableID,
              object["vin"] as? String == owner.stableID, object["ownerUid"] as? String == "",
              integer(object["revision"]) != nil, integer(object["clearAt"]) != nil,
              (object["legacy"] as? [Any])?.isEmpty == true,
              let segments = object["segments"] as? [Object], segments.count <= 12,
              Set(object.keys).isSubset(of: ["ok", "version", "ownerId", "ownerUid", "vin", "revision", "clearAt", "at", "state", "current", "segments", "legacy"]) else {
            throw Failure("history_invalid_shared_ledger")
        }
        for segment in segments {
            guard Set(segment.keys).isSubset(of: ["id", "from", "to"]),
                  boundedText(segment["id"], limit: 200) != nil,
                  integer(segment["from"]) != nil, integer(segment["to"]) != nil else {
                throw Failure("history_invalid_shared_ledger")
            }
        }
        if let current = object["current"] as? Object {
            guard Set(current.keys).isSubset(of: ["id", "from"]), boundedText(current["id"], limit: 200) != nil,
                  integer(current["from"]) != nil else { throw Failure("history_invalid_shared_ledger") }
        } else if !(object["current"] is NSNull) { throw Failure("history_invalid_shared_ledger") }
        return object
    }

    private func sharedObject(_ value: String) throws -> Object {
        guard let bytes = value.data(using: .utf8), bytes.count <= Limit.fileBytes,
              let object = try JSONSerialization.jsonObject(with: bytes) as? Object else {
            throw Failure("history_invalid_shared_result")
        }
        guard object["ok"] as? Bool == true else {
            throw Failure("history_shared_" + (boundedText(object["error"], limit: 56) ?? "failed"))
        }
        return object
    }

    private func jsonData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw Failure("history_invalid_json") }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func jsonString(_ value: Any) throws -> String {
        guard let text = String(data: try jsonData(value), encoding: .utf8) else { throw Failure("history_invalid_json") }
        return text
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func number(_ value: Any?) -> Double? {
        guard let value = value, !(value is NSNull) else { return nil }
        let result: Double?
        if let numeric = value as? NSNumber {
            guard CFGetTypeID(numeric) != CFBooleanGetTypeID() else { return nil }
            result = numeric.doubleValue
        }
        else if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result = Double(text) }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    private func integer(_ value: Any?) -> Int64? {
        guard let n = number(value), n.rounded(.towardZero) == n,
              abs(n) <= Double(Limit.safeInteger) else { return nil }
        return Int64(n)
    }
    private func numericValue(_ value: Any?) -> Any {
        if let integer = integer(value) { return integer }
        return number(value).map { $0 as Any } ?? NSNull()
    }
    private func integerValue(_ value: Any?) -> Any { integer(value).map { $0 as Any } ?? NSNull() }
    private func boundedText(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, text.utf8.count <= limit,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return text
    }
    private func text(_ value: Any) -> String? {
        if let string = value as? String { return string }
        return integer(value).map { String($0) }
    }
    private func frameValue(_ value: Any?) throws -> Any {
        guard let value = value, !(value is NSNull) else { return NSNull() }
        if let string = boundedText(value, limit: 128) { return string }
        if let numeric = integer(value), numeric >= 0 { return numeric }
        throw Failure("history_invalid_frame")
    }
    private func synthetic(_ value: Object) -> Bool {
        if value["demo"] as? Bool == true || value["model"] as? Bool == true || value["synthetic"] as? Bool == true { return true }
        for key in ["source", "dataSource", "sampleSource", "mode"] {
            if let kind = value[key] as? String, ["demo", "model", "simulation", "mock"].contains(kind.lowercased()) { return true }
        }
        return false
    }
    private func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func nextRevision(_ previous: Int64, _ now: Int64) throws -> Int64 {
        guard previous >= 0, previous < Limit.safeInteger else { throw Failure("history_revision_overflow") }
        return max(now, previous + 1)          // 仅 IO 回执水位，不是电池/充电业务算法。
    }
    private func code(_ error: Error) -> String { (error as? Failure)?.code ?? "history_io_failed" }
}
