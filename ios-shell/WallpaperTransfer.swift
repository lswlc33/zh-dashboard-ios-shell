import Foundation
import UIKit
import Network

// 壳只拥有通用资产与字节能力；车辆协议、审核、选择编号和传输状态机由私有网页拥有。
// URLSession 无 requiredInterface；已加入目标私网时拒绝下载，先互联网准备再连接车机。
private final class IOSWallpaperDownload: NSObject, URLSessionDataDelegate {
    private let spec: IOSWallpaperSpec
    private let directory: URL
    private let token: IOSVehicleCancellation
    private let guardScope: () -> Bool
    private let progress: (Int) -> Void
    private let internetGuard: (@escaping (Bool) -> Void) -> Void
    private let monitor = NWPathMonitor()
    private let io = OperationQueue()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received = 0, expected = -1, redirects = 0
    // didReceive 分块的闸门节流游标（单调 uptime 秒，-1 = 尚未检查过）：与 received 等一样
    // 只在 io 串行队列（URLSession delegate 回调队列）读写，无并发访问。
    private var lastGuardAt: TimeInterval = -1
    private var failure: Error?
    private var completion: ((Result<IOSWallpaperPreparedPackage, Error>) -> Void)?
    private let lock = NSLock()
    private var internetValid = false
    private var finished = false

    init(spec: IOSWallpaperSpec, directory: URL, token: IOSVehicleCancellation,
         guardScope: @escaping () -> Bool, internetGuard: @escaping (@escaping (Bool) -> Void) -> Void,
         progress: @escaping (Int) -> Void) {
        self.spec = spec; self.directory = directory; self.token = token
        self.guardScope = guardScope; self.internetGuard = internetGuard; self.progress = progress
        super.init()
        io.name = "io.github.lswlc33.dashboard.ios.asset-download"; io.maxConcurrentOperationCount = 1
    }
    func start(completion: @escaping (Result<IOSWallpaperPreparedPackage, Error>) -> Void) {
        precondition(Thread.isMainThread); self.completion = completion
        guard spec.url != nil else { finish(.failure(IOSWallpaperError("download_unavailable"))); return }
        var started = false
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let pathValid = path.status == .satisfied && !path.usesInterfaceType(.other)
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular))
                && !IOSVehicleNetworkService.hasVPNInterface()
            self.internetGuard { allowed in
                let valid = pathValid && allowed
                self.lock.lock(); self.internetValid = valid; let finished = self.finished; self.lock.unlock()
                guard !finished else { return }
                if !valid {
                    self.token.cancel(); self.finish(.failure(IOSWallpaperError("internet_unavailable_or_vehicle_ap_joined")))
                    return
                }
                if started { return }; started = true
                self.io.addOperation { [weak self] in self?.beginRequest() }
            }
        }
        monitor.start(queue: .main)
    }
    private func guardDownload() throws {
        try token.check()
        lock.lock(); let valid = internetValid && !finished; lock.unlock()
        var scopeValid = false
        if Thread.isMainThread { scopeValid = guardScope() }
        else { DispatchQueue.main.sync { scopeValid = self.guardScope() } }
        let semaphore = DispatchSemaphore(value: 0)
        var allowed = false
        DispatchQueue.main.async {
            self.internetGuard { value in allowed = value; semaphore.signal() }
        }
        guard semaphore.wait(timeout: .now() + 5) == .success,
              valid, scopeValid, allowed, !IOSVehicleNetworkService.hasVPNInterface() else {
            throw IOSWallpaperError("internet_route_or_scope_lost")
        }
        // SSID 查询可能迟到；等完后不能借用等待前的 scope/token 快照启动或继续 IO。
        try token.check()
        lock.lock(); let stillValid = internetValid && !finished; lock.unlock()
        DispatchQueue.main.sync { scopeValid = self.guardScope() }
        guard stillValid, scopeValid else { throw IOSWallpaperError("cancelled_or_stale_after_internet_guard") }
        try token.check()
    }
    private func beginRequest() {
        do {
            try guardDownload()
            guard let url = spec.url else { throw IOSWallpaperError("download_unavailable") }
            let candidate = directory.appendingPathComponent(spec.fileName)
            guard FileManager.default.createFile(atPath: candidate.path, contents: nil) else { throw IOSWallpaperError("cache_file") }
            file = try FileHandle(forWritingTo: candidate)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 120
            config.waitsForConnectivity = false; config.allowsCellularAccess = true
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config, delegate: self, delegateQueue: io)
            self.session = session
            var request = URLRequest(url: url)
            request.httpMethod = "GET"; request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("", forHTTPHeaderField: "Cookie"); request.setValue("", forHTTPHeaderField: "Authorization")
            let task = session.dataTask(with: request); self.task = task
            var resumed = false
            // resume 与导航/取消同在 main 最后一拍核验；旧 worker 不会在已取消后新启请求。
            DispatchQueue.main.sync {
                guard self.token.valid, self.guardScope() else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard !self.finished, self.internetValid else { return }
                task.resume(); resumed = true
            }
            guard resumed else { task.cancel(); throw IOSWallpaperError("cancelled_before_task_resume") }
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            try guardDownload(); redirects += 1
            guard redirects <= 4, let url = request.url else { throw IOSWallpaperError("redirect_limit") }
            _ = try IOSWallpaperPackage.allowedURL(url.absoluteString)
            var safe = request; safe.httpMethod = "GET"; safe.httpBody = nil
            safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            safe.setValue("", forHTTPHeaderField: "Cookie"); safe.setValue("", forHTTPHeaderField: "Authorization")
            completionHandler(safe)
        } catch { failure = error; completionHandler(nil); task.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try guardDownload()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else { throw IOSWallpaperError("download_http") }
            _ = try IOSWallpaperPackage.allowedURL(url.absoluteString)
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw IOSWallpaperError("download_encoding") }
            let length = response.expectedContentLength
            guard length >= -1, length != 0, length <= IOSWallpaperPackage.maxFile else { throw IOSWallpaperError("download_size") }
            expected = Int(length)
            guard spec.fileSize == nil || expected < 0 || spec.fileSize == expected else { throw IOSWallpaperError("download_size") }
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            // 分块（约 64KB 一拍）不再逐块全量跑 guardDownload：它含主线程 sync 与最长 5s
            // 的信号量等待，逐块检查会把传输拖成一拍一停。改为节流——首块必查，之后距上次
            // 全量检查 ≥2 秒才再跑。guardDownload 本身语义不动：beginRequest/响应头/重定向/
            // complete 与包校验仍逐次全量检查，安全闸门不被削弱；检查失败时不推进游标，
            // 下一分块立即重查并走原有失败路径。
            let now = ProcessInfo.processInfo.systemUptime
            if lastGuardAt < 0 || now - lastGuardAt >= 2 { try guardDownload(); lastGuardAt = now }
            guard !data.isEmpty, data.count <= IOSWallpaperPackage.maxFile - received,
                  spec.fileSize == nil || received + data.count <= spec.fileSize!, let file = file else { throw IOSWallpaperError("download_size") }
            try file.write(contentsOf: data); received += data.count
            let total = spec.fileSize ?? expected, value = total > 0 ? min(99, received * 100 / total) : 0
            DispatchQueue.main.async { [weak self] in self?.progress(value) }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            if let failure = failure { throw failure }; if let error = error { throw error }
            try guardDownload()
            guard received > 0, expected < 0 || received == expected else { throw IOSWallpaperError("download_size") }
            try file?.synchronize(); try file?.close(); file = nil
            let package = try IOSWallpaperPackage.validate(file: directory.appendingPathComponent(spec.fileName), spec: spec, check: guardDownload)
            finish(.success(package))
        } catch { finish(.failure(error)) }
    }
    func cancel(completion: (() -> Void)? = nil) {
        token.cancel(); finish(.failure(IOSWallpaperError("cancelled")))
        // 所有 delegate/write 均在同一串行 queue；清理屏障后才允许删目录。
        io.addOperation { [self] in
            session?.invalidateAndCancel(); task?.cancel(); session = nil; task = nil
            try? file?.close(); file = nil
            completion?()
        }
    }
    private func finish(_ result: Result<IOSWallpaperPreparedPackage, Error>) {
        lock.lock(); let already = finished; finished = true; internetValid = false; lock.unlock()
        guard !already else { return }
        let deliver = { [self] in
            monitor.cancel()
            io.addOperation { [self] in
                session?.invalidateAndCancel(); task?.cancel(); session = nil; task = nil
                try? file?.close(); file = nil
                DispatchQueue.main.async { [self] in
                    guard let callback = completion else { return }; completion = nil; callback(result)
                }
            }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}

final class IOSNativeAssetService: IOSBridgeCancellableService {
    let methods = ["asset.download.begin", "asset.zip.build.begin", "asset.poll", "asset.read", "asset.cancel"]
    private let context = IOSVehicleContext()
    private let network: IOSVehicleNetworkService
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.asset", qos: .userInitiated)
    private var job: Job?
    private var watch: DispatchWorkItem?
    private final class Job {
        let ticket = UUID().uuidString
        let lease: IOSVehicleContext.Lease
        let token = IOSVehicleCancellation(seconds: 120)
        var directory: URL?
        var spec: IOSWallpaperSpec?
        var package: IOSWallpaperPreparedPackage?
        var download: IOSWallpaperDownload?
        var handle: FileHandle?
        var busy = true, reading = false
        var progress = 0, error = ""
        init(lease: IOSVehicleContext.Lease) { self.lease = lease }
    }
    init(network: IOSVehicleNetworkService) { self.network = network }
    func setScopeProvider(_ provider: @escaping () -> IOSRideScope?) { context.scopeProvider = provider }
    func setNavigationProvider(_ provider: @escaping () -> String?) { context.navigationProvider = provider }
    func setFrameProvider(_ provider: @escaping () -> String?) { context.frameProvider = provider }
    func navigationChanged() { precondition(Thread.isMainThread); context.invalidate(); cancelJob() }
    func applicationBackgrounded() { navigationChanged() }
    func cancel(method: String, args: [Any]) { cancelJob() }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard let object = args.first as? [String: Any] else { throw IOSWallpaperError("invalid_args") }
            let lease = try context.capture(object)
            if method == "asset.download.begin" || method == "asset.zip.build.begin" {
                let local = method == "asset.zip.build.begin"
                guard args.count == (local ? 3 : 1), job == nil else { throw IOSWallpaperError("asset_busy_or_invalid_args") }
                let main = local ? args[1] as? String : "", speed = local ? args[2] as? String : ""
                guard let main = main, let speed = speed, !local || IOSWallpaperPackage.boundedLocal(main, speed) else { throw IOSWallpaperError("invalid_images") }
                let allowed: Set<String> = local ? ["fileName", "mainWidth", "mainHeight", "speedWidth", "speedHeight"]
                    : ["url", "fileName", "fileSize", "md5"]
                guard Set(object.keys).isSubset(of: allowed.union(["navigationId", "epoch", "frame"])) else { throw IOSWallpaperError("unexpected_asset_metadata") }
                let metadata = object.filter { allowed.contains($0.key) }
                guard metadata.values.allSatisfy({ value in
                    if let text = value as? String { return text.utf8.count <= 8192 }
                    return value is NSNumber || value is NSNull
                }) else { throw IOSWallpaperError("metadata_too_large_or_invalid") }
                let text = String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8) ?? ""
                guard text.utf8.count <= 16384 else { throw IOSWallpaperError("metadata_too_large") }
                let j = Job(lease: lease); job = j
                reply(["ok": true, "ticket": j.ticket, "ready": false, "busy": true], nil)
                armWatch(j)
                worker.async { [weak self] in
                    guard let self = self else { return }
                    var directory: URL?
                    do {
                        try j.token.check()
                        let spec = try IOSWallpaperSpec.parse(text, local: local)
                        let target = FileManager.default.temporaryDirectory.appendingPathComponent("native-asset-" + j.ticket, isDirectory: true)
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                        directory = target
                        if local {
                            let package = try IOSWallpaperPackage.buildLocal(directory: target, spec: spec, main: main, speed: speed, check: j.token.check)
                            let handle = try FileHandle(forReadingFrom: package.file)
                            DispatchQueue.main.async {
                                guard self.current(j), j.token.valid else {
                                    self.worker.async { try? handle.close(); try? FileManager.default.removeItem(at: target) }; return
                                }
                                j.spec = spec; j.directory = target; j.package = package; j.handle = handle
                                j.busy = false; j.progress = 100
                            }
                        } else {
                            DispatchQueue.main.async {
                                guard self.current(j), j.token.valid else { self.remove(target); return }
                                j.spec = spec; j.directory = target
                                let download = IOSWallpaperDownload(spec: spec, directory: target, token: j.token,
                                    guardScope: { [weak self] in self?.current(j) == true },
                                    internetGuard: { [weak self] completion in
                                        guard let self = self, self.current(j) else { completion(false); return }
                                        self.network.internetRouteAllowed(scope: j.lease.scope, completion: completion)
                                    },
                                    progress: { [weak self] value in if self?.current(j) == true { j.progress = value } })
                                j.download = download
                                download.start { result in
                                    guard self.current(j) else { self.remove(target); return }
                                    switch result {
                                    case let .success(package):
                                        self.worker.async {
                                            do {
                                                try j.token.check(); let handle = try FileHandle(forReadingFrom: package.file)
                                                DispatchQueue.main.async {
                                                    guard self.current(j), j.token.valid else {
                                                        self.worker.async { try? handle.close() }; return
                                                    }
                                                    j.handle = handle; j.package = package; j.progress = 100; j.busy = false; j.download = nil
                                                }
                                            } catch { DispatchQueue.main.async { self.fail(j, error) } }
                                        }
                                    case let .failure(error): self.fail(j, error)
                                    }
                                }
                            }
                        }
                    } catch {
                        if let directory = directory { self.remove(directory) }
                        DispatchQueue.main.async { self.fail(j, error) }
                    }
                }
                return
            }
            guard args.count == 1, let ticket = object["ticket"] as? String, let j = job,
                  j.ticket == ticket, context.same(lease, j.lease), current(j) else { throw IOSWallpaperError("invalid_asset_ticket") }
            switch method {
            case "asset.poll": reply(info(j), nil)
            case "asset.cancel": cancelJob(); reply(["ok": true, "ticket": ticket, "cancelled": true], nil)
            case "asset.read":
                guard !j.busy, !j.reading, j.error.isEmpty, let package = j.package, let handle = j.handle else { throw IOSWallpaperError("asset_not_ready") }
                let offset = try IOSWallpaperJSON.integer(object["offset"], max: package.size)
                let length = try IOSWallpaperJSON.integer(object["length"], min: 1, max: 65536)
                // offset 已到文件尾：length≥1 的要求无解，回明确错误而不是空 payload+eof 的边角语义。
                guard offset < package.size else { throw IOSWallpaperError("invalid_offset") }
                j.reading = true
                worker.async { [weak self] in
                    guard let self = self else { return }
                    do {
                        var valid = false; DispatchQueue.main.sync { valid = self.current(j) }
                        guard valid else { throw IOSWallpaperError("stale_context") }
                        try handle.seek(toOffset: UInt64(offset))
                        let count = min(length, package.size - offset)
                        var data = Data()
                        while data.count < count {
                            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { throw IOSWallpaperError("asset_truncated") }
                            data.append(part)
                        }
                        DispatchQueue.main.async {
                            guard self.current(j) else { reply(nil, "stale_context"); return }
                            j.reading = false
                            reply(["ok": true, "ticket": ticket, "offset": offset, "length": data.count,
                                   "base64": data.base64EncodedString(), "eof": offset + data.count == package.size], nil)
                        }
                    } catch {
                        DispatchQueue.main.async { j.reading = false; self.fail(j, error); reply(nil, self.code(error)) }
                    }
                }
            default: throw IOSWallpaperError("unsupported_method")
            }
        } catch { reply(nil, code(error)) }
    }
    private func current(_ j: Job) -> Bool { job === j && context.current(j.lease) }
    private func info(_ j: Job) -> [String: Any] {
        ["ok": j.error.isEmpty, "ticket": j.ticket, "ready": j.package != nil && j.error.isEmpty,
         "busy": j.busy, "fileName": j.package?.fileName ?? j.spec?.fileName ?? "",
         "fileSize": j.package?.size ?? 0, "md5": j.package?.md5 ?? "", "progress": j.progress,
         "error": j.error, "screenUpdated": NSNull()]
    }
    private func fail(_ j: Job, _ error: Error) {
        guard current(j) else { return }
        // 句柄先收：fail 后 job 未必马上 cancel，文件描述符别悬到那时才释放。
        if let handle = j.handle { try? handle.close(); j.handle = nil }
        j.busy = false; j.error = code(error); j.package = nil; j.token.cancel()
        // download.cancel 的完成回调负责清临时目录；这里只取消。
        let download = j.download; j.download = nil
        if let download = download { download.cancel() }
    }
    private func armWatch(_ j: Job) {
        let item = DispatchWorkItem { [weak self, weak j] in
            guard let self = self, let j = j, self.job === j else { return }
            guard self.current(j) else { self.cancelJob(); return }
            if j.busy && !j.token.valid { self.fail(j, IOSWallpaperError("asset_timeout")) }
            self.armWatch(j)
        }
        watch = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
    private func cancelJob() {
        watch?.cancel(); watch = nil
        guard let j = job else { return }; job = nil; j.token.cancel()
        let directory = j.directory, handle = j.handle; j.directory = nil; j.handle = nil; j.package = nil
        let cleanup = { [self] in worker.async { try? handle?.close(); if let directory = directory { try? FileManager.default.removeItem(at: directory) } } }
        if let download = j.download { download.cancel(completion: cleanup); j.download = nil }
        else { cleanup() }
    }
    private func remove(_ directory: URL) { worker.async { try? FileManager.default.removeItem(at: directory) } }
    private func code(_ error: Error) -> String {
        (error as? IOSWallpaperError)?.code ?? (error as? IOSVehicleNetworkError)?.code ?? "asset_failed"
    }
}
