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
    static let resources: [String] = [
        "index.html",
        "mock.json",
        "version.json",
        "manifest.webmanifest",
        "sw.js",
        "icons/icon-192.png",
        "icons/icon-512.png",
        "icons/apple-touch-icon.png"
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
        var resourceIndex: Int = 0
        var resourceCount: Int = IOSPanelCache.resources.count
        var error: String = ""
        var build: String = ""
        var busy: Bool { phase == .preparing || phase == .downloading }
        var ready: Bool { phase == .ready }
    }

    private enum Failure: Error {
        case reason(String)
        var code: String { if case let .reason(value) = self { return value }; return "panel_cache_failed" }
    }

    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.panel-cache", qos: .utility)
    private var state = State()
    private var task: URLSessionDownloadTask?
    private var generation = 0
    private var cancelled = false

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
            self.task?.cancel()
            self.task = nil
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

    private func downloadAll(into staging: URL, ticket: Int,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        let base = IOSPanelLine.baseURL()
        var index = 0
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var failed: Error?

        func step() {
            guard !cancelled, generation == ticket else {
                completion(.failure(Failure.reason("panel_cache_cancelled")))
                return
            }
            guard failed == nil else {
                completion(.failure(failed!))
                return
            }
            guard index < Self.resources.count else {
                completion(.success(()))
                return
            }
            let name = Self.resources[index]
            guard let url = URL(string: name, relativeTo: base) else {
                failed = Failure.reason("panel_resource_url_invalid")
                step()
                return
            }
            state.phase = .downloading
            state.resourceIndex = index + 1
            state.resourceCount = Self.resources.count

            download(url) { result in
                queue.async {
                    switch result {
                    case let .failure(error):
                        failed = error
                        step()
                    case let .success(data):
                        let destination = staging.appendingPathComponent(name, isDirectory: false)
                        do {
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true)
                            try data.write(to: destination, options: [.atomic])
                            totalBytes += Int64(data.count)
                            doneBytes += Int64(data.count)
                            state.total = totalBytes
                            state.done = doneBytes
                            index += 1
                            step()
                        } catch {
                            failed = Failure.reason("panel_write_failed")
                            step()
                        }
                    }
                }
            }
        }
        step()
    }

    private func download(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let session = URLSession(configuration: .ephemeral)
        let job = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
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
            completion(.success(data))
        }
        task = job
        job.resume()
    }
}
