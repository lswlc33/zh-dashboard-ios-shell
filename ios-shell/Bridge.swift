import Foundation
import UIKit
import WebKit
import CryptoKit
import ZeehoShared

// 服务只声明自己的 RPC；桥统一保证主线程派发、可信导航、一次回执和有界生命周期。
protocol IOSBridgeService: AnyObject {
    var methods: [String] { get }
    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void)
    func navigationChanged()
    func applicationBackgrounded()
}

protocol IOSBridgeMediaService: IOSBridgeService {
    func requestMediaCapture(type: WKMediaCaptureType, reply: @escaping (WKPermissionDecision) -> Void)
}

// 用户弹窗超时必须撤销实际操作，而不是只丢掉 JavaScript 回执。
protocol IOSBridgeCancellableService: IOSBridgeService {
    func cancel(method: String, args: [Any])
}

protocol IOSBridgeBackgroundHandoffService: IOSBridgeService {
    func canFinishInBackground(method: String, args: [Any]) -> Bool
}

private final class IOSReplyProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: IOSBridge?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner = owner else {
            replyHandler(IOSBridgePolicy.failure(method: "", code: "bridge_closed"), nil)
            return
        }
        owner.receive(message, replyHandler: replyHandler)
    }
}

final class IOSBridge {
    private final class Pending {
        let id: String
        let method: String
        let args: [Any]
        var generation: Int
        let epoch: Int
        let navigationID: String
        let frame: WKFrameInfo
        var bytes: Int
        var backgroundHandoff = false
        var cancelling = false
        var requestID = ""
        var transportID: String?
        var service: IOSBridgeService?
        var timer: DispatchWorkItem?
        private var handler: ((Any?, String?) -> Void)?
        init(id: String, method: String, args: [Any], generation: Int, epoch: Int, navigationID: String,
             frame: WKFrameInfo, bytes: Int, handler: @escaping (Any?, String?) -> Void) {
            self.id = id; self.method = method; self.args = args; self.generation = generation
            self.epoch = epoch; self.navigationID = navigationID
            self.frame = frame; self.bytes = bytes; self.handler = handler
            requestID = (args.first as? [String: Any])?["id"] as? String ?? ""
        }
        func complete(_ result: Any) {
            precondition(Thread.isMainThread)
            guard let handler = handler else { return }
            self.handler = nil
            timer?.cancel(); timer = nil
            service = nil
            handler(result, nil)
        }
    }

    private struct Session {
        let accountID: String
        let vin: String
        let credential: String
        let frame: String
    }

    private weak var webView: WKWebView?
    private let store = IOSStore()
    private let transport = SharedTransport()
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.bridge", qos: .userInitiated)
    private let services: [IOSBridgeService]
    private var routes: [String: IOSBridgeService] = [:]
    private let proxy = IOSReplyProxy()
    private var notificationTokens: [NSObjectProtocol] = []
    private var pending: [String: Pending] = [:]
    private var pendingBytes = 0
    private var transactions: [String: String] = [:] // 网页 id -> 当前导航的 RPC id
    private var snapshot = IOSStore.Snapshot(values: [:], revision: 0, readError: "store_not_loaded")
    private var navigationID = ""
    private var nonce = ""
    private var prepared = false
    private var navigationPermit: String?
    private var closed = false
    private var foreground = UIApplication.shared.applicationState != .background
    private var generation = 0
    private var preparation = 0
    private var epoch = 0
    private var session: Session?
    private var mediaReply: ((WKPermissionDecision) -> Void)?
    private var mediaID: UUID?
    private var mediaTimer: DispatchWorkItem?

    init(webView: WKWebView, services: [IOSBridgeService]) {
        precondition(Thread.isMainThread)
        self.webView = webView
        self.services = services
        let reserved: Set<String> = ["hello", "store.commit", "txn.request", "txn.cancel", "sync.session"]
        for service in services {
            for method in service.methods where IOSBridgePolicy.methodName(method)
                && !reserved.contains(method) && routes[method] == nil {
                routes[method] = service
            }
        }
        proxy.owner = self
        webView.configuration.userContentController.addScriptMessageHandler(proxy, contentWorld: .page,
                                                                            name: IOSBridgePolicy.handlerName)
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                      object: nil, queue: .main) { [weak self] _ in self?.backgrounded() })
        notificationTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                      object: nil, queue: .main) { [weak self] _ in self?.foregrounded() })
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        transport.close()
        let abandoned = Array(pending.values)
        let media = mediaReply
        DispatchQueue.main.async {
            for reply in abandoned {
                reply.complete(IOSBridgePolicy.failure(method: reply.method, code: "bridge_closed",
                                                       requestID: reply.requestID))
            }
            media?(.deny)
        }
    }

    var capabilities: [String] {
        (["hello", "store.commit", "txn.request", "txn.cancel", "sync.session"] + Array(routes.keys)).sorted()
    }

    // 纯刷新或后台切换不改账号 epoch；已明确启动的记录继续由系统服务自己的权限守护。
    func nativeSessionScope() -> IOSRideScope? {
        precondition(Thread.isMainThread)
        guard !closed, let session = session,
              credential(accountID: session.accountID, vin: session.vin, values: snapshot.values) == session.credential else { return nil }
        return IOSRideScope(accountID: session.accountID, vin: session.vin, generation: String(epoch))
    }

    func isPreparedNavigation(_ url: URL) -> Bool {
        !closed && prepared && PanelNavigation.isPanel(url) && PanelNavigation.navigationID(in: url) == navigationID
    }

    func consumeNavigationPermit(_ url: URL) -> Bool {
        precondition(Thread.isMainThread)
        guard isPreparedNavigation(url), navigationPermit == url.absoluteString else { return false }
        navigationPermit = nil
        return true
    }

    // 所有磁盘、Keychain、crypto 和模板编码都在 worker 做好后才允许 WebKit load。
    func prepareNavigation(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !closed, PanelNavigation.isPanel(url) else {
            completion(.failure(IOSBridgePolicy.Failure("navigation_not_allowed")))
            return
        }
        emitLifecycle("navigation")
        cancelAll(code: "stale_navigation")
        services.forEach { $0.navigationChanged() }
        generation += 1
        preparation += 1
        prepared = false
        navigationPermit = nil
        let ticket = preparation
        store.snapshot { [weak self] snapshot in
            guard let self = self, !self.closed, self.preparation == ticket else {
                completion(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
                return
            }
            self.applySnapshot(snapshot)
            let capabilities = self.capabilities
            let epoch = self.epoch
            let documentGeneration = self.generation
            self.worker.async {
                let result: Result<(URL, String, String), Error>
                do {
                    let id = try IOSBridgePolicy.randomIdentifier()
                    let nonce = try IOSBridgePolicy.randomIdentifier()
                    guard let target = PanelNavigation.withNavigationID(url, id: id),
                          let resource = Bundle.main.url(forResource: "bridge-bootstrap", withExtension: "js") else {
                        throw IOSBridgePolicy.Failure("bootstrap_missing")
                    }
                    let template = try String(contentsOf: resource, encoding: .utf8)
                    guard template.components(separatedBy: "__ZEEHO_IOS_CONFIG__").count == 2 else {
                        throw IOSBridgePolicy.Failure("bootstrap_invalid")
                    }
                    let root = PanelNavigation.home.path
                    let config: [String: Any] = [
                        "origin": "https://" + (PanelNavigation.home.host ?? ""),
                        "paths": [String(root.dropLast()), root, root + "index.html"],
                        "nonce": nonce, "navId": id, "generation": documentGeneration, "epoch": epoch,
                        "capabilities": capabilities, "storeSnapshot": snapshot.values,
                        "storeRevision": snapshot.revision, "storeReadError": snapshot.readError as Any? ?? NSNull()
                    ]
                    let source = template.replacingOccurrences(of: "__ZEEHO_IOS_CONFIG__",
                                                               with: try IOSBridgePolicy.scriptJSON(config))
                    result = .success((target, nonce, source))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.closed, self.preparation == ticket, let web = self.webView else {
                        completion(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
                        return
                    }
                    switch result {
                    case let .success((target, nonce, source)):
                        self.navigationID = PanelNavigation.navigationID(in: target)
                        self.nonce = nonce
                        let controller = web.configuration.userContentController
                        controller.removeAllUserScripts()
                        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                              forMainFrameOnly: true, in: .page))
                        self.prepared = true
                        self.navigationPermit = target.absoluteString
                        completion(.success(target))
                    case let .failure(error): completion(.failure(error))
                    }
                }
            }
        }
    }

    func navigationFailed() {
        precondition(Thread.isMainThread)
        prepared = false
        preparation += 1
        cancelAll(code: "navigation_failed")
        services.forEach { $0.navigationChanged() }
    }

    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        emitLifecycle("closed")
        closed = true; prepared = false
        cancelAll(code: "bridge_closed")
        services.compactMap { $0 as? IOSSystemSurfacesService }.forEach { $0.bridgeClosed() }
        services.forEach { $0.navigationChanged() }
        transport.close()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: IOSBridgePolicy.handlerName,
                                                                                contentWorld: .page)
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }

    fileprivate func receive(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard let object = message.body as? [String: Any], let method = object["method"] as? String,
              let id = object["id"] as? String, IOSBridgePolicy.identifier(id),
              let args = object["args"] as? [Any], args.count <= 8,
              IOSBridgePolicy.integer(object["version"]) == IOSBridgePolicy.version,
              Set(object.keys) == ["version", "nonce", "id", "method", "args"] else {
            replyHandler(IOSBridgePolicy.failure(method: "", code: "invalid_envelope"), nil)
            return
        }
        let requestID = (args.first as? [String: Any])?["id"] as? String ?? ""
        guard message.name == IOSBridgePolicy.handlerName, message.webView === webView,
              object["nonce"] as? String == nonce, authorized(message.frameInfo) else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "untrusted_document", requestID: requestID), nil)
            return
        }
        guard foreground else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "foreground_required", requestID: requestID), nil)
            return
        }
        guard capabilities.contains(method), IOSBridgePolicy.methodName(method) else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "unsupported_method", requestID: requestID), nil)
            return
        }
        guard pending[id] == nil, pending.count < IOSBridgePolicy.maxPending else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "pending_limit", requestID: requestID), nil)
            return
        }
        let limit = IOSBridgePolicy.fileMethods.contains(method) ? IOSBridgePolicy.maxFileEnvelopeBytes
            : (method == "txn.request" ? IOSBridgePolicy.maxRequestBytes
               : (method == "store.commit" ? IOSStore.maxArchiveBytes : IOSBridgePolicy.maxServiceBytes))
        let measuredSize: Int
        do { measuredSize = try Self.measure(object, limit: limit) }
        catch {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "request_too_large", requestID: requestID), nil)
            return
        }
        // 同一串行 worker 验证尚未完成的消息先按方法上限预留，避免多条排队超出总内存预算。
        let size = limit
        guard measuredSize <= size, size <= IOSBridgePolicy.maxPendingBytes - pendingBytes,
              !IOSBridgePolicy.fileMethods.contains(method)
                || !pending.values.contains(where: { IOSBridgePolicy.fileMethods.contains($0.method) }) else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "pending_bytes_limit", requestID: requestID), nil)
            return
        }
        let reply = Pending(id: id, method: method, args: args, generation: generation, epoch: epoch,
                            navigationID: navigationID, frame: message.frameInfo, bytes: size, handler: replyHandler)
        pending[id] = reply; pendingBytes += size
        let timeout: Double = IOSBridgePolicy.interactiveMethods.contains(method) ? 300 : 30
        arm(reply, seconds: timeout)
        // 有界 JSON 序列化、请求体 Base64 校验在后台做，回主线程时再次核验导航。
        worker.async { [weak self, weak reply] in
            let validationError: String?
            var validatedBytes = size
            do {
                validatedBytes = try IOSBridgePolicy.json(object, limit: limit).utf8.count
                validationError = nil
            } catch { validationError = (error as? IOSBridgePolicy.Failure)?.code ?? "invalid_json" }
            DispatchQueue.main.async { [weak self, weak reply] in
                guard let self = self, let reply = reply, self.isCurrent(reply) else { return }
                self.pendingBytes += validatedBytes - reply.bytes
                reply.bytes = validatedBytes
                if let error = validationError { self.finish(reply, IOSBridgePolicy.failure(method: method, code: error, requestID: requestID)) }
                else { self.dispatch(reply) }
            }
        }
    }

    private func authorized(_ frame: WKFrameInfo) -> Bool {
        guard !closed, prepared, !navigationID.isEmpty,
              IOSBridgePolicy.trustedFrame(frame, navigationID: navigationID),
              let url = webView?.url, isPreparedNavigation(url) else { return false }
        return true
    }

    private func isCurrent(_ reply: Pending) -> Bool {
        guard pending[reply.id] === reply, reply.navigationID == navigationID, reply.epoch == epoch,
              authorized(reply.frame) else { return false }
        return reply.backgroundHandoff || (reply.generation == generation && foreground)
    }

    private func dispatch(_ reply: Pending) {
        switch reply.method {
        case "hello":
            guard reply.args.isEmpty else { reject(reply, "invalid_args"); return }
            finish(reply, ["ok": true, "version": 1, "platform": "ios", "capabilities": capabilities])
        case "store.commit":
            guard reply.args.count == 1, let changes = reply.args.first as? [String: Any] else {
                reject(reply, "invalid_commit"); return
            }
            store.commit(changes) { [weak self, weak reply] result, snapshot in
                guard let self = self else { return }
                // 持久化可完成于旧文档退出之后；真实存档快照仍应更新，但旧回执已被取消。
                if let reply = reply, self.isCurrent(reply) { self.finish(reply, result) }
                self.applySnapshot(snapshot)
            }
        case "txn.request": beginTransaction(reply)
        case "txn.cancel":
            guard reply.args.count == 1, let cancellation = reply.args.first as? [String: Any],
                  Set(cancellation.keys) == ["id"], let id = cancellation["id"] as? String,
                  IOSBridgePolicy.identifier(id),
                  let rpc = transactions[id], let target = pending[rpc], target.generation == generation else {
                reject(reply, "unknown_request_id"); return
            }
            if let transportID = target.transportID { transport.cancel(id: transportID) }
            finish(target, IOSBridgePolicy.failure(method: target.method, code: "cancelled", requestID: target.requestID))
            finish(reply, ["ok": true, "id": id])
        case "sync.session": synchronize(reply)
        default:
            guard let service = routes[reply.method] else { reject(reply, "unsupported_method"); return }
            reply.service = service
            service.handle(method: reply.method, args: reply.args) { [weak self, weak reply] value, error in
                let deliver = { [weak self, weak reply] in
                    guard let self = self, let reply = reply, self.pending[reply.id] === reply,
                          reply.cancelling || self.isCurrent(reply) else { return }
                    if let error = error {
                        if service is IOSSystemService {
                            let safe = !error.isEmpty && error.utf8.count <= 512
                                && !error.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                            self.finish(reply, ["ok": false, "error": ["code": "service_failed",
                                                "message": safe ? error : IOSStrings.operationFailed]])
                        } else {
                            self.reject(reply, IOSBridgePolicy.identifier(error, limit: 80) ? error : "service_failed")
                        }
                    } else if let value = value {
                        // status 型 RPC 也保持原始对象，不拆不存在的 ok/result 包装。
                        self.finish(reply, value)
                    } else { self.finish(reply, NSNull()) }
                }
                if Thread.isMainThread { deliver() }
                else { DispatchQueue.main.async(execute: deliver) }
            }
        }
    }

    private func beginTransaction(_ reply: Pending) {
        guard reply.args.count == 1, let object = reply.args.first as? [String: Any],
              IOSBridgePolicy.identifier(reply.requestID), transactions[reply.requestID] == nil else {
            reject(reply, "invalid_or_duplicate_request_id"); return
        }
        let transportID = navigationID + ":" + UUID().uuidString
        reply.transportID = transportID
        transactions[reply.requestID] = reply.id
        worker.async { [weak self, weak reply] in
            let result: Result<IOSBridgePolicy.Transaction, Error>
            do { result = .success(try IOSBridgePolicy.transaction(object, transportID: transportID)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self, weak reply] in
                guard let self = self, let reply = reply, self.isCurrent(reply) else { return }
                switch result {
                case let .failure(error): self.reject(reply, (error as? IOSBridgePolicy.Failure)?.code ?? "invalid_transaction")
                case let .success(request):
                    self.arm(reply, seconds: Double(request.timeoutMs) / 1000 + 2)
                    self.transport.execute(json: request.json, completion: { [weak self, weak reply] text in
                        guard let self = self else { return }
                        self.worker.async { [weak self, weak reply] in
                            let value: [String: Any]
                            do {
                                value = try IOSBridgePolicy.transactionResult(text, transportID: transportID, requestID: request.id)
                            } catch {
                                value = IOSBridgePolicy.failure(method: "txn.request", code: "invalid_transport_result", requestID: request.id)
                            }
                            DispatchQueue.main.async { [weak self, weak reply] in
                                guard let self = self, let reply = reply, self.isCurrent(reply) else { return }
                                self.finish(reply, value)
                            }
                        }
                    })
                }
            }
        }
    }

    private func synchronize(_ reply: Pending) {
        guard reply.args.count <= 1 else { reject(reply, "invalid_session"); return }
        if let value = reply.args.first {
            guard let selection = value as? [String: Any],
                  Set(selection.keys).isSubset(of: ["accountId", "vin", "frame", "generation", "navigationId"]),
                  let accountID = selection["accountId"] as? String,
                  let vin = selection["vin"] as? String else { reject(reply, "invalid_session"); return }
            if let nav = selection["navigationId"] as? String, nav != navigationID { reject(reply, "stale_navigation"); return }
            if let requestedGeneration = selection["generation"],
               IOSBridgePolicy.integer(requestedGeneration) != generation { reject(reply, "stale_generation"); return }
            if accountID.isEmpty && vin.isEmpty {
                if session != nil { changeSession(nil, except: reply.id) }
            } else {
                guard snapshot.readError == nil, !vin.isEmpty,
                      let credential = credential(accountID: accountID, vin: vin, values: snapshot.values) else {
                    reject(reply, "session_not_persisted"); return
                }
                if session?.accountID != accountID || session?.vin != vin || session?.credential != credential {
                    // frame 是原生生成的绑定代号；网页输入 frame 不用于提升权限。
                    let selected = Session(accountID: accountID, vin: vin, credential: credential, frame: UUID().uuidString)
                    changeSession(selected, except: reply.id)
                }
            }
        }
        finish(reply, ["ok": true, "frame": session?.frame ?? "", "generation": generation, "epoch": epoch])
        emitLifecycle("session")
    }

    private func credential(accountID: String, vin: String, values: [String: String]) -> String? {
        guard IOSBridgePolicy.identifier(accountID, limit: 80), IOSBridgePolicy.identifier(vin, limit: 64),
              let text = values["zeeho.accounts.v1"], let data = text.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              IOSBridgePolicy.integer(document["v"]) == 1,
              let accounts = document["accounts"] as? [[String: Any]], accounts.count <= 20,
              accounts.filter({ $0["id"] as? String == accountID }).count == 1,
              let account = accounts.first(where: { $0["id"] as? String == accountID }),
              let token = account["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.utf8.count <= 16 * 1024,
              (IOSBridgePolicy.integer(account["invalidAt"]) ?? 0) <= 0 else { return nil }
        let vehicles = account["vehicles"] as? [[String: Any]] ?? []
        let selectedVIN = account["vin"] as? String ?? ""
        let knownVINs = Set(vehicles.compactMap { $0["vin"] as? String } + (selectedVIN.isEmpty ? [] : [selectedVIN]))
        // 只接受已经成功持久化的账号车列表/所选 VIN；空列表不能成为任意车辆通行证。
        guard knownVINs.contains(vin) else { return nil }
        let revision = IOSBridgePolicy.integer(account["credentialRev"]) ?? 1
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(revision):\(digest)"
    }

    private func changeSession(_ next: Session?, except rpcID: String? = nil) {
        // 服务先撤销旧 owner 的 observer/排队写，然后才公布新 scope，防止迟到结果串账号。
        for reply in pending.values where reply.id != rpcID { reply.cancelling = true }
        services.forEach { $0.navigationChanged() }
        cancelAll(code: "session_changed", except: rpcID)
        epoch += 1
        generation += 1
        session = next
        services.compactMap { $0 as? IOSSystemSurfacesService }.forEach { $0.scopeChanged() }
        services.compactMap { $0 as? IOSRideService }.forEach { $0.scopeChanged() }
        services.compactMap { $0 as? IOSBluetoothService }.forEach { $0.scopeChanged() }
    }

    private func applySnapshot(_ next: IOSStore.Snapshot) {
        if let session = session,
           next.readError != nil || credential(accountID: session.accountID, vin: session.vin, values: next.values) != session.credential {
            changeSession(nil)
        }
        snapshot = next
    }

    private func arm(_ reply: Pending, seconds: Double) {
        reply.timer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak reply] in
            guard let self = self, let reply = reply, self.pending[reply.id] === reply else { return }
            self.cancelOperation(reply)
            self.reject(reply, "timeout")
        }
        reply.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func cancelOperation(_ reply: Pending) {
        if let id = reply.transportID { transport.cancel(id: id) }
        reply.cancelling = true
        if let service = reply.service as? IOSBridgeCancellableService {
            service.cancel(method: reply.method, args: reply.args)
        } else if let service = reply.service, IOSBridgePolicy.interactiveMethods.contains(reply.method) {
            service.navigationChanged()
        }
    }

    private func reject(_ reply: Pending, _ code: String) {
        var failure = IOSBridgePolicy.failure(method: reply.method, code: code, requestID: reply.requestID)
        if reply.backgroundHandoff { failure["operationMayComplete"] = true }
        finish(reply, failure)
    }

    private func finish(_ reply: Pending, _ value: Any) {
        guard pending[reply.id] === reply else { return }
        pending.removeValue(forKey: reply.id)
        pendingBytes -= reply.bytes
        if transactions[reply.requestID] == reply.id { transactions.removeValue(forKey: reply.requestID) }
        reply.complete(value)
    }

    private func cancelAll(code: String, except rpcID: String? = nil) {
        for reply in Array(pending.values) where reply.id != rpcID {
            cancelOperation(reply)
            reject(reply, code)
        }
        finishMedia(.deny)
    }

    private func backgrounded() {
        guard !closed, foreground else { return }
        foreground = false
        generation += 1
        for reply in pending.values {
            reply.backgroundHandoff = (reply.service as? IOSBridgeBackgroundHandoffService)?
                .canFinishInBackground(method: reply.method, args: reply.args) == true
            if !reply.backgroundHandoff { reply.cancelling = true }
        }
        services.forEach { $0.applicationBackgrounded() }
        for reply in Array(pending.values) where !reply.backgroundHandoff {
            if let id = reply.transportID { transport.cancel(id: id) }
            reject(reply, "application_backgrounded")
        }
        finishMedia(.deny)
        emitLifecycle("background")
    }

    private func foregrounded() {
        guard !closed, !foreground else { return }
        foreground = true
        generation += 1
        emitLifecycle("foreground")
    }

    private func emitLifecycle(_ kind: String) {
        guard !navigationID.isEmpty, let web = webView else { return }
        let event: [String: Any] = ["kind": kind, "navId": navigationID, "generation": generation, "epoch": epoch]
        guard let json = try? IOSBridgePolicy.scriptJSON(event) else { return }
        web.evaluateJavaScript("window.__zeehoIOSLifecycle && window.__zeehoIOSLifecycle(" + json + ");", completionHandler: nil)
    }

    func requestMediaCapture(origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                             reply: @escaping (WKPermissionDecision) -> Void) {
        precondition(Thread.isMainThread)
        guard foreground, IOSBridgePolicy.trustedOrigin(origin), authorized(frame), mediaReply == nil,
              let service = services.compactMap({ $0 as? IOSBridgeMediaService }).first else { reply(.deny); return }
        let ticket = generation
        let id = UUID()
        mediaID = id
        mediaReply = reply
        let timer = DispatchWorkItem { [weak self, weak service] in
            guard let self = self, self.mediaID == id else { return }
            service?.navigationChanged()
            self.finishMedia(.deny, id: id)
        }
        mediaTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timer)
        service.requestMediaCapture(type: type) { [weak self] decision in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.mediaID == id, self.generation == ticket,
                      self.foreground, self.authorized(frame) else { return }
                self.finishMedia(decision, id: id)
            }
        }
    }

    private func finishMedia(_ decision: WKPermissionDecision, id: UUID? = nil) {
        if let id = id, id != mediaID { return }
        guard let reply = mediaReply else { return }
        mediaReply = nil
        mediaID = nil
        mediaTimer?.cancel(); mediaTimer = nil
        reply(decision)
    }

    // 先按 UTF-8 和节点数保守预留内存，后台再核实际序列化大小；不递归无界对象。
    private static func measure(_ object: Any, limit: Int) throws -> Int {
        var total = 0
        var nodes = 0
        func visit(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 20, nodes <= 20_000 else { throw IOSBridgePolicy.Failure("invalid_json") }
            if let text = value as? String {
                total += text.utf8.count + 2
                for scalar in text.unicodeScalars {
                    if scalar.value < 32 { total += 5 }
                    else if scalar.value == 34 || scalar.value == 92 { total += 1 }
                }
            }
            else if let array = value as? [Any] {
                total += array.count + 2
                for item in array { try visit(item, depth: depth + 1) }
            } else if let dictionary = value as? [String: Any] {
                total += dictionary.count * 4 + 2
                for (key, item) in dictionary { total += key.utf8.count; try visit(item, depth: depth + 1) }
            } else if value is NSNumber || value is NSNull { total += 24 }
            else { throw IOSBridgePolicy.Failure("invalid_json") }
            guard total <= limit else { throw IOSBridgePolicy.Failure("request_too_large") }
        }
        try visit(object, depth: 0)
        return total
    }
}
