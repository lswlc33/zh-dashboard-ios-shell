import Foundation
import CoreFoundation
import UIKit
import WebKit
import AVFoundation
import UserNotifications
import Photos
import ImageIO
import UniformTypeIdentifiers

// WK 桥在调用前验证当前文档、主框架和来源；此服务不接受网页自报的 origin 或 gesture。
// 所有敏感 RPC 再经过原生按钮确认，避免可信页面中的脚本在启动时悄悄读取或授权。
//
// 当前已实现、但网页还没有调用方的方法（保留给后续接线，删掉会让新页面无法启用能力）：
// - app.appearance：网页还没有切换原生深浅色的入口（只有 test.py 的源码合同检查提到它）。
// - clipboard.read / clipboard.write：网页统一走 navigator.clipboard / WK 的粘贴链路。
// - photos.save：网页导出图片目前走 file.share，没有直接存照片的按钮。
// - notifications.status / request / schedule / cancel：网页只把 notifications.request
//   写进 ios-bridge.js 的超时白名单，没有真正发起本地提醒。
// - media.permission：网页没有调用 getUserMedia，因此也不会走到这里的相机/麦克风授权
//   （media.capture 只是 WebKit 回调的入口，同样没有调用方）。
final class IOSSystemService: NSObject, IOSBridgeCancellableService, IOSBridgeMediaService,
                              IOSBridgeBackgroundHandoffService, UIDocumentPickerDelegate,
                              UIAdaptivePresentationControllerDelegate,
                              UNUserNotificationCenterDelegate {
    typealias Reply = (Any?, String?) -> Void

    static let maxFileBytes = 20 * 1024 * 1024
    static let maxClipboardBytes = 1024 * 1024
    private static let maxEncodedBytes = ((maxFileBytes + 2) / 3) * 4
    private static let notificationPrefix = "dashboard.local."
    private static let notificationNamespace = "dashboard.system.local.v1"
    private static let notificationBusinessKey = "dashboardBusinessID"
    private static let notificationNamespaceKey = "dashboardNamespace"
    private static let photoMimes = ["image/png", "image/jpeg", "image/heic"]
    /// app.diag 的落盘频率闸门：1 秒最多一条、每会话最多 200 条。
    ///
    /// 诊断日志是用户可见的单一文件（512KB），一旦被页面刷满就会 truncate 到 0，
    /// 真正的启动日志会被冲掉；所以超限只计数、不再写盘。
    private static let diagMinimumInterval: TimeInterval = 1
    private static let diagSessionLimit = 200

    let methods = [
        "file.share", "file.save", "clipboard.write", "clipboard.read",
        "app.info", "app.appearance", "app.settings", "app.diag", "notifications.status", "notifications.request",
        "notifications.schedule", "notifications.cancel", "media.permission", "photos.save"
    ]

    // 调用方使用 { [weak controller] in controller }，不让服务强持有页面。
    private let controller: () -> UIViewController?
    private let fileQueue = DispatchQueue(label: "dashboard.ios.system.files", qos: .utility)
    private var generation: UInt64 = 0
    private var jobs: [UUID: Job] = [:]
    private var interactiveJob: Job?
    /// app.diag 的会话内计数（只留内存，不落盘）。
    private var diagLogged = 0
    private var diagSuppressed = 0
    private var diagLastLog = -Double.infinity

    private final class Job {
        let id = UUID()
        let method: String
        /// 入参在确认后会被清掉（见 `releaseFileArguments`），所以是可选的。
        var arguments: NSArray?
        /// 清掉入参后用于匹配取消/后台接管的轻量指纹（name|mime|bytes）。
        var argumentFingerprint: String?
        let generation: UInt64
        var reply: Reply?
        var presentation: UIViewController?
        var file: PreparedFile?
        // OS 已接受写入/导出后不能撤销；取消回执明确说明可能完成，绝不伪称成功。
        var submitted = false
        var permissionSubmitted = false
        var notificationID: String?

        init(method: String, arguments: [Any], generation: UInt64, reply: @escaping Reply) {
            self.method = method
            self.arguments = NSArray(array: arguments)
            // 指纹在 begin 时就算好：确认后入参会被丢掉，取消/后台接管只能靠它匹配。
            self.argumentFingerprint = IOSSystemService.fileFingerprint(arguments)
            self.generation = generation
            self.reply = reply
        }
    }

    private struct FileInput {
        let name: String
        let mime: String
        let bodyB64: String
    }

    // 结算 RPC 与系统读源文件的生命周期分开：导航/超时不能删掉系统正在使用的图片。
    private final class TemporaryFileLease {
        let directory: URL
        private let lock = NSLock()
        private var released = false

        init(directory: URL) { self.directory = directory }

        func release() {
            lock.lock()
            let shouldRemove = !released
            released = true
            lock.unlock()
            guard shouldRemove else { return }
            let directory = directory
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: directory) }
        }

        deinit { release() }
    }

    // delegate 是弱引用，系统控制器自己持有源文件 lease，RPC 超时也不会提前释放。
    private final class ExportPicker: UIDocumentPickerViewController {
        var fileLease: TemporaryFileLease?
    }

    private struct PreparedFile {
        let url: URL
        let lease: TemporaryFileLease
        let name: String
        let mime: String
        let bytes: Int
    }

    private struct NotificationInput {
        let id: String
        let title: String
        let body: String
        let delay: TimeInterval?
        let date: Date?
        let sound: Bool
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    init(controller: @escaping () -> UIViewController?) {
        self.controller = controller
        super.init()
        // iOS 对「App 在前台时到达的本地通知」默认不呈现任何 UI，只有实现
        // UNUserNotificationCenterDelegate.willPresent 才会出横幅。这里在服务初始化时
        // 装一次 delegate（主线程，系统要求）。
        //
        // delegate 是 weak 属性：只要 IOSSystemService 活着（它由 IOSBridge.services 强持有，
        // Bridge 又由 PanelController 强持有），delegate 就不会掉；不要改成临时对象。
        if Thread.isMainThread { installNotificationDelegate() }
        else { DispatchQueue.main.async { [weak self] in self?.installNotificationDelegate() } }
    }

    private func installNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 前台到达时主动展示。`.banner` / `.list` 保证「网页排了提醒、App 正在前台」也能看到。
    ///
    /// `.sound` 无法在 willPresent 里按单条请求取回（通知内容已交付到这里，但读
    /// `input.sound` 需要跨对象保存状态，收益很小），固定带上；系统仍会尊重用户的静音与
    /// 通知设置，静音键/专注模式下不会响。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func handle(method: String, args: [Any], reply: @escaping Reply) {
        onMain {
            do {
                guard self.methods.contains(method) else { throw Failure(IOSStrings.unsupportedMethod) }
                let options = try Self.options(args)
                switch method {
                case "app.info":
                    guard options.isEmpty else { throw Failure(IOSStrings.invalidArguments) }
                    reply(self.appInfo(), nil)
                case "app.diag":
                    // 网页把自己的错误写进原生日志文件：白屏时用户导出这份文件即可。
                    // 只接受一条短文本，不做任何解析，也没有副作用。
                    guard Set(options.keys) == ["message"],
                          let message = options["message"] as? String,
                          message.utf8.count <= 4096 else {
                        throw Failure(IOSStrings.invalidArguments)
                    }
                    // 限流：1 秒最多一条 + 每会话 200 条。日志文件 512KB 一到就 truncate 到 0，
                    // 页面若在循环里报错会把真正的启动日志整段冲掉，反而更难排查。
                    let now = ProcessInfo.processInfo.systemUptime
                    guard self.diagLogged < Self.diagSessionLimit,
                          now - self.diagLastLog >= Self.diagMinimumInterval else {
                        self.diagSuppressed += 1
                        reply(["status": "throttled", "logged": self.diagLogged,
                               "suppressed": self.diagSuppressed], nil)
                        return
                    }
                    self.diagLogged += 1
                    self.diagLastLog = now
                    IOSDiagnostics.shared.log("web: " + message)
                    reply(["status": "logged", "logged": self.diagLogged,
                           "suppressed": self.diagSuppressed], nil)
                case "app.appearance":
                    // 只接受 {dark: Bool}：网页切深浅色时同步状态栏与系统控件明暗。
                    // 不申请权限、不弹确认框——它只改本 App 的外观，没有副作用。
                    guard Set(options.keys).isSubset(of: ["dark"]),
                          let raw = options["dark"] as? NSNumber,
                          CFGetTypeID(raw) == CFBooleanGetTypeID() else {
                        throw Failure(IOSStrings.invalidArguments)
                    }
                    let isDark = raw.boolValue
                    let style: UIUserInterfaceStyle = isDark ? .dark : .light
                    // 本 App 没有 UIApplicationSceneManifest，走经典 AppDelegate 手建 UIWindow，
                    // 所以 connectedScenes 是空集。必须回落到 windows / delegate.window，
                    // 否则这里是一片空操作却回执 applied（网页会以为已经改成功）。
                    let changed = self.applyAppearance(style)
                    if changed > 0 {
                        reply(["status": "applied", "dark": isDark, "windows": changed], nil)
                    } else {
                        // 窗口还没建好或已释放：明确告诉网页没生效，而不是伪报成功。
                        reply(["status": "unavailable", "dark": isDark, "windows": 0,
                               "reason": "no_key_window"], nil)
                    }
                case "notifications.status":
                    guard options.isEmpty else { throw Failure(IOSStrings.invalidArguments) }
                    let job = try self.begin(method: method, args: args, interactive: false, reply: reply)
                    UNUserNotificationCenter.current().getNotificationSettings { [weak self, weak job] settings in
                        self?.onMain {
                            guard let job = job, self?.current(job) == true else { return }
                            self?.finish(job, value: Self.notificationStatus(settings))
                        }
                    }
                case "media.permission":
                    let media = try Self.mediaTypes(options)
                    let requested = try Self.optionalBoolean(options, key: "request", fallback: false)
                    if !requested {
                        reply(Self.mediaStatus(media), nil)
                    } else {
                        let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                        self.confirmMedia(job, types: media)
                    }
                case "file.share", "file.save", "photos.save":
                    let input = try Self.fileInput(options)
                    if method == "photos.save" && !Self.photoMimes.contains(input.mime) {
                        throw Failure(IOSStrings.photoFormat)
                    }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    let title = method == "file.share" ? IOSStrings.shareTitle
                        : method == "file.save" ? IOSStrings.saveTitle : IOSStrings.photoTitle
                    let message = method == "file.share" ? IOSStrings.shareMessage(name: input.name)
                        : method == "file.save" ? IOSStrings.saveMessage(name: input.name)
                        : IOSStrings.photoMessage(name: input.name)
                    let button = method == "file.share" ? IOSStrings.share
                        : method == "file.save" ? IOSStrings.saveFile : IOSStrings.savePhoto
                    self.confirm(job, title: title, message: message, button: button) { [weak self, weak job] in
                        guard let self = self, let job = job else { return }
                        // 用户一确认就把原始入参（含最大 28MiB 的 Base64 文本）从 Job 上摘掉，
                        // 只留 name/mime/bytes 指纹。内存预算：文件上限 20MiB 原始字节，
                        // Base64 膨胀到约 27MiB，Swift String + NSArray 各留一份拷贝会翻倍；
                        // 解码出的 Data 又要 20MiB，同时持有会把峰值推到 ~70MiB，
                        // 在 3GB 机型上容易被系统杀掉。摘掉后峰值只剩 Data + 临时文件。
                        self.releaseFileArguments(job)
                        self.prepareFile(input, job: job, validatePhoto: method == "photos.save")
                    }
                case "clipboard.write":
                    guard Set(options.keys).isSubset(of: ["text"]), let text = options["text"] as? String else {
                        throw Failure(IOSStrings.invalidArguments)
                    }
                    guard text.utf8.count <= Self.maxClipboardBytes else { throw Failure(IOSStrings.clipboardTooLarge) }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.confirm(job, title: IOSStrings.clipboardWriteTitle, message: IOSStrings.clipboardWriteMessage,
                                 button: IOSStrings.copy) { [weak self, weak job] in
                        guard let self = self, let job = job, self.mayContinue(job) else { return }
                        // localOnly 禁止通用剪贴板把可能含凭据的文字同步到其他设备。
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
                        self.finish(job, value: ["status": "written", "bytes": text.utf8.count])
                    }
                case "clipboard.read":
                    guard options.isEmpty else { throw Failure(IOSStrings.invalidArguments) }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.confirm(job, title: IOSStrings.clipboardReadTitle, message: IOSStrings.clipboardReadMessage,
                                 button: IOSStrings.paste) { [weak self, weak job] in
                        guard let self = self, let job = job, self.mayContinue(job) else { return }
                        // 唯一读剪贴板的位置：原生确认按钮之后；不轮询、不探测内容、不记日志。
                        let text = UIPasteboard.general.string ?? ""
                        guard self.mayContinue(job) else { return }
                        guard text.utf8.count <= Self.maxClipboardBytes else {
                            self.finish(job, value: nil, error: IOSStrings.clipboardTooLarge); return
                        }
                        self.finish(job, value: ["status": text.isEmpty ? "empty" : "read", "text": text])
                    }
                case "app.settings":
                    guard options.isEmpty else { throw Failure(IOSStrings.invalidArguments) }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.confirm(job, title: IOSStrings.settingsTitle, message: IOSStrings.settingsMessage,
                                 button: IOSStrings.openSettings) { [weak self, weak job] in
                        guard let self = self, let job = job, self.mayContinue(job),
                              let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        job.submitted = true
                        UIApplication.shared.open(url, options: [:]) { [weak self, weak job] opened in
                            self?.onMain {
                                guard let job = job, self?.current(job) == true else { return }
                                self?.finish(job, value: opened ? ["status": "opened"] : nil,
                                             error: opened ? nil : IOSStrings.settingsFailed)
                            }
                        }
                    }
                case "notifications.request":
                    guard options.isEmpty else { throw Failure(IOSStrings.invalidArguments) }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.requestNotifications(job)
                case "notifications.schedule":
                    let input = try Self.notificationInput(options)
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.confirm(job, title: IOSStrings.scheduleTitle,
                                 message: IOSStrings.scheduleMessage(title: input.title, body: input.body),
                                 button: IOSStrings.schedule) { [weak self, weak job] in
                        guard let self = self, let job = job, self.mayContinue(job) else { return }
                        self.scheduleNotification(input, job: job)
                    }
                case "notifications.cancel":
                    guard Set(options.keys).isSubset(of: ["ids"]), let ids = options["ids"] as? [String],
                          !ids.isEmpty, ids.count <= 64, Set(ids).count == ids.count,
                          ids.allSatisfy(Self.validNotificationID) else { throw Failure(IOSStrings.invalidArguments) }
                    let job = try self.begin(method: method, args: args, interactive: true, reply: reply)
                    self.confirm(job, title: IOSStrings.cancelNotificationsTitle,
                                 message: IOSStrings.cancelNotificationsMessage(count: ids.count),
                                 button: IOSStrings.removeNotifications) { [weak self, weak job] in
                        guard let self = self, let job = job, self.mayContinue(job) else { return }
                        self.cancelNotifications(ids, job: job)
                    }
                default:
                    throw Failure(IOSStrings.unsupportedMethod)
                }
            } catch {
                reply(nil, (error as? Failure)?.message ?? IOSStrings.operationFailed)
            }
        }
    }

    // 核心必须先验证 WKSecurityOrigin、当前主框架和导航世代，再调用此 helper。
    // 单靠授权过的 SDK 状态不能 grant：每次 capture 仍需当前页面的原生确认按钮。
    func requestMediaCapture(type: WKMediaCaptureType, reply: @escaping (WKPermissionDecision) -> Void) {
        onMain {
            let types: [AVMediaType]
            switch type {
            case .camera: types = [.video]
            case .microphone: types = [.audio]
            case .cameraAndMicrophone: types = [.video, .audio]
            @unknown default: reply(.deny); return
            }
            do {
                let args: [Any] = [["kind": Self.mediaKind(types)]]
                let job = try self.begin(method: "media.capture", args: args, interactive: true) { value, error in
                    let status = (value as? [String: Any])?["status"] as? String
                    reply(error == nil && status == "authorized" ? .grant : .deny)
                }
                self.confirmMedia(job, types: types)
            } catch { reply(.deny) }
        }
    }

    func cancel(method: String, args: [Any]) {
        onMain {
            // Bridge 的 deadline 只撤销本服务内、method/args 完全匹配的任务。
            // media.capture 是 WK helper 而非公开 RPC，不能被网页 cancel 冒名撤销。
            let matching = self.jobs.values.filter { $0.method == method && self.matches($0, args: args) }
            for job in matching { self.cancelJob(job, reason: "timeout") }
        }
    }

    func canFinishInBackground(method: String, args: [Any]) -> Bool {
        guard Thread.isMainThread else { return false }
        let handedOff = Set(["file.share", "file.save", "app.settings", "photos.save"])
        guard handedOff.contains(method) else { return false }
        return jobs.values.contains {
            current($0) && $0.method == method && matches($0, args: args) && $0.submitted
        }
    }

    /// 任务入参匹配。文件类任务在确认后会丢掉 bodyB64（见 `releaseFileArguments`），
    /// 这时只能用确认前记下的轻量指纹比对，不能因为内存优化让取消/后台接管失效。
    private func matches(_ job: Job, args: [Any]) -> Bool {
        if let arguments = job.arguments { return arguments.isEqual(to: args) }
        guard let fingerprint = job.argumentFingerprint else { return false }
        return Self.fileFingerprint(args) == fingerprint
    }

    /// 文件类入参的轻量指纹：name + mime + Base64 长度。只用于匹配同一次调用，
    /// 不参与任何安全判断（真正的校验在 fileInput 里）。
    fileprivate static func fileFingerprint(_ args: [Any]) -> String? {
        guard args.count == 1, let options = args[0] as? [String: Any],
              let name = options["name"] as? String, let mime = options["mime"] as? String,
              let body = options["bodyB64"] as? String else { return nil }
        return name + "\u{1}" + mime + "\u{1}" + String(body.utf8.count)
    }

    func navigationChanged() {
        onMain { self.invalidate(reason: "navigation_changed") }
    }

    func applicationBackgrounded() {
        onMain {
            // 分享、文件导出与设置本身会让 App 进入后台；已明确提交的系统操作仍等真实完成。
            // 待批准、SDK 授权和需要下一步 UI 的任务才取消，禁止旧权限回调启动新的动作。
            let handedOff = Set(["file.share", "file.save", "app.settings", "photos.save"])
            for job in Array(self.jobs.values) {
                if job.submitted && handedOff.contains(job.method) { continue }
                self.cancelJob(job, reason: "backgrounded")
            }
        }
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private func begin(method: String, args: [Any], interactive: Bool, reply: @escaping Reply) throws -> Job {
        guard jobs.count < 8 else { throw Failure(IOSStrings.busy) }
        if interactive {
            guard interactiveJob == nil else { throw Failure(IOSStrings.busy) }
            _ = try presenter()
        }
        let job = Job(method: method, arguments: args, generation: generation, reply: reply)
        jobs[job.id] = job
        if interactive { interactiveJob = job }
        return job
    }

    private func presenter() throws -> UIViewController {
        guard UIApplication.shared.applicationState == .active else { throw Failure(IOSStrings.foregroundRequired) }
        guard let controller = controller(), controller.isViewLoaded, controller.view.window != nil else {
            throw Failure(IOSStrings.unavailable)
        }
        guard controller.presentedViewController == nil, !controller.isBeingDismissed, !controller.isBeingPresented else {
            throw Failure(IOSStrings.busy)
        }
        return controller
    }

    private func current(_ job: Job) -> Bool {
        jobs[job.id] === job && job.generation == generation && job.reply != nil
    }

    private func mayContinue(_ job: Job) -> Bool {
        guard current(job) else { return false }
        guard UIApplication.shared.applicationState == .active, let owner = controller(),
              owner.isViewLoaded, owner.view.window != nil else {
            cancelJob(job, reason: "backgrounded"); return false
        }
        return true
    }

    private func finish(_ job: Job, value: Any?, error: String? = nil, dismiss: Bool = false) {
        guard jobs[job.id] === job, let reply = job.reply else { return }
        // 先清空回调再 dismiss/reply，系统的重复 cancel/dismiss 回调也不会二次回复。
        job.reply = nil
        jobs.removeValue(forKey: job.id)
        if interactiveJob === job { interactiveJob = nil }
        let presentation = job.presentation
        job.presentation = nil
        if dismiss, presentation?.presentingViewController != nil { presentation?.dismiss(animated: false) }
        // 尚未交给 OS 的文件立即清理；已提交操作的独立 completion/delegate 持有资源 lease。
        job.file = nil
        reply(value, error)
    }

    private func cancelJob(_ job: Job, reason: String) {
        if let id = job.notificationID {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
        finish(job, value: ["status": "canceled", "reason": reason,
                            "operationMayComplete": job.submitted,
                            "permissionMayChange": job.permissionSubmitted], dismiss: true)
    }

    private func invalidate(reason: String) {
        generation &+= 1
        for job in Array(jobs.values) { cancelJob(job, reason: reason) }
    }

    private func confirm(_ job: Job, title: String, message: String, button: String,
                         action: @escaping () -> Void) {
        guard mayContinue(job) else { return }
        do {
            let owner = try presenter()
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { [weak self, weak job] _ in
                guard let job = job else { return }
                self?.cancelJob(job, reason: "user")
            })
            alert.addAction(UIAlertAction(title: button, style: .default) { [weak self, weak job, weak alert] _ in
                guard let self = self, let job = job, self.mayContinue(job) else { return }
                alert?.dismiss(animated: true) { [weak self, weak job] in
                    guard let self = self, let job = job, self.mayContinue(job) else { return }
                    job.presentation = nil
                    action()
                }
            })
            job.presentation = alert
            owner.present(alert, animated: true)
            alert.presentationController?.delegate = self
        } catch { finish(job, value: nil, error: (error as? Failure)?.message ?? IOSStrings.operationFailed) }
    }

    private static func options(_ args: [Any]) throws -> [String: Any] {
        if args.isEmpty { return [:] }
        guard args.count == 1, let options = args[0] as? [String: Any], options.count <= 12 else {
            throw Failure(IOSStrings.invalidArguments)
        }
        return options
    }

    private static func optionalBoolean(_ options: [String: Any], key: String, fallback: Bool) throws -> Bool {
        guard let value = options[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw Failure(IOSStrings.invalidArguments)
        }
        return number.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            return nil
        }
        return value.doubleValue
    }

    /// 把深浅色写到所有实际存在的窗口，返回改到的窗口数（0 表示没生效）。
    ///
    /// 先走 connectedScenes（将来若切到 Scene 生命周期仍然正确）；本项目用的是经典
    /// AppDelegate + 手建 UIWindow，connectedScenes 恒为空集，所以回落到 delegate.window。
    /// 不去用 `UIApplication.windows`：它在 iOS 15 起被标记弃用，本工程又没有 Scene 可查。
    private func applyAppearance(_ style: UIUserInterfaceStyle) -> Int {
        let app = UIApplication.shared
        var targets = app.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        if targets.isEmpty, let window = (app.delegate as? AppDelegate)?.window { targets = [window] }
        // 同一窗口可能同时出现在两处，去重后统一改，回执里的数量才是真实窗口数。
        var seen = Set<ObjectIdentifier>()
        var changed = 0
        for window in targets {
            guard seen.insert(ObjectIdentifier(window)).inserted else { continue }
            window.overrideUserInterfaceStyle = style
            changed += 1
        }
        return changed
    }

    private func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "status": "ok", "platform": "ios", "shell": "wkwebview",
            "name": info["CFBundleDisplayName"] as? String ?? IOSStrings.appTitle,
            "bundleId": info["CFBundleIdentifier"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "minimumIOS": info["MinimumOSVersion"] as? String ?? "15.4",
            "systemVersion": UIDevice.current.systemVersion, "methods": methods,
            "maxFileBytes": Self.maxFileBytes, "maxClipboardBytes": Self.maxClipboardBytes,
            "photoMimeTypes": Self.photoMimes, "localNotifications": true,
            "backgroundPolling": false, "liveActivities": false, "crossAppMedia": false,
            // 网页用它决定顶栏/底栏留白。WebView 已铺满整屏，env(safe-area-inset-*)
            // 在 WK 里可能给 0，所以必须由原生给出真实点值（pt 与 CSS px 1:1）。
            "safeArea": safeAreaJSON(),
            "panelLine": IOSPanelLine.current.rawValue,
            // 首帧就要能判断「是否已选过线路」，否则网页只能等 panelLineInfo 异步回执。
            "panelLineChosen": IOSPanelLine.chosen
        ]
    }

    /// 当前窗口安全区。
    ///
    /// 视图还没完成首次布局时 `safeAreaInsets` 全是 0——那不是「没有安全区」，
    /// 而是「还不知道」。这时返回空字典，网页看到缺字段会回退到 CSS env()；
    /// 若返回 {top:0,bottom:0}，网页会把 --sat/--sab 写成 0px，
    /// 结果就是进面板后安全区消失（真机反馈）。
    private func safeAreaJSON() -> [String: Any] {
        guard let view = controller()?.view else { return [:] }
        let insets = view.safeAreaInsets
        // bounds 为 0 说明还没布局；insets 全 0 且窗口有尺寸时才是真的没有安全区。
        guard view.bounds.width > 0, view.bounds.height > 0 else { return [:] }
        return [
            "top": Double(max(0, insets.top)),
            "bottom": Double(max(0, insets.bottom)),
            "left": Double(max(0, insets.left)),
            "right": Double(max(0, insets.right))
        ]
    }

    private static func fileInput(_ options: [String: Any]) throws -> FileInput {
        guard Set(options.keys).isSubset(of: ["name", "mime", "bodyB64"]),
              let rawName = options["name"] as? String, rawName.utf8.count <= 2048,
              let rawMime = options["mime"] as? String, rawMime.utf8.count <= 256,
              let body = options["bodyB64"] as? String else { throw Failure(IOSStrings.invalidArguments) }
        let length = body.utf8.count
        guard length <= maxEncodedBytes else { throw Failure(IOSStrings.fileTooLarge) }
        guard length > 0, length % 4 == 0 else { throw Failure(IOSStrings.invalidFile) }
        let mime = rawMime.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard mime.range(of: "^[a-z0-9][a-z0-9!#$&^_.+-]{0,95}/[a-z0-9][a-z0-9!#$&^_.+-]{0,127}$",
                         options: .regularExpression) != nil else { throw Failure(IOSStrings.invalidFile) }
        return FileInput(name: safeName(rawName, mime: mime), mime: mime, bodyB64: body)
    }

    private static func safeName(_ raw: String, mime: String) -> String {
        // 白名单过滤路径分隔符、控制字符与双向文本控制符；用户不能选择沙盒内任意路径。
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()"))
        let scalars = raw.precomposedStringWithCanonicalMapping.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }
        var name = scalars.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = IOSStrings.defaultExportName }
        while name.utf8.count > 180 { name.removeLast() }
        if let suffix = UTType(mimeType: mime)?.preferredFilenameExtension, mime != "application/octet-stream" {
            let stem = (name as NSString).deletingPathExtension
            name = (stem.isEmpty ? IOSStrings.defaultExportName : stem) + "." + suffix
        } else if (name as NSString).pathExtension.isEmpty { name += ".bin" }
        return name
    }

    /// 确认后丢掉 Job 上保留的原始入参（文件类方法含最大 28MiB 的 Base64）。
    ///
    /// 为什么可以丢：确认按钮之后所有需要的字段已经提取成 `FileInput`（name/mime/bodyB64），
    /// Job 只用于生命周期匹配。指纹在 `begin` 时就记好了，所以取消/后台接管仍能认出同一次调用。
    private func releaseFileArguments(_ job: Job) {
        job.arguments = nil
    }

    private func prepareFile(_ input: FileInput, job: Job, validatePhoto: Bool) {
        guard mayContinue(job) else { return }
        // Base64、图片检查与磁盘写入均在串行 utility 队列，不阻塞 UIKit/WebKit 主线程。
        fileQueue.async { [weak self, job] in
            var createdDirectory: URL?
            let result: Result<PreparedFile, Failure>
            do {
                guard let data = Data(base64Encoded: input.bodyB64), !data.isEmpty else { throw Failure(IOSStrings.invalidFile) }
                guard data.count <= Self.maxFileBytes else { throw Failure(IOSStrings.fileTooLarge) }
                if validatePhoto { try Self.validatePhoto(data, mime: input.mime) }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dashboard-system-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                createdDirectory = directory
                let url = directory.appendingPathComponent(input.name, isDirectory: false)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                result = .success(PreparedFile(url: url, lease: TemporaryFileLease(directory: directory),
                                               name: input.name, mime: input.mime, bytes: data.count))
            } catch {
                if let directory = createdDirectory { try? FileManager.default.removeItem(at: directory) }
                result = .failure((error as? Failure) ?? Failure(IOSStrings.fileWriteFailed))
            }
            DispatchQueue.main.async { [weak self, job] in
                guard let self = self, self.current(job) else {
                    if case .success(let file) = result { file.lease.release() }
                    return
                }
                switch result {
                case .failure(let failure): self.finish(job, value: nil, error: failure.message)
                case .success(let file):
                    job.file = file
                    guard self.mayContinue(job) else { return }
                    if job.method == "file.share" { self.shareFile(file, job: job) }
                    else if job.method == "file.save" { self.saveFile(file, job: job) }
                    else { self.addPhoto(file, job: job) }
                }
            }
        }
    }

    private static func fileReceipt(_ file: PreparedFile, status: String) -> [String: Any] {
        ["status": status, "name": file.name, "mime": file.mime, "bytes": file.bytes]
    }

    private func anchor(_ presentation: UIViewController, to owner: UIViewController) {
        if let popover = presentation.popoverPresentationController {
            popover.sourceView = owner.view
            popover.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }

    private func shareFile(_ file: PreparedFile, job: Job) {
        guard mayContinue(job) else { return }
        do {
            let owner = try presenter()
            let share = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
            share.completionWithItemsHandler = { [weak self, weak job, file] _, completed, _, error in
                // 不依赖 RPC 是否还有效，系统分享结束才释放源文件。
                file.lease.release()
                self?.onMain {
                    guard let self = self, let job = job, self.current(job) else { return }
                    if error != nil { self.finish(job, value: nil, error: IOSStrings.shareFailed) }
                    else if completed { self.finish(job, value: Self.fileReceipt(file, status: "shared")) }
                    else { self.cancelJob(job, reason: "user") }
                }
            }
            anchor(share, to: owner)
            job.presentation = share
            job.submitted = true
            owner.present(share, animated: true)
            share.presentationController?.delegate = self
        } catch { finish(job, value: nil, error: (error as? Failure)?.message ?? IOSStrings.shareFailed) }
    }

    private func saveFile(_ file: PreparedFile, job: Job) {
        guard mayContinue(job) else { return }
        do {
            let owner = try presenter()
            let picker = ExportPicker(forExporting: [file.url], asCopy: true)
            picker.fileLease = file.lease
            picker.delegate = self
            anchor(picker, to: owner)
            job.presentation = picker
            job.submitted = true
            owner.present(picker, animated: true)
            picker.presentationController?.delegate = self
        } catch { finish(job, value: nil, error: (error as? Failure)?.message ?? IOSStrings.saveFailed) }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        (controller as? ExportPicker)?.fileLease?.release()
        (controller as? ExportPicker)?.fileLease = nil
        onMain {
            guard let job = self.interactiveJob, self.current(job), job.presentation === controller,
                  let file = job.file else { return }
            guard urls.count == 1 else { self.finish(job, value: nil, error: IOSStrings.saveFailed); return }
            // 导出 delegate 是系统完成回执；不枚举目标目录，也不返回用户选择的私人路径。
            self.finish(job, value: Self.fileReceipt(file, status: "saved"))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        (controller as? ExportPicker)?.fileLease?.release()
        (controller as? ExportPicker)?.fileLease = nil
        onMain {
            guard let job = self.interactiveJob, job.presentation === controller else { return }
            self.cancelJob(job, reason: "user")
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker = presentationController.presentedViewController as? ExportPicker {
            picker.fileLease?.release()
            picker.fileLease = nil
        }
        onMain {
            guard let job = self.interactiveJob, job.presentation === presentationController.presentedViewController else { return }
            self.cancelJob(job, reason: "user")
        }
    }

    private static func validatePhoto(_ data: Data, mime: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) else { throw Failure(IOSStrings.photoFormat) }
        let expected = mime == "image/png" ? UTType.png.identifier
            : mime == "image/jpeg" ? UTType.jpeg.identifier : UTType.heic.identifier
        guard type as String == expected,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw Failure(IOSStrings.photoFormat) }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 24_000_000 else { throw Failure(IOSStrings.photoDimensions) }
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary) != nil else { throw Failure(IOSStrings.photoFormat) }
    }

    private func addPhoto(_ file: PreparedFile, job: Job) {
        guard mayContinue(job) else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            job.permissionSubmitted = true
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self, weak job] _ in
                self?.onMain {
                    guard let self = self, let job = job, self.mayContinue(job) else { return }
                    self.addPhoto(file, job: job)
                }
            }
            return
        }
        guard status == .authorized || status == .limited else {
            finish(job, value: ["status": "denied", "permission": "photos.addOnly", "message": IOSStrings.photoPermissionDenied]); return
        }
        job.submitted = true
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.name
            request.addResource(with: .photo, fileURL: file.url, options: options)
        } completionHandler: { [weak self, weak job, file] saved, error in
            // 系统还在读 fileURL 时 RPC 可以失效，但资源要等 performChanges 结束才能删除。
            file.lease.release()
            self?.onMain {
                guard let self = self, let job = job, self.current(job) else { return }
                guard !saved else {
                    self.finish(job, value: Self.fileReceipt(file, status: "saved")); return
                }
                // 权限撤销、磁盘满、格式不支持原来都吃同一句文案；这里按 PHPhotosError 的
                // domain/code 拆成 permission 与 io 两类，并把错误码写进诊断日志
                // （只写 domain/code，不写文件路径或文件名）。
                let failure = Self.photoSaveFailure(error)
                IOSDiagnostics.shared.log("photos.save 失败 domain=\(failure.domain) code=\(failure.code) kind=\(failure.reason)")
                self.finish(job, value: ["status": "failed", "reason": failure.reason,
                                         "photosCode": failure.code, "message": failure.message])
            }
        }
    }

    /// 把 Photos 的写入失败归类。权限类错误让用户去设置里改；其余都算 io（空间/格式/中断）。
    ///
    /// 判据以 `PHPhotosError` 的 domain/code 为主（这两个码 iOS 15 起就有，deployment
    /// target 15.4 可以直接引用）：`accessRestricted` / `accessUserDenied` 是权限；
    /// 其余（notEnoughSpace / invalidResource / operationInterrupted …）是 io。
    /// 再补一层授权状态复查，兜住「写入失败但错误码只报 generic」时权限其实已被撤销的情况。
    private static func photoSaveFailure(_ error: Error?) -> (domain: String, code: Int, reason: String, message: String) {
        let ns = error as NSError?
        let domain = ns?.domain ?? "unknown"
        let code = ns?.code ?? 0
        let permissionCodes: Set<Int> = [PHPhotosError.Code.accessRestricted.rawValue,
                                         PHPhotosError.Code.accessUserDenied.rawValue]
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let deniedNow = status == .denied || status == .restricted
        let isPermission = (domain == PHPhotosErrorDomain && permissionCodes.contains(code))
            || (domain == PHPhotosErrorDomain && deniedNow)
        return (domain, code, isPermission ? "permission" : "io",
                isPermission ? IOSStrings.photoPermissionDenied : IOSStrings.photoSaveFailed)
    }

    private static func mediaTypes(_ options: [String: Any]) throws -> [AVMediaType] {
        guard Set(options.keys).isSubset(of: ["kind", "request"]), let kind = options["kind"] as? String else {
            throw Failure(IOSStrings.invalidArguments)
        }
        if kind == "camera" { return [.video] }
        if kind == "audio" { return [.audio] }
        throw Failure(IOSStrings.invalidArguments)
    }

    private static func mediaKind(_ types: [AVMediaType]) -> String {
        types.count == 2 ? "cameraAndAudio" : types.first == .video ? "camera" : "audio"
    }

    private static func mediaStatus(_ types: [AVMediaType]) -> [String: Any] {
        var permissions: [String: String] = [:]
        for type in types {
            let name: String
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: name = "authorized"
            case .denied: name = "denied"
            case .restricted: name = "restricted"
            case .notDetermined: name = "notDetermined"
            @unknown default: name = "unknown"
            }
            permissions[type == .video ? "camera" : "audio"] = name
        }
        let granted = types.allSatisfy { AVCaptureDevice.authorizationStatus(for: $0) == .authorized }
        let requestable = types.contains { AVCaptureDevice.authorizationStatus(for: $0) == .notDetermined }
        return ["status": granted ? "authorized" : requestable ? "notDetermined" : "denied",
                "kind": mediaKind(types), "granted": granted, "canRequest": requestable, "permissions": permissions]
    }

    private func confirmMedia(_ job: Job, types: [AVMediaType]) {
        let title = types.count == 2 ? IOSStrings.cameraAndMicrophoneTitle
            : types.first == .video ? IOSStrings.cameraTitle : IOSStrings.microphoneTitle
        let message = types.count == 2 ? IOSStrings.cameraAndMicrophoneMessage
            : types.first == .video ? IOSStrings.cameraMessage : IOSStrings.microphoneMessage
        confirm(job, title: title, message: message, button: IOSStrings.allow) { [weak self, weak job] in
            guard let self = self, let job = job, self.mayContinue(job) else { return }
            self.authorizeMedia(types, index: 0, job: job)
        }
    }

    private func authorizeMedia(_ types: [AVMediaType], index: Int, job: Job) {
        guard mayContinue(job) else { return }
        guard index < types.count else { finish(job, value: Self.mediaStatus(types)); return }
        let type = types[index]
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: authorizeMedia(types, index: index + 1, job: job)
        case .notDetermined:
            job.permissionSubmitted = true
            AVCaptureDevice.requestAccess(for: type) { [weak self, weak job] granted in
                self?.onMain {
                    guard let self = self, let job = job, self.mayContinue(job) else { return }
                    if granted && AVCaptureDevice.authorizationStatus(for: type) == .authorized {
                        self.authorizeMedia(types, index: index + 1, job: job)
                    } else { self.finish(job, value: Self.mediaStatus(types)) }
                }
            }
        default: finish(job, value: Self.mediaStatus(types))
        }
    }

    private static func notificationStatus(_ settings: UNNotificationSettings) -> [String: Any] {
        let status: String
        switch settings.authorizationStatus {
        case .notDetermined: status = "notDetermined"
        case .denied: status = "denied"
        case .authorized: status = "authorized"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        let enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        return ["status": status, "authorizationStatus": status, "enabled": enabled,
                "canRequest": settings.authorizationStatus == .notDetermined,
                "alert": settings.alertSetting == .enabled, "sound": settings.soundSetting == .enabled,
                "localNotifications": true, "backgroundPolling": false, "liveActivities": false,
                "foregroundPresentation": "systemDefault"]
    }

    private func requestNotifications(_ job: Job) {
        guard mayContinue(job) else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self, weak job] settings in
            self?.onMain {
                guard let self = self, let job = job, self.mayContinue(job) else { return }
                guard settings.authorizationStatus == .notDetermined else {
                    self.finish(job, value: Self.notificationStatus(settings)); return
                }
                self.confirm(job, title: IOSStrings.notificationsTitle, message: IOSStrings.notificationsMessage,
                             button: IOSStrings.allow) { [weak self, weak job] in
                    guard let self = self, let job = job, self.mayContinue(job) else { return }
                    job.permissionSubmitted = true
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self, weak job] _, error in
                        self?.onMain {
                            guard let self = self, let job = job, self.mayContinue(job) else { return }
                            if error != nil { self.finish(job, value: nil, error: IOSStrings.notificationRequestFailed) }
                            else { self.readNotificationStatus(job) }
                        }
                    }
                }
            }
        }
    }

    private func readNotificationStatus(_ job: Job) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self, weak job] settings in
            self?.onMain {
                guard let self = self, let job = job, self.current(job) else { return }
                self.finish(job, value: Self.notificationStatus(settings))
            }
        }
    }

    private static func validNotificationID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil
    }

    private static func notificationInput(_ options: [String: Any]) throws -> NotificationInput {
        guard Set(options.keys).isSubset(of: ["id", "title", "body", "delaySeconds", "atMs", "sound"]),
              let id = options["id"] as? String, validNotificationID(id),
              let title = options["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, let body = options["body"] as? String, body.utf8.count <= 4096,
              !(options["delaySeconds"] != nil && options["atMs"] != nil) else { throw Failure(IOSStrings.invalidArguments) }
        let sound = try optionalBoolean(options, key: "sound", fallback: true)
        var date: Date?
        var delay: TimeInterval?
        if let raw = options["atMs"] {
            guard let milliseconds = number(raw) else { throw Failure(IOSStrings.invalidSchedule) }
            date = Date(timeIntervalSince1970: milliseconds / 1000)
            delay = nil
        } else if let raw = options["delaySeconds"] {
            guard let seconds = number(raw) else { throw Failure(IOSStrings.invalidSchedule) }
            delay = seconds
        } else { delay = 1 }
        let interval = date?.timeIntervalSinceNow ?? delay ?? 0
        guard interval >= 1, interval <= 366 * 24 * 60 * 60 else { throw Failure(IOSStrings.invalidSchedule) }
        return NotificationInput(id: id, title: title, body: body, delay: delay, date: date, sound: sound)
    }

    private func scheduleNotification(_ input: NotificationInput, job: Job) {
        guard mayContinue(job) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self, weak job] settings in
            self?.onMain {
                guard let self = self, let job = job, self.mayContinue(job) else { return }
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                        || settings.authorizationStatus == .ephemeral else {
                    // 排提醒不暗中申请授权；用户需明确调用 notifications.request。
                    self.finish(job, value: Self.notificationStatus(settings)); return
                }
                center.getPendingNotificationRequests { [weak self, weak job] pending in
                    self?.onMain {
                        guard let self = self, let job = job, self.mayContinue(job) else { return }
                        let replaced = pending.filter { Self.notificationBusinessID($0) == input.id }.map { $0.identifier }
                        guard pending.count - replaced.count < 64 else {
                            self.finish(job, value: nil, error: IOSStrings.notificationLimit); return
                        }
                        // 系统 ID 每次提交唯一；旧导航的 rollback 不能删掉新导航重排的同名业务提醒。
                        let id = Self.notificationPrefix + UUID().uuidString
                        let interval = input.date?.timeIntervalSinceNow ?? input.delay ?? 0
                        guard interval >= 1, interval <= 366 * 24 * 60 * 60 else {
                            self.finish(job, value: nil, error: IOSStrings.invalidSchedule); return
                        }
                        let content = UNMutableNotificationContent()
                        content.title = input.title
                        content.body = input.body
                        content.threadIdentifier = "dashboard.local"
                        content.userInfo = [Self.notificationNamespaceKey: Self.notificationNamespace,
                                            Self.notificationBusinessKey: input.id]
                        if input.sound { content.sound = .default }
                        let request = UNNotificationRequest(identifier: id, content: content,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
                        let atMs = Date().addingTimeInterval(interval).timeIntervalSince1970 * 1000
                        // 先记下本任务自己的系统 ID（取消/超时靠它精确清理），但 submitted
                        // 只在 add 真的成功后才置位。
                        job.notificationID = id
                        // 顺序很重要：先 add 新的，成功后再删 replaced。
                        // 新请求标识是每次唯一的 UUID，重复排不会互相覆盖，所以反过来才安全；
                        // 若先删旧的再 add，add 失败（权限被撤、磁盘满）就白丢用户原有提醒。
                        center.add(request) { [weak self, job] error in
                            DispatchQueue.main.async { [weak self, job] in
                                if error != nil {
                                    // add 失败：只撤本次新加的 UUID，旧提醒原样保留（用户的不动产）。
                                    center.removePendingNotificationRequests(withIdentifiers: [id])
                                }
                                guard let self = self, self.current(job) else {
                                    // 回执已失效（导航/超时）：新 UUID 已在上面删掉，旧提醒未动。
                                    return
                                }
                                guard error == nil else {
                                    self.finish(job, value: nil, error: IOSStrings.notificationScheduleFailed)
                                    return
                                }
                                job.submitted = true
                                if !replaced.isEmpty { center.removePendingNotificationRequests(withIdentifiers: replaced) }
                                self.finish(job, value: ["status": "scheduled", "id": input.id, "atMs": atMs,
                                                         "repeats": false, "local": true])
                            }
                        }
                    }
                }
            }
        }
    }

    private static func notificationBusinessID(_ request: UNNotificationRequest) -> String? {
        guard request.identifier.hasPrefix(notificationPrefix),
              request.content.userInfo[notificationNamespaceKey] as? String == notificationNamespace,
              let id = request.content.userInfo[notificationBusinessKey] as? String,
              validNotificationID(id) else { return nil }
        return id
    }

    private func cancelNotifications(_ ids: [String], job: Job) {
        let center = UNUserNotificationCenter.current()
        let selected = Set(ids)
        // 只查本服务签名 namespace 的业务 ID；不读系统外的通知，不影响 Ride 的提醒。
        center.getPendingNotificationRequests { [weak self, weak job] pending in
            center.getDeliveredNotifications { [weak self, weak job] delivered in
                self?.onMain {
                    guard let self = self, let job = job, self.mayContinue(job) else { return }
                    let requests = pending + delivered.map { $0.request }
                    let identifiers = Set(requests.filter {
                        guard let id = Self.notificationBusinessID($0) else { return false }
                        return selected.contains(id)
                    }.map { $0.identifier })
                    // 没算到任何 identifier 时什么都没删，不能置 submitted——否则桥会把
                    // 「取消」当成已提交给系统、允许它在后台完成并回执 operationMayComplete。
                    let removed: [String] = identifiers.isEmpty ? [] : Array(identifiers)
                    if !identifiers.isEmpty {
                        job.submitted = true
                        center.removePendingNotificationRequests(withIdentifiers: removed)
                        center.removeDeliveredNotifications(withIdentifiers: removed)
                    }
                    self.verifyNotificationsRemoved(ids, identifiers: removed, job: job, attempts: 0)
                }
            }
        }
    }

    /// 0.15 / 0.4 / 1.0 秒的退避；慢设备上 `getDeliveredNotifications` 可能仍返回旧条目。
    ///
    /// 判据放宽为「pending 已清空」即成功：delivered 列表是系统侧的展示缓存，删除后
    /// 可能延迟消失，继续等下去只会制造误报失败。
    private static let notificationVerifyBackoff: [TimeInterval] = [0.15, 0.4, 1.0]

    private func verifyNotificationsRemoved(_ ids: [String], identifiers: [String], job: Job, attempts: Int) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self, weak job] pending in
            center.getDeliveredNotifications { [weak self, weak job] delivered in
                self?.onMain {
                    guard let self = self, let job = job, self.current(job) else { return }
                    let selected = Set(identifiers)
                    let pendingLeft = pending.contains { selected.contains($0.identifier) }
                    let deliveredLeft = delivered.contains { selected.contains($0.request.identifier) }
                    // pending 清空就成功；delivered 残留只是系统展示缓存延迟，不再等它。
                    if !pendingLeft {
                        self.finish(job, value: ["status": "removed", "ids": ids,
                                                 "deliveredPending": deliveredLeft])
                    } else if attempts < Self.notificationVerifyBackoff.count {
                        let delay = Self.notificationVerifyBackoff[attempts]
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak job] in
                            guard let self = self, let job = job, self.current(job) else { return }
                            self.verifyNotificationsRemoved(ids, identifiers: identifiers, job: job, attempts: attempts + 1)
                        }
                    } else { self.finish(job, value: nil, error: IOSStrings.notificationCancelFailed) }
                }
            }
        }
    }
}
