import Foundation
import CryptoKit
import CoreFoundation
import Security

// 全部时间为 monotonic uptime 秒；初始窗口可以尚未认证，但绝不据它接收遥测。
struct IOSSessionRenewalLease {
    let recordingID: UUID
    let scope: IOSRideScope
    let connectionGeneration: String
    let authorizedAt: Double
    let authorizedUntil: Double
    let nativeAuthenticated: Bool
    init(recordingID: UUID, scope: IOSRideScope, connectionGeneration: String,
         authorizedAt: Double, authorizedUntil: Double, nativeAuthenticated: Bool = false) {
        self.recordingID = recordingID; self.scope = scope; self.connectionGeneration = connectionGeneration
        self.authorizedAt = authorizedAt; self.authorizedUntil = authorizedUntil
        self.nativeAuthenticated = nativeAuthenticated
    }
}
struct IOSSessionRenewalMaterial {
    let requestIndex: Int
    let path: [String]
    let handle: String
    let type: String
}
struct IOSSessionRenewalMaterialChange {
    let recordingID: UUID
    let scope: IOSRideScope
    let previousConnectionGeneration: String
    let materials: [IOSSessionRenewalMaterial]
    let reauthenticationRecipe: [String: Any]
    let reason: String
    init(recordingID: UUID, scope: IOSRideScope, previousConnectionGeneration: String,
         materials: [IOSSessionRenewalMaterial], reauthenticationRecipe: [String: Any],
         reason: String = "material_changed") {
        self.recordingID = recordingID; self.scope = scope; self.previousConnectionGeneration = previousConnectionGeneration
        self.materials = materials; self.reauthenticationRecipe = reauthenticationRecipe; self.reason = reason
    }
}
private struct IOSSessionRenewalFailure: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

// 通用 signed GET + literal/path/opaque baseline 验证器。协议字段和握手步骤只由私有面板提供。
// 不用网页存档的到期时间授权，不运行 JS，不把云响应/密钥交给网页或系统展示存储。
final class IOSSessionRenewalService: IOSBridgeCancellableService {
    typealias ConsentProvider = (UUID, IOSRideScope, @escaping (Bool) -> Void) -> (() -> Void)
    typealias MaterialChangedProvider = (IOSSessionRenewalMaterialChange, @escaping (IOSSessionRenewalLease?) -> Void) -> Void
    let methods = ["session.renew.prepare", "session.renew.poll", "session.renew.cancel"]
    private static let interval: Double = 240
    private static let validity: Double = 300
    private let secrets: IOSSecretHandleService
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.session.renew", qos: .userInitiated)
    private var scopeProvider: (() -> IOSRideScope?)?
    private var metadataProvider: (() -> [String: Any]?)?
    private var recordingProvider: (() -> IOSSessionRenewalLease?)?
    private var consentProvider: ConsentProvider?
    private var didRenew: ((UUID, IOSRideScope, String, Double) -> Bool)?
    private var authorizationExpired: ((UUID, IOSRideScope, String, String) -> Void)?
    private var materialChanged: MaterialChangedProvider?
    private var run: Run?
    // deinit 兜底登记表：deinit 可能在任意线程，而 run 及其 timer 槽位是主线程专属状态
    // （全文件 precondition(Thread.isMainThread)），deinit 里直接读是数据竞争；且 Swift
    // 对象一旦进入析构就不能再被安全引用（在 deinit 里捕获 self 留待稍后使用是未定义
    // 行为）。改为只在主线程的唯一赋值点（prepare 的 run = held）把 Run 登记到这张类级
    // 表（NSLock 保护，任意线程可存取），deinit 从表里取走再派发主队列取消。表项生命
    // 周期与 run 属性一致：被 stop() 收尾过的 Run 三个槽位已清空，再取消是空操作，
    // 不改变任何语义。
    private static let abandonedRunsLock = NSLock()
    private static var abandonedRuns: [ObjectIdentifier: Run] = [:]
    private var page = 0

    private final class Run {
        let id: UUID
        let scope: IOSRideScope
        var connection: String
        var expiry: Double
        var refreshedAt: Double
        var consentUntil: Double = 0
        var recipe: IOSRenewalRecipe
        var phase = "awaiting_consent"
        var reason = ""
        var consented = false
        var active = false
        var nativeAuthenticated = false
        var recipeComplete = false
        var inFlight = false
        var operation = UUID()
        var owned = false
        let page: Int
        var fetch: IOSRenewalFetch?
        var cancelConsent: (() -> Void)?
        var prepareReply: ((Any?, String?) -> Void)?
        var prepareTimeout: DispatchWorkItem?
        var operationTimeout: DispatchWorkItem?
        var newHandles = Set<String>()
        init(lease: IOSSessionRenewalLease, recipe: IOSRenewalRecipe, page: Int, reply: @escaping (Any?, String?) -> Void) {
            id = lease.recordingID; scope = lease.scope; connection = lease.connectionGeneration
            expiry = lease.authorizedUntil; refreshedAt = lease.authorizedAt
            self.recipe = recipe; self.page = page; prepareReply = reply
        }
    }
    init(secrets: IOSSecretHandleService) { self.secrets = secrets }
    deinit {
        // run 与三个 timer 槽位是主线程专属状态（全文件 precondition(Thread.isMainThread)），
        // 而 Swift 不保证 deinit 落在主线程——deinit 本体不再读任何实例属性（析构中的
        // 对象也不能被闭包安全捕获）。改从类级登记表（锁保护，任意线程可取）拿走最后一次
        // 登记的 Run；DispatchWorkItem.cancel / IOSRenewalFetch.cancel 本身线程安全，
        // 派发回主队列执行，与槽位的全部历史写入（都在主线程）建立先后关系。
        let token = ObjectIdentifier(self)
        IOSSessionRenewalService.abandonedRunsLock.lock()
        let abandoned = IOSSessionRenewalService.abandonedRuns.removeValue(forKey: token)
        IOSSessionRenewalService.abandonedRunsLock.unlock()
        DispatchQueue.main.async {
            abandoned?.fetch?.cancel(); abandoned?.prepareTimeout?.cancel(); abandoned?.operationTimeout?.cancel()
        }
    }
    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) { precondition(Thread.isMainThread); scopeProvider = provider }
    func configureSessionMetadataProvider(_ provider: @escaping () -> [String: Any]?) { precondition(Thread.isMainThread); metadataProvider = provider }
    func configureRecordingProvider(_ provider: @escaping () -> IOSSessionRenewalLease?) { precondition(Thread.isMainThread); recordingProvider = provider }
    func configureConsentProvider(_ provider: @escaping ConsentProvider) { precondition(Thread.isMainThread); consentProvider = provider }
    func configureDidRenew(_ provider: @escaping (UUID, IOSRideScope, String, Double) -> Bool) { precondition(Thread.isMainThread); didRenew = provider }
    func configureAuthorizationExpired(_ provider: @escaping (UUID, IOSRideScope, String, String) -> Void) { precondition(Thread.isMainThread); authorizationExpired = provider }
    func configureMaterialChanged(_ provider: @escaping MaterialChangedProvider) { precondition(Thread.isMainThread); materialChanged = provider }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count == 1, let options = args.first as? [String: Any],
              let scope = scopeProvider?(), let metadata = metadataProvider?(),
              IOSSecretHandleService.accepts(options, metadata: metadata, scope: scope),
              let idText = options["recordingId"] as? String, let id = UUID(uuidString: idText) else { reply(nil, "stale_session"); return }
        if method == "session.renew.prepare" { prepare(options, scope: scope, id: id, reply: reply); return }
        guard Set(options.keys).isSubset(of: ["navigationId", "epoch", "frame", "recordingId"]),
              let held = run, held.id == id, held.scope == scope else { reply(nil, "unknown_recording"); return }
        if method == "session.renew.cancel" {
            stop(held, reason: "user_cancelled"); reply(snapshot(held), nil)
        } else if method == "session.renew.poll" {
            _ = admitted(held); reply(snapshot(held), nil)
        } else { reply(nil, "unsupported_method") }
    }

    private func prepare(_ options: [String: Any], scope: IOSRideScope, id: UUID, reply: @escaping (Any?, String?) -> Void) {
        guard run == nil || run?.phase == "cancelled" || run?.phase == "expired",
              Set(options.keys).isSubset(of: ["navigationId", "epoch", "frame", "recordingId", "signerHandle", "tokenHandle", "recipe"]),
              let lease = recordingProvider?(), lease.recordingID == id, lease.scope == scope, validWindow(lease),
              let consent = consentProvider else { reply(nil, "native_recording_required"); return }
        guard materialChanged != nil, didRenew != nil, authorizationExpired != nil else {
            reply(["ok": false, "state": "reauthentication_required", "reason": "native_renewal_provider_unavailable",
                   "recordingId": id.uuidString, "active": false, "attachedNative": true, "consented": false,
                   "recipeComplete": false, "authorizationFresh": false, "nativeAuthenticated": false,
                   "canAcceptTelemetry": false, "backgroundAuthRenewalSupported": false], nil); return
        }
        do {
            let recipe = try IOSRenewalRecipe.parse(options, secrets: secrets, scope: scope)
            let held = Run(lease: lease, recipe: recipe, page: page, reply: reply)
            run = held
            // 同步登记到 deinit 兜底表（见 abandonedRuns 注释）。旧 run 若存在，必然已经
            // stop()（只有 phase 为 cancelled/expired 才允许重新 prepare），槽位已清空，
            // 直接覆盖登记即可。
            IOSSessionRenewalService.abandonedRunsLock.lock()
            IOSSessionRenewalService.abandonedRuns[ObjectIdentifier(self)] = held
            IOSSessionRenewalService.abandonedRunsLock.unlock()
            let timeout = DispatchWorkItem { [weak self, weak held] in
                guard let self = self, let held = held, self.run === held, held.prepareReply != nil else { return }
                self.stop(held, reason: "prepare_timeout")
            }
            held.prepareTimeout = timeout
            let preparationBudget = max(0, min(300, held.expiry - ProcessInfo.processInfo.systemUptime))
            DispatchQueue.main.asyncAfter(deadline: .now() + preparationBudget, execute: timeout)
            let cancel = consent(id, scope) { [weak self, weak held] approved in
                let finish = { [weak self, weak held] in
                    guard let self = self, let held = held, self.run === held, held.phase == "awaiting_consent" else { return }
                    held.cancelConsent = nil
                    guard approved, self.current(held), self.page == held.page,
                          ProcessInfo.processInfo.systemUptime < held.expiry else { self.stop(held, reason: approved ? "stale_session" : "user_cancelled"); return }
                    do {
                        held.consentUntil = ProcessInfo.processInfo.systemUptime + IOSSecretHandleService.recordingTTL
                        try self.secrets.bindRecording(handles: held.recipe.handles, scope: held.scope,
                                                       recordingID: held.id, consentUntil: held.consentUntil,
                                                       replacementMaterials: held.recipe.materialHandles)
                        held.owned = true; held.consented = true; held.phase = "initializing"
                        // 首次真实云核验立即执行，不等四分钟，更不把 JS 已认证布尔值当原生授权。
                        self.fetch(held, initial: true)
                    } catch { self.stop(held, reason: (error as? IOSSecretHandleFailure)?.code ?? "secret_failed") }
                }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
            }
            if held.phase == "awaiting_consent" { held.cancelConsent = cancel }
        } catch { reply(nil, (error as? IOSSessionRenewalFailure)?.code ?? (error as? IOSSecretHandleFailure)?.code ?? "invalid_renewal_recipe") }
    }

    // 主机只能在真实 run 的生命周期调用；网页没有 activate RPC。
    @discardableResult func activate(recordingId: UUID) -> Bool {
        precondition(Thread.isMainThread)
        guard let held = run, held.id == recordingId, held.owned, held.consented, current(held) else { return false }
        return admitted(held)
    }
    // 从 BLE notify / Ride 样本接纳前触发，后台不依赖 Timer 能否被系统调度。
    // false 必须让调用方暂停 admission；仅保持 GATT 连接不等于新鲜授权。
    @discardableResult func observe(recordingId: UUID, scope: IOSRideScope, connectionGeneration: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let held = run, held.id == recordingId, held.scope == scope, held.connection == connectionGeneration else { return false }
        guard admitted(held) else { return false }
        if !held.inFlight, ProcessInfo.processInfo.systemUptime - held.refreshedAt >= Self.interval { fetch(held, initial: false) }
        return admitted(held)
    }
    func recordingEnded(recordingId: UUID) {
        precondition(Thread.isMainThread)
        if let held = run, held.id == recordingId { stop(held, reason: "recording_ended") }
        secrets.recordingEnded(recordingId: recordingId)
    }
    func scopeChanged() {
        precondition(Thread.isMainThread)
        if let held = run, !current(held) { stop(held, reason: "stale_session") }
        secrets.scopeChanged()
    }
    func navigationChanged() {
        precondition(Thread.isMainThread); page += 1
        guard let held = run else { return }
        // 同 owner/epoch 的已批准、实际在跑录制可以跨页面；仅准备中的 UI/请求不能交接。
        if held.owned && held.active && held.prepareReply == nil && current(held) { return }
        stop(held, reason: "stale_navigation")
    }
    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        guard let held = run else { return }
        if held.owned && held.active && held.prepareReply == nil && current(held) { return }
        stop(held, reason: "application_backgrounded")
    }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        guard method == "session.renew.prepare", let held = run, held.prepareReply != nil,
              let options = args.first as? [String: Any], let id = options["recordingId"] as? String,
              UUID(uuidString: id) == held.id else { return }
        stop(held, reason: "operation_cancelled")
    }

    private func invalidateLateLease(_ lease: IOSSessionRenewalLease?) {
        guard let lease = lease, let issued = recordingProvider?(), issued.recordingID == lease.recordingID,
              issued.scope == lease.scope, issued.connectionGeneration == lease.connectionGeneration,
              issued.authorizedAt == lease.authorizedAt, issued.authorizedUntil == lease.authorizedUntil else { return }
        authorizationExpired?(lease.recordingID, lease.scope, lease.connectionGeneration, "stale_renewal_result")
    }
    private func validWindow(_ lease: IOSSessionRenewalLease) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return lease.scope.valid && !lease.connectionGeneration.isEmpty && lease.connectionGeneration.utf8.count <= 128
            && lease.authorizedAt.isFinite && lease.authorizedUntil.isFinite && lease.authorizedAt <= now
            && lease.authorizedAt >= 0 && lease.authorizedUntil > now
            && lease.authorizedUntil - lease.authorizedAt <= Self.validity + 0.001
    }
    private func current(_ held: Run) -> Bool {
        guard run === held, scopeProvider?() == held.scope, let lease = recordingProvider?(),
              lease.recordingID == held.id, lease.scope == held.scope else { return false }
        return lease.connectionGeneration == held.connection
    }
    private func admitted(_ held: Run) -> Bool {
        guard held.active, held.nativeAuthenticated, held.phase == "active" else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard current(held), now < held.expiry, now < held.consentUntil,
              let lease = recordingProvider?(), lease.nativeAuthenticated, validWindow(lease),
              lease.authorizedUntil >= held.expiry - 0.001 else { stop(held, reason: current(held) ? "authorization_expired" : "stale_session"); return false }
        return true
    }
    private func snapshot(_ held: Run) -> [String: Any] {
        let lease = recordingProvider?()
        let fresh = held.active && held.nativeAuthenticated && current(held)
            && lease?.nativeAuthenticated == true && lease.map({ validWindow($0) && $0.authorizedUntil >= held.expiry - 0.001 }) == true
            && ProcessInfo.processInfo.systemUptime < held.expiry && ProcessInfo.processInfo.systemUptime < held.consentUntil
        return ["ok": held.phase != "expired" && held.phase != "cancelled", "state": held.phase, "reason": held.reason,
                "recordingId": held.id.uuidString, "active": fresh, "attachedNative": current(held),
                "connectionGeneration": fresh ? held.connection : "", "nativeAdmission": fresh,
                "inFlight": held.inFlight, "consented": held.consented, "recipeComplete": held.recipeComplete && fresh,
                "authorizationFresh": fresh, "nativeAuthenticated": fresh, "canAcceptTelemetry": fresh,
                "backgroundAuthRenewalSupported": fresh && materialChanged != nil && didRenew != nil && authorizationExpired != nil,
                "renewing": held.inFlight, "authorizationRemainingMs": fresh ? max(0, Int((held.expiry - ProcessInfo.processInfo.systemUptime) * 1000)) : 0]
    }
    private func completePrepare(_ held: Run) {
        held.prepareTimeout?.cancel(); held.prepareTimeout = nil
        let reply = held.prepareReply; held.prepareReply = nil
        reply?(snapshot(held), nil)
    }
    private func revoke(_ held: Run, reason: String) {
        held.active = false; held.nativeAuthenticated = false; held.recipeComplete = false
        // 在任何新材料/重握手 callback 前同步撤旧 lease，停止采样并发布 gap。
        authorizationExpired?(held.id, held.scope, held.connection, reason)
    }
    private func stop(_ held: Run, reason: String) {
        guard run === held, held.phase != "cancelled", held.phase != "expired" else { return }
        held.operation = UUID(); held.fetch?.cancel(); held.fetch = nil; held.inFlight = false
        held.operationTimeout?.cancel(); held.operationTimeout = nil
        let cancel = held.cancelConsent; held.cancelConsent = nil
        held.reason = reason; held.phase = reason == "user_cancelled" || reason == "recording_ended" ? "cancelled" : "expired"
        revoke(held, reason: reason)
        cancel?()
        secrets.recordingEnded(recordingId: held.id)
        if !held.owned { for handle in held.recipe.handles { try? secrets.release(handle: handle, scope: held.scope) } }
        held.newHandles.removeAll(); completePrepare(held)
    }
    private func fetch(_ held: Run, initial: Bool) {
        guard run === held, current(held), !held.inFlight, held.owned,
              ProcessInfo.processInfo.systemUptime < held.expiry,
              ProcessInfo.processInfo.systemUptime < held.consentUntil else { stop(held, reason: "authorization_expired"); return }
        held.inFlight = true; held.operation = UUID()
        let operation = held.operation
        // 这是有界操作 deadline，不是后台保活或周期续约承诺；notify 仍负责触发和即时闸门。
        let deadline = DispatchWorkItem { [weak self, weak held] in
            guard let self = self, let held = held, self.run === held, held.operation == operation, held.inFlight else { return }
            self.stop(held, reason: "authorization_expired")
        }
        held.operationTimeout?.cancel(); held.operationTimeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, min(held.expiry, held.consentUntil) - ProcessInfo.processInfo.systemUptime), execute: deadline)
        fetchRequest(held, operation: operation, initial: initial, index: 0, materials: [])
    }
    private final class FreshMaterial {
        let requestIndex: Int
        let path: [String]
        let baseline: String
        var value: Data
        let changed: Bool
        init(requestIndex: Int, path: [String], baseline: String, value: Data, changed: Bool) {
            self.requestIndex = requestIndex; self.path = path; self.baseline = baseline; self.value = value; self.changed = changed
        }
        deinit { value.resetBytes(in: 0..<value.count) }
    }
    private func freshCurrent(_ held: Run, operation: UUID) -> Bool {
        run === held && held.operation == operation && held.inFlight && current(held)
            && ProcessInfo.processInfo.systemUptime < held.expiry && ProcessInfo.processInfo.systemUptime < held.consentUntil
    }
    private func fetchRequest(_ held: Run, operation: UUID, initial: Bool, index: Int, materials: [FreshMaterial]) {
        guard freshCurrent(held, operation: operation) else { stop(held, reason: "authorization_expired"); return }
        if index == held.recipe.requests.count { verified(held, operation: operation, initial: initial, materials: materials); return }
        let descriptor = held.recipe.requests[index], scope = held.scope, id = held.id, token = held.recipe.token
        // 签名/JSON 核验离开主线程；返回后重新检查旧授权 deadline 和 native owner，不能迟到复活。
        worker.async { [weak self, weak held] in
            guard let self = self, let held = held else { return }
            let request: Result<URLRequest, Error> = Result { try descriptor.signedRequest(secrets: self.secrets, scope: scope, recordingID: id, token: token) }
            DispatchQueue.main.async { [weak self, weak held] in
                guard let self = self, let held = held, self.freshCurrent(held, operation: operation) else { return }
                switch request {
                case let .failure(error): self.stop(held, reason: (error as? IOSSecretHandleFailure)?.code ?? "signing_failed")
                case let .success(request):
                    let remaining = held.expiry - ProcessInfo.processInfo.systemUptime
                    let fetch = IOSRenewalFetch(request: request, timeout: min(15, remaining)) { [weak self, weak held] result in
                        DispatchQueue.main.async { [weak self, weak held] in
                            guard let self = self, let held = held, self.run === held, held.operation == operation else { return }
                            held.fetch = nil
                            guard self.freshCurrent(held, operation: operation) else { self.stop(held, reason: "authorization_expired"); return }
                            switch result {
                            case let .failure(error): self.stop(held, reason: error.code)
                            case var .success(data):
                                self.worker.async { [weak self, weak held] in
                                    defer { data.resetBytes(in: 0..<data.count) }
                                    guard let self = self, let held = held else { return }
                                    let verified: Result<[FreshMaterial], Error> = Result {
                                        let json = try IOSRenewalJSON.object(data)
                                        var fresh: [FreshMaterial] = []
                                        for assertion in descriptor.validation {
                                            let value = try assertion.extract(json)
                                            let isMaterial = descriptor.materialPaths.contains(assertion.path)
                                            let equal = try assertion.matches(value, secrets: self.secrets, scope: scope, recordingID: id)
                                            if isMaterial {
                                                guard let baseline = assertion.baseline, let text = value as? String,
                                                      text.utf8.count <= 4096 else { throw IOSSessionRenewalFailure("invalid_material") }
                                                fresh.append(FreshMaterial(requestIndex: index, path: assertion.path, baseline: baseline,
                                                                           value: Data(text.utf8), changed: !equal))
                                            } else if !equal { throw IOSSessionRenewalFailure("owner_validation_failed") }
                                        }
                                        return fresh
                                    }
                                    DispatchQueue.main.async { [weak self, weak held] in
                                        guard let self = self, let held = held, self.run === held, held.operation == operation else { return }
                                        guard self.freshCurrent(held, operation: operation) else { self.stop(held, reason: "authorization_expired"); return }
                                        switch verified {
                                        case let .failure(error): self.stop(held, reason: (error as? IOSSessionRenewalFailure)?.code ?? (error as? IOSSecretHandleFailure)?.code ?? "invalid_response")
                                        case let .success(fresh): self.fetchRequest(held, operation: operation, initial: initial, index: index + 1, materials: materials + fresh)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    held.fetch = fetch; fetch.start()
                }
            }
        }
    }
    private func verified(_ held: Run, operation: UUID, initial: Bool, materials: [FreshMaterial]) {
        guard freshCurrent(held, operation: operation) else { stop(held, reason: "authorization_expired"); return }
        let changed = materials.contains(where: { $0.changed })
        for group in Dictionary(grouping: materials, by: { $0.baseline }).values {
            guard let first = group.first, group.allSatisfy({ $0.changed == first.changed && $0.value == first.value }) else {
                stop(held, reason: "ambiguous_material_baseline"); return
            }
        }
        if initial && changed { stop(held, reason: "initial_material_mismatch"); return }
        if !initial && !changed {
            let now = ProcessInfo.processInfo.systemUptime, next = now + Self.validity
            guard admitted(held), let issuer = didRenew,
                  issuer(held.id, held.scope, held.connection, next), current(held),
                  ProcessInfo.processInfo.systemUptime < held.expiry,
                  let issued = recordingProvider?(), issued.nativeAuthenticated, validWindow(issued),
                  issued.authorizedUntil >= next - 0.001 else { stop(held, reason: "lease_renewal_rejected"); return }
            held.expiry = next; held.refreshedAt = now; held.inFlight = false; held.reason = ""
            held.operationTimeout?.cancel(); held.operationTimeout = nil
            return // 不改 connectionGeneration / GATT / operation ticket。
        }
        revoke(held, reason: initial ? "initial_authorization" : "material_changed")
        held.phase = "reauthentication_required"; held.reason = initial ? "initial_authorization" : "material_changed"
        guard let provider = materialChanged else { held.inFlight = false; completePrepare(held); return }
        do {
            var refs: [IOSSessionRenewalMaterial] = []
            var replacements: [String: String] = [:]
            for material in materials {
                let handle: String
                if material.changed {
                    // 一条旧 baseline 若被不同 path 共用，fresh 新值必须一致，否则拒绝含糊配方。
                    if let previous = replacements[material.baseline] {
                        guard try secrets.matches(handle: previous, data: material.value, scope: held.scope, recordingID: held.id) else { throw IOSSessionRenewalFailure("ambiguous_material_baseline") }
                        handle = previous
                    } else {
                        handle = try secrets.importOpaque(material.value, scope: held.scope, expires: held.consentUntil, recordingID: held.id)
                        replacements[material.baseline] = handle; held.newHandles.insert(handle)
                    }
                } else { handle = material.baseline }
                refs.append(IOSSessionRenewalMaterial(requestIndex: material.requestIndex, path: material.path, handle: handle, type: "string"))
            }
            let change = IOSSessionRenewalMaterialChange(recordingID: held.id, scope: held.scope,
                                                        previousConnectionGeneration: held.connection, materials: refs,
                                                        reauthenticationRecipe: held.recipe.reauthenticationRecipe,
                                                        reason: initial ? "initial_authorization" : "material_changed")
            // Provider 必须完成有界原生握手和真实 ACK。返回本地 TTL 或 JS true 不满足合同。
            provider(change) { [weak self, weak held] lease in
                let finish = { [weak self, weak held] in
                    guard let self = self, let held = held else { return }
                    guard self.run === held, held.operation == operation, held.inFlight else {
                        self.invalidateLateLease(lease); return
                    }
                    guard self.scopeProvider?() == held.scope, ProcessInfo.processInfo.systemUptime < held.expiry,
                          ProcessInfo.processInfo.systemUptime < held.consentUntil,
                          let lease = lease, lease.recordingID == held.id, lease.scope == held.scope,
                          lease.nativeAuthenticated, self.validWindow(lease),
                          let issued = self.recordingProvider?(), issued.recordingID == held.id,
                          issued.scope == held.scope, issued.connectionGeneration == lease.connectionGeneration,
                          issued.nativeAuthenticated, self.validWindow(issued),
                          issued.authorizedUntil == lease.authorizedUntil else {
                        self.invalidateLateLease(lease)
                        self.stop(held, reason: "reauthentication_failed"); return
                    }
                    held.recipe.replaceBaselines(replacements)
                    for old in replacements.keys where !held.recipe.handles.contains(old) { try? self.secrets.release(handle: old, scope: held.scope) }
                    do {
                        try self.secrets.reserveReplacements(scope: held.scope, recordingID: held.id, materials: held.recipe.materialHandles)
                    } catch { self.invalidateLateLease(lease); self.stop(held, reason: "secret_reservation_limit"); return }
                    held.newHandles.removeAll()
                    held.connection = lease.connectionGeneration; held.expiry = lease.authorizedUntil
                    held.refreshedAt = lease.authorizedAt; held.active = true; held.nativeAuthenticated = true
                    held.recipeComplete = true; held.phase = "active"; held.reason = ""; held.inFlight = false
                    held.operationTimeout?.cancel(); held.operationTimeout = nil
                    self.completePrepare(held)
                }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
            }
        } catch { stop(held, reason: (error as? IOSSecretHandleFailure)?.code ?? (error as? IOSSessionRenewalFailure)?.code ?? "material_import_failed") }
    }
}

private struct IOSRenewalAssertion {
    let path: [String]
    let type: String
    var baseline: String?
    let literal: Any?
    let equalsAny: [Any]?
    func extract(_ source: [String: Any]) throws -> Any {
        var value: Any = source
        for component in path {
            guard let object = value as? [String: Any], let next = object[component] else { throw IOSSessionRenewalFailure("missing_validation_path") }
            value = next
        }
        guard Self.valid(value, type: type) else { throw IOSSessionRenewalFailure("validation_type_mismatch") }
        return value
    }
    static func valid(_ value: Any, type: String) -> Bool {
        if type == "string" { return IOSSecretHandleService.text(value, max: IOSSecretHandleService.maxBytes) != nil }
        if type == "numberOrString", value is String { return IOSSecretHandleService.text(value, max: 4096) != nil }
        guard let number = value as? NSNumber else { return false }
        return type == "bool" ? CFGetTypeID(number) == CFBooleanGetTypeID()
            : (type == "number" || type == "numberOrString") && CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }
    func matches(_ value: Any, secrets: IOSSecretHandleService, scope: IOSRideScope, recordingID: UUID) throws -> Bool {
        if let handle = baseline, let text = value as? String { return try secrets.matches(handle: handle, data: Data(text.utf8), scope: scope, recordingID: recordingID) }
        func equal(_ expected: Any) -> Bool {
            if let text = value as? String { return text == expected as? String }
            guard !(expected is String), let a = value as? NSNumber, let b = expected as? NSNumber,
                  (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) else { return false }
            return a == b
        }
        if let alternatives = equalsAny { return alternatives.contains(where: equal) }
        guard let literal = literal else { return false }
        return equal(literal)
    }
}
private struct IOSRenewalRequest {
    let url: URL
    let query: [(String, String)]
    let headers: [String: String]
    let appID: String
    let signer: String
    let paramHeader: String
    let signHeader: String
    let nonceAlphabet: [UInt8]
    let nonceRandomLength: Int
    var validation: [IOSRenewalAssertion]
    let materialPaths: [[String]]
    func signedRequest(secrets: IOSSecretHandleService, scope: IOSRideScope, recordingID: UUID, token: String) throws -> URLRequest {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        // nonce 字符表来自私有 descriptor；拒绝采样消除 modulo bias，不含任何协议密钥。
        var random = [UInt8](repeating: 0, count: 32), suffix = [UInt8]()
        defer { random.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let ceiling = 256 - 256 % nonceAlphabet.count
        while suffix.count < nonceRandomLength {
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw IOSSessionRenewalFailure("random_unavailable")
            }
            for byte in random where Int(byte) < ceiling {
                suffix.append(nonceAlphabet[Int(byte) % nonceAlphabet.count])
                if suffix.count == nonceRandomLength { break }
            }
        }
        let nonce = ts + String(decoding: suffix, as: UTF8.self)
        let param = "appId=\(appID)&nonce=\(nonce)&timestamp=\(ts)"
        let rawQuery = query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let signature = try secrets.withSecret(handle: signer, scope: scope, purpose: .signer, recordingID: recordingID) { secret in
            var digest = Insecure.SHA1()
            digest.update(data: Data((rawQuery + param).utf8))
            digest.update(bufferPointer: secret)
            var sha = Data(digest.finalize().map { String(format: "%02x", $0) }.joined().utf8)
            defer { sha.resetBytes(in: 0..<sha.count) }
            return Insecure.MD5.hash(data: sha).map { String(format: "%02x", $0) }.joined()
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        parts.percentEncodedQuery = query.isEmpty ? nil : query.map {
            $0.0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        guard let target = parts.url else { throw IOSSessionRenewalFailure("invalid_query") }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(param, forHTTPHeaderField: paramHeader); request.setValue(signature, forHTTPHeaderField: signHeader)
        let authorization = try secrets.withSecret(handle: token, scope: scope, purpose: .token, recordingID: recordingID) { bytes -> String in
            guard let value = String(bytes: bytes, encoding: .utf8), IOSSecretHandleService.text(value, max: IOSSecretHandleService.maxBytes) != nil else { throw IOSSecretHandleFailure("invalid_token") }
            return "Bearer " + value
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
}
private struct IOSRenewalRecipe {
    let token: String
    var requests: [IOSRenewalRequest]
    let reauthenticationRecipe: [String: Any]
    var handles: Set<String> { Set([token] + requests.map { $0.signer } + requests.flatMap { $0.validation.compactMap { $0.baseline } }) }
    var materialHandles: Set<String> { Set(requests.flatMap { request in
        request.validation.filter { request.materialPaths.contains($0.path) }.compactMap { $0.baseline }
    }) }
    mutating func replaceBaselines(_ replacements: [String: String]) {
        for index in requests.indices { for assertion in requests[index].validation.indices {
            if let old = requests[index].validation[assertion].baseline, let new = replacements[old] { requests[index].validation[assertion].baseline = new }
        } }
    }
    static func path(_ value: Any?) throws -> [String] {
        guard let path = value as? [String], !path.isEmpty, path.count <= 8,
              path.allSatisfy({ IOSSecretHandleService.text($0, max: 128) != nil }) else { throw IOSSessionRenewalFailure("invalid_validation_path") }
        return path
    }
    static func parse(_ options: [String: Any], secrets: IOSSecretHandleService, scope: IOSRideScope) throws -> IOSRenewalRecipe {
        guard let token = options["tokenHandle"] as? String, UUID(uuidString: token) != nil,
              let signer = options["signerHandle"] as? String, UUID(uuidString: signer) != nil,
              let recipe = options["recipe"] as? [String: Any],
              Set(recipe.keys).isSubset(of: ["version", "requests", "intervalMs", "validityMs", "reauthenticationRecipe"]),
              IOSSecretHandleService.integer(recipe["version"]) == 1,
              IOSSecretHandleService.integer(recipe["intervalMs"]) == 240_000,
              IOSSecretHandleService.integer(recipe["validityMs"]) == 300_000,
              let descriptors = recipe["requests"] as? [[String: Any]], !descriptors.isEmpty, descriptors.count <= 2,
              let handshake = recipe["reauthenticationRecipe"] as? [String: Any],
              JSONSerialization.isValidJSONObject(handshake),
              (try JSONSerialization.data(withJSONObject: handshake)).count <= 65_536 else { throw IOSSessionRenewalFailure("invalid_renewal_recipe") }
        guard try secrets.valueType(handle: token, scope: scope, purpose: .token) == .string else { throw IOSSecretHandleFailure("invalid_token") }
        _ = try secrets.valueType(handle: signer, scope: scope, purpose: .signer)
        var requests: [IOSRenewalRequest] = [], totalPaths = 0
        for descriptor in descriptors {
            guard Set(descriptor.keys).isSubset(of: ["url", "method", "query", "headers", "sign", "validation", "materialPaths"]),
                  descriptor["method"] as? String == "GET", let text = IOSSecretHandleService.text(descriptor["url"], max: 4096),
                  !text.contains("\\"), !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                  let parts = URLComponents(string: text), parts.scheme == "https",
                  ["tapi.zeehoev.com", "h5.zeehoev.com"].contains(parts.host?.lowercased() ?? ""),
                  parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, !parts.path.isEmpty, !parts.path.hasPrefix("//"),
                  !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), let url = parts.url,
                  let sign = descriptor["sign"] as? [String: Any],
                  Set(sign.keys).isSubset(of: ["appId", "nonceMode", "suffixSecretHandle", "transform", "paramHeader", "signHeader", "timestampUnit", "nonceRandomLength", "nonceAlphabet", "queryMode"]),
                  let app = IOSSecretHandleService.text(sign["appId"], max: 128),
                  app.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }),
                  sign["nonceMode"] as? String == "timestampRandom",
                  sign["transform"] as? String == "sha1HexThenMd5Hex",
                  sign["suffixSecretHandle"] as? String == signer,
                  sign["paramHeader"] as? String == "cfmoto-x-param", sign["signHeader"] as? String == "cfmoto-x-sign",
                  let querySource = descriptor["query"] as? [[String: Any]], querySource.count <= 24,
                  let assertionSource = descriptor["validation"] as? [[String: Any]], !assertionSource.isEmpty,
                  let materialSource = descriptor["materialPaths"] as? [Any] else { throw IOSSessionRenewalFailure("invalid_renewal_request") }
            let alphabetText = sign["nonceAlphabet"] as? String ?? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            let alphabet = Array(alphabetText.utf8)
            let randomLength = IOSSecretHandleService.integer(sign["nonceRandomLength"] ?? 16)
            guard alphabet.count >= 16, alphabet.count <= 96, Set(alphabet).count == alphabet.count,
                  alphabet.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  let randomLength = randomLength, (8...32).contains(randomLength),
                  sign["timestampUnit"] == nil || sign["timestampUnit"] as? String == "milliseconds",
                  sign["queryMode"] == nil || sign["queryMode"] as? String == "sortedRawNonEmpty" else {
                throw IOSSessionRenewalFailure("invalid_sign_descriptor")
            }
            var query: [(String, String)] = [], queryKeys = Set<String>(), querySize = 0
            for item in querySource {
                guard Set(item.keys) == ["key", "value"], let key = IOSSecretHandleService.text(item["key"], max: 128),
                      let value = IOSSecretHandleService.text(item["value"], max: 4096, empty: true), queryKeys.insert(key).inserted,
                      key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "." }) else { throw IOSSessionRenewalFailure("invalid_query") }
                querySize += key.utf8.count + value.utf8.count
                guard querySize <= 8192 else { throw IOSSessionRenewalFailure("query_too_large") }
                // 私有签名层惯例：空值不参与 GET query 或签名。
                if !value.isEmpty { query.append((key, value)) }
            }
            query.sort { $0.0 < $1.0 }
            var headers: [String: String] = [:], headerSize = 0
            if let source = descriptor["headers"] {
                guard let source = source as? [String: Any], source.count <= 16 else { throw IOSSessionRenewalFailure("invalid_headers") }
                for (name, value) in source {
                    let lower = name.lowercased()
                    guard let value = IOSSecretHandleService.text(value, max: 4096, empty: true), name.utf8.count <= 64,
                          name.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 }),
                          !["authorization", "host", "cookie", "set-cookie", "connection", "content-length", "transfer-encoding", "cfmoto-x-param", "cfmoto-x-sign", "cache-control"].contains(lower),
                          headers[lower] == nil else { throw IOSSessionRenewalFailure("invalid_headers") }
                    headerSize += name.utf8.count + value.utf8.count
                    guard headerSize <= 8192 else { throw IOSSessionRenewalFailure("headers_too_large") }
                    headers[lower] = value
                }
            }
            let materialPaths = try materialSource.map { try path($0) }
            guard Set(materialPaths).count == materialPaths.count else { throw IOSSessionRenewalFailure("invalid_material_paths") }
            var assertions: [IOSRenewalAssertion] = [], paths = Set<[String]>()
            for source in assertionSource {
                let hasEquals = source["equals"] != nil, hasAny = source["equalsAny"] != nil
                guard Set(source.keys).isSubset(of: ["path", "equals", "equalsAny", "type"]), hasEquals != hasAny,
                      let type = source["type"] as? String, ["string", "number", "bool", "numberOrString"].contains(type) else {
                    throw IOSSessionRenewalFailure("invalid_validation")
                }
                let parsedPath = try path(source["path"])
                guard paths.insert(parsedPath).inserted else { throw IOSSessionRenewalFailure("duplicate_validation_path") }
                totalPaths += 1
                guard totalPaths <= 24 else { throw IOSSessionRenewalFailure("validation_limit") }
                var baseline: String?, literal: Any?, alternatives: [Any]?
                if let any = source["equalsAny"] {
                    guard type == "numberOrString", let values = any as? [Any], !values.isEmpty, values.count <= 8,
                          values.allSatisfy({ IOSRenewalAssertion.valid($0, type: type) }) else { throw IOSSessionRenewalFailure("invalid_validation_alternatives") }
                    alternatives = values
                } else if let ref = source["equals"] as? [String: Any] {
                    guard Set(ref.keys) == ["secretBaselineRef"], type == "string", let handle = ref["secretBaselineRef"] as? String,
                          UUID(uuidString: handle) != nil, try secrets.valueType(handle: handle, scope: scope, purpose: .baseline) == .string else { throw IOSSessionRenewalFailure("invalid_baseline_ref") }
                    baseline = handle
                } else {
                    guard let equals = source["equals"], IOSRenewalAssertion.valid(equals, type: type) else { throw IOSSessionRenewalFailure("invalid_validation_literal") }
                    literal = equals
                }
                if materialPaths.contains(parsedPath) && (baseline == nil || type != "string") { throw IOSSessionRenewalFailure("material_baseline_required") }
                assertions.append(IOSRenewalAssertion(path: parsedPath, type: type, baseline: baseline, literal: literal, equalsAny: alternatives))
            }
            guard materialPaths.allSatisfy({ paths.contains($0) }) else { throw IOSSessionRenewalFailure("material_baseline_required") }
            requests.append(IOSRenewalRequest(url: url, query: query, headers: headers, appID: app, signer: signer,
                                              paramHeader: "cfmoto-x-param", signHeader: "cfmoto-x-sign", nonceAlphabet: alphabet,
                                              nonceRandomLength: randomLength, validation: assertions, materialPaths: materialPaths))
        }
        guard requests.contains(where: { !$0.materialPaths.isEmpty }), requests.contains(where: { request in
            request.validation.contains(where: { !request.materialPaths.contains($0.path) && $0.equalsAny == nil && $0.type != "numberOrString" })
        }) else { throw IOSSessionRenewalFailure("owner_validation_required") }
        let result = IOSRenewalRecipe(token: token, requests: requests, reauthenticationRecipe: handshake)
        let materials = result.materialHandles
        let ownerBaselines = Set(requests.flatMap { request in
            request.validation.filter { !request.materialPaths.contains($0.path) }.compactMap { $0.baseline }
        })
        guard materials.count <= 8, materials.isDisjoint(with: ownerBaselines) else {
            throw IOSSessionRenewalFailure("material_reservation_limit")
        }
        for handle in materials {
            try secrets.withSecret(handle: handle, scope: scope, purpose: .baseline) { bytes in
                guard bytes.count <= 4096 else { throw IOSSessionRenewalFailure("material_reservation_limit") }
            }
        }
        guard let idText = options["recordingId"] as? String, let id = UUID(uuidString: idText) else {
            throw IOSSessionRenewalFailure("native_recording_required")
        }
        try secrets.checkReplacementBudget(scope: scope, recordingID: id, materials: materials)
        return result
    }
}

// 私有响应先做严格语法闸门，拒绝重复键（含 Unicode escape 等价键）、非有限数值和过深嵌套。
private enum IOSRenewalJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 524_288, String(data: data, encoding: .utf8) != nil else { throw IOSSessionRenewalFailure("invalid_response") }
        var parser = Parser(bytes: Array(data))
        defer { parser.bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        try parser.value(depth: 0); parser.space()
        guard parser.at == parser.bytes.count, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IOSSessionRenewalFailure("invalid_response") }
        return object
    }
    private struct Parser {
        var bytes: [UInt8]
        var at = 0
        var peek: UInt8 { at < bytes.count ? bytes[at] : 0 }
        mutating func space() { while [9, 10, 13, 32].contains(peek) { at += 1 } }
        mutating func take(_ value: UInt8) -> Bool { guard at < bytes.count, peek == value else { return false }; at += 1; return true }
        mutating func require(_ value: UInt8) throws { guard take(value) else { throw IOSSessionRenewalFailure("invalid_response") } }
        mutating func string() throws -> String {
            let start = at; try require(34)
            while at < bytes.count {
                let c = peek; at += 1
                if c == 34 {
                    guard let text = try JSONSerialization.jsonObject(with: Data(bytes[start..<at]), options: .fragmentsAllowed) as? String else { throw IOSSessionRenewalFailure("invalid_response") }
                    return text
                }
                guard c >= 32 else { throw IOSSessionRenewalFailure("invalid_response") }
                if c == 92 {
                    let escape = peek; at += 1
                    if escape == 117 {
                        for _ in 0..<4 { guard at < bytes.count, (48...57).contains(peek) || (65...70).contains(peek) || (97...102).contains(peek) else { throw IOSSessionRenewalFailure("invalid_response") }; at += 1 }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) { throw IOSSessionRenewalFailure("invalid_response") }
                }
            }
            throw IOSSessionRenewalFailure("invalid_response")
        }
        mutating func value(depth: Int) throws {
            guard depth <= 32 else { throw IOSSessionRenewalFailure("response_depth_limit") }
            space()
            if peek == 34 { _ = try string(); return }
            if peek == 123 || peek == 91 {
                let object = take(123); if !object { try require(91) }
                let end: UInt8 = object ? 125 : 93
                var keys = Set<String>(); space(); if take(end) { return }
                while true {
                    space()
                    if object { let key = try string(); guard keys.insert(key).inserted else { throw IOSSessionRenewalFailure("duplicate_response_key") }; space(); try require(58) }
                    try value(depth: depth + 1); space(); if take(end) { return }; try require(44)
                }
            }
            for literal in ["true", "false", "null"] {
                let part = Array(literal.utf8)
                if bytes.count - at >= part.count, Array(bytes[at..<(at + part.count)]) == part { at += part.count; return }
            }
            let start = at; _ = take(45)
            if !take(48) { guard (49...57).contains(peek) else { throw IOSSessionRenewalFailure("invalid_response") }; while (48...57).contains(peek) { at += 1 } }
            if take(46) { guard (48...57).contains(peek) else { throw IOSSessionRenewalFailure("invalid_response") }; while (48...57).contains(peek) { at += 1 } }
            if take(101) || take(69) { if !take(43) { _ = take(45) }; guard (48...57).contains(peek) else { throw IOSSessionRenewalFailure("invalid_response") }; while (48...57).contains(peek) { at += 1 } }
            guard let text = String(bytes: bytes[start..<at], encoding: .utf8), let number = Double(text), number.isFinite else { throw IOSSessionRenewalFailure("nonfinite_response_number") }
        }
    }
}

// ephemeral 会话，不接受 redirect/cookie/cache；delegate 按到达字节截断，不先无限下载再检查。
private final class IOSRenewalFetch: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let request: URLRequest
    private let timeout: Double
    private let queue = OperationQueue()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var completion: ((Result<Data, IOSSessionRenewalFailure>) -> Void)?
    private var finished = false
    init(request: URLRequest, timeout: Double, completion: @escaping (Result<Data, IOSSessionRenewalFailure>) -> Void) {
        self.request = request; self.timeout = max(0.001, timeout); self.completion = completion
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
    }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session; task = session.dataTask(with: request); task?.resume()
    }
    func cancel() { queue.addOperation { [weak self] in self?.finish(.failure(IOSSessionRenewalFailure("cancelled"))) } }
    private func finish(_ result: Result<Data, IOSSessionRenewalFailure>) {
        guard !finished else { return }; finished = true
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        let callback = completion; completion = nil
        callback?(result)
        data.resetBytes(in: 0..<data.count); data.removeAll(keepingCapacity: false)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(IOSSessionRenewalFailure("redirect_not_allowed")))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == request.url else {
            completionHandler(.cancel); finish(.failure(IOSSessionRenewalFailure("invalid_response"))); return
        }
        guard http.statusCode == 200 else { completionHandler(.cancel); finish(.failure(IOSSessionRenewalFailure(http.statusCode == 401 || http.statusCode == 403 ? "auth_rejected" : "http_rejected"))); return }
        guard response.expectedContentLength <= 524_288 else { completionHandler(.cancel); finish(.failure(IOSSessionRenewalFailure("response_too_large"))); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished, chunk.count <= 524_288 - data.count else { finish(.failure(IOSSessionRenewalFailure("response_too_large"))); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(IOSSessionRenewalFailure("renewal_network_failed"))); return }
        // 将唯一 buffer 移交核验 worker；不回传 HTTP body 到 RPC。
        let output = data; data = Data(); finish(.success(output))
    }
}
