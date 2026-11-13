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
    /// 最近一次生成的 bootstrap 源码。自定义 scheme 下 atDocumentStart 注入
    /// 可能不生效（WKWebView 对非 http(s) 来源的限制），didCommit 时用它兜底补注入。
    private var bootstrapSource: String?
    /// 补注入的尝试次数，按导航 ticket（navId）记账：换文档就换 key，
    /// 旧 ticket 的计数自然作废，不需要在准备阶段清理一个全局标志。
    private var bootstrapAttempts: [String: Int] = [:]
    private static let maxBootstrapAttempts = 3
    private var prepared = false
    private var navigationPermit: String?
    private var closed = false
    private var foreground = UIApplication.shared.applicationState != .background
    private var generation = 0
    private var preparation = 0
    /// 每轮导航只记有限条桥错误，不记录参数、token 或 nonce 值。
    private var loggedFailures = 0
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

    // 兼容层只获得已持久化会话的代号；token 和凭据摘要不穿过网页/系统展示桥。
    func nativeSessionMetadata() -> [String: Any]? {
        precondition(Thread.isMainThread)
        guard let scope = nativeSessionScope(), let session = session, prepared else { return nil }
        return ["navId": navigationID, "frame": session.frame, "epoch": epoch, "generation": generation,
                "accountId": scope.accountID, "vin": scope.vin]
    }

    func currentNavigationID() -> String? {
        precondition(Thread.isMainThread)
        return !closed && prepared && !navigationID.isEmpty ? navigationID : nil
    }

    func currentSessionFrame() -> String? {
        precondition(Thread.isMainThread)
        return nativeSessionScope() == nil ? nil : session?.frame
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
        loggedFailures = 0
        prepared = false
        navigationPermit = nil
        // 新一轮导航：清掉上一轮的重试计数与源码，避免旧导航的计数继续生效。
        bootstrapAttempts.removeAll()
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
                    // origin/paths 必须跟实际要加载的文档走：本地快照是
                    // zeeho-panel://panel/，线上是 https://<host>/。
                    // 写死 https 会让本地模式下 bootstrap 的 origin 校验失败，
                    // __zeehoIOS 不注入 → 网页判定「无桥」→ 白屏。
                    let targetParts = URLComponents(url: target, resolvingAgainstBaseURL: false)
                    let targetScheme = (targetParts?.scheme ?? target.scheme ?? "").lowercased()
                    let targetHost = (targetParts?.host ?? target.host ?? "").lowercased()
                    let targetOrigin = targetParts.flatMap { parts -> String? in
                        guard let scheme = parts.scheme, let host = parts.host else { return nil }
                        return parts.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
                    } ?? ""
                    let targetPath = target.path.isEmpty ? "/index.html" : target.path
                    let targetRoot = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
                    // origin 在自定义 scheme 下可能是字符串 "null"（opaque origin），
                    // 所以除了 origin 还单独给 scheme/host/rootPath，让 bootstrap 用
                    // 「protocol + host ± rootPath」这套不依赖 location.origin 的判据。
                    let config: [String: Any] = [
                        "origin": targetOrigin,
                        "scheme": targetScheme,
                        "host": targetHost,
                        "rootPath": String(targetRoot.dropLast()),
                        "paths": [String(targetRoot.dropLast()), targetRoot, targetRoot + "index.html"],
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
                        self.bootstrapSource = source
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

    /// 补注入 bootstrap。
    ///
    /// `addUserScript(.atDocumentStart)` 在自定义 scheme 页面上不一定执行——
    /// 真机实测：`hasBootstrap` 在 2 秒后的探测里是 true，但 `ios-bridge.js`
    /// 执行那一刻 `window.__zeehoIOS` 还是 undefined，于是 candidate=false，
    /// 网页退回「UI 测试预览」（数据取不到、安全区也不走原生分支）。
    ///
    /// didCommit 时文档已建立、页面脚本还在解析中，此刻 evaluateJavaScript
    /// 注入能保证在页面自己的脚本之前生效。
    ///
    /// 要点（之前三处都踩过）：
    /// 1. 先探一次 `typeof window.__zeehoIOS`：user script 已经跑过就别再跑，
    ///    否则 `configurable: false` 的 defineProperty 抛 TypeError，而 bootstrap
    ///    自己的 error 监听会画一个全屏黑浮层——用户看到的就是「纯黑点不动」。
    /// 2. 失败要能重试：`evaluateJavaScript` 不报错不等于生效（可能打在旧文档上），
    ///    所以每次注入后都复查一次，未生效就退避重试，最多 3 次。
    /// 3. 重试按导航 ticket 计数，换文档就清零。
    func reinjectBootstrapIfNeeded() {
        precondition(Thread.isMainThread)
        guard !closed, prepared, let source = bootstrapSource, let web = webView,
              let url = web.url, PanelNavigation.navigationID(in: url) == navigationID else { return }
        let ticket = navigationID
        let attempt = bootstrapAttempts[ticket] ?? 0
        guard attempt < Self.maxBootstrapAttempts else {
            IOSDiagnostics.shared.log("bootstrap 补注入放弃：已试 \(attempt) 次")
            return
        }
        web.evaluateJavaScript("typeof window.__zeehoIOS !== 'undefined'") { [weak self] value, _ in
            guard let self = self, !self.closed, self.navigationID == ticket else { return }
            if (value as? Bool) == true {
                // user script 这次跑得早，不需要补。
                return
            }
            self.bootstrapAttempts[ticket] = attempt + 1
            web.evaluateJavaScript(source) { [weak self] _, error in
                guard let self = self, !self.closed, self.navigationID == ticket else { return }
                if let error = error {
                    IOSDiagnostics.shared.log("bootstrap 补注入第 \(attempt + 1) 次失败: \(error.localizedDescription)")
                }
                // 复查：没报错也可能因为文档未就绪而没生效。
                web.evaluateJavaScript("typeof window.__zeehoIOS !== 'undefined'") { [weak self] value, _ in
                    guard let self = self, !self.closed, self.navigationID == ticket else { return }
                    if (value as? Bool) == true {
                        IOSDiagnostics.shared.log("bootstrap 补注入成功（第 \(attempt + 1) 次）")
                        return
                    }
                    let delay = [0.15, 0.4, 1.0][min(attempt, 2)]
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.reinjectBootstrapIfNeeded()
                    }
                }
            }
        }
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
            let origin = message.frameInfo.securityOrigin
            logFailure(method: method, code: "untrusted_document",
                       detail: "main=\(message.frameInfo.isMainFrame) prepared=\(prepared) nonceMatch=\(object["nonce"] as? String == nonce) scheme=\(origin.protocol) host=\(origin.host) port=\(origin.port)")
            replyHandler(IOSBridgePolicy.failure(method: method, code: "untrusted_document", requestID: requestID), nil)
            return
        }
        // 前台判据不能只靠 didBecomeActive/didEnterBackground 通知：
        // 1) `foreground` 初值在 init 时取，viewDidLoad 阶段 App 往往还不是 active；
        // 2) 若通知在观察者注册之前就发过，它会永久停在错误的一侧——
        //    停在 false 时每个 RPC 都被 foreground_required 拒掉（表现正是
        //    「偏好存不了 + 小组件永远没快照」）；停在 true 时后台操作会被误放行。
        // 这里按 applicationState（当下真值）双向校正，但**只改布尔**：
        // 绝不能调 foregrounded()/backgrounded()——它们会 generation += 1、广播 lifecycle、
        // 拒绝在途请求；在消息处理函数里隐式推进世代会把网页的 generation 弄旧，
        // 之后 sync.session 直接被 stale_generation 拒掉（桥永久无 session）。
        let appState = UIApplication.shared.applicationState
        if appState == .background {
            if foreground { foreground = false }
        } else if !foreground {
            foreground = true
        }
        guard foreground else {
            // 之前这里静默拒绝，排查时日志里什么都看不到；记一条（含真实 applicationState）。
            logFailure(method: method, code: "foreground_required", detail: "state=\(Self.stateName(appState))")
            replyHandler(IOSBridgePolicy.failure(method: method, code: "foreground_required", requestID: requestID), nil)
            return
        }
        guard capabilities.contains(method), IOSBridgePolicy.methodName(method) else {
            replyHandler(IOSBridgePolicy.failure(method: method, code: "unsupported_method", requestID: requestID), nil)
            return
        }
        guard pending[id] == nil, pending.count < IOSBridgePolicy.maxPending else {
            logFailure(method: method, code: "pending_limit", detail: "count=\(pending.count)")
            replyHandler(IOSBridgePolicy.failure(method: method, code: "pending_limit", requestID: requestID), nil)
            return
        }
        let limit = IOSBridgePolicy.fileMethods.contains(method) ? IOSBridgePolicy.maxFileEnvelopeBytes
            : (method == "txn.request" ? IOSBridgePolicy.maxRequestBytes
               : (method == "store.commit" ? IOSStore.maxArchiveBytes : IOSBridgePolicy.maxServiceBytes))
        let measuredSize: Int
        do { measuredSize = try IOSBridgeBudget.measure(object, limit: limit) }
        catch {
            let code = (error as? IOSBridgeBudget.Failure)?.code ?? "request_too_large"
            logFailure(method: method, code: code)
            replyHandler(IOSBridgePolicy.failure(method: method, code: code, requestID: requestID), nil)
            return
        }
        // 按本条消息的保守 JSON 大小预留；按方法最大值预扣会让三条小请求就把 32MB 判满。
        let size = measuredSize
        guard size <= IOSBridgePolicy.maxPendingBytes - pendingBytes,
              !IOSBridgePolicy.fileMethods.contains(method)
                || !pending.values.contains(where: { IOSBridgePolicy.fileMethods.contains($0.method) }) else {
            logFailure(method: method, code: "pending_bytes_limit",
                       detail: "pending=\(pendingBytes) incoming=\(size) count=\(pending.count)")
            replyHandler(IOSBridgePolicy.failure(method: method, code: "pending_bytes_limit", requestID: requestID), nil)
            return
        }
        let reply = Pending(id: id, method: method, args: args, generation: generation, epoch: epoch,
                            navigationID: navigationID, frame: message.frameInfo, bytes: size, handler: replyHandler)
        pending[id] = reply; pendingBytes += size
        let timeout: Double
        if IOSBridgePolicy.interactiveMethods.contains(method) { timeout = 300 }
        else if method == "network.read", let options = args.first as? [String: Any] {
            let requested = IOSBridgePolicy.integer(options["timeoutMs"]) ?? 15_000
            timeout = Double(min(60_000, max(1_000, requested))) / 1000 + 2
        } else { timeout = 30 }
        arm(reply, seconds: timeout)
        // 有界 JSON 序列化、请求体 Base64 校验在后台做，回主线程时再次核验导航。
        worker.async { [weak self, weak reply] in
            let validationError: String?
            var validatedBytes = size
            do {
                validatedBytes = try IOSBridgePolicy.json(object, limit: limit).utf8.count
                guard validatedBytes <= size else { throw IOSBridgePolicy.Failure("request_too_large") }
                validationError = nil
            } catch { validationError = (error as? IOSBridgePolicy.Failure)?.code ?? "invalid_json" }
            DispatchQueue.main.async { [weak self, weak reply] in
                guard let self = self, let reply = reply, self.isCurrent(reply) else { return }
                if let error = validationError {
                    self.reject(reply, error)
                    return
                }
                self.pendingBytes += validatedBytes - reply.bytes
                reply.bytes = validatedBytes
                self.dispatch(reply)
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
            IOSDiagnostics.shared.log("bridge: hello 成功 generation=\(generation) storeReady=\(snapshot.readError == nil)")
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
        finish(reply, ["ok": true, "frame": session?.frame ?? "", "generation": generation, "epoch": epoch,
                       "navId": navigationID, "accountId": session?.accountID ?? "", "vin": session?.vin ?? ""])
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
        services.compactMap { $0 as? IOSCastService }.forEach { $0.scopeChanged() }
        services.compactMap { $0 as? IOSSessionRenewalService }.forEach { $0.scopeChanged() }
        services.compactMap { $0 as? IOSSecretHandleService }.forEach { $0.scopeChanged() }
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

    private func logFailure(method: String, code: String, detail: String = "") {
        guard loggedFailures < 20 else { return }
        loggedFailures += 1
        let safeMethod = IOSBridgePolicy.methodName(method) ? method : "invalid"
        IOSDiagnostics.shared.log("bridge: 拒绝 method=\(safeMethod) code=\(code) generation=\(generation) \(detail)")
    }

    /// 只给日志用的可读状态名；不参与任何业务判定。
    private static func stateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func reject(_ reply: Pending, _ code: String) {
        logFailure(method: reply.method, code: code)
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

    // 保留字节预留与序列化校验在独立 Foundation helper 中，真实 CI 可直接验证并发预算。
}
