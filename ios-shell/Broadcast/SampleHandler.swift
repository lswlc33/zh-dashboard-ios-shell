import Foundation
import ReplayKit
import Network
import CoreMedia
import CoreFoundation

// 本 extension 持有所有 TCP 连接与编码器；主 App suspend 后不会依赖它转发视频。
// 系统 broadcastStarted 才代表用户授权；App start / picker 展示都不能代替这个回调。
final class SampleHandler: RPBroadcastSampleHandler {
    private let engine = IOSCastBroadcastEngine()
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        engine.start { [weak self] reason in
            self?.finishBroadcastWithError(NSError(domain: "ZeehoCast", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }
    override func broadcastPaused() { engine.pause() }
    override func broadcastResumed() { engine.resume() }
    override func broadcastFinished() { engine.stop() }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video: engine.video(sampleBuffer)
        case .audioApp, .audioMic:
            // Android 三通道实现没有音频协商或音频包。丢弃真实音频，不冒充传输了音频。
            // App picker 隐藏麦克风，状态能力明确 audio=false；不保留音频缓冲。
            break
        @unknown default: break
        }
    }
}

final class IOSCastBroadcastEngine {
    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.cast.broadcast", qos: .userInitiated)
    private let encoder: IOSCastEncoder
    private var mailbox: IOSCastMailbox?
    private var grant: IOSCastGrant?
    private var ports: IOSCastRecipe.Ports { grant!.recipe.ports }
    private var recipe: IOSCastRecipe { grant!.recipe }
    private var timer: DispatchSourceTimer?
    private var finish: ((String) -> Void)?
    private var observing = false
    private var active = false
    private var paused = false
    private var generation: UInt64 = 0
    private var listeners: [UInt16: NWListener] = [:]
    private var listenerReady: Set<UInt16> = []
    private var sockets: [UInt16: IOSCastSocket] = [:]
    private var connected: Set<UInt16> = []
    private var pending: [UInt16: NWConnection] = [:]
    private var probe: IOSCastSocket?
    private var probeDeadline = 0.0
    private var probeAccepted = false
    private var attemptStarted = 0.0
    private var castingStarted = 0.0
    private var lastSentAt = 0.0
    private var lastGrantCheckAt = -Double.infinity
    private var lastSampleAt = 0.0
    private var lastPublishAt = 0.0
    private var phase = "provisioning"
    private var reason = ""
    private var plan: IOSCastPlan?
    private var settings = IOSCastSettings()
    private var frameIndex: UInt32 = 0
    private var consecutiveEmpty = 0
    private var retries = 0
    private var attemptFrames: UInt64 = 0
    private var sentFrames: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var keyframes: UInt64 = 0
    private var emptyPulls: UInt64 = 0

    init() {
        encoder = IOSCastEncoder(queue: queue)
        encoder.onFatal = { [weak self] code in self?.fail(code) }
        encoder.acceptsSample = { [weak self] in
            guard let self = self, self.active, !self.paused, self.checkGrant() else { return false }
            self.lastSampleAt = ProcessInfo.processInfo.systemUptime
            return self.encoder.running
        }
    }
    deinit {
        if observing { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(IOSCastMailbox.changedNotification as CFString), nil) }
    }
    func start(finish: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.active else { return }
            self.finish = finish
            do {
                let mailbox = try IOSCastMailbox()
                let grant = try mailbox.grant()
                let now = Date().timeIntervalSince1970
                guard !grant.revoked, now >= grant.issuedAt - 2, now <= grant.selectBefore, now < grant.endBefore else {
                    throw IOSCastError.reason("cast_selection_expired")
                }
                // 已运行同匿名票据不再次消费授权，拒绝扩展被重复启动。
                if let heartbeat = try? mailbox.heartbeat(), heartbeat.id == grant.id, heartbeat.fresh, heartbeat.broadcastActive {
                    throw IOSCastError.reason("cast_session_active")
                }
                self.mailbox = mailbox; self.grant = grant; self.settings = grant.settings; self.active = true
                self.lastSampleAt = ProcessInfo.processInfo.systemUptime
                self.observe()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(250))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                self.beginAttempt()
            } catch { self.fail(IOSCastError.code(error)) }
        }
    }
    private func observe() {
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let engine = Unmanaged<IOSCastBroadcastEngine>.fromOpaque(observer).takeUnretainedValue()
                engine.queue.async { [weak engine] in _ = engine?.checkGrant(force: true) }
            }, IOSCastMailbox.changedNotification as CFString, nil, .deliverImmediately)
    }
    private func checkGrant(force: Bool = false) -> Bool {
        guard active, let old = grant, let mailbox = mailbox else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastGrantCheckAt < 0.2 { return true }
        lastGrantCheckAt = now
        do {
            let current = try mailbox.grant()
            guard current.id == old.id, current.targetIP == old.targetIP, !current.revoked,
                  Date().timeIntervalSince1970 < current.endBefore else {
                fail(current.reason.isEmpty ? "cast_session_revoked" : current.reason); return false
            }
            // 活跃流的尺寸/格式已协商，不能无声改配置。setTier 仅主 App 空闲态设置。
            guard current.settings.tier == old.settings.tier, current.settings.extended == old.settings.extended,
                  current.settings.maxWidth == old.settings.maxWidth, current.settings.maxHeight == old.settings.maxHeight,
                  current.settings.maxFPS == old.settings.maxFPS, current.settings.maxBitrate == old.settings.maxBitrate else {
                fail("cast_settings_changed"); return false
            }
            return true
        } catch { fail("cast_grant_unavailable"); return false }
    }
    private func beginAttempt() {
        guard active, checkGrant(), let grant = grant else { return }
        teardownTransport()
        generation &+= 1
        let epoch = generation
        attemptStarted = ProcessInfo.processInfo.systemUptime
        castingStarted = 0; lastSentAt = 0; attemptFrames = 0; frameIndex = 0; consecutiveEmpty = 0
        plan = nil; probeAccepted = false; phase = retries == 0 ? "provisioning" : "adapting"
        do {
            for port in [ports.data, ports.media, ports.control] {
                let listener = try NWListener(using: IOSCastTarget.wifiParameters(), on: NWEndpoint.Port(rawValue: port)!)
                listeners[port] = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self = self, self.active, self.generation == epoch, let listener = listener,
                          self.listeners[port] === listener else { return }
                    switch state {
                    case .ready:
                        self.listenerReady.insert(port)
                        if self.listenerReady.count == 3 { self.beginProbe(epoch: epoch, target: grant.targetIP) }
                    case let .failed(error):
                        self.fail(IOSCastError.network(error) == "local_network_permission_denied" ? "local_network_permission_denied" : "listener_port_unavailable")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self, self.active, self.generation == epoch else { connection.cancel(); return }
                    guard case let .hostPort(host, _) = connection.endpoint, case let .ipv4(ip) = host,
                          ip == IPv4Address(grant.targetIP) else { connection.cancel(); return }
                    // 探测成功之前只保留每口最新的一条，不解析/应答陌生未就绪会话。
                    if !self.probeAccepted {
                        self.pending.removeValue(forKey: port)?.cancel(); self.pending[port] = connection
                    } else { self.accept(connection, port: port, epoch: epoch) }
                }
                listener.start(queue: queue)
            }
            publish()
        } catch { fail("listener_port_unavailable") }
    }
    private func beginProbe(epoch: UInt64, target: String) {
        guard active, generation == epoch, probe == nil else { return }
        let connection = NWConnection(host: .ipv4(IPv4Address(target)!), port: NWEndpoint.Port(rawValue: ports.probe)!,
                                      using: IOSCastTarget.wifiParameters())
        let socket = IOSCastSocket(connection, queue: queue, control: true)
        probe = socket; probeDeadline = ProcessInfo.processInfo.systemUptime + 4
        socket.onClosed = { [weak self, weak socket] code in
            guard let self = self, self.active, self.generation == epoch, self.probe === socket else { return }
            self.fail(["cast_peer_rejected", "local_network_permission_denied"].contains(code) ? code : "vehicle_status_unavailable")
        }
        socket.onControl = { [weak self, weak socket] frame, _ in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.probe === socket else { return }
            guard frame.type == self.recipe.probe.responseType,
                  let body = try? IOSCastWire.object(frame.body),
                  let status = body[self.recipe.probe.statusKey] as? NSNumber, CFGetTypeID(status) == CFBooleanGetTypeID(), status.boolValue else {
                self.fail("vehicle_status_rejected"); return
            }
            self.probe = nil; socket.onClosed = nil; socket.close("probe_complete")
            self.probeAccepted = true; self.phase = "handshaking"; self.reason = "waiting_vehicle_connections"
            let pending = self.pending; self.pending.removeAll()
            for (port, connection) in pending { self.accept(connection, port: port, epoch: epoch) }
            self.publish()
        }
        socket.start(expectedIP: target) { [weak self, weak socket] in
            guard let self = self, let socket = socket, self.active, self.generation == epoch else { return }
            do {
                let body = try self.recipe.render(self.recipe.probe.requestJSON)
                socket.send(try IOSCastWire.control(self.recipe.probe.requestType, body: body)) {
                    self.probeDeadline = ProcessInfo.processInfo.systemUptime + 4
                }
            } catch { self.fail(IOSCastError.code(error)) }
        }
    }
    private func accept(_ connection: NWConnection, port: UInt16, epoch: UInt64) {
        guard let grant = grant, active, generation == epoch else { connection.cancel(); return }
        if let old = sockets.removeValue(forKey: port) { old.onClosed = nil; old.close("replaced") }
        connected.remove(port)
        if port == ports.data { frameIndex = 0; encoder.resetDelivery() }
        let socket = IOSCastSocket(connection, queue: queue, control: port == ports.control)
        sockets[port] = socket
        socket.onClosed = { [weak self, weak socket] code in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.sockets[port] === socket else { return }
            self.connected.remove(port); self.sockets.removeValue(forKey: port)
            self.channelEnded(port: port, reason: code)
        }
        socket.onControl = { [weak self, weak socket] frame, next in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.sockets[port] === socket,
                  self.checkGrant() else { return }
            do {
                guard let rule = self.recipe.control.first(where: { $0.request == frame.type }), rule.action != "ignore" else { next(); return }
                let replies = try socket.replies(rule, body: frame.body, recipe: self.recipe)
                if replies.isEmpty { next() }
                else if replies.count == 1 { socket.send(replies[0], completion: next) }
                else { socket.send(replies[0]) { socket.send(replies[1], completion: next) } }
            } catch { self.fail(IOSCastError.code(error)) }
        }
        socket.onMedia = { [weak self, weak socket] frame, next in
            guard let self = self, let socket = socket, self.active, self.generation == epoch,
                  self.sockets[port] === socket, self.checkGrant() else { return }
            if port == self.ports.data { self.pull(frame, socket: socket, epoch: epoch, next: next) }
            else { self.media(frame, socket: socket, next: next) }
        }
        socket.start(expectedIP: grant.targetIP) { [weak self, weak socket] in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.sockets[port] === socket else { return }
            self.connected.insert(port)
            self.reason = self.connected.count == 3 ? "waiting_vehicle_start" : "waiting_vehicle_connections"
            self.publish()
        }
    }
    private func media(_ frame: IOSCastWire.Media, socket: IOSCastSocket, next: @escaping () -> Void) {
        do {
            guard let rule = recipe.media.first(where: { $0.request == frame.command }), rule.action != "ignore" else { next(); return }
            guard let command = rule.reply else { throw IOSCastError.reason("cast_recipe_invalid") }
            switch rule.action {
            case "configure":
                let config = try recipe.parseCapture(frame.body)
                if !encoder.running { plan = try recipe.plan(config, settings) }
                guard let plan = plan else { throw IOSCastError.reason("media_config_invalid") }
                socket.send(try IOSCastWire.media(command, serial: frame.serial, body: recipe.acknowledgement(plan)), completion: next)
            case "start":
                if plan == nil { plan = try recipe.plan(recipe.fallback, settings) }
                guard let plan = plan, probeAccepted else { throw IOSCastError.reason("vehicle_status_unavailable") }
                if !encoder.running {
                    try encoder.start(plan)
                    castingStarted = ProcessInfo.processInfo.systemUptime; lastSampleAt = castingStarted
                    phase = "handshaking"; reason = "waiting_frame_pull"
                }
                // VT session/hardware 准备成功才 ACK；仍不等于接收端真正拉到视频。
                socket.send(try IOSCastWire.media(command, serial: frame.serial)) { self.publish(); next() }
            case "keyframe":
                encoder.requestKeyframe()
                socket.send(try IOSCastWire.media(command, serial: frame.serial), completion: next)
            default:
                let body = rule.bodyBase64.flatMap { Data(base64Encoded: $0) } ?? Data()
                socket.send(try IOSCastWire.media(command, serial: frame.serial, body: body), completion: next)
            }
        } catch { fail(IOSCastError.code(error)) }
    }
    private func pull(_ request: IOSCastWire.Media, socket: IOSCastSocket, epoch: UInt64, next: @escaping () -> Void) {
        guard request.command == recipe.pullCommand else { next(); return }
        guard request.body.isEmpty else { fail("data_frame_invalid"); return }
        if let frame = paused ? nil : encoder.poll() { deliver(frame, socket: socket, next: next); return }
        // 与 Android 25 ms 等待一致，但不阻塞串行编码队列；这期间不接下一条拉帧。
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak socket] in
            guard let self = self, let socket = socket, self.active, self.generation == epoch,
                  self.sockets[self.ports.data] === socket, self.checkGrant() else { return }
            self.deliver(self.paused ? nil : self.encoder.poll(), socket: socket, next: next)
        }
    }
    private func deliver(_ frame: IOSCastEncoder.Frame?, socket: IOSCastSocket, next: @escaping () -> Void) {
        do {
            let packet = try IOSCastWire.packet(frame?.bytes, index: frameIndex, extended: plan?.extended == true)
            socket.send(packet) { [weak self] in
                guard let self = self, self.active else { return }
                if let frame = frame {
                    self.sentFrames &+= 1; self.attemptFrames &+= 1; self.sentBytes &+= UInt64(packet.count)
                    if frame.keyframe { self.keyframes &+= 1 }
                    if self.plan?.extended == true { self.frameIndex &+= 1 }
                    self.consecutiveEmpty = 0; self.lastSentAt = ProcessInfo.processInfo.systemUptime
                    // 只有真视频写完且三口真实ready才 casting，不把空包或 VT start 当 streaming。
                    if self.connected.count == 3 { self.phase = "casting"; self.reason = "" }
                } else {
                    self.emptyPulls &+= 1; self.consecutiveEmpty += 1
                    if self.consecutiveEmpty >= 40 { self.consecutiveEmpty = 0; self.encoder.requestKeyframe() }
                }
                next()
            }
        } catch { fail(IOSCastError.code(error)) }
    }
    private func channelEnded(port: UInt16, reason: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - castingStarted
        if port != ports.control, castingStarted > 0, elapsed >= 0, elapsed < 15,
           attemptFrames > 0, retries < 5, let index = recipe.tiers.firstIndex(where: { $0.id == settings.tier }),
           index + 1 < recipe.tiers.count {
            settings.tier = recipe.tiers[index + 1].id; retries += 1
            phase = "adapting"; self.reason = "compatibility_downgrade"
            teardownTransport(); generation &+= 1
            let epoch = generation
            publish()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.active, self.generation == epoch, self.checkGrant() else { return }
                self.beginAttempt()
            }
        } else { fail(reason) }
    }
    func video(_ sample: CMSampleBuffer) { encoder.submit(sample) }
    func pause() { queue.async { [weak self] in
        guard let self = self, self.active else { return }
        self.paused = true; self.phase = "handshaking"; self.reason = "broadcast_paused"; self.encoder.resetDelivery(); self.publish()
    } }
    func resume() { queue.async { [weak self] in
        guard let self = self, self.active else { return }
        self.paused = false; self.lastSampleAt = ProcessInfo.processInfo.systemUptime
        self.phase = "handshaking"; self.reason = "waiting_frame_pull"; self.encoder.resetDelivery(); self.publish()
    } }
    func stop() { queue.async { [weak self] in self?.end("idle", reason: "user_stopped", notifySystem: false) } }
    private func tick() {
        guard active, checkGrant() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if probe != nil, now > probeDeadline { fail("vehicle_status_unavailable"); return }
        if castingStarted == 0, now - attemptStarted > 35 { fail("frame_pull_timeout"); return }
        if castingStarted > 0, !paused {
            if now - lastSampleAt > 10 { fail("screen_capture_timeout"); return }
            // 空闲与半包/写阻塞分开：停止拉帧15s失败，半包/写阻塞2s失败。
            if lastSentAt > 0, now - lastSentAt > 15 { fail("frame_pull_timeout"); return }
            if lastSentAt == 0, now - castingStarted > 35 { fail("first_frame_timeout"); return }
        }
        for (port, socket) in Array(sockets) {
            socket.tick(idleLimit: port == ports.control ? nil : 60,
                        ioLimit: port == ports.data && encoder.running ? 2 : 15)
            if !active { return }
        }
        if now - lastPublishAt >= 1 { publish() }
    }
    private func publish() {
        guard let mailbox = mailbox, let grant = grant else { return }
        let heartbeat = IOSCastHeartbeat(version: 1, id: grant.id, updatedAt: Date().timeIntervalSince1970,
            phase: phase, reason: reason, broadcastActive: active, probeAccepted: probeAccepted,
            listenersReady: listenerReady.sorted(), connectedPorts: connected.sorted(), expectedPorts: ports.listeners.sorted(), encoderReady: encoder.running,
            sentFrames: sentFrames, sentBytes: sentBytes, keyframes: keyframes, emptyPulls: emptyPulls,
            droppedFrames: encoder.droppedFrames, tier: settings.tier, retries: retries,
            width: plan?.width ?? 0, height: plan?.height ?? 0, fps: plan?.fps ?? 0, bitrate: plan?.bitrate ?? 0)
        do { try mailbox.setHeartbeat(heartbeat); lastPublishAt = ProcessInfo.processInfo.systemUptime }
        catch { if active { end("failed", reason: "cast_heartbeat_write_failed", notifySystem: true, publishFinal: false) } }
    }
    private func teardownTransport() {
        probe?.onClosed = nil; probe?.close("stopped"); probe = nil
        for socket in sockets.values { socket.onClosed = nil; socket.close("stopped") }
        sockets.removeAll(); connected.removeAll()
        for connection in pending.values { connection.cancel() }; pending.removeAll()
        for listener in listeners.values { listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel() }
        listeners.removeAll(); listenerReady.removeAll(); encoder.stop()
    }
    private func fail(_ reason: String) {
        let stopped = ["user_stopped", "profile_forgotten", "cast_cancelled", "projection_cancelled"].contains(reason)
        end(stopped ? "idle" : "failed", reason: reason, notifySystem: true)
    }
    private func end(_ phase: String, reason: String, notifySystem: Bool, publishFinal: Bool = true) {
        guard active || finish != nil else { return }
        active = false; generation &+= 1; self.phase = phase; self.reason = reason
        timer?.cancel(); timer = nil; teardownTransport()
        if observing {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(IOSCastMailbox.changedNotification as CFString), nil)
            observing = false
        }
        if publishFinal { publish() }
        // 用户系统终止也使短期票据不可重用；不能下一次控制中心开启复用旧会话。
        if let grant = grant { try? mailbox?.revoke(grant.id, reason: reason) }
        let callback = finish; finish = nil
        if notifySystem { callback?(reason) }
    }
}
