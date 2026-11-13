import UIKit

// 更新状态与账号无关；按线路缓存真实回执，网页和欢迎页共用同一份检查结果。
@MainActor
final class IOSUpdateCenter {
    static let shared = IOSUpdateCenter()
    private struct AppRequest {
        let id = UUID()
        let task: Task<IOSRelease, Error>
    }
    private struct PanelRequest {
        let id = UUID()
        let revision: UInt64
        let task: Task<String, Error>
    }
    private var releases: [IOSPanelLine: IOSRelease] = [:]
    private var appStates: [IOSPanelLine: [String: Any]] = [:]
    private var panelStates: [IOSPanelLine: [String: Any]] = [:]
    private var appRequests: [IOSPanelLine: AppRequest] = [:]
    private var panelRequests: [IOSPanelLine: PanelRequest] = [:]
    private var appCheckedAt: [IOSPanelLine: TimeInterval] = [:]
    private var panelCheckedAt: [IOSPanelLine: TimeInterval] = [:]
    private var panelRevisions: [IOSPanelLine: UInt64] = [:]
    private static let automaticInterval: TimeInterval = 30 * 60

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    func status() -> [String: Any] {
        let line = IOSPanelLine.current
        return ["ok": true, "line": line.rawValue,
                "app": appStates[line] ?? ["state": "idle"],
                "panel": panelStates[line] ?? ["state": "idle"]]
    }

    func checkApp(line: IOSPanelLine, force: Bool = true) async throws -> IOSRelease {
        if !force, let at = appCheckedAt[line], ProcessInfo.processInfo.systemUptime - at < Self.automaticInterval {
            if let release = releases[line] { return release }
            if appStates[line]?["state"] as? String == "error" { throw UpdateError.http }
        }
        let request: AppRequest
        if let pending = appRequests[line] { request = pending }
        else {
            appStates[line] = ["state": "checking"]
            appCheckedAt[line] = ProcessInfo.processInfo.systemUptime
            request = AppRequest(task: Task { try await IOSUpdater.latest(line: line) })
            appRequests[line] = request
        }
        do {
            let release = try await request.task.value
            let hasUpdate = try release.isNewer(version: installedVersion, build: installedBuild)
            try release.requireSupportedSystem()
            if appRequests[line]?.id == request.id {
                releases[line] = release
                appStates[line] = ["state": hasUpdate ? "update" : "latest", "hasUpdate": hasUpdate,
                                   "currentName": installedVersion, "currentCode": try IOSRelease.safeBuild(installedBuild),
                                   "latestName": release.version, "latestCode": try IOSRelease.safeBuild(release.build),
                                   "notes": release.notes, "line": line.rawValue]
                appCheckedAt[line] = ProcessInfo.processInfo.systemUptime
                appRequests.removeValue(forKey: line)
            }
            return release
        } catch {
            if appRequests[line]?.id == request.id {
                appRequests.removeValue(forKey: line)
                appStates[line] = ["state": "error", "error": error.localizedDescription]
                releases.removeValue(forKey: line)
            }
            throw error
        }
    }

    func appResult(line: IOSPanelLine) -> [String: Any] {
        var result = appStates[line] ?? ["state": "idle"]
        result["ok"] = result["state"] as? String != "error"
        result["line"] = line.rawValue
        return result
    }

    func checkPanel(current: String, line: IOSPanelLine, force: Bool = true) async throws -> [String: Any] {
        if !force, let at = panelCheckedAt[line], ProcessInfo.processInfo.systemUptime - at < Self.automaticInterval,
           let previous = panelStates[line] {
            if let remote = previous["remote"] as? String { return panelResult(current: current, remote: remote, line: line) }
            if previous["state"] as? String == "error" { throw UpdateError.http }
        }
        let request: PanelRequest
        if let pending = panelRequests[line] { request = pending }
        else {
            panelStates[line] = ["state": "checking"]
            panelCheckedAt[line] = ProcessInfo.processInfo.systemUptime
            request = PanelRequest(revision: panelRevisions[line] ?? 0,
                task: Task { try await IOSUpdater.latestPanelBuild(line: line) })
            panelRequests[line] = request
        }
        do {
            let remote = try await request.task.value
            let result = panelResult(current: current, remote: remote, line: line)
            if panelRequests[line]?.id == request.id, request.revision == (panelRevisions[line] ?? 0) {
                panelStates[line] = panelResult(current: IOSPanelCache.shared.snapshotBuild(), remote: remote, line: line)
                panelCheckedAt[line] = ProcessInfo.processInfo.systemUptime
                panelRequests.removeValue(forKey: line)
            }
            return result
        } catch {
            if panelRequests[line]?.id == request.id, request.revision == (panelRevisions[line] ?? 0) {
                panelRequests.removeValue(forKey: line)
                panelStates[line] = ["state": "error", "error": error.localizedDescription]
            }
            throw error
        }
    }

    private func panelResult(current: String, remote: String, line: IOSPanelLine) -> [String: Any] {
        let hasUpdate = current.isEmpty || remote > current
        return ["ok": true, "state": hasUpdate ? "update" : "latest", "current": current,
                "remote": remote, "hasUpdate": hasUpdate, "line": line.rawValue]
    }

    func panelReady(build: String, line: IOSPanelLine) {
        panelRevisions[line] = (panelRevisions[line] ?? 0) &+ 1
        panelRequests.removeValue(forKey: line)?.task.cancel()
        panelCheckedAt.removeValue(forKey: line)
        panelStates[line] = ["state": "ready", "pending": build, "line": line.rawValue]
    }
}

@MainActor
enum IOSUpdatePresentation {
    static func message(from owner: UIViewController, title: String, text: String) {
        guard owner.isViewLoaded, owner.view.window != nil,
              UIApplication.shared.applicationState == .active, owner.presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.updateDone, style: .default))
        owner.present(alert, animated: true)
    }

    @discardableResult
    static func checkApp(from owner: UIViewController, manual: Bool,
                         completion: @escaping () -> Void = {}) -> Task<Void, Never> {
        let line = IOSPanelLine.current, revision = IOSPanelLine.revision
        return Task { @MainActor [weak owner] in
            defer { completion() }
            do {
                let center = IOSUpdateCenter.shared
                let release = try await center.checkApp(line: line, force: manual)
                guard !Task.isCancelled, let owner = owner, active(owner, line: line, revision: revision) else { return }
                guard try release.isNewer(version: center.installedVersion, build: center.installedBuild) else {
                    if manual {
                        message(from: owner, title: IOSStrings.updateUpToDateTitle,
                                text: String(format: IOSStrings.recoveryUpdateHint, center.installedVersion, center.installedBuild))
                    }
                    return
                }
                guard owner.presentedViewController == nil else { return }
                // 全屏告知页，只有「我知道了」：App 内不提供下载，用户自行从外部获取新版本自签安装。
                let notice = UpdateNoticeViewController(release: release,
                                                        installedVersion: center.installedVersion,
                                                        installedBuild: center.installedBuild)
                notice.modalTransitionStyle = .coverVertical
                owner.present(notice, animated: true)
            } catch {
                guard manual, !Task.isCancelled, let owner = owner, active(owner, line: line, revision: revision) else { return }
                message(from: owner, title: IOSStrings.updateCheckFailedTitle, text: error.localizedDescription)
            }
        }
    }

    @discardableResult
    static func checkPanel(from owner: UIViewController, onUpdate: @escaping () -> Void,
                           completion: @escaping () -> Void = {}) -> Task<Void, Never> {
        let line = IOSPanelLine.current, revision = IOSPanelLine.revision
        let current = IOSPanelCache.shared.snapshotBuild()
        return Task { @MainActor [weak owner] in
            defer { completion() }
            do {
                let result = try await IOSUpdateCenter.shared.checkPanel(current: current, line: line)
                guard !Task.isCancelled, let owner = owner, active(owner, line: line, revision: revision), owner.presentedViewController == nil else { return }
                if result["hasUpdate"] as? Bool == true {
                    let remote = result["remote"] as? String ?? ""
                    let alert = UIAlertController(title: IOSStrings.updatePanelTitle,
                        message: String(format: IOSStrings.updatePanelAvailable, current, remote), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: IOSStrings.updateLater, style: .cancel))
                    alert.addAction(UIAlertAction(title: IOSStrings.updatePanelApply, style: .default) { [weak owner] _ in
                        guard let owner = owner, active(owner, line: line, revision: revision) else { return }
                        onUpdate()
                    })
                    owner.present(alert, animated: true)
                } else {
                    message(from: owner, title: IOSStrings.updateUpToDateTitle,
                            text: String(format: IOSStrings.updatePanelLatest, current))
                }
            } catch {
                guard !Task.isCancelled, let owner = owner, active(owner, line: line, revision: revision) else { return }
                message(from: owner, title: IOSStrings.updateCheckFailedTitle, text: error.localizedDescription)
            }
        }
    }

    static func active(_ owner: UIViewController, line: IOSPanelLine, revision: UInt64) -> Bool {
        owner.isViewLoaded && owner.view.window != nil && IOSPanelLine.current == line
            && IOSPanelLine.revision == revision && UIApplication.shared.applicationState == .active
    }
}

// 这里只接受固定动作和已检查的版本；网页不能提供下载 URL 或本机路径。
final class IOSUpdateService: IOSBridgeCancellableService {
    let methods = ["app.recovery", "update.status", "update.check", "panel.check", "panel.update"]
    private final class Job {
        let id = UUID()
        let method: String
        let args: [Any]
        let generation: UInt64
        let line: IOSPanelLine
        let lineRevision: UInt64
        let reply: (Any?, String?) -> Void
        var task: Task<Void, Never>?
        init(method: String, args: [Any], generation: UInt64, line: IOSPanelLine, reply: @escaping (Any?, String?) -> Void) {
            self.method = method; self.args = args; self.generation = generation; self.line = line
            self.lineRevision = IOSPanelLine.revision; self.reply = reply
        }
    }
    private let welcome: () -> Bool
    private let restart: () -> Void
    private var generation: UInt64 = 0
    private var jobs: [UUID: Job] = [:]

    init(welcome: @escaping () -> Bool, restart: @escaping () -> Void) {
        self.welcome = welcome; self.restart = restart
    }

    func navigationChanged() {
        precondition(Thread.isMainThread)
        generation &+= 1
        for job in Array(jobs.values) { finish(job, failure: "stale_navigation") }
    }
    func applicationBackgrounded() {
        precondition(Thread.isMainThread)
        generation &+= 1
        for job in Array(jobs.values) { finish(job, failure: "foreground_required") }
    }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        for job in Array(jobs.values) where job.method == method && NSArray(array: job.args).isEqual(to: args) {
            finish(job, failure: "operation_cancelled")
        }
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count <= 1, args.isEmpty || args.first is [String: Any] else { reply(failure("invalid_args"), nil); return }
        let options = args.first as? [String: Any] ?? [:], line = IOSPanelLine.current
        guard UIApplication.shared.applicationState == .active else { reply(failure("foreground_required"), nil); return }
        switch method {
        case "app.recovery":
            guard options.isEmpty else { reply(failure("invalid_args"), nil); return }
            guard welcome() else { reply(failure("recovery_unavailable"), nil); return }
            reply(["ok": true], nil)
        case "update.status":
            guard options.isEmpty else { reply(failure("invalid_args"), nil); return }
            begin(method: method, args: args, line: line, reply: reply) { IOSUpdateCenter.shared.status() }
        case "update.check":
            guard options.isEmpty else { reply(failure("invalid_args"), nil); return }
            begin(method: method, args: args, line: line, reply: reply) {
                _ = try await IOSUpdateCenter.shared.checkApp(line: line)
                return IOSUpdateCenter.shared.appResult(line: line)
            }
        case "panel.check":
            guard Set(options.keys).isSubset(of: ["current"]),
                  let current = options["current"] as? String, current.utf8.count <= 32 else {
                reply(failure("invalid_args"), nil); return
            }
            begin(method: method, args: args, line: line, reply: reply) {
                try await IOSUpdateCenter.shared.checkPanel(current: current, line: line)
            }
        case "panel.update":
            guard Set(options.keys) == ["line"], options["line"] as? String == line.rawValue,
                  !jobs.values.contains(where: { $0.method == "panel.update" }),
                  !IOSPanelCache.shared.snapshot().busy else { reply(failure("panel_update_busy"), nil); return }
            let job = Job(method: method, args: args, generation: generation, line: line, reply: reply)
            jobs[job.id] = job
            IOSPanelCache.shared.initialize(force: true) { [weak self, weak job] state in
                guard let self = self, let job = job, self.jobs[job.id] === job else { return }
                guard self.current(job) else { self.finish(job, failure: "update_line_changed"); return }
                guard !state.busy else { return }
                if !state.ready { self.finish(job, failure: state.error.isEmpty ? "panel_update_failed" : state.error); return }
                Task { @MainActor in IOSUpdateCenter.shared.panelReady(build: state.build, line: line) }
                self.finish(job, value: ["ok": true, "build": state.build, "line": line.rawValue])
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == job.generation, IOSPanelLine.current == line else { return }
                    self.restart()
                }
            }
        default: reply(failure("unsupported_method"), nil)
        }
    }

    private func begin(method: String, args: [Any], line: IOSPanelLine, reply: @escaping (Any?, String?) -> Void,
                       operation: @escaping @MainActor () async throws -> [String: Any]) {
        let job = Job(method: method, args: args, generation: generation, line: line, reply: reply)
        jobs[job.id] = job
        job.task = Task { @MainActor [weak self, weak job] in
            guard let self = self, let job = job else { return }
            do {
                let value = try await operation()
                guard self.current(job) else { self.finish(job, failure: "update_line_changed"); return }
                self.finish(job, value: value)
            } catch {
                guard self.current(job) else { self.finish(job, failure: "update_line_changed"); return }
                if let failure = error as? IOSBridgePolicy.Failure { self.finish(job, failure: failure.code) }
                else { self.finish(job, value: ["ok": false, "error": ["code": "update_failed", "message": error.localizedDescription]]) }
            }
        }
    }

    private func current(_ job: Job) -> Bool {
        jobs[job.id] === job && job.generation == generation && job.line == IOSPanelLine.current
            && job.lineRevision == IOSPanelLine.revision && UIApplication.shared.applicationState == .active
    }
    private func finish(_ job: Job, value: [String: Any]? = nil, failure code: String? = nil) {
        guard jobs.removeValue(forKey: job.id) === job else { return }
        job.task?.cancel(); job.task = nil
        if code != nil, job.method == "panel.update" { IOSPanelCache.shared.cancel { _ in } }
        job.reply(value ?? failure(code ?? "update_failed"), nil)
    }
    private func failure(_ code: String) -> [String: Any] { IOSBridgePolicy.failure(method: "update", code: code) }
}
