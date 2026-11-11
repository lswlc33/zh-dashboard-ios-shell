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
        static let sessions = 12          // 与 ChargeLog.MAX_SESSIONS 一致，超出按结束时间丢最旧。
        static let staleTemporarySeconds: Int64 = 3_600
        static let sweepEntries = 2_048   // 单次清扫最多检查的目录项，避免超大目录拖住读盘。
        // BatteryHistory.wanted() 的最小阈值是「供电 60s 再减 10s 容差」，低于它就是必节流。
        static let throttleFloorMs: Int64 = 50_000
        // 抬升时钟的上限。超过一年的「未来点」不像时钟偏快，更像字节损坏；
        // 若也拿来抬 now，restore 的 31 天窗口会把全部真实历史滤掉、下次保存就把文件写空。
        static let maxFutureSkewMs: Int64 = 366 * 24 * 60 * 60 * 1000
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
        // 读盘时实际采用的时钟（可能已被文件内最大时间戳抬升）。写路径的 KMP 调用必须沿用它，
        // 否则 restore/hydrate 会再次把「未来点」判成 invalid_history，抬升就失去意义。
        let clock: Int64
    }
    private struct Loaded {
        let state: StoreState?
        let fingerprint: String?
        let exists: Bool
        let readError: String?
        let droppedPoints: Int
        let droppedSessions: Int
        let owners: Int
        // 本次读盘实际使用的时钟（已被文件内最大时间戳抬升）。KMP 的 restore/hydrate 必须与它一致，
        // 否则「未来时间戳」会再次被判成 invalid_history，等于白抬升。
        let effectiveNow: Int64
    }
    // ② 校验结果：object 是修好的容器，value 是给 KMP 的规范 JSON，dropped 是被丢弃的坏条目数。
    private struct Sanitized {
        let object: Object
        let value: String
        let dropped: Int
    }
    // ④ record 的廉价准入只缓存「原始证据」，不复刻 KMP 的采样解析。
    // KMP 的 BatterySample.parse 是纯函数：证据完全相同 ⇒ state/powered 完全相同
    // ⇒ wanted() 里既没有状态边沿也没有供电边沿，只剩时间阈值可判。
    // 只要证据有一项不同（含 vehicleOwned 从假变真），就返回 nil 退回完整读盘。
    private struct RawEvidence: Equatable {
        let charging: Int
        let code: String
        let source: String
        let lock: Int64
        let vehicleOwned: Bool
    }
    private struct WriteHint {
        let owner: String
        let pointAt: Int64        // 最后一条电池采样的 t；0 表示还没有采样
        let ledgerAt: Int64       // 账本最后一次状态事件的 at
        let clearAt: Int64
        let dropped: Int          // 该次读盘丢弃的坏点数，提前回执也带上同一个值
        let droppedSessions: Int
        let revision: Int64       // 最近一次已知的存储水位
        let raw: RawEvidence?     // 仅在「知道最后一条落盘点由什么证据产生」时才有值
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
    private var hint: WriteHint?                                // 仅 worker；④ 的廉价准入依据。
    private var lastError = ""                                  // 仅 worker；最近一次失败的可读代码，供 status 带出。
    private var lastSweepAt: Date?                              // 仅 worker；③ 清扫节流。

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
            self.worker.async { [self] in
                // Swift 6 要求闭包内显式 self. 才能明确捕获语义（嵌套闭包同样）。
                defer { DispatchQueue.main.async { [self] in self.queuedWork -= 1 } }
                autoreleasepool {
                    do {
                        try self.requireCurrent(request)
                        // record 的廉价准入要在 load 之前：网页每次前台同步都会提交样本，其中大部分
                        // 会被 KMP 节流；先判断「一定写不进去」就不必整份读盘+校验。
                        if method == "history.record", let early = self.earlyRecord(arguments, request) {
                            self.complete(request, early); return
                        }
                        let loaded = try self.load(owner, now: self.nowMillis())
                        if method == "history.status" {
                            self.complete(request, self.status(loaded, request)); return
                        }
                        if method == "history.clear" {
                            // 只接受 charge / all。SharedBattery.clear() 会解除 VIN 绑定，KMP 没有
                            // 「只清电池采样、保留充电账本」的原语；接受一个做不到的值会让网页以为清成功了。
                            let target = arguments["target"] as? String ?? "charge"
                            guard ["charge", "all"].contains(target) else {
                                throw Failure("history_invalid_clear_target")
                            }
                            try self.checkExpectedWatermark(arguments, loaded)
                            DispatchQueue.main.async { [self] in self.presentClear(request, arguments, loaded, target) }
                            return
                        }
                        guard loaded.readError == nil, let state = loaded.state else {
                            throw Failure(loaded.readError ?? "history_read_failed")
                        }
                        switch method {
                        case "history.record": try self.record(arguments, state, loaded, request)
                        case "history.battery":
                            let range = arguments["range"] as? String ?? "24h"
                            guard ["24h", "3d", "7d", "30d"].contains(range) else {
                                throw Failure("history_invalid_range")
                            }
                            self.complete(request, try self.batteryResponse(state, range, request))
                        case "history.charge":
                            self.complete(request, try self.chargeResponse(state, request, dropped: loaded.droppedPoints))
                        default: throw Failure("history_unsupported_method")
                        }
                    } catch {
                        self.complete(request, nil, self.code(error))
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
            // Swift 6：闭包内成员访问必须显式 self.。
            guard self.isCurrent(request) else { self.finish(request, error: "history_scope_changed"); return }
            self.finish(request, value: value, error: error)
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
        // 读盘时钟可能已被「未来时间戳」抬升过。KMP 的 restore/accept/hydrate/reduce 必须沿用同一个
        // 时钟，否则刚被 Swift 放过（或过滤掉）的未来点又会被 KMP 判成 invalid_history。
        let clock = previous.clock
        let sampleAt = integer(arguments["sampleAt"])
        let batteryAt = integer(snapshot["batteryAt"])
        let vehicleAt = integer(snapshot["vehicleAt"])
        guard let at = sampleAt, at > 0, at <= now else { throw Failure("history_invalid_sample_time") }
        let savedLedger = try sharedObject(previous.ledger)
        let clearAt = integer(savedLedger["clearAt"]) ?? 0
        if at <= clearAt {
            // 系统清除水位是事务闸门：确认前的迟到样本不能让已清历史重新出现。
            // dropped 字段与其它回执保持一致，避免网页在不同分支看到不同形状。
            complete(request, ["ok": true, "accepted": false, "persisted": false,
                               "status": "cleared", "clearAt": clearAt,
                               "droppedPoints": loaded.droppedPoints,
                               "droppedSessions": loaded.droppedSessions,
                               "metadata": metadata(request)])
            return
        }
        var battery = previous.battery
        var nextSnapshot = previous.snapshot
        var nextLedger = previous.ledger
        var result: Object
        var evidence: RawEvidence?
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
            evidence = rawEvidence(snapshot, sample, at: at)
            let candidate = SharedBattery()
            _ = try sharedObject(candidate.restoreJSON(json: previous.snapshot, now: clock))
            result = try sharedObject(candidate.acceptSampleJSON(json: try jsonString(input), now: clock))
            if result["accepted"] as? Bool != true {
                result["persisted"] = false
                result["metadata"] = metadata(request)
                result["vin"] = request.scope.vin
                self.noteDrops(&result, loaded)
                complete(request, result); return
            }
            guard let point = result["sample"] as? Object, integer(point["t"]) == at else {
                throw Failure("history_invalid_shared_result")
            }
            nextSnapshot = candidate.snapshotJSON()
            _ = try validatedSnapshot(nextSnapshot, owner: request.owner, now: clock)
            let state = integer(point["state"]) ?? -1
            nextLedger = try reduce(previous.ledger,
                                    event: ["type": "state", "state": state, "at": at],
                                    owner: request.owner, now: clock)
            battery = candidate
        } else {
            guard snapshot["vehicleFresh"] as? Bool == true, vehicleAt == at,
                  let chargeCode = boundedText(snapshot["vehicleChargeCode"], limit: 32),
                  !chargeCode.isEmpty, chargeCode != "-1",
                  let state = integer(snapshot["vehicleCharging"]), (0...2).contains(state),
                  (chargeCode == "1") == (state == 1) else { throw Failure("history_unknown_vehicle_state") }
            // 仅真实车况改变账本水位，不借旧电池读数拼一条新采样。
            nextLedger = try reduce(previous.ledger, event: ["type": "state", "state": state, "at": at],
                                    owner: request.owner, now: clock)
            result = ["ok": true, "accepted": nextLedger != previous.ledger,
                      "status": nextLedger == previous.ledger ? "out_of_order" : "accepted", "sampleAt": at]
            if nextLedger == previous.ledger {
                result["persisted"] = false; result["metadata"] = metadata(request)
                self.noteDrops(&result, loaded)
                complete(request, result); return
            }
        }
        // 存储水位取两者较大值：时钟被回拨过也不能让 revision 退回到旧值以下。
        let revision = try nextRevision(previous.revision, max(now, clock))
        let candidate = StoreState(battery: battery, snapshot: nextSnapshot, ledger: nextLedger,
                                   revision: revision, clock: clock)
        let durable: Bool
        do {
            durable = try save(candidate, request: request, expectedFingerprint: loaded.fingerprint, existed: loaded.exists)
            lastWriteError = nil; lastWriteOwner = request.owner.stableID
        } catch {
            lastWriteError = code(error); lastWriteOwner = request.owner.stableID
            // ⑨ owner 撞上限是本模块唯一「不是磁盘故障但用户必须知道」的失败：
            // 网页允许 20 个账号，这里只保留 12 个 (账号, VIN) 的文件，超出就会静默丢历史。
            // 把原因原文带到 status.lastError，界面才有机会提示「已达上限，请先清掉不用的车」。
            lastError = code(error) == "history_owner_limit"
                ? "history_owner_limit: 本机历史最多保留 \(Limit.owners) 个账号/车辆组合，已达上限"
                : code(error)
            throw error                     // candidate 未发布；相同真实样本可以重新提交。
        }
        result["persisted"] = true; result["storageRevision"] = revision; result["durable"] = durable
        result["vin"] = request.scope.vin; result["metadata"] = metadata(request)
        self.noteDrops(&result, loaded)
        remember(candidate, owner: request.owner, raw: evidence, dropped: loaded.droppedPoints,
                 droppedSessions: loaded.droppedSessions)
        complete(request, result)
    }

    // ④ record 的廉价准入。只在「凭本进程已知水位就能确定写不进去」时提前回执，
    // 拿不准一律返回 nil 走完整读盘，绝不复制 KMP 的采样解析规则。
    private func earlyRecord(_ arguments: Object, _ request: Request) -> Object? {
        guard let known = hint, known.owner == request.owner.stableID,
              arguments["accepted"] as? Bool == true, let snapshot = arguments["snapshot"] as? Object,
              !synthetic(arguments), !synthetic(snapshot),
              let source = arguments["source"] as? String, ["battery", "vehicle"].contains(source) else {
            return nil
        }
        let now = nowMillis()
        guard let at = integer(arguments["sampleAt"]), at > 0, at <= now else { return nil }
        var base: Object = ["ok": true, "accepted": false, "persisted": false,
                            "vin": request.scope.vin, "metadata": metadata(request)]
        base["droppedPoints"] = known.dropped
        base["droppedSessions"] = known.droppedSessions
        if at <= known.clearAt {
            // 与 record 完整路径相同的清除闸门回执，同样不需要读盘。
            base["status"] = "cleared"; base["clearAt"] = known.clearAt
            return base
        }
        if source == "vehicle" {
            guard snapshot["vehicleFresh"] as? Bool == true, integer(snapshot["vehicleAt"]) == at,
                  let code = boundedText(snapshot["vehicleChargeCode"], limit: 32),
                  !code.isEmpty, code != "-1",
                  let state = integer(snapshot["vehicleCharging"]), (0...2).contains(state),
                  (code == "1") == (state == 1) else { return nil }
            // reduce 对 state < 0 或 at 不新于账本水位的事件原样返回账本。
            guard state < 0 || at <= known.ledgerAt else { return nil }
            base["status"] = "out_of_order"; base["sampleAt"] = at
            return base
        }
        guard snapshot["batteryFresh"] as? Bool == true,
              let sample = snapshot["sample"] as? Object, integer(sample["batteryAt"]) == at,
              !synthetic(sample) else { return nil }
        // 只有「本轮原始充电证据与上一条已接受采样完全相同」才敢推断状态/供电无边沿；
        // 只要有一个字段变了，就必须交给 KMP 重新判定。
        guard let previous = known.raw, previous == rawEvidence(snapshot, sample) else { return nil }
        if at <= known.pointAt {
            base["status"] = "out_of_order"; base["sampleAt"] = at
            return base
        }
        // 无状态/供电边沿时 wanted() 只剩时间阈值：最短也要求 60s-10s 容差，低于它必然 throttled。
        guard at - known.pointAt < Limit.throttleFloorMs else { return nil }
        base["status"] = "throttled"; base["sampleAt"] = at
        return base
    }

    // ② 读盘时丢弃的坏点必须在回执里说明，不能让用户以为数据完整。
    private func noteDrops(_ result: inout Object, _ loaded: Loaded) {
        result["droppedPoints"] = loaded.droppedPoints
        result["droppedSessions"] = loaded.droppedSessions
    }

    // 只抽取「决定 KMP state/powered 的原始证据」，不做任何状态推导。
    // vehicleOwned 是 BatterySample.parse 里唯一与时钟相关的门条件（本轮 fresh、两个 vehicleAt
    // 相等且都在本轮、与 batteryAt 相差 ≤90s）；把它算成布尔值纳入证据，
    // 这样「供电由未知变已知」也会让证据不相等，从而退回完整路径。
    private func rawEvidence(_ snapshot: Object, _ sample: Object, at: Int64) -> RawEvidence {
        let vehicleAt = integer(snapshot["vehicleAt"]) ?? 0
        let sampleVehicleAt = integer(sample["vehicleAt"]) ?? 0
        let vehicleOwned = snapshot["vehicleFresh"] as? Bool == true && vehicleAt > 0
            && sampleVehicleAt == vehicleAt && abs(vehicleAt - at) <= 90_000
        return RawEvidence(charging: integer(sample["charging"]) ?? -1,
                           code: boundedText(sample["chargeCode"], limit: 32) ?? "",
                           source: boundedText(sample["chargeSource"], limit: 16) ?? "",
                           lock: vehicleOwned ? (integer(snapshot["lock"]) ?? -1) : -1,
                           vehicleOwned: vehicleOwned)
    }

    private func reduce(_ ledger: String, event: Object, owner: Owner, now: Int64) throws -> String {
        var bound = event
        owner.shared.forEach { bound[$0.key] = $0.value }
        let reduced = SharedChargeLog().reduceJSON(ledgerJSON: ledger, eventJSON: try jsonString(bound), now: now)
        return try validatedLedger(reduced, owner: owner).value
    }

    // 记住本次落盘水位，供下一次 record 的廉价准入使用。
    // raw 为 nil 时不等于清空证据：只要「账号、最后一条采样、revision 都没变」，
    // 说明文件内容与上次记录证据时一致，旧证据仍然成立，继续复用（否则一次 history.battery
    // 就会把证据洗掉，随后的 record 又退回全量读盘）。
    private func remember(_ state: StoreState, owner: Owner, raw: RawEvidence?, dropped: Int,
                          droppedSessions: Int) {
        let snapshot = (try? sharedObject(state.snapshot)) ?? [:]
        let ledger = (try? sharedObject(state.ledger)) ?? [:]
        remember(owner: owner, snapshot: snapshot, ledger: ledger, revision: state.revision,
                 raw: raw, dropped: dropped, droppedSessions: droppedSessions)
    }

    // 读盘路径已经在手里有解析好的对象，再序列化+解析一次 16MB 快照是纯浪费；
    // 所以单独留一个接收对象的入口（④ 的意义在于不要为了一件小事全量读盘）。
    private func remember(owner: Owner, snapshot: Object, ledger: Object, revision: Int64,
                          raw: RawEvidence?, dropped: Int, droppedSessions: Int) {
        let pointAt = (snapshot["records"] as? [Object])?.last.flatMap { integer($0["t"]) } ?? 0
        let keptRaw: RawEvidence?
        if let raw = raw {
            keptRaw = raw
        } else if let old = hint, old.owner == owner.stableID,
                  old.pointAt == pointAt, old.revision == revision {
            keptRaw = old.raw
        } else {
            keptRaw = nil
        }
        hint = WriteHint(owner: owner.stableID, pointAt: pointAt,
                         ledgerAt: integer(ledger["at"]) ?? 0,
                         clearAt: integer(ledger["clearAt"]) ?? 0,
                         dropped: dropped, droppedSessions: droppedSessions,
                         revision: revision, raw: keptRaw)
    }

    private func batteryResponse(_ state: StoreState, _ range: String, _ request: Request) throws -> Object {
        // 报表刻意用真实墙上时钟：① 抬升时钟只是让「未来点」通过 KMP 的严格校验，
        // 它们仍不该出现在 24h/3d 等窗口里（buildReport 会按 valid(now) 自行跳过）。
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
        // ⑦ 只回一份：public/js/app/shell.js 读的是 `reply.report || reply`，顶层不再展开同样的
        // report 字段，否则 IPC 体积凭空翻倍（电池点最多约 1MB）。
        var result: Object = ["report": report, "storageRevision": state.revision]
        return result
    }

    private func chargeResponse(_ state: StoreState, _ request: Request, dropped: Int = 0) throws -> Object {
        // hydrate 对每条样本都做 valid(now) 严格校验，用真实墙上时钟时「未来点」会让整份账本
        // 抛 invalid_history（这正是 ① 的读不出问题）。所以必须沿用读盘抬升过的时钟：
        // 这些点本来就是时钟偏快时写下的真实数据，只是它们的绝对时间比现在早不到一小时之外，
        // 暂时出现在账本尾部比整份读不出更好。
        let now = max(nowMillis(), state.clock)
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
        history["droppedPoints"] = dropped
        // 完整原生后台健康度/估算修复本轮并未实现，不能用接口存在宣称支持。
        history["healthEstimator"] = "not-implemented"
        // ⑦ 网页读 `reply.history || reply`（public/js/app.js），所以只保留 history 一份。
        // 不再把同一对象的字段展开到顶层：那会让「充电账本约 1MB」的回执直接翻成 2MB。
        var result: Object = ["history": history, "storageRevision": state.revision]
        return result
    }

    // MARK: - 原生清除确认与持久化墓碑

    private func presentClear(_ request: Request, _ arguments: Object, _ loaded: Loaded, _ target: String) {
        precondition(Thread.isMainThread)
        guard isCurrent(request) else { finish(request, error: "history_scope_changed"); return }
        guard prompt == nil, let controller = presenterProvider?(), controller.viewIfLoaded?.window != nil,
              controller.presentedViewController == nil else { finish(request, error: "history_presenter_unavailable"); return }
        let destructiveAll = target != "charge" || loaded.readError != nil
        // TODO(文案)：迁入 IOSStrings.historyClearTitleAll / historyClearTitleCharge。
        let title = destructiveAll ? "清除本车本地历史？" : "清除本车充电记录？"
        // TODO(文案)：迁入 IOSStrings.historyClearMessageUnreadable / historyClearMessageAll / historyClearMessageCharge。
        let message = loaded.readError != nil
            ? "这份本地历史无法读取。不会自动覆盖原文件；只有在你确认后，才会删除损坏的历史内容并保存新的清除水位。此操作无法撤销。"
            : destructiveAll
                ? "只清除当前账号、当前车辆的电池采样和充电记录，并保存清除水位。不影响其他账号或车辆，也不会向服务器发送删除请求。此操作无法撤销。"
                : "只清除当前账号、当前车辆的充电记录，并保存清除水位。电池采样仍保留，不影响其他账号或车辆，也不会向服务器发送删除请求。此操作无法撤销。"
        let clear = ClearPrompt(request, arguments, loaded, destructiveAll ? "all" : target)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        clear.alert = alert; prompt = clear
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak clear] _ in
            guard let self = self, let clear = clear, self.prompt === clear else { return }
            clear.timer?.cancel(); self.prompt = nil
            self.finish(request, error: "history_clear_cancelled")
        })
        // 破坏性动作的按钮文字是“清除”而不是通用的“确定”，保留内联并记 TODO。
        // TODO(文案)：迁入 IOSStrings.historyClearConfirm。
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self, weak clear] _ in
            guard let self = self, let clear = clear, self.prompt === clear else { return }
            clear.timer?.cancel(); self.prompt = nil
            guard self.isCurrent(request) else { self.finish(request, error: "history_scope_changed"); return }
            guard self.queuedWork < Limit.pending else { self.finish(request, error: "history_queue_full"); return }
            self.queuedWork += 1
            self.worker.async { [self] in
                // 嵌套闭包里即使已 [self] 捕获，Swift 6 仍要求显式 self. 才明确捕获语义。
                defer { DispatchQueue.main.async { [self] in self.queuedWork -= 1 } }
                autoreleasepool {
                    do { try self.commitClear(clear) }
                    catch {
                        self.lastWriteError = self.code(error); self.lastWriteOwner = request.owner.stableID
                        self.complete(request, nil, self.code(error))
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
        // 沿用本次读盘抬升过的时钟：文件里若有未来点，restore 会把它当合法数据保留，
        // 否则清 charge 的路径会先被 KMP 判成 invalid_history，清空反而失败。
        let clock = actual.effectiveNow
        let previous: StoreState
        if let saved = actual.state { previous = saved }
        else { previous = try emptyState(request.owner, now: clock) }
        let ledger = try reduce(previous.ledger, event: ["type": "clear"], owner: request.owner, now: clock)
        let battery: SharedBattery
        let snapshot: String
        if clear.target == "charge" {
            battery = previous.battery; snapshot = previous.snapshot
        } else {
            battery = SharedBattery()
            _ = try sharedObject(battery.restoreJSON(json: previous.snapshot, now: clock))
            battery.clear()
            // SharedBattery.clear 解除VIN绑定；恢复同hash空状态，不在Swift实现裁剪或记账。
            var empty = try sharedObject(battery.snapshotJSON())
            empty["vin"] = request.owner.stableID
            _ = try sharedObject(battery.restoreJSON(json: try jsonString(empty), now: clock))
            snapshot = battery.snapshotJSON()
        }
        let candidate = StoreState(battery: battery, snapshot: snapshot, ledger: ledger,
                                   revision: try nextRevision(previous.revision, max(now, clock)), clock: clock)
        let durable: Bool
        do {
            durable = try save(candidate, request: request, expectedFingerprint: actual.fingerprint, existed: actual.exists)
            lastWriteError = nil; lastWriteOwner = request.owner.stableID
        } catch {
            lastWriteError = code(error); lastWriteOwner = request.owner.stableID
            lastError = code(error)
            throw error
        }
        var response = try chargeResponse(candidate, request, dropped: actual.droppedPoints)
        response["cleared"] = true; response["target"] = clear.target; response["persisted"] = true
        response["durable"] = durable
        response["status"] = status(Loaded(state: candidate, fingerprint: nil, exists: true, readError: nil,
                                           droppedPoints: actual.droppedPoints, droppedSessions: actual.droppedSessions,
                                           owners: actual.owners, effectiveNow: clock), request)
        remember(candidate, owner: request.owner, raw: nil, dropped: actual.droppedPoints,
                 droppedSessions: actual.droppedSessions)
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
        // ③ 崩溃遗留的临时文件（save 的 defer 只删自己刚建的那个）会一直占着 208MB 预算，
        // 攒满后 history_directory_full 就成了所有写入的固定错误。清扫必须在预算统计之前完成；
        // 只删「老于 1 小时 + 名字以点开头且含 .tmp」的文件，不动损坏原件（*.json）和他人文件。
        sweepStaleTemporaryFiles(directory)
        return directory
    }

    private func sweepStaleTemporaryFiles(_ directory: URL) {
        dispatchPrecondition(condition: .onQueue(worker))
        // 每次 load/save 前都列目录代价太大；同一分钟内的读盘共用一次清扫结果。
        let now = Date()
        if let last = lastSweepAt, now.timeIntervalSince(last) < 60 { return }
        lastSweepAt = now
        // 有界清扫：超大目录也只检查前 sweepEntries 项，避免读盘被清扫拖住。
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(Limit.staleTemporarySeconds))
        for entry in entries.prefix(Limit.sweepEntries) {
            let name = entry.lastPathComponent
            guard name.hasPrefix("."), name.contains(".tmp") else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            guard modified < cutoff else { continue }
            // unlink 而不是 FileManager.removeItem：后者会跟随符号链接删到目标。
            _ = entry.path.withCString { Darwin.unlink($0) }
        }
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
        // ⑨ 目录上限是固定的；这里顺手数一下已有的 owner 文件，仅用于 status 暴露水位。
        let owners = ownerFileCount(directory)
        let data: Data?
        do { data = try readFile(file) }
        catch {
            return Loaded(state: nil, fingerprint: nil, exists: true, readError: code(error),
                          droppedPoints: 0, droppedSessions: 0, owners: owners, effectiveNow: now)
        }
        guard let bytes = data else {
            return Loaded(state: try emptyState(owner, now: now), fingerprint: nil, exists: false, readError: nil,
                          droppedPoints: 0, droppedSessions: 0, owners: owners, effectiveNow: now)
        }
        let fingerprint = digest(bytes)
        do {
            // 结构性损坏才整体判坏：顶层字段、owner、版本。逐点/逐段的问题在下面收集后丢弃。
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? Object,
                  integer(root["version"]) == 1, root["ownerStableId"] as? String == owner.stableID,
                  let revision = integer(root["storageRevision"]), revision >= 0,
                  let rawBattery = root["battery"] as? Object, let rawLedger = root["ledger"] as? Object else {
                throw Failure("history_invalid_file")
            }
            // ① 系统时钟被回拨时，文件里的点可能“在未来”。它们本来是时钟偏快时写下的真实数据，
            // 不该让整份历史永久读不出，也不该因此拒绝后续写入。做法是把 restore/hydrate 用的 now
            // 抬到「文件内最大时间戳 + 1」：这些点会被 KMP 当成合法数据接受，只是暂时落在报表窗口
            // 之外（等墙上时钟追上又会自然出现）。
            // 取舍：只修补“未来”这一种时钟问题。单条 t 非法（<=0、重复、乱序、非整数）仍然按坏点
            // 丢弃（见下面 sanitize*），不会因为抬升时钟而混进历史。
            let clock = elevatedClock(now, battery: rawBattery, ledger: rawLedger)
            let battery = try sanitizeSnapshot(rawBattery, owner: owner, now: clock)
            let ledger = try sanitizeLedger(rawLedger, owner: owner)
            // 校验通过的部分才交给 KMP；KMP 的 restore/hydrate 仍是严格校验，
            // 所以坏点必须在传进去之前就过滤掉，否则它会把整份数据判成 invalid_history。
            let batteryJSON = battery.value
            let ledgerJSON = ledger.value
            let restored = SharedBattery()
            _ = try sharedObject(restored.restoreJSON(json: batteryJSON, now: clock))
            // hydrate 同时验证账本和全部真实样本；脏点已剔除，因此这里只会暴露真正的结构问题。
            _ = try sharedObject(SharedChargeLog().hydrateJSON(ledgerJSON: ledgerJSON, samplesJSON: batteryJSON, now: clock))
            let state = StoreState(battery: restored, snapshot: restored.snapshotJSON(), ledger: ledgerJSON,
                                   revision: revision, clock: clock)
            // ④ 播种廉价准入水位。raw 先留 nil（读盘时不知道最后一条点的原始证据），
            // 下一次电池采样记录成功后会被替换成真实证据。
            remember(owner: owner, snapshot: battery.object, ledger: ledger.object, revision: revision,
                     raw: nil, dropped: battery.dropped, droppedSessions: ledger.dropped)
            return Loaded(state: state, fingerprint: fingerprint, exists: true, readError: nil,
                          droppedPoints: battery.dropped, droppedSessions: ledger.dropped,
                          owners: owners, effectiveNow: clock)
        } catch {
            // 读盘失败时旧 hint 不可信（文件可能刚被改坏），清掉让下一次 record 走完整路径。
            if hint?.owner == owner.stableID { hint = nil }
            return Loaded(state: nil, fingerprint: fingerprint, exists: true, readError: code(error),
                          droppedPoints: 0, droppedSessions: 0, owners: owners, effectiveNow: now)
        }
    }

    // ① 把 restore/hydrate 的 now 抬到「文件内最大时间戳 + 1」。
    // 有界的原因：如果无限制地跟随文件里的最大 t，一条字节损坏（例如 t 被写成 2099 年）
    // 就会让 now 跳到百年后，restore 的 31 天窗口会把全部真实历史滤掉，下次保存就把文件写空——
    // 那比“读不出”更糟。所以超过一年的“未来”判定为损坏，不参与抬升，稍后按坏点丢弃并计入 dropped。
    private func elevatedClock(_ now: Int64, battery: Object, ledger: Object) -> Int64 {
        var maxT = now
        for point in (battery["records"] as? [Object]) ?? [] {
            // t 无法解析、非正数、或超前超过一年：都不参与抬升，由 sanitizeSnapshot 当坏点丢弃。
            guard let t = integer(point["t"]), t > 0, t - now <= Limit.maxFutureSkewMs else { continue }
            maxT = max(maxT, t)
        }
        // 账本只含会话边界，同样可能落在未来；只取不超过上限的时间。
        for segment in (ledger["segments"] as? [Object]) ?? [] {
            for key in ["from", "to"] {
                guard let t = integer(segment[key]), t > 0, t - now <= Limit.maxFutureSkewMs else { continue }
                maxT = max(maxT, t)
            }
        }
        if let current = ledger["current"] as? Object, let t = integer(current["from"]),
           t > 0, t - now <= Limit.maxFutureSkewMs { maxT = max(maxT, t) }
        // 只有真的存在超前点才加 1，避免普通文件把 now 抬到未来。
        return maxT > now ? maxT + 1 : now
    }

    private func ownerFileCount(_ directory: URL) -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return ownerFileCount(contents)
    }

    // owner 文件名是 64 位 hex + .json；只有这种文件计入 12 个上限，临时文件/损坏副本不算。
    private func ownerFileCount(_ contents: [URL]) -> Int {
        contents.filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64 }.count
    }

    private func emptyState(_ owner: Owner, now: Int64) throws -> StoreState {
        let battery = SharedBattery()
        let input: Object = ["ok": true, "version": 4, "vin": owner.stableID, "revision": 0, "records": [Any]()]
        _ = try sharedObject(battery.restoreJSON(json: try jsonString(input), now: now))
        let ledger = SharedChargeLog().createJSON(ownerJSON: try jsonString(owner.shared))
        _ = try validatedLedger(ledger, owner: owner)
        return StoreState(battery: battery, snapshot: battery.snapshotJSON(), ledger: ledger, revision: 0, clock: now)
    }

    // 返回 durable：rename 已成功且目录 fsync 也确认时为 true；rename 成功但 fsync 失败时
    // 回读比对内容后仍算成功，只是 durable=false（⑧）。
    @discardableResult
    private func save(_ state: StoreState, request: Request, expectedFingerprint: String?, existed: Bool) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(worker))
        // 严格校验：本进程产出的数据不该有坏点，有就是 bug，直接失败而不是静默写残。
        let snapshot = try validatedSnapshot(state.snapshot, owner: request.owner, now: state.clock)
        let ledger = try validatedLedger(state.ledger, owner: request.owner).object
        let root: Object = ["version": 1, "ownerStableId": request.owner.stableID,
                            "storageRevision": state.revision, "battery": snapshot, "ledger": ledger]
        let bytes = try jsonData(root)
        guard bytes.count <= Limit.fileBytes else { throw Failure("history_file_full") }
        let directory = try historyDirectory()
        let file = historyFile(request.owner, in: directory)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // ⑨ 计数与 status.ownerCount 共用同一个判定（64 位 hex + .json），避免两处口径漂移。
        let ownerFiles = ownerFileCount(contents)
        if !existed && ownerFiles >= Limit.owners {
            throw Failure("history_owner_limit")
        }
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
        guard directoryFD >= 0 else { return try commitConfirmed(file, bytes) }
        defer { _ = Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else {
            // ⑧ rename 大概率已经落盘，只是目录 fsync 没确认。旧实现直接报失败，
            // 用户看到「清除失败」其实已清掉，会再点一次。这里回读文件比对内容：
            // 内容一致就当成功（durable=false 只是告警），对不上才真的失败。
            return try commitConfirmed(file, bytes)
        }
        return true
    }

    // 目录 fsync 未确认时，回读目标文件核对是否已经是本次要写的内容。
    // 内容一致 = rename 已生效，可以当成功；不一致/读不出 = 真的没写成。
    private func commitConfirmed(_ file: URL, _ bytes: Data) throws -> Bool {
        guard let current = try? readFile(file), let currentBytes = current else {
            throw Failure("history_durability_unconfirmed")
        }
        guard currentBytes == bytes else { throw Failure("history_durability_unconfirmed") }
        return false
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
            "writeError": write.map { $0 as Any } ?? NSNull(),
            // ⑨ owner 上限这类失败只会体现在这里；有值时才返回，避免网页判断空串。
            "lastError": lastError.isEmpty ? NSNull() : lastError,
            "persisted": loaded.exists && loaded.readError == nil,
            "storageRevision": loaded.state.map { $0.revision as Any } ?? NSNull(),
            "clearAt": ledger?["clearAt"] ?? NSNull(), "revision": ledger?["revision"] ?? NSNull(),
            "retentionDays": 31, "maxRecords": Limit.records, "maxFileBytes": Limit.fileBytes,
            "maxOwners": Limit.owners, "maxDiskBytes": Limit.diskBytes,
            // ⑨ 12 个 owner 上限按 (账号, VIN) 计数，网页却允许 20 个账号；撞上限时
            // record 会静默失败，所以这里把「已达上限」和已用数量都摊开给界面看。
            "ownerCount": loaded.owners, "atOwnerLimit": loaded.owners >= Limit.owners,
            "metadata": metadata(request), "initialized": true,
            "algorithm": "KMP-SharedBattery-SharedChargeLog", "healthEstimator": "not-implemented",
            "backgroundHealth": false, "interpolation": false]
        // ② 丢弃的坏点必须显式暴露，否则用户只会看到「记录变少了」而不知道原因。
        result["droppedPoints"] = loaded.droppedPoints
        result["droppedSessions"] = loaded.droppedSessions
        result["ledgerState"] = ledger?["state"] ?? NSNull()
        return result
    }

    private func writeError(_ owner: Owner) -> String? { lastWriteOwner == owner.stableID ? lastWriteError : nil }

    // MARK: - JSON 边界（仅字段校验/映射，不复制电池或记账算法）

    // ② 读盘路径的容错校验：只把结构性损坏（顶层字段、owner、版本）当致命，
    // 逐点问题收集成 dropped 后丢弃。KMP 的 restore/hydrate 是严格校验，
    // 所以必须在进 KMP 之前就把坏点删掉，不能指望它自己忽略。
    private func sanitizeSnapshot(_ raw: Object, owner: Owner, now: Int64) throws -> Sanitized {
        guard integer(raw["version"]) == 4, raw["vin"] as? String == owner.stableID,
              integer(raw["revision"]).map({ $0 >= 0 }) == true else {
            throw Failure("history_invalid_shared_snapshot")
        }
        let allowed: Set<String> = ["ok", "version", "vin", "revision", "records"]
        guard Set(raw.keys).isSubset(of: allowed) else { throw Failure("history_invalid_shared_snapshot") }
        // ④ 键集合提到循环外：1.8 万点若每个点新建一个 Set，光集合分配就是明显开销。
        let pointKeys: Set<String> = ["t", "soc", "v", "a", "w", "state", "pwr", "odo", "cf", "temp"]
        var dropped = 0
        var kept: [Object] = []
        var previous = 0 as Int64
        // records 不是数组属于结构性损坏（容器类型错），元素坏才是可丢弃的点。
        guard let entries = raw["records"] as? [Any] else { throw Failure("history_invalid_shared_snapshot") }
        for point in entries {
            // t 必须严格递增：KMP restore 对乱序/重复直接判 invalid_history，
            // 而重复时间戳在报表里也只会被 distinctBy 丢掉，先在这里清掉并计入 dropped。
            guard let object = point as? Object, validPoint(object, keys: pointKeys),
                  let t = integer(object["t"]), t > previous, t <= now else {
                dropped += 1; continue
            }
            previous = t; kept.append(object)
        }
        // 超出 KMP 的 10 万点上限时按时间保留最新的，避免 restore 抛 history_too_many_points。
        if kept.count > Limit.records {
            dropped += kept.count - Limit.records
            kept.removeFirst(kept.count - Limit.records)
        }
        var object = raw
        object["records"] = kept
        return Sanitized(object: object, value: try jsonString(object), dropped: dropped)
    }

    // 单点是否可用。判定标准刻意与 KMP 的 BatteryRecord.valid() 对齐而不更严：
    // 只有「会让 restore 整份抛 invalid_history」的字段才拒绝，其余可选值（odo/cf 的 -1 哨兵、
    // state=-1 表示未知）都是合法数据，不能因为“看起来怪”就丢掉用户真实采样。
    private func validPoint(_ point: Object, keys: Set<String>) -> Bool {
        guard Set(point.keys).isSubset(of: keys),
              point.values.allSatisfy({ number($0) != nil }),
              let t = integer(point["t"]), t > 0,
              // complete(soc, v, a)：soc 0...100、电压有限且非负、电流有限。
              let soc = integer(point["soc"]), (0...100).contains(soc),
              let v = number(point["v"]), v.isFinite, v >= 0,
              let a = number(point["a"]), a.isFinite,
              let w = number(point["w"]), w.isFinite else { return false }
        return true
    }

    private func sanitizeLedger(_ raw: Object, owner: Owner) throws -> Sanitized {
        // 版本/owner/水位是账本结构本身，坏了就不是「某个会话脏」而是整份不可用。
        guard integer(raw["version"]) == 3, raw["ownerId"] as? String == owner.stableID,
              raw["vin"] as? String == owner.stableID, raw["ownerUid"] as? String == "",
              integer(raw["revision"]).map({ $0 >= 0 }) == true,
              let clearAt = integer(raw["clearAt"]), clearAt >= 0,
              let at = integer(raw["at"]), at >= clearAt,
              let state = integer(raw["state"]), (-1...2).contains(state) else {
            throw Failure("history_invalid_shared_ledger")
        }
        let allowed: Set<String> = ["ok", "version", "ownerId", "ownerUid", "vin", "revision", "clearAt", "at",
                                    "state", "current", "segments", "legacy"]
        guard Set(raw.keys).isSubset(of: allowed) else { throw Failure("history_invalid_shared_ledger") }
        // legacy 是 KMP 的旧会话格式，本服务从不写它；非空说明文件被别的版本动过，按结构损坏处理。
        guard (raw["legacy"] as? [Any])?.isEmpty == true else { throw Failure("history_invalid_shared_ledger") }
        var dropped = 0
        var segments: [Object] = []
        guard let entries = raw["segments"] as? [Any] else { throw Failure("history_invalid_shared_ledger") }
        for entry in entries {
            guard let segment = entry as? Object, Set(segment.keys).isSubset(of: ["id", "from", "to"]),
                  boundedText(segment["id"], limit: 200) != nil,
                  let from = integer(segment["from"]), from > 0,
                  let to = integer(segment["to"]), to >= from else {
                dropped += 1; continue
            }
            segments.append(segment)
        }
        // 超出上限按结束时间丢最旧，和 KMP retainNewest 的口径一致。
        if segments.count > Limit.sessions {
            dropped += segments.count - Limit.sessions
            segments.sort { (integer($0["to"]) ?? 0) > (integer($1["to"]) ?? 0) }
            segments.removeLast(segments.count - Limit.sessions)
        }
        var current: Any = NSNull()
        if let value = raw["current"] as? Object {
            if Set(value.keys).isSubset(of: ["id", "from"]), boundedText(value["id"], limit: 200) != nil,
               let from = integer(value["from"]), from > clearAt, from <= at {
                current = value
            } else {
                // current 坏掉但 state == 1 时 KMP 会要求 current 存在；把状态降成未知比整份不可读好。
                dropped += 1
            }
        } else if !(raw["current"] is NSNull) {
            dropped += 1
        }
        var object = raw
        var nextState = state
        if nextState == 1 && current is NSNull { nextState = -1 }
        if nextState != 1 && !(current is NSNull) { current = NSNull() }
        object["segments"] = segments
        object["current"] = current
        object["state"] = nextState
        return Sanitized(object: object, value: try jsonString(object), dropped: dropped)
    }

    // 写盘路径仍用严格校验：这里的数据是本进程产出的，不该有坏点；
    // 一旦有就是代码 bug，宁可直接失败也不要静默把数据写残。
    private func validatedSnapshot(_ value: String, owner: Owner, now: Int64) throws -> Object {
        let object = try sharedObject(value)
        let sanitized = try sanitizeSnapshot(object, owner: owner, now: now)
        guard sanitized.dropped == 0 else { throw Failure("history_invalid_shared_snapshot") }
        return object
    }

    private func validatedLedger(_ value: String, owner: Owner) throws -> Sanitized {
        let object = try sharedObject(value)
        let sanitized = try sanitizeLedger(object, owner: owner)
        guard sanitized.dropped == 0 else { throw Failure("history_invalid_shared_ledger") }
        return sanitized
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
