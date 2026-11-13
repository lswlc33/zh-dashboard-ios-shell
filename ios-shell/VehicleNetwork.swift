import Foundation
import UIKit
import Network
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import Darwin

struct IOSVehicleNetworkError: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

// 只代表可加入的标准 AP。二维码中的 P2P MAC 不构成 iOS 的 Wi-Fi Direct 能力。
struct IOSVehicleWiFiProfile {
    let ssid: String
    let password: String
    let carIP: String
    let hidden: Bool

    init(ssid: String, password: String = "", carIP: String = "192.168.0.1", hidden: Bool = false) throws {
        guard !ssid.isEmpty, ssid.utf8.count <= 32,
              !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              carIP == "192.168.0.1",
              password.isEmpty || (password.utf8.count >= 8 && password.utf8.count <= 63
                && password.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 })) else {
            throw IOSVehicleNetworkError("invalid_wifi_profile")
        }
        self.ssid = ssid; self.password = password; self.carIP = carIP; self.hidden = hidden
    }

    static func parse(_ object: [String: Any]) throws -> IOSVehicleWiFiProfile {
        guard let ssid = object["ssid"] as? String,
              object["password"] == nil || object["password"] is String,
              object["carIp"] == nil || object["carIp"] is String,
              object["hidden"] == nil || object["hidden"] is Bool else {
            throw IOSVehicleNetworkError("invalid_wifi_profile")
        }
        return try IOSVehicleWiFiProfile(ssid: ssid, password: object["password"] as? String ?? "",
                                        carIP: object["carIp"] as? String ?? "192.168.0.1",
                                        hidden: object["hidden"] as? Bool ?? false)
    }
}

// worker 只读取消令牌，账号与 UIKit provider 永远在主线程求值。
final class IOSVehicleCancellation {
    private let lock = NSLock()
    private var cancelled = false
    let deadline: TimeInterval
    init(seconds: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + seconds }
    var valid: Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && ProcessInfo.processInfo.systemUptime < deadline
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        guard valid else { throw IOSVehicleNetworkError("cancelled_or_timeout") }
    }
}

struct IOSVehicleRoute {
    let interface: Network.NWInterface
    let sourceIP: String
    let ssid: String
    let carIP: String

    // Network 与 NetworkExtension/SystemConfiguration 存在同名符号，显式限定到 Network 模块。
    func matches(_ path: Network.NWPath) -> Bool {
        path.status == .satisfied && path.usesInterfaceType(.wifi)
            && !path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.other)
            && path.availableInterfaces.contains(where: { $0.name == interface.name && $0.type == .wifi })
    }

    func parameters() -> Network.NWParameters {
        let tcp = Network.NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = Network.NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        parameters.requiredInterface = interface
        parameters.prohibitedInterfaceTypes = [.cellular, .wiredEthernet, .loopback, .other]
        // NWParameters 没有 localEndpoint；绑定源地址用 requiredLocalEndpoint。
        parameters.requiredLocalEndpoint = .hostPort(host: Network.NWEndpoint.Host(sourceIP),
                                                     port: Network.NWEndpoint.Port.any)
        parameters.includePeerToPeer = false
        return parameters
    }
}

// 一个已核验的、不可换出口的连接。readExact 保留粘包，短读继续收；取消关闭实际 socket。
final class IOSVehicleSocket {
    let route: IOSVehicleRoute
    private let connection: NWConnection
    private let guardRoute: (@escaping (Bool) -> Void) -> Void
    private var buffer = Data()
    private var reader: ((Result<Data, Error>) -> Void)?
    private var requested = 0
    private var readTimer: DispatchWorkItem?
    private var closed = false
    private var writing = false
    private var eof = false
    var onInvalidated: (() -> Void)?
    var onClosed: (() -> Void)?
    var pathVerified: Bool { !closed && connection.currentPath.map(route.matches) == true }

    init(connection: NWConnection, route: IOSVehicleRoute,
         guardRoute: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.connection = connection; self.route = route; self.guardRoute = guardRoute
        connection.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if !self.route.matches(path) { self.cancel(); self.onInvalidated?() }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled: self.cancel(); self.onInvalidated?()
            default: break
            }
        }
    }

    func send(_ bytes: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !closed, !writing, bytes.count <= 65546 else {
            completion(.failure(IOSVehicleNetworkError("socket_unavailable"))); return
        }
        writing = true
        guardRoute { [weak self] valid in
            guard let self = self, !self.closed, valid, let path = self.connection.currentPath,
                  self.route.matches(path) else {
                self?.writing = false; self?.cancel()
                completion(.failure(IOSVehicleNetworkError("route_lost"))); return
            }
            self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                self?.writing = false
                if let error = error { self?.cancel(); completion(.failure(error)) }
                else if self?.closed != false { completion(.failure(IOSVehicleNetworkError("cancelled"))) }
                else { completion(.success(())) }
            })
        }
    }

    func readExact(_ count: Int, timeoutMs: Int = 15000, completion: @escaping (Result<Data, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !closed, reader == nil, count > 0, count <= 65536, timeoutMs >= 1, timeoutMs <= 60000 else {
            completion(.failure(IOSVehicleNetworkError("invalid_read"))); return
        }
        requested = count; reader = completion
        let timer = DispatchWorkItem { [weak self] in self?.cancel(code: "read_timeout") }
        readTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeoutMs) / 1000, execute: timer)
        guardRoute { [weak self] valid in
            guard let self = self, !self.closed else { return }
            guard valid, self.pathVerified else { self.cancel(code: "route_lost"); return }
            self.receive()
        }
    }

    private func receive() {
        guard !closed, reader != nil else { return }
        if buffer.count >= requested {
            let data = Data(buffer.prefix(requested)); buffer.removeFirst(requested)
            guardRoute { [weak self] valid in
                guard let self = self, !self.closed else { return }
                guard valid, self.pathVerified else { self.cancel(code: "route_lost"); return }
                let reply = self.reader; self.reader = nil; self.readTimer?.cancel(); self.readTimer = nil
                reply?(.success(data))
            }
            return
        }
        if eof { cancel(code: "short_read"); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data) }
            self.eof = complete
            if error != nil || self.buffer.count > 131072 || (data?.isEmpty != false && !complete) {
                self.cancel(code: "receive_failed"); return
            }
            self.receive()
        }
    }

    func cancel(code: String = "cancelled") {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true; connection.pathUpdateHandler = nil; connection.stateUpdateHandler = nil
        connection.cancel(); readTimer?.cancel(); readTimer = nil
        buffer.removeAll(); let reply = reader; reader = nil
        let cleanup = onClosed; onClosed = nil; cleanup?()
        reply?(.failure(IOSVehicleNetworkError(code)))
    }

    deinit { connection.cancel() }
}

final class IOSVehicleNetworkService: IOSBridgeCancellableService {
    let methods = ["wifi.status", "wifi.isJoined", "wifi.join", "wifi.leave"]
    private var scopeProvider: (() -> IOSRideScope?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var metadataProvider: (() -> [String: Any]?)?
    private var page: UInt64 = 0
    private var pending: [UUID: IOSVehicleCancellation] = [:]
    private var cancellations: [UUID: () -> Void] = [:]
    /// SSID → 创建者 ownerHash。NEHotspotConfiguration 本身跨启动持久，归属记录若只留内存，
    /// 重启后 wifi.leave 会永远 configuration_not_owned（配置删不掉，只能去系统设置手动删）。
    /// 持久化到 UserDefaults，与配置的生命周期对齐；join 用「系统里已存在」的判断兜住一致性。
    private var configuredOwners: [String: String]
    private var vehicleProfiles: [String: Set<String>] = [:]
    // apply 没有撤销 API；迟到回调清理完前不允许同 SSID 的下一次 apply 竞争。
    private var applyingSSID: String?
    private var liveSockets: [UUID: IOSVehicleSocket] = [:]
    private var allowedPorts: Set<UInt16>

    private static let ownerStore = UserDefaults.standard
    private static let ownerStoreKey = "zeeho.wifi.configuredOwners.v1"

    init(allowedPorts: Set<UInt16> = []) {
        self.allowedPorts = Set(allowedPorts.filter { $0 > 0 }.sorted().prefix(8))
        // 只认字符串值的条目，脏数据直接丢弃而不是崩（dictionary(forKey:) 的 key 恒为 String）。
        let stored = Self.ownerStore.dictionary(forKey: Self.ownerStoreKey) ?? [:]
        self.configuredOwners = stored.reduce(into: [:]) { map, item in
            if let hash = item.value as? String { map[item.key] = hash }
        }
    }

    /// 归属映射落盘：内存与 UserDefaults 一起更新，调用点都在主线程（join/leave 的桥入口）。
    private func persistOwners() {
        Self.ownerStore.set(configuredOwners, forKey: Self.ownerStoreKey)
    }

    func setScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread); scopeProvider = provider
    }
    func setPresenterProvider(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread); presenterProvider = provider
    }
    func setMetadataProvider(_ provider: @escaping () -> [String: Any]?) {
        precondition(Thread.isMainThread); metadataProvider = provider
    }

    private struct WiFiMetadata: Equatable {
        let navigation: String
        let frame: String
        let epoch: Int
    }
    private func metadata(scope: IOSRideScope) throws -> WiFiMetadata {
        guard let value = metadataProvider?(),
              let nav = value["navId"] as? String, !nav.isEmpty,
              let frame = value["frame"] as? String, !frame.isEmpty,
              let epoch = try? IOSWallpaperJSON.integer(value["epoch"], max: Int.max),
              String(epoch) == scope.generation,
              value["accountId"] as? String == scope.accountID, value["vin"] as? String == scope.vin else {
            throw IOSVehicleNetworkError("stale_wifi_context")
        }
        return WiFiMetadata(navigation: nav, frame: frame, epoch: epoch)
    }
    private func validateWiFiContext(_ object: [String: Any], scope: IOSRideScope,
                                     required: Bool) throws -> WiFiMetadata? {
        let keys = ["navigationId", "frame", "epoch"]
        let supplied = keys.filter { object[$0] != nil }
        if !required && supplied.isEmpty { return nil }
        let current = try metadata(scope: scope)
        if required && supplied.count != keys.count { throw IOSVehicleNetworkError("wifi_context_required") }
        // 只读方法可不传 common；一旦传了任何字段，也不能把旧文档身份借给当前车辆。
        if object["navigationId"] != nil, object["navigationId"] as? String != current.navigation {
            throw IOSVehicleNetworkError("stale_wifi_navigation")
        }
        if object["frame"] != nil, object["frame"] as? String != current.frame {
            throw IOSVehicleNetworkError("stale_wifi_frame")
        }
        if let value = object["epoch"] {
            guard let epoch = try? IOSWallpaperJSON.integer(value, max: Int.max), epoch == current.epoch else {
                throw IOSVehicleNetworkError("stale_wifi_epoch")
            }
        }
        return current
    }

    func navigationChanged() {
        precondition(Thread.isMainThread); page &+= 1
        allowedPorts.removeAll()
        pending.values.forEach { $0.cancel() }
        let sockets = Array(liveSockets.values); liveSockets.removeAll()
        sockets.forEach { $0.cancel() }
        Array(cancellations.values).forEach { $0() }
        pending.removeAll(); cancellations.removeAll()
    }
    func applicationBackgrounded() { navigationChanged() }
    func cancel(method: String, args: [Any]) { navigationChanged() }

    private func current(_ scope: IOSRideScope, _ token: IOSVehicleCancellation) -> Bool {
        token.valid && scope.valid && scopeProvider?() == scope
            && UIApplication.shared.applicationState == .active
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count == 1, let object = args.first as? [String: Any],
              let scope = scopeProvider?(), scope.valid else { reply(nil, "authorized_vehicle_required"); return }
        do {
            let captured = try validateWiFiContext(object, scope: scope,
                required: method == "wifi.join" || method == "wifi.leave")
            let revision = page
            let scopedReply: (Any?, String?) -> Void = { [weak self] value, error in
                guard let self = self, self.page == revision, self.scopeProvider?() == scope,
                      captured == nil || (try? self.metadata(scope: scope)) == captured else {
                    reply(nil, "stale_wifi_context"); return
                }
                reply(value, error)
            }
            let profile = try IOSVehicleWiFiProfile.parse(object)
            switch method {
            case "wifi.status", "wifi.isJoined":
                inspectJoined(profile: profile, scope: scope, reply: scopedReply)
            case "wifi.join":
                // joinOnce=true 可在后台约 15 秒断开；桥不开放它，避免长传输隐式掉线。
                guard object["joinOnce"] == nil || (object["joinOnce"] as? Bool) == false else {
                    reply(nil, "join_once_not_supported"); return
                }
                let token = IOSVehicleCancellation(seconds: 35)
                join(profile: profile, scope: scope, cancellation: token) { result in
                    switch result {
                    case .success: self.inspectJoined(profile: profile, scope: scope, reply: scopedReply)
                    case let .failure(error): scopedReply(self.status(profile, connected: false, error: self.code(error)), nil)
                    }
                }
            case "wifi.leave":
                guard configuredOwners[profile.ssid] == scope.ownerHash, applyingSSID == nil else {
                    reply(nil, "configuration_not_owned"); return
                }
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: profile.ssid)
                configuredOwners.removeValue(forKey: profile.ssid)
                persistOwners()
                // removeConfiguration 没有断线回执；必须报告实际状态而不是把调用当已离开。
                inspectJoined(profile: profile, scope: scope) { value, error in
                    var result = value as? [String: Any] ?? [:]
                    result["configurationRemoved"] = true
                    if let joined = result["joined"] as? Bool { result["disconnected"] = !joined }
                    else { result["disconnected"] = NSNull() }
                    scopedReply(result, error)
                }
            default: reply(nil, "unsupported_method")
            }
        } catch { reply(nil, code(error)) }
    }

    func join(profile: IOSVehicleWiFiProfile, scope: IOSRideScope, cancellation token: IOSVehicleCancellation,
              completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard current(scope, token), applyingSSID == nil,
              let presenter = presenterProvider?(), presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else {
            completion(.failure(IOSVehicleNetworkError("foreground_or_wifi_busy"))); return
        }
        let id = UUID(), revision = page
        applyingSSID = profile.ssid; pending[id] = token
        var delivered = false
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard !delivered else { return }; delivered = true
            self?.pending.removeValue(forKey: id); self?.cancellations.removeValue(forKey: id)
            completion(result)
        }
        cancellations[id] = { token.cancel(); finish(.failure(IOSVehicleNetworkError("cancelled"))) }
        let timeout = DispatchWorkItem { token.cancel(); finish(.failure(IOSVehicleNetworkError("join_timeout"))) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)
        NEHotspotConfigurationManager.shared.getConfiguredSSIDs { [weak self] ssids in
            DispatchQueue.main.async {
                guard let self = self else { timeout.cancel(); finish(.failure(IOSVehicleNetworkError("service_closed"))); return }
                let existed = ssids.contains(profile.ssid)
                guard self.page == revision, self.current(scope, token) else {
                    self.applyingSSID = nil; timeout.cancel(); finish(.failure(IOSVehicleNetworkError("cancelled"))); return
                }
                let configuration = profile.password.isEmpty ? NEHotspotConfiguration(ssid: profile.ssid)
                    : NEHotspotConfiguration(ssid: profile.ssid, passphrase: profile.password, isWEP: false)
                configuration.joinOnce = false; configuration.hidden = profile.hidden
                NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
                    DispatchQueue.main.async {
                        timeout.cancel()
                        guard let self = self else { finish(.failure(IOSVehicleNetworkError("service_closed"))); return }
                        self.applyingSSID = nil
                        guard self.page == revision, self.current(scope, token) else {
                            if !existed { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: profile.ssid) }
                            finish(.failure(IOSVehicleNetworkError("cancelled"))); return
                        }
                        if let error = error as NSError?, !(error.domain == NEHotspotConfigurationErrorDomain
                            && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                            finish(.failure(IOSVehicleNetworkError(error.domain == NEHotspotConfigurationErrorDomain
                                && error.code == NEHotspotConfigurationError.userDenied.rawValue ? "user_denied" : "wifi_apply_failed")))
                            return
                        }
                        if !existed {
                            self.configuredOwners[profile.ssid] = scope.ownerHash
                            self.persistOwners()
                        }
                        self.vehicleProfiles[scope.ownerHash, default: []].insert(profile.ssid)
                        // 系统接受配置不等于已加入；先核对系统实际 SSID，再由 status 核验私网路径。
                        self.waitForRoute(profile: profile, scope: scope, token: token, completion: finish)
                    }
                }
            }
        }
    }

    private func waitForRoute(profile: IOSVehicleWiFiProfile, scope: IOSRideScope, token: IOSVehicleCancellation,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        guard current(scope, token) else { completion(.failure(IOSVehicleNetworkError("join_not_verified"))); return }
        currentSSID { [weak self] ssid in
            guard let self = self, self.current(scope, token) else {
                completion(.failure(IOSVehicleNetworkError("join_not_verified"))); return
            }
            if ssid == profile.ssid { completion(.success(())); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForRoute(profile: profile, scope: scope, token: token, completion: completion)
            }
        }
    }

    func grant(port: UInt16, scope: IOSRideScope) -> Bool {
        precondition(Thread.isMainThread)
        guard scopeProvider?() == scope, scope.valid, port > 0, allowedPorts.count < 8 || allowedPorts.contains(port),
              UIApplication.shared.applicationState == .active else { return false }
        allowedPorts.insert(port); return true
    }

    func inspectJoined(profile: IOSVehicleWiFiProfile, scope: IOSRideScope,
                       reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        let token = IOSVehicleCancellation(seconds: 7), id = UUID(), revision = page
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pending[id] = token
        var delivered = false
        let finish: (Any?, String?) -> Void = { [weak self] value, error in
            guard !delivered else { return }; delivered = true
            monitor.pathUpdateHandler = nil; monitor.cancel()
            self?.pending.removeValue(forKey: id); self?.cancellations.removeValue(forKey: id)
            reply(value, error)
        }
        cancellations[id] = { token.cancel(); finish(nil, "cancelled") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { finish(nil, "ssid_timeout") }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self, !delivered else { return }
            self.currentSSID { ssid in
                guard self.page == revision, self.current(scope, token) else { finish(nil, "stale_context"); return }
                var result = self.status(profile, connected: false)
                let known = ssid != nil && !(ssid?.isEmpty ?? true)
                let joined = known && ssid == profile.ssid
                result["joined"] = known ? joined : NSNull()
                result["targetJoined"] = known ? joined : NSNull()
                result["ssidReadable"] = known
                let interfaces = path.availableInterfaces.filter { $0.type == .wifi }
                let verified = joined && path.status == .satisfied && path.usesInterfaceType(.wifi)
                    && !path.usesInterfaceType(.other) && !path.usesInterfaceType(.cellular)
                    && interfaces.count == 1 && !Self.hasVPNInterface()
                    && Self.sourceIP(interface: interfaces[0].name, target: profile.carIP) != nil
                result["connected"] = verified; result["targetVerified"] = verified
                result["ssid"] = joined ? profile.ssid : ""
                result["connectionMode"] = verified ? "wifi" : ""
                result["interface"] = verified ? interfaces[0].name : ""
                result["sourceIP"] = verified ? Self.sourceIP(interface: interfaces[0].name, target: profile.carIP) ?? "" : ""
                result["ok"] = known
                result["error"] = known ? "" : "ssid_unknown"
                finish(result, nil)
            }
        }
        monitor.start(queue: .main)
    }

    func open(profile: IOSVehicleWiFiProfile, scope: IOSRideScope, port: UInt16,
              cancellation token: IOSVehicleCancellation,
              completion: @escaping (Result<IOSVehicleSocket, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard current(scope, token), allowedPorts.contains(port), port > 0 else {
            completion(.failure(IOSVehicleNetworkError("stale_scope_or_port_not_allowed"))); return
        }
        let id = UUID(), revision = page
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        pending[id] = token
        var connection: NWConnection?
        var delivered = false
        var inspecting = false
        var timer: DispatchWorkItem?
        let finish: (Result<IOSVehicleSocket, Error>) -> Void = { [weak self] result in
            guard !delivered else {
                if case let .success(socket) = result { socket.cancel() }; return
            }
            delivered = true; monitor.pathUpdateHandler = nil; monitor.cancel(); timer?.cancel()
            self?.pending.removeValue(forKey: id); self?.cancellations.removeValue(forKey: id)
            if case .failure = result {
                connection?.stateUpdateHandler = nil; connection?.pathUpdateHandler = nil; connection?.cancel()
            }
            completion(result)
        }
        cancellations[id] = { connection?.cancel(); finish(.failure(IOSVehicleNetworkError("cancelled"))) }
        let timeout = DispatchWorkItem { finish(.failure(IOSVehicleNetworkError("route_unavailable"))) }
        timer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: timeout)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self, !delivered, !inspecting else { return }
            guard self.page == revision, self.current(scope, token), path.status == .satisfied,
                  path.usesInterfaceType(.wifi),
                  !path.usesInterfaceType(.other), !path.usesInterfaceType(.cellular) else {
                finish(.failure(IOSVehicleNetworkError("wifi_path_unavailable"))); return
            }
            let interfaces = path.availableInterfaces.filter { $0.type == .wifi }
            guard interfaces.count == 1 else { finish(.failure(IOSVehicleNetworkError("ambiguous_wifi_path"))); return }
            inspecting = true
            self.currentSSID { ssid in
                guard !delivered, self.page == revision, self.current(scope, token), ssid == profile.ssid,
                      let source = Self.sourceIP(interface: interfaces[0].name, target: profile.carIP),
                      !Self.hasVPNInterface() else {
                    finish(.failure(IOSVehicleNetworkError("ssid_or_local_route_unverified"))); return
                }
                let route = IOSVehicleRoute(interface: interfaces[0], sourceIP: source, ssid: ssid ?? "", carIP: profile.carIP)
                let socketConnection = NWConnection(host: NWEndpoint.Host(profile.carIP),
                    port: NWEndpoint.Port(rawValue: port)!, using: route.parameters())
                connection = socketConnection
                socketConnection.stateUpdateHandler = { [weak self] state in
                    guard let self = self, !delivered else { return }
                    switch state {
                    case .ready:
                        self.validate(route: route, scope: scope, cancellation: token) { valid in
                            guard !delivered, valid, let live = socketConnection.currentPath, route.matches(live) else {
                                finish(.failure(IOSVehicleNetworkError("route_unverified"))); return
                            }
                            let socket = IOSVehicleSocket(connection: socketConnection, route: route) { [weak self] reply in
                                guard let self = self, self.page == revision else { reply(false); return }
                                self.validate(route: route, scope: scope, cancellation: token, completion: reply)
                            }
                            self.vehicleProfiles[scope.ownerHash, default: []].insert(profile.ssid)
                            self.liveSockets[id] = socket
                            socket.onClosed = { [weak self] in self?.liveSockets.removeValue(forKey: id) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, token.deadline - ProcessInfo.processInfo.systemUptime)) { [weak socket] in
                                socket?.cancel(code: "session_timeout")
                            }
                            finish(.success(socket))
                        }
                    case .failed, .cancelled: finish(.failure(IOSVehicleNetworkError("vehicle_port_unreachable")))
                    default: break
                    }
                }
                socketConnection.start(queue: .main)
            }
        }
        monitor.start(queue: .main)
    }

    func validate(route: IOSVehicleRoute, scope: IOSRideScope, cancellation token: IOSVehicleCancellation,
                  completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard current(scope, token), !Self.hasVPNInterface(),
              Self.sourceIP(interface: route.interface.name, target: route.carIP) == route.sourceIP else {
            completion(false); return
        }
        currentSSID { [weak self] ssid in
            guard let self = self else { completion(false); return }
            completion(self.current(scope, token) && ssid == route.ssid && !Self.hasVPNInterface()
                && Self.sourceIP(interface: route.interface.name, target: route.carIP) == route.sourceIP)
        }
    }

    private func currentSSID(_ completion: @escaping (String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                if let ssid = network?.ssid, !ssid.isEmpty { completion(ssid); return }
                // CaptiveNetwork 仍受 Access WiFi Information entitlement/系统授权约束；未知即拒绝。
                guard let interfaces = CNCopySupportedInterfaces() as? [String] else { completion(nil); return }
                let names = interfaces.compactMap { interface -> String? in
                    guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any] else { return nil }
                    return info[kCNNetworkInfoKeySSID as String] as? String
                }
                completion(Set(names).count == 1 ? names.first : nil)
            }
        }
    }

    static func hasVPNInterface() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return true }
        defer { freeifaddrs(list) }
        var pointer = list
        while let node = pointer {
            let value = node.pointee, name = String(cString: value.ifa_name)
            if value.ifa_flags & UInt32(IFF_UP) != 0
                && (name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")) { return true }
            pointer = value.ifa_next
        }
        return false
    }

    static func sourceIP(interface: String, target: String) -> String? {
        var targetAddress = in_addr()
        guard inet_pton(AF_INET, target, &targetAddress) == 1 else { return nil }
        let targetBits = UInt32(bigEndian: targetAddress.s_addr)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var pointer = list, candidates: [String] = []
        while let node = pointer {
            let item = node.pointee; pointer = item.ifa_next
            guard String(cString: item.ifa_name) == interface, item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr, let netmask = item.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET, Int32(netmask.pointee.sa_family) == AF_INET else { continue }
            let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let maskAddr = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let bits = UInt32(bigEndian: addr.s_addr), mask = UInt32(bigEndian: maskAddr.s_addr)
            let prefix = mask.nonzeroBitCount
            guard prefix >= 16, prefix <= 30, mask == UInt32.max << (32 - prefix),
                  bits != targetBits, bits & mask == targetBits & mask,
                  bits & ~mask != 0, bits & ~mask != ~mask else { continue }
            var copy = addr, chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &copy, &chars, socklen_t(INET_ADDRSTRLEN)) != nil { candidates.append(String(cString: chars)) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func internetRouteAllowed(scope: IOSRideScope, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard scopeProvider?() == scope, scope.valid, !Self.hasVPNInterface() else { completion(false); return }
        let revision = page
        let known = vehicleProfiles[scope.ownerHash] ?? []
        currentSSID { [weak self] ssid in
            guard let self = self, self.page == revision, self.scopeProvider?() == scope,
                  UIApplication.shared.applicationState == .active, !Self.hasVPNInterface() else {
                completion(false); return
            }
            // 192.168.0/24 也常见于家庭路由；网段相同不是车机身份证明。
            if let ssid = ssid { completion(!known.contains(ssid)); return }
            // 系统隐藏 SSID 且已有原生确认的车辆 AP 时无法排除它，保守拒绝。
            completion(known.isEmpty)
        }
    }

    static func hasVehicleSubnet(target: String = "192.168.0.1") -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return true }
        defer { freeifaddrs(list) }
        var targetAddress = in_addr()
        guard inet_pton(AF_INET, target, &targetAddress) == 1 else { return true }
        let targetBits = UInt32(bigEndian: targetAddress.s_addr)
        var pointer = list
        while let node = pointer {
            let item = node.pointee; pointer = item.ifa_next
            guard item.ifa_flags & UInt32(IFF_UP) != 0, let address = item.ifa_addr,
                  let netmask = item.ifa_netmask, Int32(address.pointee.sa_family) == AF_INET,
                  Int32(netmask.pointee.sa_family) == AF_INET else { continue }
            let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let maskAddress = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let bits = UInt32(bigEndian: addr.s_addr), mask = UInt32(bigEndian: maskAddress.s_addr)
            let prefix = mask.nonzeroBitCount
            if prefix >= 16, prefix <= 30, mask == UInt32.max << (32 - prefix),
               bits & mask == targetBits & mask { return true }
        }
        return false
    }

    private func status(_ profile: IOSVehicleWiFiProfile, connected: Bool, error: String = "") -> [String: Any] {
        ["ok": error.isEmpty, "connected": connected, "targetVerified": connected,
         "targetJoined": connected ? true : NSNull(), "ssid": connected ? profile.ssid : "",
         "targetSSID": profile.ssid, "carIp": profile.carIP, "connectionMode": connected ? "wifi" : "",
         "standardAP": true, "p2pSupported": false, "legacyAPAvailability": "unknown",
         "vpnAssessment": "public_interface_checks_only", "joinOnce": false, "error": error]
    }
    private func code(_ error: Error) -> String { (error as? IOSVehicleNetworkError)?.code ?? "wifi_failed" }
}

// 通用桥上下文只读原生 provider；页面不能用自己的 token/布尔值提升车辆归属。
final class IOSVehicleContext {
    var scopeProvider: (() -> IOSRideScope?)?
    var navigationProvider: (() -> String?)?
    var frameProvider: (() -> String?)?
    private(set) var revision: UInt64 = 0
    struct Lease {
        let scope: IOSRideScope
        let navigation: String
        let frame: String?
        let revision: UInt64
    }
    func invalidate() { precondition(Thread.isMainThread); revision &+= 1 }
    func capture(_ object: [String: Any]) throws -> Lease {
        precondition(Thread.isMainThread)
        guard let scope = scopeProvider?(), scope.valid,
              let nav = object["navigationId"] as? String, !nav.isEmpty, nav.utf8.count <= 128,
              navigationProvider?() == nav,
              let epoch = try? IOSWallpaperJSON.integer(object["epoch"], max: Int.max),
              String(epoch) == scope.generation,
              UIApplication.shared.applicationState == .active else { throw IOSVehicleNetworkError("stale_context") }
        let frame = frameProvider?()
        if frameProvider != nil {
            guard let frame = frame, !frame.isEmpty, object["frame"] as? String == frame else {
                throw IOSVehicleNetworkError("stale_frame")
            }
        }
        return Lease(scope: scope, navigation: nav, frame: frame, revision: revision)
    }
    func current(_ lease: Lease) -> Bool {
        precondition(Thread.isMainThread)
        return revision == lease.revision && scopeProvider?() == lease.scope
            && navigationProvider?() == lease.navigation
            && (frameProvider == nil || frameProvider?() == lease.frame)
            && UIApplication.shared.applicationState == .active
    }
    func same(_ a: Lease, _ b: Lease) -> Bool {
        a.scope == b.scope && a.navigation == b.navigation && a.frame == b.frame && a.revision == b.revision
    }
}

// 一份短票据一条连接，不包含车辆报文、确认字段或业务状态机。
final class IOSVehicleTCPService: IOSBridgeCancellableService {
    let methods = ["network.open", "network.read", "network.write", "network.poll", "network.close"]
    private let network: IOSVehicleNetworkService
    private let context = IOSVehicleContext()
    private var session: Session?
    typealias PortConfirmer = (IOSRideScope, String, String, UInt16, @escaping (Bool) -> Void) -> (() -> Void)?
    private var portConfirmer: PortConfirmer?
    private final class Session {
        let ticket = UUID().uuidString
        let lease: IOSVehicleContext.Lease
        let token = IOSVehicleCancellation(seconds: 180)
        let port: UInt16
        var socket: IOSVehicleSocket?
        var busy = true
        var confirmationCancel: (() -> Void)?
        func dismissConfirmation() {
            let cancel = confirmationCancel; confirmationCancel = nil; cancel?()
        }
        init(lease: IOSVehicleContext.Lease, port: UInt16) { self.lease = lease; self.port = port }
    }
    init(network: IOSVehicleNetworkService) { self.network = network }
    func setScopeProvider(_ provider: @escaping () -> IOSRideScope?) { context.scopeProvider = provider }
    func setNavigationProvider(_ provider: @escaping () -> String?) { context.navigationProvider = provider }
    func setFrameProvider(_ provider: @escaping () -> String?) { context.frameProvider = provider }
    func setPortConfirmer(_ confirmer: @escaping PortConfirmer) { portConfirmer = confirmer }
    func navigationChanged() { precondition(Thread.isMainThread); context.invalidate(); close() }
    func applicationBackgrounded() { navigationChanged() }
    func cancel(method: String, args: [Any]) { close() }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard args.count == 1, let object = args.first as? [String: Any] else { throw IOSVehicleNetworkError("invalid_args") }
            let lease = try context.capture(object)
            if method == "network.open" {
                guard session == nil else { throw IOSVehicleNetworkError("network_busy") }
                let profile = try IOSVehicleWiFiProfile.parse(object)
                guard object["password"] == nil else { throw IOSVehicleNetworkError("join_wifi_separately") }
                let port = UInt16(try IOSWallpaperJSON.integer(object["port"], min: 1, max: 65535))
                guard let confirmer = portConfirmer else { throw IOSVehicleNetworkError("port_confirmation_required") }
                let s = Session(lease: lease, port: port); session = s
                var confirmed = false
                let decision: (Bool) -> Void = { [weak self] allowed in
                    let deliver = { [weak self] in
                        guard !confirmed else { return }; confirmed = true
                        s.dismissConfirmation()
                        guard let self = self, self.current(s), allowed,
                              self.network.grant(port: port, scope: lease.scope) else {
                            self?.closeIfOwned(s); reply(nil, "port_not_authorized_or_stale"); return
                        }
                        self.network.open(profile: profile, scope: lease.scope, port: port, cancellation: s.token) { [weak self] result in
                            guard let self = self, self.current(s) else {
                                if case let .success(socket) = result { socket.cancel() }; reply(nil, "stale_context"); return
                            }
                            s.busy = false
                            switch result {
                            case let .success(socket):
                                s.socket = socket
                                socket.onInvalidated = { [weak self, weak s] in
                                    if let s = s, self?.session === s { self?.close() }
                                }
                                self.armWatch(s); reply(self.info(s, verified: true), nil)
                            case let .failure(error): self.close(); reply(nil, self.code(error))
                            }
                        }
                    }
                    if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
                }
                // confirmer 必须是原生前台 UI，不得直接返回网页传入的 bool。
                let dismiss = confirmer(lease.scope, lease.navigation, profile.carIP, port, decision)
                if !confirmed, self.session === s { s.confirmationCancel = dismiss }
                else { dismiss?() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { if !confirmed { decision(false) } }
                return
            }
            guard let ticket = object["ticket"] as? String, let s = session, s.ticket == ticket,
                  context.same(lease, s.lease), current(s), let socket = s.socket else { throw IOSVehicleNetworkError("invalid_socket_ticket") }
            if method == "network.close" { close(); reply(["ok": true, "ticket": ticket, "closed": true], nil); return }
            guard !s.busy else { throw IOSVehicleNetworkError("network_busy") }
            s.busy = true
            network.validate(route: socket.route, scope: s.lease.scope, cancellation: s.token) { [weak self] valid in
                guard let self = self, self.current(s), valid, socket.pathVerified else {
                    self?.closeIfOwned(s); reply(nil, "route_lost"); return
                }
                do {
                    switch method {
                    case "network.poll": s.busy = false; reply(self.info(s, verified: true), nil)
                    case "network.read":
                        let count = try IOSWallpaperJSON.integer(object["length"], min: 1, max: 65536)
                        let timeout = try object["timeoutMs"].map { try IOSWallpaperJSON.integer($0, min: 1, max: 60000) } ?? 15000
                        socket.readExact(count, timeoutMs: timeout) { result in
                            guard self.current(s) else { reply(nil, "stale_context"); return }
                            s.busy = false
                            switch result {
                            case let .success(data):
                                reply(["ok": true, "ticket": ticket, "base64": data.base64EncodedString(), "length": data.count, "exact": true], nil)
                            case let .failure(error): self.close(); reply(nil, self.code(error))
                            }
                        }
                    case "network.write":
                        guard let text = object["base64"] as? String, text.utf8.count <= 87384,
                              let data = Data(base64Encoded: text), !data.isEmpty, data.count <= 65536,
                              data.base64EncodedString() == text else { throw IOSVehicleNetworkError("invalid_chunk") }
                        socket.send(data) { result in
                            guard self.current(s) else { reply(nil, "stale_context"); return }
                            s.busy = false
                            switch result {
                            case .success: reply(["ok": true, "ticket": ticket, "written": data.count, "remoteAcknowledged": false], nil)
                            case let .failure(error): self.close(); reply(nil, self.code(error))
                            }
                        }
                    default: throw IOSVehicleNetworkError("unsupported_method")
                    }
                } catch { s.busy = false; reply(nil, self.code(error)) }
            }
        } catch { reply(nil, code(error)) }
    }
    private func current(_ s: Session) -> Bool {
        session === s && s.token.valid && context.current(s.lease)
    }
    private func closeIfOwned(_ s: Session) {
        if session === s { close() }
    }
    private func info(_ s: Session, verified: Bool) -> [String: Any] {
        let route = s.socket?.route
        return ["ok": true, "ticket": s.ticket, "connected": verified, "targetVerified": verified,
                "targetJoined": verified, "ip": route?.carIP ?? "", "ssid": route?.ssid ?? "",
                "interface": route?.interface.name ?? "", "sourceIP": route?.sourceIP ?? "", "port": Int(s.port),
                "connectionMode": "wifi", "p2pSupported": false, "legacyAPAvailability": "unknown",
                "vpnAssessment": "public_interface_checks_only", "exactRead": true]
    }
    private func armWatch(_ s: Session) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak s] in
            guard let self = self, let s = s, self.session === s else { return }
            guard self.current(s) else { self.close(); return }
            self.armWatch(s)
        }
    }
    private func close() {
        guard let s = session else { return }; session = nil
        s.token.cancel(); s.dismissConfirmation()
        s.socket?.onInvalidated = nil; s.socket?.cancel(); s.socket = nil
    }
    private func code(_ error: Error) -> String {
        (error as? IOSVehicleNetworkError)?.code ?? (error as? IOSWallpaperError)?.code ?? "network_failed"
    }
}
