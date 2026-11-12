import Foundation

// 面板静态资源本地快照。对应安卓 WebCache 的 NATIVE_PATHS 子集：
// 只有把面板资源落到本机，欢迎页的「初始化 / 进度 / 资源序号」才有意义，
// 也才能在弱网或离线时直接进面板。
//
// 与安卓的差异：iOS 没有 WebView 自带 HTTP 缓存可复用，所以这里自己下载、
// 自己校验、自己落盘，再交给 PanelSchemeHandler 用自定义 scheme 提供给 WKWebView。
//
// 快照生命周期：
//   1. `initialize(force:)` 先把整批资源下到 `.staging-<UUID>`，成功后两步改名换进 `current`。
//      `force` 只表示「忽略已有快照、必须重新下载」，**不再提前删 current**：
//      下载失败/取消时 staging 删掉、current 原封不动，用户不会因为一次失败丢掉可用面板。
//   2. 提交成功后写 `panel-meta.json`（构建号 / 线路 / 下载毫秒时间），
//      供 `needsRefresh()` 判断快照是否过期、`initialize` 判断线路是否换了。
//   3. 读路径只认 `current`；`snapshotDirectory()` 首次解析后缓存结果，
//      之后退化成一次 fileExists，不在主线程做目录创建之类的 IO。
final class IOSPanelCache {
    static let shared = IOSPanelCache()

    // 顺序即资源序号；与 build-static.mjs 生成的产物集合保持一致。
    // 首个是 index.html，它决定整份快照是否可用。
    // 其余是页面引用的数据、图标与 PWA 清单，缺了虽然不白屏但会 404。
    // 不含 sw.js：壳内 `registerSw()` 在 `inShell()` 为真时直接 return
    // （见 public/js/app.js），Service Worker 在 WebView 里永远不注册，
    // 下载它只会多花一次请求和一份磁盘。
    static let resources: [String] = [
        "index.html",
        "mock.json",
        "version.json",
        "manifest.webmanifest",
        "theme.LICENSE.txt",
        "icons/icon-192.png",
        "icons/icon-512.png",
        "icons/apple-touch-icon.png",
        "icons/favicon-32.png",
        "icons/icon-maskable-512.png"
    ]

    /// 必需资源：下载失败就不提交整份快照。
    /// 只有 index.html 满足这个条件——没有它就没有页面；mock.json 缺失时网页自己有
    /// catch 兜底，其余都是图标与清单，缺一个最多 404 一次。
    /// 用并行表而不是给 `resources` 的元素加字段：RecoveryView /
    /// UpdatePanelViewController / test.py 都在读 `resources.count`，改类型会牵连其他文件。
    private static let requiredNames: Set<String> = ["index.html"]

    private static func isRequired(_ name: String) -> Bool { requiredNames.contains(name) }

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
        /// 已落盘完成的文件数。进度条以它为准，不依赖 Content-Length。
        /// 可选资源失败被跳过时也计入（见 `skipped`），否则进度条永远到不了 100%。
        var completedFiles: Int = 0
        var resourceCount: Int = IOSPanelCache.resources.count
        var error: String = ""
        var build: String = ""
        /// 可选资源里下载失败、被跳过的路径。欢迎页据此提示「N 个资源未下载」。
        var skipped: [String] = []
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

    /// `panel-meta.json` 的内容。只在 initialize 提交成功后写：
    /// 用它区分「快照太旧」和「快照来自另一条线路」，避免用户永远停在旧面板。
    struct SnapshotMeta {
        /// 面板构建号（快照内 version.json 的 build）。
        var build: String = ""
        /// 下载时的线路（IOSPanelLine.rawValue）。线路换了旧快照必须整批重下。
        var line: String = ""
        /// 下载完成时间，毫秒时间戳；0 表示未知（旧版本留下的快照没有这个文件）。
        var downloadedAt: Int64 = 0
        /// 成功下载时的 IPA build。覆盖安装保留旧文件，build 变化必须重新拉取网页。
        var shellBuild: String = ""
    }

    private enum Failure: Error {
        case reason(String)
        var code: String { if case let .reason(value) = self { return value }; return "panel_cache_failed" }
    }

    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.panel-cache", qos: .utility)
    /// 复用同一个 session：每次下载新建一个会漏连接池，也不利于统一取消。
    /// 下载会话。
    ///
    /// 用 `.default` 而不是 `.ephemeral`：`.default` 的连接复用（keep-alive）才是关键——
    /// ephemeral 不给磁盘缓存也不复用连接池里的 TLS session，每个请求都要重新握手
    /// （GitHub Pages 是 HTTPS，握手本身就 2~3 个 RTT）。11 个资源并发下载时这点开销最明显。
    /// pipelining 自 iOS 13 起被系统忽略，保留这行只是历史遗留，不会再带来并行收益。
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
    /// 在途的 dataTask，按自增 id 存。完成/失败会立刻摘掉：之前只 append 不删，
    /// 数组会跟着重试次数无界增长（重试最多的资源会留下十几份已完成的 task）。
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var nextTaskID = 0
    /// 串行锁：同时保护 `tasks`、`cachedCurrent`、`committing`。
    /// 这三份状态会被主线程（scheme handler 取目录）和下载队列同时读写。
    private let lock = NSLock()
    /// 解析过的 `current` 目录。PanelSchemeHandler.start 在主线程上对每个子资源
    /// 调用 `snapshotDirectory()`，每次都做 createDirectory + setResourceValues
    /// 会白白拖慢首屏渲染，所以首次解析后缓存下来。
    private var cachedCurrent: URL?
    /// 提交窗口期：`current` 已改名成 `.old-*`、staging 还没换上。
    /// 这段时间里 `snapshotDirectory()` 必须停掉自愈，否则它会把 `.old-*` 抢回
    /// `current`，紧接着的 `staging -> current` 就因为「目标已存在」而失败。
    private var committing = false
    /// 提交窗口期内暂时对外提供的那份备份。窗口只有两次 rename 的时长，
    /// 但这期间网页的子资源请求不该 404，指向备份目录是零成本且正确的。
    private var pendingBackup: URL?
    private var generation = 0
    private var cancelled = false
    /// 本次初始化正在用的 staging 目录。取消/失败时显式删除：
    /// 被取消的 dataTask 回调会因 generation 变化被丢弃，没人会再来清理它。
    private var stagingDirectory: URL?
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
    ///
    /// 快路径只做一次 fileExists，慢路径才真的解析目录（首次调用、或快照被外部清掉）。
    /// 这里的 self-heal 见 `resolveCurrent`。
    func snapshotDirectory() -> URL? {
        lock.lock()
        let cached = cachedCurrent
        lock.unlock()
        if let cached = cached,
           FileManager.default.fileExists(atPath: cached.appendingPathComponent("index.html").path) {
            return cached
        }
        return resolveCurrent()
    }

    /// 解析 `current` 目录，必要时先自愈，结果写回缓存。内部加锁，调用方不必持锁。
    @discardableResult
    private func resolveCurrent(root: URL? = nil) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        // 提交窗口期内 current 是故意缺失的，既不能自愈也不能返回旧缓存
        // （旧缓存路径此时不存在）；有条件时改指备份目录，让子资源请求不至于 404。
        if committing {
            let fallback = pendingBackup
            cachedCurrent = nil
            guard let fallback = fallback,
                  FileManager.default.fileExists(
                    atPath: fallback.appendingPathComponent("index.html").path) else { return nil }
            return fallback
        }
        let rootURL: URL
        if let root = root {
            rootURL = root
        } else if let computed = try? rootDirectory() {
            rootURL = computed
        } else {
            cachedCurrent = nil
            return nil
        }
        let current = rootURL.appendingPathComponent("current", isDirectory: true)
        let index = current.appendingPathComponent("index.html", isDirectory: false)
        var available = FileManager.default.fileExists(atPath: index.path)
        if !available {
            // 提交窗口期被杀会留下「没有 current、有 .old-*」：把最近修改的那份改回
            // current，否则用户明明有完整快照，却会被当成首次安装要求重新下载。
            if let restored = Self.restoreLatestBackup(root: rootURL, current: current) {
                IOSDiagnostics.shared.log("panelCache: 从 \(restored.lastPathComponent) 恢复 current")
                available = FileManager.default.fileExists(atPath: index.path)
            }
        }
        cachedCurrent = available ? current : nil
        return cachedCurrent
    }

    /// 把 `current` 改回最近修改的 `.old-*`。只有 current 整个缺失时才调用。
    private static func restoreLatestBackup(root: URL, current: URL) -> URL? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else {
            return nil
        }
        let backups = entries.filter { $0.lastPathComponent.hasPrefix(".old-") }
        guard !backups.isEmpty else { return nil }
        // 同时存在多份时只有最后一次提交是完整的，按修改时间取最新的。
        // 注意 `try?` 的括号位置：不加括号会得到 `Date??`，`<` 不接受 Optional。
        let latest = backups.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left < right
        }
        guard let latest = latest, (try? manager.moveItem(at: latest, to: current)) != nil else {
            return nil
        }
        return latest
    }

    /// 清掉上次被杀/取消留下的半成品目录。只在 initialize 开头调用（有界）：
    /// 正常提交后 `.staging-*` 与 `.old-*` 都会被删掉，不清的话反复「初始化 -> 取消」
    /// 会让每份 3.5MB 起的半成品在沙盒里无限堆积。
    /// 注意不能用 `.skipsHiddenFiles`——这些目录名都以点开头。
    private func removeLeftovers(in root: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".staging-") || name.hasPrefix(".old-") else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    /// 读当前快照记录的构建号（`version.json` 的 build）。用于握手与更新提示。
    func snapshotBuild() -> String {
        guard let directory = snapshotDirectory() else { return "" }
        return Self.readBuild(from: directory)
    }

    private static func readBuild(from directory: URL) -> String {
        let file = directory.appendingPathComponent("version.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let build = object["build"] as? String else { return "" }
        return build
    }

    // MARK: - 元数据

    private static let metaFileName = "panel-meta.json"

    /// 读 `panel-meta.json`。缺失（旧版本留下的快照）或损坏都返回 nil。
    /// 只读本地文件，不发网络请求——是否该刷新由调用方决定。
    func snapshotMeta() -> SnapshotMeta? {
        guard let root = try? rootDirectory() else { return nil }
        return Self.readMeta(root: root)
    }

    /// 快照过期、换线、升级 IPA 或缺少元数据时都要重新下载。
    /// 这里只做判定；初始化与欢迎页共用同一规则，避免发现过期后又因「有缓存」早退。
    func needsRefresh(maxAgeHours: Int = 24) -> Bool {
        guard let meta = snapshotMeta() else { return true }
        return Self.needsRefresh(meta: meta, maxAgeHours: maxAgeHours)
    }

    private static var shellBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    private static func needsRefresh(meta: SnapshotMeta, maxAgeHours: Int = 24) -> Bool {
        IOSPanelCachePolicy.needsRefresh(downloadedAt: meta.downloadedAt, line: meta.line,
                                        shellBuild: meta.shellBuild, currentLine: IOSPanelLine.current.rawValue,
                                        currentShellBuild: shellBuild, now: Date().timeIntervalSince1970,
                                        maxAgeHours: maxAgeHours)
    }

    private static func readMeta(root: URL) -> SnapshotMeta? {
        let file = root.appendingPathComponent(metaFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var meta = SnapshotMeta()
        meta.build = object["build"] as? String ?? ""
        meta.line = object["line"] as? String ?? ""
        meta.shellBuild = object["shellBuild"] as? String ?? ""
        if let number = object["downloadedAt"] as? NSNumber {
            meta.downloadedAt = number.int64Value
        }
        return meta
    }

    /// 写元数据。失败不算致命（下轮 needsRefresh 会再判一次），所以不抛错。
    private static func writeMeta(root: URL, build: String, line: String) {
        let object: [String: Any] = [
            "build": build,
            "line": line,
            "shellBuild": shellBuild,
            // 毫秒：秒级精度在「刚下载完就判过期」的边界上容易误判。
            "downloadedAt": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let file = root.appendingPathComponent(metaFileName, isDirectory: false)
        try? data.write(to: file, options: [.atomic])
    }

    // MARK: - 状态

    func snapshot() -> State {
        queue.sync { state }
    }

    // MARK: - 初始化

    /// 下载并替换快照。`force` 表示「忽略已有快照、必须重新下载」。
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
            self.state = State(phase: .preparing, resourceCount: Self.resources.count)
            self.emit(ticket, completion)

            do {
                let root = try self.rootDirectory()
                // 先自愈再清扫：被杀在两次改名之间时，唯一完整的快照正躺在 `.old-*` 里，
                // 顺序反了会把用户仅有的可用快照当垃圾删掉。
                _ = self.resolveCurrent(root: root)
                self.removeLeftovers(in: root)

                let meta = Self.readMeta(root: root)
                // 线路变了就整批当「必需重下」，不交付混源快照。
                let lineChanged = meta != nil && meta?.line != IOSPanelLine.current.rawValue
                let refreshNeeded = meta.map { Self.needsRefresh(meta: $0) } ?? true
                if !force, !refreshNeeded, self.snapshotDirectory() != nil {
                    self.state.phase = .ready
                    self.state.build = self.snapshotBuild()
                    self.state.error = ""
                    self.emit(ticket, completion)
                    return
                }
                IOSDiagnostics.shared.log("panelCache: 下载快照 force=\(force) refresh=\(refreshNeeded) oldBuild=\(meta?.build ?? "unknown") shellBuild=\(Self.shellBuild) line=\(IOSPanelLine.current.rawValue)")

                let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                                     .posixPermissions: 0o700])
                self.stagingDirectory = staging
                self.downloadAll(into: staging, ticket: ticket, strict: lineChanged) { [weak self] result in
                    guard let self = self else { return }
                    self.queue.async {
                        guard self.generation == ticket else { return }
                        switch result {
                        case let .failure(error):
                            try? FileManager.default.removeItem(at: staging)
                            self.stagingDirectory = nil
                            self.state.phase = .error
                            self.state.error = (error as? Failure)?.code ?? "panel_cache_failed"
                            self.emit(ticket, completion)
                        case .success:
                            self.commit(staging: staging, root: root, ticket: ticket, completion: completion)
                        }
                    }
                }
            } catch {
                // 建 staging 或读目录就失败：把可能已经建出来的 staging 一并清掉。
                if let staging = self.stagingDirectory {
                    try? FileManager.default.removeItem(at: staging)
                    self.stagingDirectory = nil
                }
                self.state.phase = .error
                self.state.error = (error as? Failure)?.code ?? "panel_cache_failed"
                self.emit(ticket, completion)
            }
        }
    }

    /// 把 staging 换成 current。两步改名是原子的：先把 current 让到 `.old-<UUID>`，
    /// 再把 staging 改名成 current，最后删掉备份。任一步失败都尝试把备份改回去，
    /// 保证「要么是新的完整快照，要么还是原来那份」。
    private func commit(staging: URL, root: URL, ticket: Int,
                        completion: @escaping (State) -> Void) {
        let manager = FileManager.default
        let current = root.appendingPathComponent("current", isDirectory: true)
        let backup = root.appendingPathComponent(".old-" + UUID().uuidString, isDirectory: true)
        let hadOld = manager.fileExists(atPath: current.path)

        lock.lock()
        committing = true
        pendingBackup = hadOld ? backup : nil
        lock.unlock()
        defer {
            lock.lock()
            committing = false
            pendingBackup = nil
            lock.unlock()
        }

        if hadOld {
            do {
                try manager.moveItem(at: current, to: backup)
            } catch {
                // 连旧快照都让不开（沙盒异常），保持现状并报错，别硬写。
                try? manager.removeItem(at: staging)
                stagingDirectory = nil
                state.phase = .error
                state.error = "panel_commit_failed"
                emit(ticket, completion)
                return
            }
        }
        do {
            try manager.moveItem(at: staging, to: current)
            if hadOld { try? manager.removeItem(at: backup) }
            stagingDirectory = nil
            let build = Self.readBuild(from: current)
            // 提交成功才写 meta：失败时留着旧的 downloadedAt 反而更诚实
            // （needsRefresh 会把它判成过期并重试）。
            Self.writeMeta(root: root, build: build, line: IOSPanelLine.current.rawValue)
            lock.lock()
            cachedCurrent = current
            lock.unlock()
            state.phase = .ready
            state.build = build
            state.error = ""
            IOSDiagnostics.shared.log("panelCache: 快照提交成功 build=\(build) shellBuild=\(Self.shellBuild)")
        } catch {
            if hadOld { try? manager.moveItem(at: backup, to: current) }
            try? manager.removeItem(at: staging)
            stagingDirectory = nil
            state.phase = .error
            state.error = "panel_commit_failed"
            lock.lock()
            cachedCurrent = hadOld ? current : nil
            lock.unlock()
        }
        emit(ticket, completion)
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
                self.state = State(phase: .ready, build: self.snapshotBuild())
            } else {
                self.state = State()
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
            let pending = Array(self.tasks.values)
            self.tasks.removeAll()
            self.lock.unlock()
            // 同 failBatch：先放锁再 cancel，避免和 download/forget 抢同一把锁。
            for job in pending { job.cancel() }
            // 半成品必须当场删：被取消的回调会因为 generation 变化被丢弃，不会有人再来收尾。
            if let staging = self.stagingDirectory {
                try? FileManager.default.removeItem(at: staging)
                self.stagingDirectory = nil
            }
            self.state = self.snapshotDirectory() != nil
                ? State(phase: .ready, build: self.snapshotBuild())
                : State()
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
    /// 而且进度条只在每个文件完成时跳一次，中途看起来像卡死。现在：
    ///   - 同时最多 `maxConcurrent` 个请求（太多会被 CDN 限速，4 是常见甜点）
    ///   - 每个字节都回调进度（节流到 100ms，避免刷爆主线程）
    ///   - total 用响应头 Content-Length 累加，进度条按真实比例走
    private static let maxConcurrent = 4
    private static let progressInterval: TimeInterval = 0.1
    /// 单个资源失败后最多重试次数。移动网络抖动很常见，
    /// 一次失败就整批 abort 会让用户卡在「N-1/N」不动。
    private static let maxRetriesPerResource = 2

    /// 单个资源的下载状态。用显式状态机而不是一个共享游标：
    /// 旧实现失败时把 `nextIndex` 退回去重试，同一资源可能被两个并发位同时领取，
    /// `completedFiles` 于是超过 `resourceCount`（真机见过 13/11、15/11）。
    private enum ItemStatus {
        case pending
        case inflight
        case done
        /// 必需资源失败：整批已放弃，这里只是留个准确的状态。
        case failed
        /// 可选资源失败：记日志后跳过，快照仍然提交。
        case skipped
    }

    /// 并发下载的共享状态。用引用类型而不是闭包捕获 var：
    /// Swift 6 不允许在异步闭包里改捕获的可变局部变量。
    private final class Batch {
        let ticket: Int
        /// 线路变了时整批当必需：可选资源失败也阻断提交，避免产出混源快照。
        let strict: Bool
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var lastEmit: TimeInterval = 0
        var inFlight = 0
        var finished = false
        /// 每个下标已计入 total 的字节数（HEAD 与下载实测取大值）。
        /// 单独记一份是为了 HEAD 给 1.02MB、实际解压后 3.56MB 时能就地修正，而不是再累加一遍。
        var accountedBytes: [Int: Int64] = [:]
        /// 每个下标实际收到的字节数（取大值）。重试会再回调一次全量字节，
        /// 直接 `doneBytes += received` 会让 done 翻倍。
        var receivedBytes: [Int: Int64] = [:]
        /// 已完成（落盘成功或被跳过）的文件数。进度条以它为主，字节数为辅——
        /// 字节数依赖 Content-Length，CDN 压缩/缺头时不可靠。
        var completedFiles = 0
        /// 每个资源已尝试次数，用于单文件重试。
        var attempts: [Int: Int] = [:]
        /// 每个资源的状态；`completedFiles` 的自增以它为准（`.done` 只置一次）。
        var status: [ItemStatus]
        /// 待领取的下标队列（FIFO）。重试的下标重新入队，不覆盖任何游标。
        var queue: [Int]
        /// 可选资源失败后被跳过的路径，透出到 State。
        var skipped: [String] = []
        let completion: (Result<Void, Error>) -> Void

        init(ticket: Int, count: Int, strict: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
            self.ticket = ticket
            self.strict = strict
            self.status = Array(repeating: .pending, count: count)
            self.queue = Array(0..<count)
            self.completion = completion
        }

        /// 把一个下标的真实字节数记进 total。只增不减，取历史最大值：
        /// 同一下标可能先由 HEAD 报一个值、下载时再报一个（压缩头不一致时会差 3 倍）。
        func account(index: Int, bytes: Int64) {
            guard bytes > 0 else { return }
            let previous = accountedBytes[index] ?? 0
            guard bytes > previous else { return }
            accountedBytes[index] = bytes
            totalBytes += bytes - previous
        }

        /// 记录已收到的字节，只按增量累加 `doneBytes`，重试不会重复计数。
        func receive(index: Int, bytes: Int64) {
            let previous = receivedBytes[index] ?? 0
            guard bytes > previous else { return }
            receivedBytes[index] = bytes
            doneBytes += bytes - previous
        }

        /// 放弃某个下标（可选资源失败）：把它已计入的字节从 total/done 里撤掉。
        /// 不撤的话 total 会永远比实际能收到的多，进度条末尾停在 e.g. 3.4/3.6MB。
        func drop(index: Int) {
            if let accounted = accountedBytes.removeValue(forKey: index) { totalBytes -= accounted }
            if let received = receivedBytes.removeValue(forKey: index) { doneBytes -= received }
        }
    }

    private func downloadAll(into staging: URL, ticket: Int, strict: Bool,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        let base = IOSPanelLine.baseURL()
        let batch = Batch(ticket: ticket, count: Self.resources.count, strict: strict, completion: completion)
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
            // 只把真正从 HEAD 拿到长度的下标计入 total。HEAD 失败或被服务端压缩时
            // 长度是错的（index.html 3.56MB -> 1.02MB），混进来会让进度条倒挂成
            // 「已下载 3.9MB / 1.2MB」。拿不到的项等下载时按实测补（见 startDownload）。
            for (index, size) in sizes.enumerated() {
                guard let size = size else { continue }
                batch.account(index: index, bytes: size)
            }
            self.state.total = batch.totalBytes
            self.emitState(ticket)
            // 起 maxConcurrent 个并发位，每个位下完一个就立刻领下一个。
            self.pullNext(base: base, staging: staging, batch: batch)
        }
    }

    /// 用并行 HEAD 拿每个资源的真实大小，没拿到的位置是 nil。
    ///
    /// **必须禁用压缩**：GitHub Pages 对 html/js/json 会回 gzip，HEAD 的
    /// Content-Length 是压缩后的长度（index.html 3.56MB -> 1.02MB），
    /// 而 URLSession 下载时给的是解压后的字节。两者混用会让进度条算错
    /// （真机实测卡在 90%）。
    /// 这里显式 `Accept-Encoding: identity` 拿原始大小；拿不到就留 nil，
    /// 由下载时的实测字节兜底。
    private func probeSizes(base: URL, ticket: Int,
                            completion: @escaping ([Int64?]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var sizes = [Int64?](repeating: nil, count: Self.resources.count)
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

    /// 补满并发位：从 `pending` 队列里领下一个资源开始下载；队列空了在途也归零时收尾。
    private func pullNext(base: URL, staging: URL, batch: Batch) {
        guard generation == batch.ticket, !cancelled, !batch.finished else { return }
        while !batch.finished, batch.inFlight < Self.maxConcurrent, !batch.queue.isEmpty {
            let index = batch.queue.removeFirst()
            // 防御：队列里不应出现非 pending 的下标（重试入队前会先置回 pending）。
            guard batch.status[index] == .pending else { continue }
            let name = Self.resources[index]
            guard let url = URL(string: name, relativeTo: base) else {
                // URL 组不出来是清单/基址配置问题，重试也是一样的结果，直接判死。
                // 不走进 registerFailure 的重试分支：那条路会把它重新入队，
                // 而下面的 while 会立刻再领到它，重试次数用完之后才退出，白转两圈。
                batch.status[index] = .failed
                failBatch(batch, Failure.reason("panel_resource_url_invalid"))
                return
            }
            batch.status[index] = .inflight
            batch.inFlight += 1
            startDownload(index: index, name: name, url: url, base: base,
                          staging: staging, batch: batch)
        }
        if batch.inFlight == 0, batch.queue.isEmpty, !batch.finished {
            finishBatch(batch)
        }
    }

    private func startDownload(index: Int, name: String, url: URL, base: URL,
                              staging: URL, batch: Batch) {
        download(url,
                 onProgress: { [weak self] received, expected in
                     guard let self = self else { return }
                     self.queue.async {
                         guard self.generation == batch.ticket else { return }
                         // 预探没拿到大小的资源（HEAD 失败/无 Content-Length），
                         // 下载时用实测字节补进 total；HEAD 值偏小（压缩）时也会被就地抬高。
                         batch.account(index: index, bytes: expected > 0 ? expected : received)
                         batch.receive(index: index, bytes: received)
                         self.state.total = batch.totalBytes
                         self.state.done = batch.doneBytes
                         self.throttledEmit(batch)
                     }
                 },
                 completion: { [weak self] result in
                     guard let self = self else { return }
                     self.queue.async {
                         guard self.generation == batch.ticket, !batch.finished else { return }
                         batch.inFlight -= 1
                         switch result {
                         case let .success(data):
                             let destination = staging.appendingPathComponent(name, isDirectory: false)
                             do {
                                 try FileManager.default.createDirectory(
                                     at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
                                 try data.write(to: destination, options: [.atomic])
                                 // 幂等：同一个下标只计一次完成数，进度不会超过 100%。
                                 if batch.status[index] != .done {
                                     batch.status[index] = .done
                                     batch.completedFiles += 1
                                     self.state.completedFiles = batch.completedFiles
                                 }
                                 self.emitState(batch.ticket)
                             } catch {
                                 self.registerFailure(index: index, name: name,
                                                      error: Failure.reason("panel_write_failed"), batch: batch)
                             }
                         case let .failure(error):
                             self.registerFailure(index: index, name: name, error: error, batch: batch)
                         }
                         self.pullNext(base: base, staging: staging, batch: batch)
                     }
                 })
    }

    /// 统一处理单资源失败：先重试，重试用完再按必需/可选分级。
    /// `pending` 的下标会重新入队（FIFO），同一资源同一时刻只可能有一个下载在跑。
    private func registerFailure(index: Int, name: String, error: Error, batch: Batch) {
        guard batch.status[index] != .done else { return }
        let code = (error as? Failure)?.code ?? "panel_cache_failed"
        let attempts = (batch.attempts[index] ?? 0) + 1
        batch.attempts[index] = attempts

        // 取消不是网络抖动，重试没有意义，直接放弃整批。
        if code != "panel_cache_cancelled", attempts <= Self.maxRetriesPerResource {
            IOSDiagnostics.shared.log("panelCache: \(name) 第 \(attempts) 次失败（\(code)），重新排队")
            batch.status[index] = .pending
            batch.queue.append(index)
            return
        }
        if batch.strict || Self.isRequired(name) {
            batch.status[index] = .failed
            failBatch(batch, error)
            return
        }
        // 可选资源：记日志、跳过、继续整批。计入 completedFiles，
        // 否则进度条会停在一个永远到不了的分子上。
        IOSDiagnostics.shared.log("panelCache: \(name) 放弃下载（\(code)），按可选资源跳过")
        batch.status[index] = .skipped
        batch.skipped.append(name)
        batch.drop(index: index)
        batch.completedFiles += 1
        state.completedFiles = batch.completedFiles
        state.skipped = batch.skipped
        state.total = batch.totalBytes
        state.done = batch.doneBytes
        emitState(batch.ticket)
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
        // 最后一道闸：必需资源必须真的落盘。正常路径失败会直接 failBatch，
        // 万一状态机有漏洞，也不能把缺 index.html 的目录提交成 current。
        for (index, name) in Self.resources.enumerated() where Self.isRequired(name) {
            if batch.status[index] != .done {
                failBatch(batch, Failure.reason("panel_required_missing"))
                return
            }
        }
        batch.finished = true
        batch.completion(.success(()))
    }

    private func failBatch(_ batch: Batch, _ error: Error) {
        guard !batch.finished else { return }
        batch.finished = true
        // 整批已经注定失败，剩下的在途请求继续跑只是白烧流量。
        // 这里不碰 status：它们的回调会因为 batch.finished 提前 return。
        lock.lock()
        let pending = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        // 先放锁再 cancel：cancel 会同步触发 URLSession 的清理回调，
        // 而那个回调要拿同一把锁（见 download/forget），持锁调用会自锁。
        for job in pending { job.cancel() }
        batch.completion(.failure(error))
    }

    /// 单文件下载。进度粒度是「整个文件」——`URLSession.dataTask` 的
    /// completion 只在全部收完时回调，拿不到中途字节数。
    /// 要做真正的字节级进度得改用 `URLSessionDataDelegate` 的 didReceive(data:)，
    /// 那需要把整个 session 换成 delegate 模式；10 个文件（1 大 9 小）时
    /// 「每文件一次回调」已经够用，不值得为此重构。
    /// `onProgress` 的第二个参数是 Content-Length（未知时为 0）。
    private func download(_ url: URL,
                          onProgress: @escaping (Int64, Int64) -> Void,
                          completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let taskID: Int
        lock.lock()
        nextTaskID += 1
        taskID = nextTaskID
        lock.unlock()
        let job = Self.session.dataTask(with: request) { [weak self] data, response, error in
            // 请求一结束就从表里摘掉：否则重试期间同一资源会留下多份已完成的 task，
            // cancel 时白 cancel 一遍，内存也只增不减。
            self?.forget(taskID)
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
        tasks[taskID] = job
        lock.unlock()
        job.resume()
    }

    private func forget(_ taskID: Int) {
        lock.lock()
        tasks.removeValue(forKey: taskID)
        lock.unlock()
    }
}
