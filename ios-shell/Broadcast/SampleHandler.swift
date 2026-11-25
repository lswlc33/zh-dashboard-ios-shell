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
    private var routeMonitor: NWPathMonitor?
    private var routePath: Network.NWPath?
    private var finish: ((String) -> Void)?
    private var observing = false
    private var active = false
    private var paused = false
    private var generation: UInt64 = 0
    private var listeners: [UInt16: NWListener] = [:]
    private var listenerReady: Set<UInt16> = []
    private var sockets: [UInt16: IOSCastSocket] = [:]
    private var controlSockets: [IOSCastSocket] = []
    private var sessionControl: IOSCastSocket?
    private var castIdentity: IOSCastIdentity?
    private var sessionIdentity: Data?
    private var sessionStarted = false
    private var nextControlIdentifier: UInt32 = 1
    private var nextKeepAlive = Double.infinity
    private var configured = false
    private var prefixedVideo = false
    private var screen: [String: Int] = [:]
    private let screenLock = NSLock()
    private var submittedScreen: [String: Int] = [:]
    // ReplayKit 可能只在握手前交付静止画面；锁下仅保留最后一份有效输入供后续拉帧重编码。
    private var submittedSample: CMSampleBuffer?
    private var acceptingSamples = false
    private var waitingSessionStart: (() -> Void)?
    private var connected: Set<UInt16> = []
    private var pending: [UInt16: [NWConnection]] = [:]
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
            // 最新真实帧可供静止画面反复编码；这里记录编码活性，不要求 ReplayKit 持续回调。
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
        screenLock.lock(); acceptingSamples = true; screenLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.active else { return }
            self.finish = finish
            do {
                let mailbox = try IOSCastMailbox()
                let grant = try mailbox.grant()
                guard let extensionID = Bundle.main.bundleIdentifier,
                      IOSCastMailbox.validExtensionID(extensionID), grant.extensionID == extensionID else {
                    throw IOSCastError.reason("cast_extension_mismatch")
                }
                let now = Date().timeIntervalSince1970
                guard !grant.revoked, now >= grant.issuedAt - 2, now <= grant.selectBefore, now < grant.endBefore else {
                    throw IOSCastError.reason("cast_selection_expired")
                }
                // 已运行同匿名票据不再次消费授权，拒绝扩展被重复启动。
                if let heartbeat = try? mailbox.heartbeat(), heartbeat.id == grant.id, heartbeat.fresh, heartbeat.broadcastActive {
                    throw IOSCastError.reason("cast_session_active")
                }
                guard let route = grant.route, route.valid, route.targetIP == grant.targetIP else {
                    throw IOSCastError.reason("cast_route_required")
                }
                if let error = route.sourceError() { throw IOSCastError.reason(error) }
                self.castIdentity = try IOSCastIdentity(bits: grant.recipe.session?.rsaBits ?? 1024)
                self.mailbox = mailbox; self.grant = grant; self.settings = grant.settings; self.active = true
                self.lastSampleAt = ProcessInfo.processInfo.systemUptime
                self.observe()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(250))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                // 扩展重新解析同一个真实接口；未收到路径证据前不监听或探测。
                self.attemptStarted = ProcessInfo.processInfo.systemUptime
                let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
                self.routeMonitor = monitor
                monitor.pathUpdateHandler = { [weak self] path in
                    guard let self = self, self.active else { return }
                    if let error = route.pathError(path) { self.fail(error); return }
                    let firstPath = self.routePath == nil
                    self.routePath = path
                    if firstPath { self.beginAttempt() }
                }
                monitor.start(queue: self.queue)
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
            guard current.id == old.id, current.extensionID == old.extensionID, current.targetIP == old.targetIP,
                  current.route == old.route, !current.revoked,
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
        guard active, checkGrant(), let grant = grant, let route = grant.route, let path = routePath else { return }
        if let error = route.pathError(path) { fail(error); return }
        guard let interface = route.interface(in: path) else { fail("cast_interface_changed"); return }
        teardownTransport()
        generation &+= 1
        let epoch = generation
        attemptStarted = ProcessInfo.processInfo.systemUptime
        castingStarted = 0; lastSentAt = 0; attemptFrames = 0; frameIndex = 0; consecutiveEmpty = 0
        plan = nil; probeAccepted = false; phase = retries == 0 ? "provisioning" : "adapting"
        do {
            for port in [ports.data, ports.media, ports.control] {
                let parameters = try route.parameters(interface: interface, port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                listeners[port] = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self = self, self.active, self.generation == epoch, let listener = listener,
                          self.listeners[port] === listener else { return }
                    switch state {
                    case .ready:
                        self.listenerReady.insert(port)
                        if self.listenerReady.count == 3 { self.beginProbe(epoch: epoch, target: grant.targetIP) }
                    case let .failed(error):
                        let code = IOSCastError.network(error)
                        self.fail(IOSCastError.routeFailure(code) ? code : "listener_port_unavailable")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self, self.active, self.generation == epoch else { connection.cancel(); return }
                    guard case let .hostPort(host, _) = connection.endpoint, case let .ipv4(ip) = host,
                          ip == IPv4Address(grant.targetIP) else { connection.cancel(); return }
                    // 控制口最多两条（主控/反向状态）；探测前仍不解析，禁止无界待接队列。
                    if !self.probeAccepted {
                        let limit = port == self.ports.control ? 2 : 1
                        guard self.pending[port, default: []].count < limit else { connection.cancel(); return }
                        self.pending[port, default: []].append(connection)
                    } else { self.accept(connection, port: port, epoch: epoch) }
                }
                listener.start(queue: queue)
            }
            publish()
        } catch {
            let code = IOSCastError.code(error)
            fail(IOSCastError.routeFailure(code) ? code : "listener_port_unavailable")
        }
    }
    private func beginProbe(epoch: UInt64, target: String) {
        guard active, generation == epoch, probe == nil, let route = grant?.route, let path = routePath else { return }
        if let error = route.pathError(path) { fail(error); return }
        guard let interface = route.interface(in: path) else { fail("cast_interface_changed"); return }
        let parameters: NWParameters
        do { parameters = try route.parameters(interface: interface) }
        catch { fail(IOSCastError.code(error)); return }
        let connection = NWConnection(host: .ipv4(IPv4Address(target)!), port: NWEndpoint.Port(rawValue: ports.probe)!,
                                      using: parameters)
        let socket = IOSCastSocket(connection, queue: queue, control: true, route: route)
        probe = socket; probeDeadline = ProcessInfo.processInfo.systemUptime + 4
        socket.onClosed = { [weak self, weak socket] code in
            guard let self = self, self.active, self.generation == epoch, self.probe === socket else { return }
            self.fail(IOSCastError.routeFailure(code) || code == "cast_peer_rejected" ? code : "vehicle_status_unavailable")
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
            for (port, connections) in pending { for connection in connections { self.accept(connection, port: port, epoch: epoch) } }
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
    private func holds(_ socket: IOSCastSocket, port: UInt16) -> Bool {
        port == ports.control ? controlSockets.contains { $0 === socket } : sockets[port] === socket
    }
    private func accept(_ connection: NWConnection, port: UInt16, epoch: UInt64) {
        guard let grant = grant, let route = grant.route, active, generation == epoch else { connection.cancel(); return }
        if port == ports.control {
            guard controlSockets.count < 2 else { connection.cancel(); return }
        } else if let old = sockets.removeValue(forKey: port) { old.onClosed = nil; old.close("replaced") }
        if port != ports.control { connected.remove(port) }
        if port == ports.data {
            frameIndex = 0; prefixedVideo = false
            do { try restartEncoderDelivery() }
            catch { connection.cancel(); fail(IOSCastError.code(error)); return }
        }
        let socket = IOSCastSocket(connection, queue: queue, control: port == ports.control, route: route,
                                   identity: port == ports.control ? castIdentity : nil)
        if port == ports.control { controlSockets.append(socket) } else { sockets[port] = socket }
        socket.onClosed = { [weak self, weak socket] code in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.holds(socket, port: port) else { return }
            self.connected.remove(port)
            if port == self.ports.control { self.controlSockets.removeAll { $0 === socket } }
            else { self.sockets.removeValue(forKey: port) }
            self.channelEnded(port: port, reason: code)
        }
        socket.onControl = { [weak self, weak socket] frame, next in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.holds(socket, port: port),
                  self.checkGrant() else { return }
            self.control(frame, socket: socket, epoch: epoch, next: next)
        }
        socket.onMedia = { [weak self, weak socket] frame, next in
            guard let self = self, let socket = socket, self.active, self.generation == epoch,
                  self.holds(socket, port: port), self.checkGrant() else { return }
            if port == self.ports.data { self.pull(frame, socket: socket, epoch: epoch, next: next) }
            else { self.media(frame, socket: socket, next: next) }
        }
        socket.start(expectedIP: grant.targetIP) { [weak self, weak socket] in
            guard let self = self, let socket = socket, self.active, self.generation == epoch, self.holds(socket, port: port) else { return }
            self.connected.insert(port)
            self.reason = self.connected.count == 3 ? "waiting_vehicle_start" : "waiting_vehicle_connections"
            self.publish()
        }
    }
    private func control(_ frame: IOSCastWire.Control, socket: IOSCastSocket, epoch: UInt64, next: @escaping () -> Void) {
        guard active, generation == epoch, holds(socket, port: ports.control) else { return }
        screenLock.lock(); screen = submittedScreen; screenLock.unlock()
        if recipe.session?.request == frame.type, screen.isEmpty {
            guard waitingSessionStart == nil else { fail("control_frame_invalid"); return }
            waitingSessionStart = { [weak self, weak socket] in
                guard let self = self, let socket = socket else { return }
                self.control(frame, socket: socket, epoch: epoch, next: next)
            }
            return
        }
        do {
            guard let rule = recipe.control.first(where: { $0.request == frame.type }), rule.action != "ignore" else { next(); return }
            let replies = try socket.replies(rule, frame: frame, recipe: recipe)
            if rule.action == "rsa" {
                guard let signature = socket.signedIdentity else { throw IOSCastError.reason("cast_identity_missing") }
                if let previous = sessionIdentity, previous != signature {
                    throw IOSCastError.reason("cast_identity_mismatch")
                }
                sessionIdentity = signature
            }
            var output = replies.reduce(into: Data()) { $0.append($1) }
            let starts = recipe.session?.request == frame.type && !sessionStarted
            if starts, let session = recipe.session {
                for message in session.start { output.append(try sessionMessage(message)) }
                sessionControl = socket; sessionStarted = true
            }
            let completed = { [weak self] in
                guard let self = self, self.active, self.generation == epoch else { return }
                if starts, let session = self.recipe.session {
                    self.nextKeepAlive = ProcessInfo.processInfo.systemUptime + Double(session.heartbeatMilliseconds) / 1000
                }
                next()
            }
            if output.isEmpty { completed() } else { socket.send(output, completion: completed) }
        } catch { fail(IOSCastError.code(error)) }
    }
    private func sessionMessage(_ message: IOSCastRecipe.Reply) throws -> Data {
        let body = try message.json.map { try recipe.render($0, screen: screen) } ?? Data()
        let identifier = nextControlIdentifier; nextControlIdentifier &+= 1
        return try IOSCastWire.control(message.type, identifier: identifier, body: body)
    }
    private func media(_ frame: IOSCastWire.Media, socket: IOSCastSocket, next: @escaping () -> Void) {
        do {
            guard let rule = recipe.media.first(where: { $0.request == frame.command }), rule.action != "ignore" else { next(); return }
            guard let command = rule.reply else { throw IOSCastError.reason("cast_recipe_invalid") }
            switch rule.action {
            case "configure":
                if let offset = recipe.capture.signatureOffset {
                    guard frame.body.count > offset, frame.body.count - offset <= 1024,
                          let expected = sessionIdentity else { throw IOSCastError.reason("media_identity_missing") }
                    var echo = Data(frame.body.dropFirst(offset))
                    while echo.last == 0 { echo.removeLast() }
                    guard let signature = Data(base64Encoded: echo), signature == expected else {
                        throw IOSCastError.reason("media_identity_mismatch")
                    }
                }
                let config = try recipe.parseCapture(frame.body)
                if !encoder.running { plan = try recipe.plan(config, settings) }
                guard let plan = plan else { throw IOSCastError.reason("media_config_invalid") }
                configured = true
                socket.send(try IOSCastWire.media(command, serial: frame.serial, body: recipe.acknowledgement(plan)), completion: next)
            case "start":
                if recipe.capture.signatureOffset != nil, !configured { throw IOSCastError.reason("media_config_required") }
                if plan == nil { plan = try recipe.plan(recipe.fallback, settings) }
                guard let plan = plan, probeAccepted else { throw IOSCastError.reason("vehicle_status_unavailable") }
                if !encoder.running {
                    try encoder.start(plan)
                    castingStarted = ProcessInfo.processInfo.systemUptime; lastSampleAt = castingStarted
                    phase = "handshaking"; reason = "waiting_frame_pull"
                    submitLatestSample(epoch: generation)
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
        if recipe.session?.waitForFrame == true {
            waitForVideo(socket: socket, epoch: epoch, deadline: nil, next: next)
            return
        }
        if let frame = paused ? nil : encoder.poll() { deliver(frame, socket: socket, next: next); return }
        submitLatestSample(epoch: epoch)
        // 与 Android 25 ms 等待一致，但不阻塞串行编码队列；这期间不接下一条拉帧。
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak socket] in
            guard let self = self, let socket = socket, self.active, self.generation == epoch,
                  self.sockets[self.ports.data] === socket, self.checkGrant() else { return }
            self.deliver(self.paused ? nil : self.encoder.poll(), socket: socket, next: next)
        }
    }
    private func waitForVideo(socket: IOSCastSocket, epoch: UInt64, deadline: TimeInterval?, next: @escaping () -> Void) {
        guard active, generation == epoch, sockets[ports.data] === socket, checkGrant() else { return }
        // 数据口可先于控制/媒体启动；暂停和协商阶段不消耗真正的首帧等待窗口。
        guard !paused, sessionStarted, encoder.running else {
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak socket] in
                guard let self = self, let socket = socket else { return }
                self.waitForVideo(socket: socket, epoch: epoch, deadline: nil, next: next)
            }
            return
        }
        if let frame = encoder.poll() { deliver(frame, socket: socket, next: next); return }
        let now = ProcessInfo.processInfo.systemUptime
        let frameDeadline = max(deadline ?? now + 5, castingStarted + 5)
        guard now < frameDeadline else { fail("first_frame_timeout"); return }
        // ReplayKit 静止时可不再回调；按车机拉帧节奏重编码最新真实画面，仍由 fps/inFlight 限流。
        submitLatestSample(epoch: epoch)
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak socket] in
            guard let self = self, let socket = socket else { return }
            self.waitForVideo(socket: socket, epoch: epoch, deadline: frameDeadline, next: next)
        }
    }
    private func deliver(_ frame: IOSCastEncoder.Frame?, socket: IOSCastSocket, next: @escaping () -> Void) {
        do {
            var packet = try IOSCastWire.packet(frame?.bytes, index: frameIndex, extended: plan?.extended == true)
            if frame != nil, !prefixedVideo, let session = recipe.session {
                packet = Data(repeating: 0, count: session.firstFrameZeroBytes) + packet
            }
            socket.send(packet) { [weak self] in
                guard let self = self, self.active else { return }
                if let frame = frame {
                    self.prefixedVideo = true
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
        guard !IOSCastError.routeFailure(reason) else { fail(reason); return }
        if let error = grant?.route?.sourceError() { fail(error); return }
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
    func video(_ sample: CMSampleBuffer) {
        var dimensions: [String: Int]?
        if let image = CMSampleBufferGetImageBuffer(sample) {
            let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
            if (16...4096).contains(width), (16...4096).contains(height) {
                let orientation = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.intValue ?? 1
                let rotation = [1: 0, 3: 2, 6: 1, 8: 3][orientation] ?? 0
                dimensions = ["width": width, "height": height, "rotation": rotation]
            }
        }
        screenLock.lock()
        guard acceptingSamples else { screenLock.unlock(); return }
        if let dimensions = dimensions, CMSampleBufferDataIsReady(sample) {
            submittedScreen = dimensions
            submittedSample = sample
        }
        screenLock.unlock()
        encoder.submit(sample)
    }
    private func submitLatestSample(epoch: UInt64) {
        // 先让已入队的 submit 释放 inputGate，再重交缓存；不阻塞串行握手/编码队列。
        queue.async { [weak self] in
            guard let self = self, self.active, self.generation == epoch, self.encoder.running, !self.paused else { return }
            self.screenLock.lock(); let sample = self.submittedSample; self.screenLock.unlock()
            if let sample = sample { self.encoder.submit(sample) }
        }
    }
    private func restartEncoderDelivery() throws {
        guard encoder.running else { return }
        guard let plan = plan else { throw IOSCastError.reason("media_config_invalid") }
        // 同 PTS 的静态画面也必须重编码为 IDR；重建隔离旧 VT 回调，清掉旧时间戳和参考链。
        encoder.stop(); try encoder.start(plan)
        let now = ProcessInfo.processInfo.systemUptime
        castingStarted = now; lastSampleAt = now
        if lastSentAt > 0 { lastSentAt = now }
        submitLatestSample(epoch: generation)
    }
    func pause() { queue.async { [weak self] in
        guard let self = self, self.active else { return }
        self.paused = true; self.phase = "handshaking"; self.reason = "broadcast_paused"; self.encoder.resetDelivery(); self.publish()
    } }
    func resume() { queue.async { [weak self] in
        guard let self = self, self.active else { return }
        self.paused = false
        do {
            try self.restartEncoderDelivery()
            self.phase = "handshaking"; self.reason = "waiting_frame_pull"; self.publish()
        } catch { self.fail(IOSCastError.code(error)) }
    } }
    func stop() { queue.async { [weak self] in self?.end("idle", reason: "user_stopped", notifySystem: false) } }
    private func tick() {
        guard active, checkGrant() else { return }
        if let error = grant?.route?.sourceError() { fail(error); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let resume = waitingSessionStart {
            screenLock.lock(); let hasScreen = !submittedScreen.isEmpty; screenLock.unlock()
            if hasScreen { waitingSessionStart = nil; resume() }
            if !active { return }
        }
        if now >= nextKeepAlive, let session = recipe.session, let socket = sessionControl, socket.writeSince == nil {
            do {
                nextKeepAlive = now + Double(session.heartbeatMilliseconds) / 1000
                socket.send(try sessionMessage(session.heartbeat)) {}
            } catch { fail(IOSCastError.code(error)); return }
        }
        if probe != nil, now > probeDeadline { fail("vehicle_status_unavailable"); return }
        if castingStarted == 0, now - attemptStarted > 35 { fail("frame_pull_timeout"); return }
        if castingStarted > 0, !paused {
            if now - lastSampleAt > 10 { fail("screen_capture_timeout"); return }
            // 空闲与半包/写阻塞分开：停止拉帧15s失败，半包/写阻塞2s失败。
            if lastSentAt > 0, now - lastSentAt > 15 { fail("frame_pull_timeout"); return }
            if lastSentAt == 0, now - castingStarted > 35 { fail("first_frame_timeout"); return }
        }
        // 媒体控制口握手后可长期静默，暂停也会停止拉帧；会话活性由上面的帧流超时判断。
        for (port, socket) in Array(sockets) {
            socket.tick(ioLimit: port == ports.data && encoder.running ? 2 : 15)
            if !active { return }
        }
        for socket in Array(controlSockets) {
            socket.tick(ioLimit: 15)
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
        for socket in controlSockets { socket.onClosed = nil; socket.close("stopped") }
        controlSockets.removeAll(); sessionControl = nil; sessionIdentity = nil; sessionStarted = false
        nextControlIdentifier = 1; nextKeepAlive = .infinity; configured = false; prefixedVideo = false; waitingSessionStart = nil
        sockets.removeAll(); connected.removeAll()
        for connections in pending.values { connections.forEach { $0.cancel() } }; pending.removeAll()
        for listener in listeners.values { listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel() }
        listeners.removeAll(); listenerReady.removeAll(); encoder.stop()
    }
    private func fail(_ reason: String) {
        let stopped = ["user_stopped", "profile_forgotten", "cast_cancelled", "projection_cancelled"].contains(reason)
        end(stopped ? "idle" : "failed", reason: reason, notifySystem: true)
    }
    private func end(_ phase: String, reason: String, notifySystem: Bool, publishFinal: Bool = true) {
        guard active || finish != nil else { return }
        let stopSocket = phase == "idle" && grant?.route?.sourceError() == nil ? sessionControl : nil
        let stopBytes = grant?.recipe.session.flatMap { try? sessionMessage($0.stop) }
        // 停止后先隔离所有回调/编码；最多给本已验证的控制连接 250ms 完成停止通知。
        if let socket = stopSocket, let bytes = stopBytes, !socket.closed, socket.writeSince == nil {
            controlSockets.removeAll { $0 === socket }
            socket.onClosed = nil; socket.onControl = nil; socket.onMedia = nil
            socket.send(bytes) { socket.close("stopped") }
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { socket.close("stopped") }
        }
        active = false; generation &+= 1; self.phase = phase; self.reason = reason
        timer?.cancel(); timer = nil
        routeMonitor?.pathUpdateHandler = nil; routeMonitor?.cancel(); routeMonitor = nil; routePath = nil
        teardownTransport()
        castIdentity = nil
        screenLock.lock(); acceptingSamples = false; submittedScreen = [:]; submittedSample = nil; screenLock.unlock()
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
