import Foundation
import CryptoKit

// 面板静态资源本地快照。对应安卓 WebCache 的 NATIVE_PATHS 子集：
// 只有把面板资源落到本机，欢迎页的「初始化 / 进度 / 资源序号」才有意义，
// 也才能在弱网或离线时直接进面板。
//
// 与安卓的差异：iOS 没有 WebView 自带 HTTP 缓存可复用，所以这里自己下载、
// 自己校验、自己落盘，再交给 PanelSchemeHandler 用自定义 scheme 提供给 WKWebView。
final class IOSPanelCache {
    static let shared = IOSPanelCache()

    // 顺序即资源序号；与 build-static.mjs 生成的产物集合保持一致。
    // 首个是 index.html，它决定整份快照是否可用。
    // 后四项是 index.html 会引用的图标与 PWA 清单，缺了虽然不白屏但会 404。
    static let resources: [String] = [
        "index.html",
        "mock.json",
        "version.json",
        "manifest.webmanifest",
        "sw.js",
        "theme.LICENSE.txt",
        "icons/icon-192.png",
        "icons/icon-512.png",
        "icons/apple-touch-icon.png",
        "icons/favicon-32.png",
        "icons/icon-maskable-512.png"
    ]

    enum Phase: String {
        case idle
        case preparing
        case downloading
        case ready
        case error
    }

    struct State {
        var phase: Phase = .idle
        var done: Int64 = 0
        var total: Int64 = 0
        /// 已开始下载的资源序号（从 1 起），用于「资源 N/M」。
        var resourceIndex: Int = 0
        /// 已落盘完成的文件数。进度条以它为准，不依赖 Content-Length。
        var completedFiles: Int = 0
        var resourceCount: Int = IOSPanelCache.resources.count
        var error: String = ""
        var build: String = ""
        var busy: Bool { phase == .preparing || phase == .downloading }
        var ready: Bool { phase == .ready }
        /// 进度比例。优先用「已完成文件数 / 总数」——字节数依赖 Content-Length，
        /// CDN 压缩或缺少响应头时会算错（真机曾卡在 90%）。
        var progress: Double {
            if resourceCount > 0, completedFiles > 0 {
                return min(1, Double(completedFiles) / Double(resourceCount))
            }
            if total > 0 {
                return min(1, Double(done) / Double(total))
            }
            return 0
        }
    }

    private enum Failure: Error {
        case reason(String)
        var code: String { if case let .reason(value) = self { return value }; return "panel_cache_failed" }
    }

    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.panel-cache", qos: .utility)
    /// 复用同一个 ephemeral session：每次下载新建一个会漏连接池，也不利于统一取消。
    /// 下载会话。
    ///
    /// 用 `.default` 而不是 `.ephemeral`：ephemeral 不给磁盘缓存也不复用连接池里的
    /// TLS session，每个请求都要重新握手（GitHub Pages 是 HTTPS，握手本身就 2~3 个 RTT）。
    /// 11 个资源串行下载时这点开销被放大得最明显。
    /// urlCache 仍置空，避免拿到过期的面板资源。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldUsePipelining = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()
    private var state = State()
    private var tasks: [URLSessionDataTask] = []
    private let lock = NSLock()
    private var generation = 0
    private var cancelled = false
    /// 初始化期间每次状态变化都回调，让欢迎页看到实时进度。
    var onState: ((State) -> Void)?

    private init() {}

    // MARK: - 目录

    /// 快照目录。与 Store 同级但独立：清快照不能碰登录态，清登录态也不能碰快照。
    private func rootDirectory() throws -> URL {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("ZeehoPanel", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                 .posixPermissions: 0o700])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(excluded)
        return directory
    }

    /// 当前生效快照的根（`ZeehoPanel/current`）。不存在表示还没有可用快照。
    func snapshotDirectory() -> URL? {
        guard let root = try? rootDirectory() else { return nil }
        let current = root.appendingPathComponent("current", isDirectory: true)
        let index = current.appendingPathComponent("index.html", isDirectory: false)
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        return current
    }

    /// 读当前快照记录的构建号（`version.json` 的 build）。用于握手与更新提示。
    func snapshotBuild() -> String {
        guard let directory = snapshotDirectory() else { return "" }
        let file = directory.appendingPathComponent("version.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let build = object["build"] as? String else { return "" }
        return build
    }

    // MARK: - 状态

    func snapshot() -> State {
        queue.sync { state }
    }

    // MARK: - 初始化

    /// 下载并替换快照。`force` 会先清空旧快照（对应安卓 resetStaticResources）。
    /// 任何一步失败都保留旧快照，绝不把半成品写成 current。
    func initialize(force: Bool, completion: @escaping (State) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.state.busy else {
                let current = self.state
                DispatchQueue.main.async { completion(current) }
                return
            }
            self.generation += 1
            let ticket = self.generation
            self.cancelled = false
            self.state = State(phase: .preparing, done: 0, total: 0, resourceIndex: 0,
                               resourceCount: Self.resources.count, error: "", build: "")
            self.emit(ticket, completion)

            do {
                let root = try self.rootDirectory()
                if force { try? FileManager.default.removeItem(at: root.appendingPathComponent("current", isDirectory: true)) }
                let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                                     .posixPermissions: 0o700])
                self.downloadAll(into: staging, ticket: ticket) { result in
                    self.queue.async {
                        guard self.generation == ticket else { return }
                        switch result {
                        case let .failure(error):
                            try? FileManager.default.removeItem(at: staging)
                            self.state.phase = .error
                            self.state.error = (error as? Failure)?.code ?? "panel_cache_failed"
                            self.emit(ticket, completion)
                        case .success:
                            // 只有整组下载成功才交换 current；rename 是原子的。
                            let current = root.appendingPathComponent("current", isDirectory: true)
                            let backup = root.appendingPathComponent(".old-" + UUID().uuidString, isDirectory: true)
                            let hadOld = FileManager.default.fileExists(atPath: current.path)
                            if hadOld { try? FileManager.default.moveItem(at: current, to: backup) }
                            do {
                                try FileManager.default.moveItem(at: staging, to: current)
                                if hadOld { try? FileManager.default.removeItem(at: backup) }
                                self.state.phase = .ready
                                self.state.build = self.snapshotBuild()
                                self.state.error = ""
                            } catch {
                                if hadOld { try? FileManager.default.moveItem(at: backup, to: current) }
                                try? FileManager.default.removeItem(at: staging)
                                self.state.phase = .error
                                self.state.error = "panel_commit_failed"
                            }
                            self.emit(ticket, completion)
                        }
                    }
                }
            } catch {
                self.state.phase = .error
                self.state.error = (error as? Failure)?.code ?? "panel_cache_failed"
                self.emit(ticket, completion)
            }
        }
    }

    /// 只读预检：不清缓存，只按现有快照决定 ready 与否。
    func refresh(completion: @escaping (State) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.state.busy else {
                let current = self.state
                DispatchQueue.main.async { completion(current) }
                return
            }
            if self.snapshotDirectory() != nil {
                self.state = State(phase: .ready, done: 0, total: 0, resourceIndex: 0,
                                   resourceCount: Self.resources.count, error: "",
                                   build: self.snapshotBuild())
            } else {
                self.state = State(phase: .idle, done: 0, total: 0, resourceIndex: 0,
                                   resourceCount: Self.resources.count, error: "", build: "")
            }
            let current = self.state
            DispatchQueue.main.async { completion(current) }
        }
    }

    /// 取消进行中的初始化。已落盘的内容全部丢弃，旧快照保持可用。
    func cancel(completion: @escaping (State) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelled = true
            self.generation += 1
            self.lock.lock()
            for job in self.tasks { job.cancel() }
            self.tasks.removeAll()
            self.lock.unlock()
            if self.snapshotDirectory() != nil {
                self.state = State(phase: .ready, done: 0, total: 0, resourceIndex: 0,
                                   resourceCount: Self.resources.count, error: "",
                                   build: self.snapshotBuild())
            } else {
                self.state = State(phase: .idle, done: 0, total: 0, resourceIndex: 0,
                                   resourceCount: Self.resources.count, error: "", build: "")
            }
            let current = self.state
            DispatchQueue.main.async { completion(current) }
        }
    }

    private func emit(_ ticket: Int, _ completion: @escaping (State) -> Void) {
        guard generation == ticket else { return }
        let current = state
        DispatchQueue.main.async { completion(current) }
    }

    // MARK: - 下载

    /// 并发下载全部资源。
    ///
    /// 之前的实现是「一个文件下完再下一个」，11 个文件串行 = 首屏要等 11 个 RTT，
    /// 而且进度条只在每个文件完成时跳一次，中途看起来像卡死。改成：
    ///   - 同时最多 `maxConcurrent` 个请求（太多会被 CDN 限速，4 是常见甜点）
    ///   - 每个字节都回调进度（节流到 100ms，避免刷爆主线程）
    ///   - total 用响应头 Content-Length 累加，进度条按真实比例走
    private static let maxConcurrent = 4
    private static let progressInterval: TimeInterval = 0.1
    /// 单个资源失败后最多重试次数。移动网络抖动很常见，
    /// 一次失败就整批 abort 会让用户卡在「N-1/N」不动。
    private static let maxRetriesPerResource = 2

    /// 并发下载的共享状态。用引用类型而不是闭包捕获 var：
    /// Swift 6 不允许在异步闭包里改捕获的可变局部变量。
    private final class Batch {
        let ticket: Int
        var remaining: Int
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var failed: Error?
        var lastEmit: TimeInterval = 0
        var inFlight = 0
        var nextIndex = 0
        var finished = false
        /// 已经计入 totalBytes 的资源下标，避免重复累加 Content-Length。
        var knownSizes = Set<Int>()
        /// 已完成（落盘成功）的文件数。进度条以它为主，字节数为辅——
        /// 字节数依赖 Content-Length，CDN 压缩/缺头时不可靠。
        var completedFiles = 0
        /// 每个资源已尝试次数，用于单文件重试。
        var attempts: [Int: Int] = [:]
        let completion: (Result<Void, Error>) -> Void

        init(ticket: Int, count: Int, completion: @escaping (Result<Void, Error>) -> Void) {
            self.ticket = ticket
            self.remaining = count
            self.completion = completion
        }
    }

    private func downloadAll(into staging: URL, ticket: Int,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        let base = IOSPanelLine.baseURL()
        let batch = Batch(ticket: ticket, count: Self.resources.count, completion: completion)
        state.phase = .downloading
        state.resourceCount = Self.resources.count
        // 冷启动时先把阶段推给界面，别让用户盯着「待完成」等第一个字节。
        emitState(ticket)

        if Self.resources.isEmpty {
            batch.finished = true
            completion(.success(()))
            return
        }
        // 先并发探一遍 Content-Length：进度条从第一秒起就是真实比例，
        // 而不是等最后一个文件下完才跳到 100%。
        // notify 已经回到本类的串行队列上，不需要再 async 一次。
        probeSizes(base: base, ticket: ticket) { [weak self] sizes in
            guard let self = self else { return }
            guard self.generation == ticket, !batch.finished else { return }
            batch.totalBytes = sizes.reduce(0) { $0 + $1 }
            batch.knownSizes = Set(Self.resources.indices)
            self.state.total = batch.totalBytes
            self.emitState(ticket)
            // 起 maxConcurrent 个并发位，每个位下完一个就立刻领下一个。
            for _ in 0..<min(Self.maxConcurrent, Self.resources.count) {
                self.pullNext(base: base, staging: staging, batch: batch)
            }
        }
    }

    /// 用并行 HEAD 拿每个资源的真实大小。
    ///
    /// **必须禁用压缩**：GitHub Pages 对 html/js/json 会回 gzip，HEAD 的
    /// Content-Length 是压缩后的长度（index.html 3.56MB → 1.02MB），
    /// 而 URLSession 下载时给的是解压后的字节。两者混用会让进度条算到
    /// 200%+ 然后卡住（真机实测卡在 90%）。
    /// 这里显式 `Accept-Encoding: identity` 拿原始大小；拿不到就退回 0，
    /// 由下载时的实测字节兜底。
    private func probeSizes(base: URL, ticket: Int,
                            completion: @escaping ([Int64]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var sizes = [Int64](repeating: 0, count: Self.resources.count)
        for (index, name) in Self.resources.enumerated() {
            guard let url = URL(string: name, relativeTo: base) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.httpMethod = "HEAD"
            // 关键：要原始字节数，不要压缩后的长度。
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            group.enter()
            let job = Self.session.dataTask(with: request) { _, response, _ in
                defer { group.leave() }
                guard let http = response as? HTTPURLResponse,
                      // 服务端仍可能压缩（部分 CDN 无视 identity），
                      // 那种情况下 Content-Length 不可信，直接放弃这一项。
                      (http.value(forHTTPHeaderField: "Content-Encoding") ?? "")
                        .lowercased().contains("gzip") == false,
                      let length = http.value(forHTTPHeaderField: "Content-Length"),
                      let value = Int64(length), value > 0 else { return }
                lock.lock(); sizes[index] = value; lock.unlock()
            }
            job.resume()
        }
        group.notify(queue: queue) { completion(sizes) }
    }

    /// 领下一个还没分配的资源并开始下载；没有剩余且全部完成时收尾。
    private func pullNext(base: URL, staging: URL, batch: Batch) {
        guard !cancelled, generation == batch.ticket else {
            failBatch(batch, Failure.reason("panel_cache_cancelled"))
            return
        }
        guard batch.failed == nil, !batch.finished else { return }
        guard batch.nextIndex < Self.resources.count else {
            // 没有更多资源；等在途的都回来再收尾。
            if batch.inFlight == 0 {
                finishBatch(batch)
            }
            return
        }
        let index = batch.nextIndex
        batch.nextIndex += 1
        let name = Self.resources[index]
        guard let url = URL(string: name, relativeTo: base) else {
            failBatch(batch, Failure.reason("panel_resource_url_invalid"))
            return
        }
        batch.inFlight += 1
        state.resourceIndex = min(index + 1, Self.resources.count)

        download(url,
                 onProgress: { [weak self] received, expected in
                     guard let self = self else { return }
                     self.queue.async {
                         guard self.generation == batch.ticket else { return }
                         // 预探没拿到大小的资源（HEAD 失败/无 Content-Length），
                         // 下载时补上，保证 total 最终等于真实字节数。
                         if expected > 0, !batch.knownSizes.contains(index) {
                             batch.knownSizes.insert(index)
                             batch.totalBytes += expected
                         }
                         batch.doneBytes += received
                         self.state.total = batch.totalBytes
                         self.state.done = batch.doneBytes
                         self.throttledEmit(batch)
                     }
                 },
                 completion: { [weak self] result in
                     guard let self = self else { return }
                     self.queue.async {
                         guard self.generation == batch.ticket else { return }
                         switch result {
                         case let .failure(error):
                             // 单文件失败先重试（网络抖动很常见）；重试次数用完才整体失败。
                             // 之前一次失败就整批 abort，用户看到的就是「卡在 90% 然后没了」。
                             let attempts = (batch.attempts[index] ?? 0) + 1
                             batch.attempts[index] = attempts
                             if attempts <= Self.maxRetriesPerResource,
                                (error as? Failure)?.code != "panel_cache_cancelled" {
                                 IOSDiagnostics.shared.log(
                                     "panelCache: \(name) 第 \(attempts) 次失败（\((error as? Failure)?.code ?? "?")），重试")
                                 // 把序号让回去，让这个并发位重新领同一个文件。
                                 batch.nextIndex = index
                                 batch.inFlight -= 1
                                 self.pullNext(base: base, staging: staging, batch: batch)
                                 return
                             }
                             batch.inFlight -= 1
                             batch.remaining -= 1
                             self.failBatch(batch, error)
                         case let .success(data):
                             batch.inFlight -= 1
                             batch.remaining -= 1
                             let destination = staging.appendingPathComponent(name, isDirectory: false)
                             do {
                                 try FileManager.default.createDirectory(
                                     at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
                                 try data.write(to: destination, options: [.atomic])
                                 batch.completedFiles += 1
                                 self.state.completedFiles = batch.completedFiles
                                 self.emitState(batch.ticket)
                                 self.pullNext(base: base, staging: staging, batch: batch)
                             } catch {
                                 self.failBatch(batch, Failure.reason("panel_write_failed"))
                             }
                         }
                     }
                 })
    }

    private func throttledEmit(_ batch: Batch) {
        let now = Date().timeIntervalSince1970
        guard now - batch.lastEmit >= Self.progressInterval else { return }
        batch.lastEmit = now
        emitState(batch.ticket)
    }

    private func emitState(_ ticket: Int) {
        guard generation == ticket else { return }
        let current = state
        DispatchQueue.main.async { self.onState?(current) }
    }

    private func finishBatch(_ batch: Batch) {
        guard !batch.finished else { return }
        batch.finished = true
        batch.completion(.success(()))
    }

    private func failBatch(_ batch: Batch, _ error: Error) {
        guard !batch.finished else { return }
        batch.finished = true
        batch.completion(.failure(error))
    }

    /// 单文件下载。进度粒度是「整个文件」——`URLSession.dataTask` 的
    /// completion 只在全部收完时回调，拿不到中途字节数。
    /// 要做真正的字节级进度得改用 `URLSessionDataDelegate` 的 didReceive(data:)，
    /// 那需要把整个 session 换成 delegate 模式；11 个文件（1 大 10 小）时
    /// 「每文件一次回调」已经够用，不值得为此重构。
    /// `onProgress` 的第二个参数是 Content-Length（未知时为 0）。
    private func download(_ url: URL,
                          onProgress: @escaping (Int64, Int64) -> Void,
                          completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let job = Self.session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(Failure.reason((error as NSError).code == NSURLErrorCancelled
                    ? "panel_cache_cancelled" : "panel_download_failed")))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data, !data.isEmpty else {
                completion(.failure(Failure.reason("panel_download_failed")))
                return
            }
            let declared = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
            onProgress(Int64(data.count), declared > 0 ? declared : 0)
            completion(.success(data))
        }
        lock.lock()
        tasks.append(job)
        lock.unlock()
        job.resume()
    }
}
