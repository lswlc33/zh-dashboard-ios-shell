import Foundation
import UIKit
import ReplayKit
import Network

// App target only。集成方提供原生 scope/presenter；不得从 JS 传来的 token/VIN 建 scope。
// IOSCompatibility 的 window.ZeehoCast VERSION=1 七方法映射见 methods / handle；额外 setTier。
final class IOSCastService: IOSBridgeCancellableService {
    let methods = ["cast.version", "cast.capabilities", "cast.start", "cast.stop", "cast.status", "cast.setTier",
                   "cast.pair", "cast.diagnostics", "cast.requestProjection", "cast.forgetProfile"]
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var metadataProvider: (() -> [String: Any]?)?
    private struct MutableCall: Equatable {
        let scope: IOSRideScope
        let navigationID: String
        let frame: String
        let epoch: Int
        let documentGeneration: Int
        let attemptID: String
    }
    private var activeCall: MutableCall?
    private var activeScope: IOSRideScope?
    private var sessionID: String?
    private var selectedTarget: String? // 当前 App 内存；不保存 SSID/password/sn，也不进入 App Group。
    private var preferredSettings = IOSCastSettings()
    private var selectedRecipe: IOSCastRecipe?
    private var mailbox: IOSCastMailbox?
    private var localPhase = "idle"
    private var localReason = ""
    private var selectionDeadline = 0.0
    private var pickerController: IOSCastPickerController?
    private var observer: Timer?
    private var wifiMonitor: NWPathMonitor?
    private var wifiConnected = false
    private var wifiKnown = false
    private var diagnostics: [[String: Any]] = []
    private var lastDiagnostic = ""
    private var selectionIsPending = false

    init() {
        precondition(Thread.isMainThread)
        mailbox = try? IOSCastMailbox()
        // App 重建时没有旧原生 scope；不能认领仍在系统扩展里跑的匿名广播。
        if let leftover = try? mailbox?.grant(), !leftover.revoked {
            try? mailbox?.revoke(leftover.id, reason: "cast_host_recreated")
        }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.wifiKnown = true; self.wifiConnected = connected
                if !connected, self.sessionID != nil { self.revoke(reason: "wifi_disconnected") }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.lswlc33.dashboard.ios.cast.wifi"))
        observer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit {
        observer?.invalidate(); wifiMonitor?.cancel()
        // 不销毁他人对象、不删除文件；匿名票据撤销会立即通知 extension。
        if let id = sessionID { try? mailbox?.revoke(id, reason: "cast_service_closed") }
    }
    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread)
        scopeProvider = provider; scopeChanged()
    }
    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread)
        presenterProvider = provider
    }
    func configureMetadataProvider(_ provider: @escaping () -> [String: Any]?) {
        precondition(Thread.isMainThread)
        if sessionID != nil { revoke(reason: "cast_metadata_provider_changed") }
        metadataProvider = provider
    }
    func scopeChanged() {
        precondition(Thread.isMainThread)
        if let old = activeScope, scopeProvider?() != old {
            revoke(reason: "stale_session"); selectedTarget = nil; selectedRecipe = nil; preferredSettings = IOSCastSettings()
        }
    }
    func navigationChanged() {
        precondition(Thread.isMainThread)
        // 未确认的页面意图不能带到另一份文档；已由用户系统授权的整屏广播与 WK 页面分离。
        scopeChanged()
        if selectionIsPending { revoke(reason: "stale_navigation") }
    }
    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        // 不在主 App 后台保活/伪造heartbeat。系统授权后 extension 独立负责 TCP。
        // 系统 picker 确认会造成 App inactive/background，不能在这里撤销合法确认。
        scopeChanged()
    }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        guard method == "cast.start" || method == "cast.requestProjection",
              let options = try? object(args), let held = activeCall,
              let attempt = options["attemptId"] as? String, attempt == held.attemptID,
              matches(options, held) else { return }
        // 桥的迟到取消属于旧文档/旧尝试；不能拿新 current scope 代替旧身份撤销 B。
        revoke(reason: "cast_cancelled")
    }
    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        scopeChanged(); refresh()
        do {
            let mutating = ["cast.start", "cast.stop", "cast.setTier", "cast.pair", "cast.forgetProfile", "cast.requestProjection"].contains(method)
            let options: [String: Any]
            let call: MutableCall?
            if mutating {
                options = try object(args)
                call = try captureMutation(options, requiresAttempt: method == "cast.start" || method == "cast.requestProjection")
            } else { options = [:]; call = nil }
            switch method {
            case "cast.version": reply(1, nil)
            case "cast.capabilities": reply(capabilities(), nil)
            case "cast.status": reply(snapshot(), nil)
            case "cast.start":
                guard let call = call else { throw IOSCastError.reason("stale_context") }
                reply(try start(options: options, call: call), nil)
            case "cast.stop":
                try requireSession(options)
                let stoppedID = sessionID ?? ""
                revoke(reason: "user_stopped")
                if localReason == "cast_revoke_write_failed" { throw IOSCastError.reason(localReason) }
                var out = snapshot(); out["accepted"] = true; out["stoppedSessionId"] = stoppedID; reply(out, nil)
            case "cast.setTier":
                guard sessionID == nil else { throw IOSCastError.reason("session_active") }
                guard let tier = options["tier"] as? String, let recipe = selectedRecipe,
                      recipe.tiers.contains(where: { $0.id == tier }) else {
                    throw IOSCastError.reason("cast_tier_invalid")
                }
                preferredSettings.tier = tier; reply(["ok": true, "tier": tier], nil)
            case "cast.pair":
                guard sessionID == nil else { throw IOSCastError.reason("session_active") }
                guard scopeProvider?()?.valid == true else { throw IOSCastError.reason("authorized_vehicle_required") }
                // Wi-Fi join/status 属于 Net 模块；这里不把 MAC、SSID 或蓝牙连通当作 GO IP。
                guard let target = options["targetIP"] as? String else { throw IOSCastError.reason("cast_target_required") }
                if options["recipe"] != nil { selectedRecipe = try IOSCastRecipe.from(options["recipe"]) }
                selectedTarget = try IOSCastTarget.validate(target)
                reply(["ok": true, "profile": ["targetIP": "private-wifi", "captureSource": "screen"],
                       "wifiJoinRequired": !wifiConnected, "reason": "target_selected_not_verified"], nil)
            case "cast.forgetProfile":
                if sessionID != nil || options["expectedSessionId"] != nil || options["ticket"] != nil { try requireSession(options) }
                revoke(reason: "profile_forgotten")
                if localReason == "cast_revoke_write_failed" { throw IOSCastError.reason(localReason) }
                selectedTarget = nil; selectedRecipe = nil
                var out = snapshot(); out["accepted"] = true; out["savedProfile"] = NSNull(); reply(out, nil)
            case "cast.diagnostics":
                let raw = (args.first as? [String: Any])?["limit"] ?? args.first
                let value = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? "") ?? 50
                let items = Array(diagnostics.suffix(max(1, min(200, value))))
                reply(["ok": true, "items": items, "count": items.count], nil)
            case "cast.requestProjection":
                // iOS 不存在可缓存的 MediaProjection token。不能在网页 requestProjection 里
                // 假装授予整屏捕获，后续 start 必须真实展示 RPSystemBroadcastPickerView。
                let cap = capabilities()
                guard cap["available"] as? Bool == true else {
                    throw IOSCastError.reason(cap["reason"] as? String ?? "projection_unavailable")
                }
                guard let call = call else { throw IOSCastError.reason("stale_context") }
                reply(["ok": true, "requested": false, "projectionReady": false,
                       "attemptId": call.attemptID, "sessionId": "", "ticket": "",
                       "requiresStart": true, "systemPickerRequired": true,
                       "reason": "system_broadcast_picker_required"], nil)
            default: reply(nil, "unsupported_method")
            }
        } catch {
            let code = IOSCastError.code(error)
            record(code)
            reply(["ok": false, "error": code, "reason": code, "phase": "failed"], nil)
        }
    }
    private func captureMutation(_ options: [String: Any], requiresAttempt: Bool) throws -> MutableCall {
        guard UIApplication.shared.applicationState == .active,
              let scope = scopeProvider?(), scope.valid, let metadata = metadataProvider?(),
              let navigation = metadata["navId"] as? String ?? metadata["navigationId"] as? String,
              IOSBridgePolicy.identifier(navigation), let epoch = IOSBridgePolicy.integer(metadata["epoch"]), epoch >= 0,
              scope.generation == String(epoch), let generation = IOSBridgePolicy.integer(metadata["generation"]), generation >= 0,
              let frame = metadata["frame"] as? String, !frame.isEmpty, frame.utf8.count <= 256,
              !frame.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw IOSCastError.reason("authorized_scope_required")
        }
        let attempt = options["attemptId"] as? String ?? ""
        if requiresAttempt {
            guard IOSBridgePolicy.identifier(attempt) else { throw IOSCastError.reason("cast_attempt_required") }
        }
        let call = MutableCall(scope: scope, navigationID: navigation, frame: frame, epoch: epoch,
                               documentGeneration: generation, attemptID: attempt)
        guard matches(options, call) else { throw IOSCastError.reason("stale_context") }
        return call
    }
    private func matches(_ options: [String: Any], _ call: MutableCall) -> Bool {
        guard let scope = options["scope"] as? [String: Any] else { return false }
        return options["navigationId"] as? String == call.navigationID
            && options["frame"] as? String == call.frame && IOSBridgePolicy.integer(options["epoch"]) == call.epoch
            && scope["navId"] as? String == call.navigationID && scope["frame"] as? String == call.frame
            && IOSBridgePolicy.integer(scope["epoch"]) == call.epoch
            && IOSBridgePolicy.integer(scope["generation"]) == call.documentGeneration
            && scope["accountId"] as? String == call.scope.accountID && scope["vin"] as? String == call.scope.vin
    }
    private func requireSession(_ options: [String: Any]) throws {
        let expected = options["expectedSessionId"] as? String ?? options["ticket"] as? String
        guard let expected = expected, !expected.isEmpty, let id = sessionID, expected == id else {
            throw IOSCastError.reason("stale_cast_session")
        }
        if let ticket = options["ticket"] as? String, ticket != id { throw IOSCastError.reason("stale_cast_session") }
        if let attempt = options["attemptId"] as? String, attempt != activeCall?.attemptID {
            throw IOSCastError.reason("stale_cast_session")
        }
    }
    private func object(_ args: [Any]) throws -> [String: Any] {
        if args.isEmpty { return [:] }
        if let value = args.first as? [String: Any] { return value }
        if let text = args.first as? String, text.utf8.count <= 49152 {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
            return try IOSCastWire.object(Data(text.utf8))
        }
        throw IOSCastError.reason("bridge_bad_json")
    }
    private func integrationReason() -> String? {
        guard mailbox != nil else { return "cast_app_group_unavailable" }
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "local_network_usage_description_missing" }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil),
              urls.contains(where: { url in
                  guard url.pathExtension == "appex", let bundle = Bundle(url: url),
                        bundle.bundleIdentifier == IOSCastMailbox.extensionID,
                        let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                        ext["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload",
                        let principal = ext["NSExtensionPrincipalClass"] as? String, principal.hasSuffix(".SampleHandler") else { return false }
                  return FileManager.default.fileExists(atPath: bundle.executableURL?.path ?? "")
              }) else { return "broadcast_extension_missing" }
        guard RPScreenRecorder.shared().isAvailable else { return "projection_unavailable" }
        return nil
    }
    private func environmentError() -> Any {
        if let missing = integrationReason() { return missing }
        if wifiKnown && !wifiConnected { return "wifi_required" }
        return NSNull()
    }
    private func capabilities() -> [String: Any] {
        let missing = integrationReason()
        return ["ok": true, "version": 1, "available": missing == nil, "reason": missing ?? "",
                "environmentError": environmentError(),
                "wifiConnected": wifiConnected, "wifiKnown": wifiKnown,
                "protocol": "bounded-frame-recipe", "recipeVersion": 1, "captureSource": "screen", "entireScreen": true,
                "systemPickerRequired": true, "projectionReady": false, "audio": false,
                "audioReason": "video_only_transport", "wifiDirect": false, "wifiAP": true,
                "airPlay": false, "reverseTouch": false, "tiers": selectedRecipe?.tiers.map { $0.id } ?? [],
                "experimental": true, "reasonIfIncompatible": "receiver_protocol_not_verified"]
    }
    private func start(options: [String: Any], call: MutableCall) throws -> [String: Any] {
        let scope = call.scope
        guard sessionID == nil else { throw IOSCastError.reason("session_active") }
        if let heartbeat = try? mailbox?.heartbeat(), heartbeat.fresh, heartbeat.broadcastActive {
            throw IOSCastError.reason("session_active")
        }
        if let missing = integrationReason() { throw IOSCastError.reason(missing) }
        guard wifiKnown, wifiConnected else { throw IOSCastError.reason("wifi_required") }
        guard UIApplication.shared.applicationState == .active, let presenter = presenterProvider?(),
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            throw IOSCastError.reason("cast_presenter_unavailable")
        }
        let target = try IOSCastTarget.validate(options["targetIP"] as? String ?? selectedTarget ?? "")
        let recipe = try options["recipe"].map { try IOSCastRecipe.from($0) } ?? selectedRecipe
        guard let recipe = recipe else { throw IOSCastError.reason("cast_recipe_required") }
        let settingOptions = options["settings"] as? [String: Any] ?? options
        var settings = try IOSCastSettings.from(settingOptions)
        if settings.tier.isEmpty { settings.tier = preferredSettings.tier.isEmpty ? recipe.tiers[0].id : preferredSettings.tier }
        guard recipe.tiers.contains(where: { $0.id == settings.tier }) else { throw IOSCastError.reason("cast_tier_invalid") }
        selectedRecipe = recipe
        guard let mailbox = mailbox else { throw IOSCastError.reason("cast_app_group_unavailable") }
        let now = Date().timeIntervalSince1970
        let id = UUID().uuidString
        let grant = IOSCastGrant(version: 1, id: id, targetIP: target, issuedAt: now, selectBefore: now + 120,
                                 endBefore: now + 7200, revoked: false, reason: "", settings: settings, recipe: recipe)
        try mailbox.setGrant(grant)
        sessionID = id; activeCall = call; activeScope = scope; selectionDeadline = grant.selectBefore; selectionIsPending = true
        localPhase = "provisioning"; localReason = "waiting_user_broadcast_confirmation"
        let controller = IOSCastPickerController(extensionID: IOSCastMailbox.extensionID)
        controller.onCancelled = { [weak self] in
            guard let self = self, self.sessionID == id, self.activeCall == call else { return }
            self.revoke(reason: "projection_cancelled")
        }
        pickerController = controller
        presenter.present(controller, animated: true)
        record("system_picker_presented")
        // ok/accepted 仅“意图+展示已接受”；明确 broadcasting/streaming=false，不能当连接成功。
        var out = snapshot(); out["accepted"] = true; out["requested"] = true
        out["broadcastActive"] = false; out["streaming"] = false; out["projectionReady"] = false
        return out
    }
    private func refresh() {
        guard let id = sessionID else { return }
        let isRevoked = (try? mailbox?.grant())?.revoked == true
        if !isRevoked, let scope = activeScope, scopeProvider?() != scope { revoke(reason: "stale_session"); return }
        if let heartbeat = try? mailbox?.heartbeat(), heartbeat.id == id, heartbeat.version == 1, heartbeat.fresh {
            if heartbeat.broadcastActive {
                if isRevoked { localPhase = "stopping"; return }
                selectionIsPending = false
                // 用户可能仍在系统选择面板；不自动点击、不伪造授权。App 重新激活才关本地说明。
                if UIApplication.shared.applicationState == .active, let controller = pickerController {
                    controller.onCancelled = nil; controller.dismiss(animated: true); pickerController = nil
                }
                localPhase = heartbeat.streaming ? "casting" : heartbeat.phase == "casting" ? "handshaking" : heartbeat.phase
                localReason = heartbeat.reason
            } else {
                localPhase = heartbeat.phase; localReason = heartbeat.reason
                finishLocal()
            }
        } else if selectionIsPending {
            if Date().timeIntervalSince1970 > selectionDeadline { revoke(reason: "cast_selection_timeout") }
        } else {
            // 扩展崩溃/被系统回收或心跳写失败；绝不根据本地旧 casting 标志继续报 streaming。
            revoke(reason: "broadcast_heartbeat_timeout")
        }
        record(localPhase + ":" + localReason)
    }
    private func revoke(reason: String) {
        guard let id = sessionID else {
            localPhase = reason == "user_stopped" || reason == "profile_forgotten" ? "idle" : "failed"
            localReason = reason; return
        }
        do {
            guard let mailbox = mailbox else { throw IOSCastError.reason("cast_app_group_unavailable") }
            try mailbox.revoke(id, reason: reason)
        }
        catch {
            // 写失败可见；仍保留 id，避免谎报已停止。扩展票据最多2h且250ms检查读错误。
            localPhase = "failed"; localReason = "cast_revoke_write_failed"; record(localReason); return
        }
        selectionIsPending = false
        localPhase = "stopping"; localReason = reason
        if let controller = pickerController { controller.onCancelled = nil; controller.dismiss(animated: true); pickerController = nil }
        // 未启动扩展时撤销已足够；已启动仍等真实终止heartbeat，不能宣称stop完成。
        if let heartbeat = try? mailbox?.heartbeat(), heartbeat.id == id, heartbeat.fresh, heartbeat.broadcastActive { return }
        finishLocal()
        localPhase = reason == "user_stopped" || reason == "profile_forgotten" ? "idle" : "failed"
    }
    private func finishLocal() {
        if let controller = pickerController { controller.onCancelled = nil; controller.dismiss(animated: true); pickerController = nil }
        sessionID = nil; activeCall = nil; activeScope = nil; selectionIsPending = false
    }
    private func snapshot() -> [String: Any] {
        let heartbeat: IOSCastHeartbeat? = {
            guard let id = sessionID, let value = try? mailbox?.heartbeat(), value.id == id, value.version == 1, value.fresh else { return nil }
            return value
        }()
        let revoked = sessionID.flatMap { id -> Bool? in
            guard let grant = try? mailbox?.grant(), grant.id == id else { return nil }
            return grant.revoked
        } ?? false
        let streaming = !revoked && heartbeat?.streaming == true
        // 全部先落到显式类型变量，再一次性写入字典。
        // 直接写带可选链的大型字面量会让 Swift 类型检查器超时（真实 CI 两次报出）。
        let session: String = sessionID ?? ""
        let attempt: String = activeCall?.attemptID ?? ""
        let phase: String = revoked ? localPhase : (streaming ? "casting" : localPhase)
        let broadcastActive: Bool = heartbeat?.broadcastActive == true
        let projectionReady: Bool = !revoked && broadcastActive
        let tier: String = heartbeat?.tier ?? preferredSettings.tier
        let retries: Int = heartbeat?.retries ?? 0
        let probeAccepted: Bool = heartbeat?.probeAccepted ?? false
        let listeners: [String] = heartbeat?.listenersReady ?? []
        let ports: [String] = heartbeat?.connectedPorts ?? []
        let encoderReady: Bool = heartbeat?.encoderReady == true
        let environment: String = environmentError()
        let sentFrames: Int = heartbeat?.sentFrames ?? 0
        let sentBytes: Int = heartbeat?.sentBytes ?? 0
        let keyframes: Int = heartbeat?.keyframes ?? 0
        let emptyPulls: Int = heartbeat?.emptyPulls ?? 0
        let droppedFrames: Int = heartbeat?.droppedFrames ?? 0
        let width: Int = heartbeat?.width ?? 0
        let height: Int = heartbeat?.height ?? 0
        let fps: Int = heartbeat?.fps ?? 0
        let bitrate: Int = heartbeat?.bitrate ?? 0
        let stats: [String: Any] = ["sentFrames": sentFrames, "sentBytes": sentBytes,
                                    "keyframes": keyframes, "emptyPulls": emptyPulls,
                                    "droppedFrames": droppedFrames]
        let encoder: [String: Any] = ["width": width, "height": height, "fps": fps,
                                      "bitrate": bitrate, "codec": "H264", "hardware": encoderReady]
        let value: [String: Any] = [
            "ok": true, "version": 1, "sessionId": session, "ticket": session, "attemptId": attempt,
            "phase": phase, "reason": localReason, "streaming": streaming,
            "broadcastActive": broadcastActive, "projectionReady": projectionReady,
            "projectionPending": selectionIsPending, "wifiConnected": wifiConnected,
            "captureSource": "screen", "audio": false, "compatibilityTier": tier,
            "retries": retries, "probeAccepted": probeAccepted,
            "listenersReady": listeners, "connectedPorts": ports,
            "encoderReady": encoderReady, "savedProfile": NSNull(),
            "environmentError": environment, "experimental": true,
            "stats": stats, "encoder": encoder
        ]
        return value
    }
    private func record(_ code: String) {
        guard code != lastDiagnostic else { return }
        lastDiagnostic = code
        diagnostics.append(["at": Date().timeIntervalSince1970 * 1000, "event": code])
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
    }
}

private final class IOSCastPickerController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onCancelled: (() -> Void)?
    private let extensionID: String
    init(extensionID: String) { self.extensionID = extensionID; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 24; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel(); title.text = "Share your entire screen"; title.font = .preferredFont(forTextStyle: .title2)
        title.numberOfLines = 0; title.textAlignment = .center
        let hint = UILabel()
        hint.text = "Notifications and other apps are visible to the vehicle. Tap the broadcast button below, select ZEEHO Cast and confirm Start Broadcast in the system panel. Connect to the receiver Wi-Fi first. Video only; experimental receiver compatibility."
        hint.font = .preferredFont(forTextStyle: .body); hint.numberOfLines = 0; hint.textAlignment = .center
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = extensionID; picker.showsMicrophoneButton = false
        picker.accessibilityLabel = "Choose system screen broadcast"
        picker.widthAnchor.constraint(equalToConstant: 64).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel casting", for: .normal)
        cancel.addTarget(self, action: #selector(cancelled), for: .touchUpInside)
        [title, hint, picker, cancel].forEach { stack.addArrangedSubview($0) }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        presentationController?.delegate = self
    }
    @objc private func cancelled() { onCancelled?() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onCancelled?() }
}
