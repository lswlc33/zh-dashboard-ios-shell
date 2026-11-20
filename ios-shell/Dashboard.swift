import UIKit
import WebKit


@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootRouter()
        window.makeKeyAndVisible()
        self.window = window
        // 临时文件清扫：Caches/native-blob-*、tmp/dashboard-system-*、tmp/native-asset-*
        // 的唯一正常清理入口是「拿到 lease 的那一方主动释放」。复制/下载/分享途中 App 被
        // 系统杀掉（大文件时最容易被 jetsam 选中）就留下整份目录，之后再没有任何代码看到它。
        // IOSNativeFileStreamService.maxFileBytes 是 512MB，几次被杀的复制就能堆出上 GB。
        // 系统虽然可以回收 Caches/tmp，但没有任何上界保证；启动时做一次有界清扫。
        // 放在后台队列，不阻塞首帧。
        DispatchQueue.global(qos: .utility).async { IOSTemporaryFileSweeper.sweepAtLaunch() }
        if let identifiers = launchOptions?[.bluetoothCentrals] as? [String] {
            IOSBluetoothService.shared.restoreIfRequested(identifiers)
        }
        // 后台任务必须在 didFinishLaunching 里注册完，否则系统唤起时找不到 handler
        // （日志只会看到 "No handler registered"，任务被静默丢弃）。
        // 注册本身不发请求、不申请权限：真正的执行等到系统唤醒时才发生。
        if #available(iOS 13.0, *) {
            IOSBackgroundScheduler.shared.register(
                refresh: { completion in IOSBackgroundRunner.runRefresh(completion: completion) })
            // 启动时撤销旧签到/每日任务请求，只申请 refresh 与闲时 processing 单次采样。
            IOSBackgroundScheduler.shared.scheduleAll()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 退后台时重提一次后台采样请求：系统可能在上次执行后没有继续唤醒，
        // 只靠「handler 内 reschedule」会在链条断掉后永久停摆。
        // 这里不承诺执行时间，只是让下一次机会始终处于排队状态。
        if #available(iOS 13.0, *) { IOSBackgroundScheduler.shared.scheduleAll() }
    }
}

// 启动分流：有可用快照且不是刚升级过就直接进面板，否则先走原生欢迎/恢复页。
// 与安卓的 RecoveryActivity 语义一致——冷启动第一帧可以是原生页，而不是网页骨架。
final class RootRouter: UIViewController {
    private var panel: PanelController?
    private var recovery: RecoveryViewController?
    private var routeGeneration = 0
    private var routeInFlight = false
    private var activeToken: NSObjectProtocol?

    deinit {
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // 快捷指令可在后台冷启动进程；先注册恢复通知，再判前台，避免网页 hello 被拒后锁入预览。
        activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.route() }
        IOSPanelLine.applyPersisted()
        route()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        route()
    }

    private func route() {
        guard UIApplication.shared.applicationState == .active,
              panel == nil, recovery == nil, !routeInFlight else { return }
        routeInFlight = true
        routeGeneration &+= 1
        let ticket = routeGeneration
        // unfinished 只是上一进程没来得及记成功（强退/系统回收也会留下），
        // 不是明确失败。有好快照仍直接进；首次/升级欢迎和真实失败不能跳过。
        let reason = BootHealth.pendingReason()
        if !reason.isEmpty && reason != "unfinished" {
            showRecovery(reason: reason)
            return
        }
        IOSPanelCache.shared.refresh { [weak self] state in
            guard let self = self, self.routeGeneration == ticket,
                  self.panel == nil, self.recovery == nil else { return }
            self.routeInFlight = false
            guard UIApplication.shared.applicationState == .active else { return }
            // 预检期间可能记下了明确失败，不能用旧的无错误快照覆盖它。
            let currentReason = BootHealth.pendingReason()
            if !currentReason.isEmpty && currentReason != "unfinished" {
                self.showRecovery(reason: currentReason)
                return
            }
            let needsWelcome = BootHealth.needsWelcome()
            if state.ready && !needsWelcome {
                BootHealth.clear()
                BootHealth.markWelcomeShown()
                self.showPanel()
                // 快照过期（超过 24 小时或换过线路）就后台补一份新的，
                // 下次冷启动生效。这里不能阻塞进面板：用户要的是立刻看到页面。
                // 以前完全没有这个判定，导致面板产物更新后老用户几个月都看不到新页面。
                if IOSPanelCache.shared.needsRefresh() {
                    IOSDiagnostics.shared.log("面板快照已过期，后台刷新")
                    IOSPanelCache.shared.initialize(force: false) { _ in }
                }
            } else {
                BootHealth.markWelcomeShown()
                self.showRecovery(reason: needsWelcome ? "" : currentReason)
            }
        }
    }

    private func showPanel() {
        guard panel == nil, recovery == nil else { return }
        routeGeneration &+= 1
        let ticket = routeGeneration
        let controller = PanelController()
        panel = controller
        // 先接好回调再触发 viewDidLoad；旧控制器的迟到失败不能拆掉新面板。
        controller.onBootFailure = { [weak self, weak controller] reason in
            guard let self = self, let controller = controller, self.routeGeneration == ticket,
                  self.panel === controller else { return }
            self.switchToRecovery(reason: reason)
        }
        controller.onWelcome = { [weak self, weak controller] in
            guard let self = self, let controller = controller, self.routeGeneration == ticket,
                  self.panel === controller else { return }
            self.openWelcome()
        }
        addChild(controller)
        // 用约束而不是 frame：RootRouter 是 window 的 rootViewController，
        // route() 触发时 view.bounds 可能还是 zero，写死 frame 会让子视图永远 0×0，
        // 表现就是「只有 toolbar 可见、所有按钮点不动」。
        controller.loadViewIfNeeded()
        guard panel === controller, routeGeneration == ticket else { return }
        attach(controller.view)
        controller.didMove(toParent: self)
    }

    private func showRecovery(reason: String) {
        guard panel == nil, recovery == nil else { return }
        routeGeneration &+= 1
        let ticket = routeGeneration
        let controller = RecoveryViewController(reason: reason)
        recovery = controller
        controller.onEnter = { [weak self, weak controller] in
            guard let self = self, let controller = controller, self.routeGeneration == ticket,
                  self.recovery === controller else { return }
            self.dismissRecovery()
            BootHealth.clear()
            self.showPanel()
        }
        addChild(controller)
        attach(controller.view)
        controller.didMove(toParent: self)
    }

    /// 子控制器铺满 RootRouter：约束到 view 四边，不依赖当时的 bounds。
    private func attach(_ child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func dismissRecovery() {
        guard let controller = recovery else { return }
        routeGeneration &+= 1
        recovery = nil
        controller.onEnter = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func removePanel() {
        guard let controller = panel else { return }
        routeGeneration &+= 1
        panel = nil
        controller.onBootFailure = nil
        controller.onWelcome = nil
        controller.stopForRecovery()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func openWelcome() {
        guard recovery == nil else { return }
        removePanel()
        BootHealth.clear()
        showRecovery(reason: "")
    }

    private func switchToRecovery(reason: String) {
        removePanel()
        BootHealth.failed(reason: reason)
        if recovery == nil { showRecovery(reason: reason) }
    }

    override var prefersStatusBarHidden: Bool { false }
    override var childForStatusBarStyle: UIViewController? { children.first }
}

// 启动健康状态：等价安卓 BootHealth。
// 明确失败会强制恢复；unfinished 只是未确认成功，有好快照的普通冷启动可忽略。
enum BootHealth {
    private static let defaults = UserDefaults.standard
    private static let reasonKey = "io.github.lswlc33.dashboard.ios.boot.reason"
    private static let welcomeKey = "io.github.lswlc33.dashboard.ios.boot.welcome"
    private static let buildKey = "io.github.lswlc33.dashboard.ios.boot.build"

    /// 首次安装或 App 版本变化后需要看一次欢迎页。
    static func needsWelcome() -> Bool {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return defaults.string(forKey: buildKey) != build
    }

    static func markWelcomeShown() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        defaults.set(build, forKey: buildKey)
    }

    static func pendingReason() -> String {
        defaults.string(forKey: reasonKey) ?? ""
    }

    static func failed(reason: String) {
        defaults.set(reason, forKey: reasonKey)
    }

    static func clear() {
        defaults.removeObject(forKey: reasonKey)
    }
}

final class PanelController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private lazy var web: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // 本地快照走自定义 scheme；没有快照时这个 handler 不会被用到。
        configuration.setURLSchemeHandler(IOSPanelSchemeHandler(rootProvider: { IOSPanelCache.shared.snapshotDirectory() }),
                                          forURLScheme: IOSPanelSchemeHandler.scheme)
        // 允许内联播放（充电动画等视频素材），并让页面能自动播放。
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // 本地快照的持久化：默认用非持久 store 会让 localStorage 每次冷启动清零，
        // 账号 token 就丢了。显式用 default() 保证与线上同源行为。
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // 自定义 scheme 在 WK 里默认不是 secure context，localStorage / crypto.subtle
        // 会抛 SecurityError。注册成「可被当作安全来源」需要私有 API，
        // 这里不碰私有 API；网页的 store.js 已对 localStorage 做了 try/catch，
        // 真跑不通时下面的 fallbackToNetwork 会兜住。
        return view
    }()
    private var bridge: IOSBridge?
    private var updateTask: Task<Void, Never>?
    private var panelCheckTask: Task<Void, Never>?
    private var checkedOnLaunch = false
    private var returningToWelcome = false
    private var lastSafeArea = UIEdgeInsets.zero
    /// 当前这轮是否在用本地快照；失败时用它决定要不要自动回退线上。
    private var usingLocalSnapshot = false
    /// 本轮导航是否已经因本地快照失败回退过一次。
    ///
    /// 必须有这个一次性闸门：`prepareNavigation` 的白名单失败是**同步**回调的，
    /// 调用链是 preparePanel → 同步 .failure → showError → fallbackToNetwork →
    /// preparePanel(home) → 又用同一个坏本地地址 → 再同步失败 …… 全在主线程栈上，
    /// 最终栈溢出闪退。`usingLocalSnapshot = false` 挡不住，因为 preparePanel
    /// 进门就又把它置回 true。回退后必须真的落到 https。
    private var localFallbackUsed = false
    /// 主线程上的启动世代；stopLoading 之前先撤旧票据，取消/迟到回调就不会碰新导航。
    private var startupGeneration = 0
    private var currentNavigation: WKNavigation?
    private var currentNavigationID: String?
    private var navigationTerminal = true
    private var bootWatchTimer: Timer?
    private var bootWatchTick = 0
    private var bootWatchActive = false
    private var bootWatchForegroundElapsed: TimeInterval = 0
    private var bootWatchForegroundStartedAt: TimeInterval?
    /// 暂停/恢复也换票据：后台前发出的 JS 探测不能在回来后误判超时。
    private var bootWatchGeneration = 0
    private var documentFinished = false
    private var foregroundPanelURL: URL?
    /// 白屏诊断页只弹一次，别在每次看门狗探测时都弹。
    private var diagnosticsShown = false
    private var progressToken: NSKeyValueObservation?
    private var updateNotificationTokens: [NSObjectProtocol] = []
    private var lastLoggedProgress = -10

    /// 启动失败回调：交给 RootRouter 切到恢复页。
    var onBootFailure: ((String) -> Void)?
    var onWelcome: (() -> Void)?

    // 完全沉浸：状态栏与 home indicator 都可见，但页面铺到它们下面。
    override var prefersStatusBarHidden: Bool { false }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        web.navigationDelegate = self
        web.uiDelegate = self
        installBridge()
        for name in [UIApplication.didEnterBackgroundNotification, IOSPanelLine.didChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.cancelUpdateChecks()
            }
            updateNotificationTokens.append(token)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pauseBootWatch()
            }
            updateNotificationTokens.append(token)
        }
        let activeToken = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let url = self.foregroundPanelURL {
                self.foregroundPanelURL = nil
                self.preparePanel(url)
            } else { self.resumeBootWatch() }
        }
        updateNotificationTokens.append(activeToken)
        web.allowsBackForwardNavigationGestures = true
        // 页面自己按原生给出的 safeArea 留白，不需要 WebView 再叠一层 inset。
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // 观察加载进度：didFinish 不触发时，至少能知道卡在哪个百分比。
        progressToken = web.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let percent = Int(webView.estimatedProgress * 100)
            // 每 10% 记一次，避免日志被刷满。
            if percent >= self.lastLoggedProgress + 10 {
                self.lastLoggedProgress = percent
                IOSDiagnostics.shared.log("estimatedProgress: \(percent)% url=\(webView.url?.absoluteString ?? "nil")")
            }
        }
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        // 四边贴 view 而不是 safeAreaLayoutGuide：内容延伸到状态栏与 home indicator 下面。
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        loadPanel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLaunchUpdateChecks()
    }

    private func startLaunchUpdateChecks() {
        guard documentFinished, !navigationTerminal, view.window != nil, !checkedOnLaunch, !returningToWelcome else { return }
        checkedOnLaunch = true
        checkUpdate(manual: false)
        checkPanelAutomatically()
    }

    // 安全区变化（旋转、状态栏高度变化）时通知网页重新取值。
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let insets = view.safeAreaInsets
        guard insets != lastSafeArea else { return }
        lastSafeArea = insets
        web.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
    }

    private func installBridge() {
        let ride = IOSRideService()
        let history = IOSHistoryService()
        let bluetooth = IOSBluetoothService.shared
        let system = IOSSystemService(controller: { [weak self] in self })
        let surfaces = IOSSystemSurfacesService()
        let line = IOSPanelLineService()
        let utility = IOSNativeUtilityService()
        let secrets = IOSSecretHandleService()
        let renewal = IOSSessionRenewalService(secrets: secrets)
        let wifi = IOSVehicleNetworkService()
        let tcp = IOSVehicleTCPService(network: wifi)
        let assets = IOSNativeAssetService(network: wifi)
        let blobs = IOSNativeFileStreamService()
        let cast = IOSCastService()
        let widgets = IOSWidgetCompatibilityService(systemSurfaces: surfaces)
        let background = IOSBackgroundService(presenter: { [weak self] in self })
        let compatibility = IOSCompatibilityService(ride: ride, gps: IOSLocationService.shared,
                                                   system: system, widget: widgets, utility: utility)
        let updates = IOSUpdateService(welcome: { [weak self] in self?.requestWelcome() ?? false },
            restart: { [weak self] in self?.restartAfterPanelUpdate() })
        let core = IOSBridge(webView: web, services: [IOSLocationService.shared, bluetooth, ride, history,
                             system, surfaces, line, utility, secrets, renewal, wifi, tcp, assets, blobs, cast, widgets,
                             background, compatibility, updates])
        let scope: () -> IOSRideScope? = { [weak core] in core?.nativeSessionScope() }
        background.configureScopeProvider(scope)
        let presenter: () -> UIViewController? = { [weak self] in self }
        let metadata: () -> [String: Any]? = { [weak core] in core?.nativeSessionMetadata() }
        let navigation: () -> String? = { [weak core] in core?.currentNavigationID() }
        let frame: () -> String? = { [weak core] in core?.currentSessionFrame() }
        utility.configureMetadataProvider(metadata)
        utility.configurePresenter(presenter)
        secrets.configureScopeProvider(scope)
        secrets.configureSessionMetadataProvider(metadata)
        renewal.configureScopeProvider(scope)
        renewal.configureSessionMetadataProvider(metadata)
        renewal.configureRecordingProvider { [weak bluetooth] in bluetooth?.currentRecordingLease() }
        renewal.configureConsentProvider { id, selected, completion in
            guard let current = scope(), current == selected else { completion(false); return {} }
            return utility.requestConsent(title: IOSStrings.backgroundRenewalTitle,
                message: IOSStrings.backgroundRenewalMessage) { approved in
                    completion(approved && scope() == selected)
                } ?? {}
        }
        renewal.configureDidRenew { [weak bluetooth] id, selected, generation, expiry in
            bluetooth?.renewRecordingLease(id: id, scope: selected,
                                           connectionGeneration: generation, expiresUptime: expiry) == true
        }
        renewal.configureAuthorizationExpired { [weak bluetooth] id, selected, generation, reason in
            bluetooth?.invalidateRecordingAuthorization(id: id, scope: selected,
                                                         connectionGeneration: generation, reason: reason)
        }
        renewal.configureMaterialChanged { [weak bluetooth, weak secrets] change, completion in
            guard let bluetooth = bluetooth, let secrets = secrets, scope() == change.scope else {
                completion(nil); return
            }
            bluetooth.reauthenticate(change, secretResolver: { handle in
                // 只在原生执行器短时读取当前录制材料；句柄没有网页导出或磁盘路径。
                try? secrets.withSecret(handle: handle, scope: change.scope,
                                        purpose: .baseline, recordingID: change.recordingID) { Data($0) }
            }, completion: completion)
        }
        bluetooth.configureRenewalProvider(activate: { [weak renewal] in renewal?.activate(recordingId: $0) == true },
            observe: { [weak renewal] id, selected, generation in
                renewal?.observe(recordingId: id, scope: selected, connectionGeneration: generation) == true
            }, ended: { [weak renewal] in renewal?.recordingEnded(recordingId: $0) })
        compatibility.configureMetadataProvider(metadata)
        wifi.setScopeProvider(scope)
        wifi.setMetadataProvider(metadata)
        wifi.setPresenterProvider(presenter)
        tcp.setScopeProvider(scope)
        tcp.setNavigationProvider(navigation)
        tcp.setFrameProvider(frame)
        tcp.setPortConfirmer { selected, navID, address, port, completion in
            guard let current = metadata(), scope() == selected,
                  current["navId"] as? String == navID else { completion(false); return nil }
            return utility.requestConsent(title: IOSStrings.localConnectionTitle,
                message: String(format: IOSStrings.localConnectionMessage, address, Int(port))) { approved in
                guard let refreshed = metadata() else { completion(false); return }
                completion(approved && IOSNativeUtilityService.matches(current, refreshed))
            }
        }
        assets.setScopeProvider(scope)
        assets.setNavigationProvider(navigation)
        assets.setFrameProvider(frame)
        blobs.configureScopeProvider(scope)
        blobs.configureMetadataProvider(metadata)
        blobs.configurePresenter(presenter)
        cast.configureScopeProvider(scope)
        cast.configureMetadataProvider(metadata)
        cast.configurePresenter(presenter)
        bluetooth.configurePipeAuthorizationProvider { input, completion in
            guard let captured = metadata(), let selected = scope(),
                  captured["navId"] as? String == input.navID,
                  captured["frame"] as? String == input.frame, selected.vin == input.vin else {
                completion(.failure(IOSBLEPipeFailure("stale_session"))); return nil
            }
            // 服务不读取网页账号或 token；租约只属于原生已经持久化并确认的车辆。
            completion(.success(IOSBLEPipeAuthorization(scope: selected, navID: input.navID,
                frame: input.frame, expiresUptime: ProcessInfo.processInfo.systemUptime + 300,
                isCurrent: {
                    guard let current = metadata() else { return false }
                    return IOSNativeUtilityService.matches(captured, current)
                })))
            return nil
        }
        bluetooth.configurePipeConsentProvider { input, completion in
            let title = input.purpose == "system_pairing" ? IOSStrings.bluetoothPairingTitle : IOSStrings.bluetoothConnectionTitle
            let message = input.purpose == "provisioning" ? IOSStrings.bluetoothProvisioningMessage
                : input.purpose == "system_pairing" ? IOSStrings.bluetoothPairingMessage : IOSStrings.bluetoothConnectionMessage
            return utility.requestConsent(title: title, message: message, completion: completion)
        }
        ride.configureScopeProvider(scope)
        bluetooth.configureScopeProvider(scope)
        bluetooth.configureMetadataProvider(metadata)
        history.configureScopeProvider(scope)
        surfaces.configureScopeProvider(scope)
        ride.configureSystemSurfacePublisher(surfaces)
        surfaces.configurePresenter(presenter)
        ride.configurePresenter(presenter)
        IOSLocationService.shared.configurePresenter(presenter)
        bluetooth.configurePresenter(presenter)
        history.configurePresenter(presenter)
        bridge = core
    }

    @objc private func refreshPanel() {
        loadPanel()
    }

    @objc private func checkSoftwareUpdate() { checkUpdate(manual: true) }

    private func checkUpdate(manual: Bool) {
        guard updateTask == nil, !returningToWelcome else { return }
        updateTask = IOSUpdatePresentation.checkApp(from: self, manual: manual) { [weak self] in
            self?.updateTask = nil
        }
    }

    private func checkPanelAutomatically() {
        guard !navigationTerminal, let core = bridge, let navigation = core.currentNavigationID() else { return }
        let ticket = startupGeneration
        let line = IOSPanelLine.current
        panelCheckTask?.cancel()
        web.evaluateJavaScript("document.querySelector('meta[name=build]')?.content || ''") { [weak self, weak core] value, _ in
            guard let self = self, let core = core, self.bridge === core,
                  self.isCurrentStartup(ticket, navigationID: navigation),
                  core.currentNavigationID() == navigation, IOSPanelLine.current == line,
                  !self.returningToWelcome, UIApplication.shared.applicationState == .active else { return }
            let current = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.utf8.count <= 32 else { return }
            self.panelCheckTask = Task { @MainActor [weak self, weak core] in
                guard !Task.isCancelled, let self = self, let core = core,
                      self.isCurrentStartup(ticket, navigationID: navigation),
                      core.currentNavigationID() == navigation, IOSPanelLine.current == line else { return }
                _ = try? await IOSUpdateCenter.shared.checkPanel(current: current, line: line, force: false)
                guard !Task.isCancelled, self.isCurrentStartup(ticket, navigationID: navigation),
                      core.currentNavigationID() == navigation else { return }
                self.panelCheckTask = nil
            }
        }
    }

    private func requestWelcome() -> Bool {
        guard !returningToWelcome, onWelcome != nil, isViewLoaded, view.window != nil,
              UIApplication.shared.applicationState == .active, presentedViewController == nil,
              !IOSPanelCache.shared.snapshot().busy else { return false }
        returningToWelcome = true
        let ticket = startupGeneration
        let navigationID = currentNavigationID
        // 当前 RPC 先交回网页，下一主队列才拆桥；回欢迎页不会清除账号或当成启动失败。
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.returningToWelcome, self.startupGeneration == ticket,
                  self.currentNavigationID == navigationID else { return }
            guard UIApplication.shared.applicationState == .active else { self.returningToWelcome = false; return }
            self.onWelcome?()
        }
        return true
    }

    private func cancelUpdateChecks() {
        updateTask?.cancel(); updateTask = nil
        panelCheckTask?.cancel(); panelCheckTask = nil
    }

    func stopForRecovery() {
        returningToWelcome = true
        startupGeneration &+= 1
        navigationTerminal = true
        currentNavigation = nil
        currentNavigationID = nil
        cancelUpdateChecks()
        updateNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        updateNotificationTokens.removeAll()
        stopBootWatch()
        progressToken?.invalidate(); progressToken = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        bridge?.close(); bridge = nil
    }

    private func restartAfterPanelUpdate() {
        guard !returningToWelcome, isViewLoaded, view.window != nil,
              UIApplication.shared.applicationState == .active else { return }
        localFallbackUsed = false
        diagnosticsShown = false
        loadPanel()
    }

    private func loadPanel() {
        guard !returningToWelcome else { return }
        // 显式重载（诊断页「重试」、更新后重启）视为新一轮启动：
        // 必须复位所有一次性闸门。否则重试后仍失败时 diagnosticsShown 已经是 true，
        // 诊断页/横幅都不会再出现，用户只能看到永久静默白屏；
        // localFallbackUsed 残留还会让离线用户再也用不到磁盘上完好的本地快照。
        // 看门狗由 preparePanel 自己重置（它还会续上 documentFinished 的语义）。
        diagnosticsShown = false
        localFallbackUsed = false
        documentFinished = false
        BootHealth.failed(reason: "unfinished")
        IOSPanelLine.applyPersisted()
        preparePanel(PanelNavigation.home)
    }

    /// 有可用本地快照就把主文档改写到 zeeho-panel://；没有才走线上。
    ///
    /// 走本地是必须的：线上产物是 3.56MB 单文件，`window.APP` 定义在 82%、
    /// `startBoot()` 在 99%，移动网络下首屏要等十几秒；期间 WebKit 一直停在
    /// readyState=loading，不触发布局，用户看到的就是可缩放拖动的白屏
    /// （真机日志实测：estimatedProgress 卡在 30%，didFinish 永不触发）。
    /// 本地读取是 0 延迟，readyState 立刻 complete。
    ///
    /// 之前这里返回 nil 是因为自定义 scheme 下 bootstrap 的 origin 校验失败
    /// （写死 https://host 而实际是 zeeho-panel://panel），那个 bug 已在
    /// Bridge.swift 里改成从实际 target 推导 origin 修掉了。
    private static func localSnapshotURL(for url: URL) -> URL? {
        guard IOSPanelCache.shared.snapshotDirectory() != nil else { return nil }
        guard PanelNavigation.isPanel(url) else { return nil }
        guard url.scheme?.lowercased() != PanelNavigation.localScheme else { return nil }
        return PanelNavigation.localURL(matching: url)
    }

    private func preparePanel(_ url: URL) {
        guard !returningToWelcome else { return }
        guard UIApplication.shared.applicationState == .active else {
            foregroundPanelURL = url
            return
        }
        startupGeneration &+= 1
        let ticket = startupGeneration
        navigationTerminal = false
        currentNavigation = nil
        currentNavigationID = nil
        documentFinished = false
        stopBootWatch()
        cancelUpdateChecks()
        // 必须先撤掉旧导航的身份，再 stopLoading；它触发的取消回调不能结束新一轮。
        web.stopLoading()
        guard let bridge = bridge else {
            IOSDiagnostics.shared.log("preparePanel: bridge 未就绪")
            navigationTerminal = true
            return
        }
        // 有本地快照就把主文档改写到 zeeho-panel://，弱网/离线也能进；
        // 没快照保持线上 https，行为与以前一致。
        // 已经因本地快照失败回退过一次的，本轮不再用本地——否则会原地打转。
        let target = (localFallbackUsed ? nil : Self.localSnapshotURL(for: url)) ?? url
        // 记录本轮是否走本地：本地加载失败要能自动回退线上，否则用户会看到白屏。
        usingLocalSnapshot = target.scheme?.lowercased() == PanelNavigation.localScheme
        // 进度日志按导航重置，否则第一次加载到 100% 之后，后续导航的 0→100
        // 全部落在阈值以下，唯一的「卡在哪」取证通道就失效了。
        lastLoggedProgress = -10
        IOSDiagnostics.shared.log("preparePanel: url=\(url.absoluteString) target=\(target.absoluteString) local=\(usingLocalSnapshot) snapshotBuild=\(IOSPanelCache.shared.snapshotBuild())")
        bridge.prepareNavigation(to: target) { [weak self, weak bridge] result in
            guard let self = self, let bridge = bridge, self.bridge === bridge,
                  self.startupGeneration == ticket, !self.navigationTerminal,
                  !self.returningToWelcome else { return }
            switch result {
            case let .success(target):
                guard UIApplication.shared.applicationState == .active else {
                    self.foregroundPanelURL = url
                    return
                }
                let navigationID = PanelNavigation.navigationID(in: target)
                guard !navigationID.isEmpty, bridge.currentNavigationID() == navigationID else { return }
                self.currentNavigationID = navigationID
                IOSDiagnostics.shared.log("prepareNavigation OK -> \(target.absoluteString)")
                self.currentNavigation = self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            case let .failure(error):
                IOSDiagnostics.shared.log("prepareNavigation FAILED: \(error)")
                self.showError(error)
            }
        }
    }

    /// 本地快照加载失败时回退到线上地址。
    /// 返回 true 表示已经回退，调用方不要再弹错误。
    ///
    /// 一次性：本轮只回退一次，回退后 `localFallbackUsed` 置位，后续
    /// `preparePanel` 一律走 https。持久性失败（快照文件被清、Data Protection
    /// 未解锁）本来也不会因为重试本地而好转，再回退只会无限自旋。
    private func fallbackToNetwork() -> Bool {
        guard !returningToWelcome, !navigationTerminal, usingLocalSnapshot, !localFallbackUsed else { return false }
        localFallbackUsed = true
        usingLocalSnapshot = false
        BootHealth.failed(reason: "resources")
        preparePanel(PanelNavigation.home)
        return true
    }

    /// WKNavigation 对象比 web.url 更早能区分新旧；旧失败回调里 web.url 可能已是新页。
    private func isCurrentNavigation(_ webView: WKWebView, _ navigation: WKNavigation?) -> Bool {
        guard webView === web, !returningToWelcome, !navigationTerminal,
              let navigation = navigation, let current = currentNavigation,
              navigation === current, let id = currentNavigationID,
              bridge?.currentNavigationID() == id else { return false }
        return true
    }

    private func isCurrentStartup(_ ticket: Int, navigationID: String) -> Bool {
        !returningToWelcome && !navigationTerminal && startupGeneration == ticket
            && currentNavigation != nil && currentNavigationID == navigationID
            && bridge?.currentNavigationID() == navigationID
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isCurrentNavigation(webView, navigation) else { return }
        cancelUpdateChecks()
        IOSDiagnostics.shared.log("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
        beginBootWatch()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard isCurrentNavigation(webView, navigation) else { return }
        IOSDiagnostics.shared.log("didCommit: \(webView.url?.absoluteString ?? "nil")")
        // 兜底补注入：自定义 scheme 下 atDocumentStart 的 user script 可能不执行
        // （WKWebView 对非 http(s) 来源的限制），那 ios-bridge.js 执行时
        // window.__zeehoIOS 还是 undefined，candidate 恒为 false，
        // 网页就退回「UI 测试预览」。这里在文档已提交、脚本尚未跑完时补一次。
        bridge?.reinjectBootstrapIfNeeded()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentNavigation(webView, navigation), !documentFinished else { return }
        IOSDiagnostics.shared.log("didFinish: \(webView.url?.absoluteString ?? "nil")")
        // 文档下载完不等于业务就绪，先探测；仍卡骨架时保留有界诊断计时器。
        documentFinished = true
        diagnoseIfBlank()
        startLaunchUpdateChecks()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard isCurrentNavigation(webView, navigation) else { return }
        IOSDiagnostics.shared.log("didFailProvisionalNavigation: \(error.localizedDescription) (\((error as NSError).code))")
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard isCurrentNavigation(webView, navigation) else { return }
        IOSDiagnostics.shared.log("didFail: \(error.localizedDescription) (\((error as NSError).code))")
        showError(error)
    }

    // MARK: - 启动看门狗

    /// 导航开始后每 2 秒探一次，文档完成但业务未就绪时继续，最多 40 秒前台时间。
    /// 退后台/系统授权暂失焦时暂停，不把用户在设置里的停留算成启动超时。
    /// didFinish 可能永不触发，所以计时不能依赖文档完成回调。
    private func beginBootWatch() {
        guard !returningToWelcome, !navigationTerminal, !bootWatchActive else { return }
        stopBootWatch()
        bootWatchTick = 0
        bootWatchForegroundElapsed = 0
        documentFinished = false
        bootWatchActive = true
        resumeBootWatch()
    }

    private func pauseBootWatch(invalidateProbes: Bool = true) {
        if let started = bootWatchForegroundStartedAt {
            bootWatchForegroundElapsed += max(0, ProcessInfo.processInfo.systemUptime - started)
        }
        bootWatchForegroundStartedAt = nil
        if invalidateProbes { bootWatchGeneration &+= 1 }
        bootWatchTimer?.invalidate()
        bootWatchTimer = nil
    }

    private func resumeBootWatch() {
        guard !returningToWelcome, !navigationTerminal,
              UIApplication.shared.applicationState == .active else { return }
        guard bootWatchActive, bootWatchForegroundStartedAt == nil else { return }
        // 预算耗尽后不再轮询；若末次探测被退后台丢弃，恢复前台时补发最终探测。
        if bootWatchAge() >= 40 {
            diagnoseIfBlank(tag: "bootWatch#final")
            return
        }
        bootWatchForegroundStartedAt = ProcessInfo.processInfo.systemUptime
        bootWatchGeneration &+= 1
        scheduleBootWatch()
    }

    private func bootWatchAge() -> TimeInterval {
        guard let started = bootWatchForegroundStartedAt else { return bootWatchForegroundElapsed }
        return bootWatchForegroundElapsed + max(0, ProcessInfo.processInfo.systemUptime - started)
    }

    private func scheduleBootWatch() {
        guard bootWatchActive, !returningToWelcome, !navigationTerminal,
              bootWatchTimer == nil, bootWatchForegroundStartedAt != nil, bootWatchAge() < 40,
              UIApplication.shared.applicationState == .active,
              let navigationID = currentNavigationID else { return }
        let ticket = startupGeneration
        let watchTicket = bootWatchGeneration
        bootWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isCurrentStartup(ticket, navigationID: navigationID),
                  self.bootWatchActive, self.bootWatchGeneration == watchTicket else { return }
            self.bootWatchTimer = nil
            guard UIApplication.shared.applicationState == .active else { self.pauseBootWatch(); return }
            self.bootWatchTick += 1
            self.diagnoseIfBlank(tag: "bootWatch#\(self.bootWatchTick)")
            // JS 回调可能同步成功、回退或进终态，不能无条件续上一枚旧计时器。
            guard self.isCurrentStartup(ticket, navigationID: navigationID),
                  self.bootWatchActive, self.bootWatchGeneration == watchTicket else { return }
            if self.bootWatchAge() >= 40 {
                IOSDiagnostics.shared.log("bootWatch: 40 秒前台时间内业务尚未就绪，停止探测")
                // 保持看门狗活跃到末次探测回执；若该回执因退后台丢弃，恢复前台会补探。
                self.pauseBootWatch(invalidateProbes: false)
            } else {
                self.scheduleBootWatch()
            }
        }
    }

    private func stopBootWatch() {
        pauseBootWatch()
        bootWatchActive = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web, !returningToWelcome, !navigationTerminal else { return }
        IOSDiagnostics.shared.log("webContentProcessDidTerminate")
        navigationTerminal = true
        stopBootWatch()
        bridge?.navigationFailed()
        BootHealth.failed(reason: "renderer")
        onBootFailure?("renderer")
    }

    private func showError(_ error: Error) {
        guard !returningToWelcome, !navigationTerminal else { return }
        // 当前导航取消只收尾，不写失败或耗掉本地回退；旧导航已由身份闸门挡住。
        if (error as NSError).code == NSURLErrorCancelled {
            navigationTerminal = true
            stopBootWatch()
            cancelUpdateChecks()
            bridge?.navigationFailed()
            return
        }
        // 本地快照读不出来（文件被清、权限问题）先自动回退线上，别让用户看白屏。
        if fallbackToNetwork() { return }
        navigationTerminal = true
        stopBootWatch()
        bridge?.navigationFailed()
        BootHealth.failed(reason: "load_failed")
        onBootFailure?("load_failed")
    }

    /// 检查页面是否真的画出了东西；空的话把细节写进日志。
    /// 只读探测，不改页面状态。`tag` 用来区分触发时机（didFinish / bootWatch#N）。
    private func diagnoseIfBlank(tag: String = "didFinish") {
        guard !returningToWelcome, !navigationTerminal,
              UIApplication.shared.applicationState == .active,
              let navigation = currentNavigation, let navigationID = currentNavigationID,
              let url = web.url, PanelNavigation.navigationID(in: url) == navigationID,
              bridge?.currentNavigationID() == navigationID else { return }
        let ticket = startupGeneration
        let watchTicket = bootWatchGeneration
        let watchAge = bootWatchAge()
        let probe = """
        (function () {
          try {
            var b = document.body;
            var info = {
              hasBody: !!b,
              childCount: b ? b.children.length : 0,
              bodyLen: b ? (b.innerHTML || '').length : 0,
              readyState: document.readyState,
              docHeight: Math.round(document.documentElement.scrollHeight || 0),
              viewportH: Math.round(window.innerHeight || 0),
              hasBootstrap: typeof window.__zeehoIOS !== 'undefined',
              hasIOSBR: typeof window.IOSBR !== 'undefined',
              iosbrCandidate: !!(window.IOSBR && window.IOSBR.candidate && window.IOSBR.candidate()),
              iosbrAvailable: !!(window.IOSBR && window.IOSBR.available && window.IOSBR.available()),
              preview: window.__zeehoWebPreview === true,
              panelBuild: (document.querySelector('meta[name="build"]') || {}).content || '',
              apiSource: window.API ? window.API.source : '',
              apiReady: !!(window.API && window.API.ready),
              storeError: window.Store && window.Store.error ? window.Store.error() : '',
              bootVisible: !!(document.getElementById('bootskel') || document.querySelector('.boot-skeleton')),
              bootSettled: window.__zeehoBootSettled === true,
              bootPercent: (document.getElementById('bootseg') || {}).getAttribute ? document.getElementById('bootseg').getAttribute('aria-valuenow') : '',
              bootState: (document.getElementById('bootfallback') || {}).getAttribute ? document.getElementById('bootfallback').getAttribute('data-state') : '',
              hasZeehoShell: typeof window.ZeehoShell !== 'undefined',
              stage: !!document.querySelector('.stage'),
              phone: !!document.querySelector('.phone'),
              scroll: !!document.querySelector('#scroll'),
              fatal: !!document.getElementById('__zeeho_ios_fatal'),
              fatalText: (document.getElementById('__zeeho_ios_fatal') || {}).textContent || '',
              origin: location.origin, path: location.pathname,
              navigationID: window.__zeehoIOS && window.__zeehoIOS.navId || '',
              title: document.title || ''
            };
            return JSON.stringify(info);
          } catch (e) { return '{"probeError":"' + String(e && e.message || e) + '"}'; }
        })()
        """
        web.evaluateJavaScript(probe) { [weak self] value, error in
            guard let self = self, self.isCurrentStartup(ticket, navigationID: navigationID),
                  self.currentNavigation === navigation, self.bootWatchGeneration == watchTicket,
                  UIApplication.shared.applicationState == .active,
                  let currentURL = self.web.url,
                  PanelNavigation.navigationID(in: currentURL) == navigationID else { return }
            if let error = error {
                IOSDiagnostics.shared.log("[\(tag)] probe FAILED: \(error)")
                return
            }
            let text = String(describing: value ?? "nil")
            IOSDiagnostics.shared.log("[\(tag)] probe: \(text)")
            // 探测到致命错误时，把它也贴到原生侧，方便用户截图反馈。
            guard let text = value as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let fatal = object["fatal"] as? Bool ?? false
            let available = object["iosbrAvailable"] as? Bool ?? false
            let preview = object["preview"] as? Bool ?? false
            let settled = object["bootSettled"] as? Bool ?? false
            let bootVisible = object["bootVisible"] as? Bool ?? false
            // 探测确实来自当前文档才可确认成功；没有 bootstrap 的结果仍用于失败诊断。
            let probeNavigationID = object["navigationID"] as? String ?? ""
            guard probeNavigationID.isEmpty || probeNavigationID == navigationID else { return }
            if self.documentFinished, available, !preview, !fatal,
               probeNavigationID == navigationID, settled || !bootVisible {
                BootHealth.clear()
                self.stopBootWatch()
                return
            }
            // 真实壳不能把桥失败说成正常演示；期限只算本次探测发出前的前台时间。
            if watchAge >= 36, !available || preview, !self.diagnosticsShown {
                self.diagnosticsShown = true
                self.navigationTerminal = true
                BootHealth.failed(reason: "ready_timeout")
                self.stopBootWatch()
                self.cancelUpdateChecks()
                self.bridge?.navigationFailed()
                IOSDiagnostics.shared.log("[\(tag)] iOS 原生服务未就绪，打开诊断日志")
                self.presentDiagnostics()
                return
            }
            if fatal, let detail = object["fatalText"] as? String, !detail.isEmpty {
                self.navigationTerminal = true
                self.stopBootWatch()
                self.cancelUpdateChecks()
                self.bridge?.navigationFailed()
                self.showDiagnosticBanner(detail)
                return
            }
            // 本地快照加载完但 body 是空的：多半是自定义 scheme 下某些能力不可用
            // （WebKit 对非 http(s) scheme 的存储/安全上下文限制）。
            // 直接切回线上 https，用户至少能进面板，而不是盯着白屏。
            //
            // 判据必须带上 readyState：单文件产物 3.5MB，<body> 在文件很靠后的位置，
            // 看门狗 2 秒第一次探测时 body 可能还没解析出来，childCount 自然为 0。
            // 只看 childCount 会把「还在下载」误判成白屏，白白把用户切到更慢的线上。
            let readyState = object["readyState"] as? String ?? ""
            let childCount = object["childCount"] as? Int ?? 0
            // 文档还在 loading 时只按前台累计 10 秒判定；后台停留不占这个预算。
            let blank = childCount == 0 && (readyState == "complete" || watchAge >= 10)
            if blank, self.usingLocalSnapshot {
                IOSDiagnostics.shared.log("[\(tag)] body 为空且在用本地快照（readyState=\(readyState)），回退线上")
                self.fallbackToNetwork()
                return
            }
            // readyState=loading 表示线上主文档仍可能在下载/解析；不要用 10 秒启动预算
            // 把慢网连接关掉。只有浏览器确认解析完成的空白才是可终止的真白屏。
            if blank, readyState == "complete", !self.diagnosticsShown {
                self.diagnosticsShown = true
                self.navigationTerminal = true
                self.stopBootWatch()
                self.cancelUpdateChecks()
                self.bridge?.navigationFailed()
                IOSDiagnostics.shared.log("[\(tag)] body 为空且已走线上（readyState=\(readyState)）——真白屏，弹出诊断")
                self.presentDiagnostics()
                return
            }
            // 桥没就绪但页面有内容：说明本地 scheme 下 messageHandlers 不可用
            // （WKWebView 对自定义 scheme 的限制），网页会退回「UI 测试预览」。
            // 这种情况必须切回线上 https——只有 https 页面才能拿到原生桥。
            let candidate = object["iosbrCandidate"] as? Bool ?? false
            if !candidate, self.usingLocalSnapshot, childCount > 0 {
                IOSDiagnostics.shared.log("[\(tag)] 本地快照下桥不可用，回退线上 https")
                self.fallbackToNetwork()
            }
        }
    }

    /// 白屏兜底：把诊断日志做成可滚动文本 + 分享按钮，用户能直接发出去。
    private func presentDiagnostics() {
        guard presentedViewController == nil else { return }
        let controller = DiagnosticsViewController()
        // 「重试」必须真的重载面板：以前诊断页里那个按钮只 dismiss，
        // 用户点完还是白屏，等于没有出口。
        let ticket = startupGeneration
        controller.onRetry = { [weak self] in
            guard let self = self, !self.returningToWelcome, self.startupGeneration == ticket else { return }
            self.loadPanel()
        }
        controller.modalPresentationStyle = .pageSheet
        present(controller, animated: true)
    }

    /// 把网页报告的致命错误显示成原生浮层，用户能直接截图。
    private func showDiagnosticBanner(_ detail: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "面板加载异常",
                                      message: String(detail.prefix(1200)),
                                      preferredStyle: .alert)
        let ticket = startupGeneration
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            guard let self = self, !self.returningToWelcome, self.startupGeneration == ticket else { return }
            self.loadPanel()
        })
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }


    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === web, !returningToWelcome else { decisionHandler(.cancel); return }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // 子资源请求仍由 WebKit 的同源/CORS 策略处理，只限制主框架与新窗口导航。
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if PanelNavigation.isPanel(url) {
            guard !navigationTerminal else { decisionHandler(.cancel); return }
            // 每次真实文档导航先拿可信快照；back/forward/reload 不复用旧 nonce。
            if action.targetFrame != nil, action.navigationType == .other,
               bridge?.consumeNavigationPermit(url) == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                preparePanel(url)
            }
            return
        }
        decisionHandler(.cancel)
        // 脚本自动跳转不得触发向外动作；只响应用户明确点击的链接，不创建带桥小窗。
        if action.navigationType == .linkActivated, PanelNavigation.isExternal(url) {
            UIApplication.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard webView === web, let bridge = bridge else { decisionHandler(.deny); return }
        bridge.requestMediaCapture(origin: origin, frame: frame, type: type, reply: decisionHandler)
    }

    /// 孪生仪表的姿态倾斜需要网页拿 deviceorientation / devicemotion。
    ///
    /// 为什么必须实现这一个回调（只加 NSMotionUsageDescription 不够）：
    /// WKWebView 里运动传感器的默认访问状态是 Prompt，而**未经这个 delegate 明确答复**时，
    /// WebKit 会走 alertForPermission 弹系统框（WebKit UIDelegate.mm 的 alertForPermission 分支）；
    /// WKWebView 在无窗口/被遮挡等情形下那个 alert 会静默失败，最终落成 denied，
    /// 网页侧的表现就是"监听器挂上了但一个事件都不来"。
    ///
    /// 放行口径与媒体权限一致：只认本站 origin，第三方页面一律拒绝。
    /// 传感器数据只用做观感（仪表倾斜），不参与任何业务判据，也不上传。
    /// （本工程 deployment target 是 iOS 15.4，该回调 iOS 15.0 起可用。）
    ///
    /// 判定复用 `isTrustedOrigin(scheme:host:port:)`：WKSecurityOrigin 没有 url 属性
    /// （CI 编译报过 "value of type 'WKSecurityOrigin' has no member 'url'"），
    /// 而那个方法正好收这三个属性，还已经处理了默认端口、本地 scheme 与 punycode 两种域名形态。
    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard webView === web,
              PanelNavigation.isTrustedOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
        else { decisionHandler(.deny); return }
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === web, !returningToWelcome, !navigationTerminal,
              navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else { return nil }
        if PanelNavigation.isPanel(url) { preparePanel(url) }
        else if PanelNavigation.isExternal(url) { UIApplication.shared.open(url) }
        return nil
    }

    // JS 弹窗的 presenter 闸门。
    //
    // 关键约束：completionHandler **必须被调用一次**，否则 WebKit 会挂住整段 JS——
    // 页面从此点不动、桥也发不出请求，用户只能杀 App（「看起来能用、点一下死」）。
    // 因此 present 之前先判「能不能展示」；不能展示就立刻用「取消」语义回调。
    //
    // 显式写 `self.view`：本类同时是 WKUIDelegate，三个 JS 弹窗回调的参数都叫 webView，
    // 裸写 `webView` 会让编译器无法确定指代（CI 实测 "type of expression is ambiguous"）。
    private var canPresentFromWebView: Bool {
        guard self.view.window != nil, presentedViewController == nil else { return false }
        return true
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard canPresentFromWebView else {
            IOSDiagnostics.shared.log("js alert 无法展示（已有弹窗/窗口未就绪），按取消回调")
            completionHandler()
            return
        }
        let alert = UIAlertController(title: IOSStrings.appTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard canPresentFromWebView else {
            IOSDiagnostics.shared.log("js confirm 无法展示（已有弹窗/窗口未就绪），按取消回调")
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: IOSStrings.appTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard canPresentFromWebView else {
            IOSDiagnostics.shared.log("js prompt 无法展示（已有弹窗/窗口未就绪），按取消回调")
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: IOSStrings.appTitle, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }
}
