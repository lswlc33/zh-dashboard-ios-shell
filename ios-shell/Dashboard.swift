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
        if let identifiers = launchOptions?[.bluetoothCentrals] as? [String] {
            IOSBluetoothService.shared.restoreIfRequested(identifiers)
        }
        return true
    }
}

// 启动分流：有可用快照且不是刚升级过就直接进面板，否则先走原生欢迎/恢复页。
// 与安卓的 RecoveryActivity 语义一致——冷启动第一帧可以是原生页，而不是网页骨架。
final class RootRouter: UIViewController {
    private var panel: PanelController?
    private var recovery: RecoveryViewController?
    private var settled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // 在 viewDidLoad 就把内容装上：viewDidAppear 期间窗口是空白的，
        // 冷启动会先闪一帧黑屏。约束布局不依赖 bounds，提前装没有副作用。
        settled = true
        // 持久化的线路要在任何导航之前应用，否则白名单与起始地址会不一致。
        IOSPanelLine.applyPersisted()
        route()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    private func route() {
        // 上次启动失败过就一定要给恢复页，让用户能看到原因并手动重试。
        let reason = BootHealth.pendingReason()
        if !reason.isEmpty {
            showRecovery(reason: reason)
            return
        }
        IOSPanelCache.shared.refresh { [weak self] state in
            guard let self = self else { return }
            if state.ready && !BootHealth.needsWelcome() {
                BootHealth.markWelcomeShown()
                self.showPanel()
            } else {
                BootHealth.markWelcomeShown()
                self.showRecovery(reason: "")
            }
        }
    }

    private func showPanel() {
        let controller = PanelController()
        panel = controller
        addChild(controller)
        // 用约束而不是 frame：RootRouter 是 window 的 rootViewController，
        // route() 触发时 view.bounds 可能还是 zero，写死 frame 会让子视图永远 0×0，
        // 表现就是「只有 toolbar 可见、所有按钮点不动」。
        attach(controller.view)
        controller.didMove(toParent: self)
        controller.onBootFailure = { [weak self] reason in
            self?.switchToRecovery(reason: reason)
        }
    }

    private func showRecovery(reason: String) {
        let controller = RecoveryViewController(reason: reason)
        recovery = controller
        controller.onEnter = { [weak self] in
            guard let self = self else { return }
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
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        recovery = nil
    }

    private func switchToRecovery(reason: String) {
        guard let controller = panel else { showRecovery(reason: reason); return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        panel = nil
        BootHealth.failed(reason: reason)
        showRecovery(reason: reason)
    }

    override var prefersStatusBarHidden: Bool { false }
    override var childForStatusBarStyle: UIViewController? { children.first }
}

// 启动健康状态：等价安卓 BootHealth。
// 只记「上次是否正常进入面板」，用来决定下次冷启动是否强制走恢复页。
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
    private var checkingUpdate = false
    private var checkedOnLaunch = false
    private var lastSafeArea = UIEdgeInsets.zero
    /// 当前这轮是否在用本地快照；失败时用它决定要不要自动回退线上。
    private var usingLocalSnapshot = false
    private var bootWatchTimer: Timer?
    private var bootWatchTick = 0
    /// 白屏诊断页只弹一次，别在每次看门狗探测时都弹。
    private var diagnosticsShown = false
    private var progressToken: NSKeyValueObservation?
    private var lastLoggedProgress = -10

    /// 启动失败回调：交给 RootRouter 切到恢复页。
    var onBootFailure: ((String) -> Void)?

    // 完全沉浸：状态栏与 home indicator 都可见，但页面铺到它们下面。
    override var prefersStatusBarHidden: Bool { false }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        web.navigationDelegate = self
        web.uiDelegate = self
        installBridge()
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
        if !checkedOnLaunch {
            checkedOnLaunch = true
            checkUpdate(manual: false)
        }
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
        let core = IOSBridge(webView: web, services: [IOSLocationService.shared, bluetooth, ride, history, system, surfaces, line])
        let scope: () -> IOSRideScope? = { [weak core] in core?.nativeSessionScope() }
        let presenter: () -> UIViewController? = { [weak self] in self }
        ride.configureScopeProvider(scope)
        bluetooth.configureScopeProvider(scope)
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

    private func updateMessage(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "iOS 软件更新", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func checkUpdate(manual: Bool) {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task { @MainActor in
            defer { checkingUpdate = false }
            do {
                let release = try await IOSUpdater.latest()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                guard try release.isNewer(version: version, build: build) else {
                    if manual { updateMessage("当前 iOS 软件版本：\(version)（\(build)），已是最新。") }
                    return
                }
                let required = try IOSRelease.versionParts(release.minimumIOS)
                guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: required[0], minorVersion: required[1], patchVersion: required[2])) else {
                    throw UpdateError.systemTooOld
                }
                guard presentedViewController == nil else { return }
                let alert = UIAlertController(title: "发现 iOS 新版本", message: "当前：\(version)（\(build)）\n新版：\(release.version)（\(release.build)）\n\n下载并校验后，在分享菜单中选择 TrollStore 确认覆盖安装，无需卸载。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
                alert.addAction(UIAlertAction(title: "下载 IPA", style: .default) { [weak self] _ in self?.downloadUpdate(release) })
                present(alert, animated: true)
            } catch {
                if manual { updateMessage(error.localizedDescription) }
            }
        }
    }

    private func downloadUpdate(_ release: IOSRelease) {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task { @MainActor in
            defer { checkingUpdate = false }
            do {
                let file = try await IOSUpdater.download(release)
                guard presentedViewController == nil else { return }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                present(share, animated: true)
            } catch { updateMessage(error.localizedDescription) }
        }
    }

    private func loadPanel() {
        BootHealth.failed(reason: "unfinished")
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
        web.stopLoading()
        guard let bridge = bridge else {
            IOSDiagnostics.shared.log("preparePanel: bridge 未就绪")
            return
        }
        // 有本地快照就把主文档改写到 zeeho-panel://，弱网/离线也能进；
        // 没快照保持线上 https，行为与以前一致。
        let target = Self.localSnapshotURL(for: url) ?? url
        // 记录本轮是否走本地：本地加载失败要能自动回退线上，否则用户会看到白屏。
        usingLocalSnapshot = target.scheme?.lowercased() == PanelNavigation.localScheme
        IOSDiagnostics.shared.log("preparePanel: url=\(url.absoluteString) target=\(target.absoluteString) local=\(usingLocalSnapshot)")
        bridge.prepareNavigation(to: target) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(target):
                IOSDiagnostics.shared.log("prepareNavigation OK -> \(target.absoluteString)")
                self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            case let .failure(error):
                IOSDiagnostics.shared.log("prepareNavigation FAILED: \(error)")
                self.showError(error)
            }
        }
    }

    /// 本地快照加载失败时回退到线上地址，并让快照失效（下次进欢迎页重下）。
    /// 返回 true 表示已经回退，调用方不要再弹错误。
    private func fallbackToNetwork() -> Bool {
        guard usingLocalSnapshot else { return false }
        usingLocalSnapshot = false
        BootHealth.failed(reason: "resources")
        preparePanel(PanelNavigation.home)
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        IOSDiagnostics.shared.log("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
        beginBootWatch()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        IOSDiagnostics.shared.log("didCommit: \(webView.url?.absoluteString ?? "nil")")
        // 兜底补注入：自定义 scheme 下 atDocumentStart 的 user script 可能不执行
        // （WKWebView 对非 http(s) 来源的限制），那 ios-bridge.js 执行时
        // window.__zeehoIOS 还是 undefined，candidate 恒为 false，
        // 网页就退回「UI 测试预览」。这里在文档已提交、脚本尚未跑完时补一次。
        bridge?.reinjectBootstrapIfNeeded()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        IOSDiagnostics.shared.log("didFinish: \(webView.url?.absoluteString ?? "nil")")
        // 页面首帧就绪后清掉失败标记，下次冷启动直接进面板。
        BootHealth.clear()
        stopBootWatch()
        // 诊断：didFinish 只代表文档加载完，不代表网页画出了内容。
        diagnoseIfBlank()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        IOSDiagnostics.shared.log("didFailProvisionalNavigation: \(error.localizedDescription) (\((error as NSError).code))")
        stopBootWatch()
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        IOSDiagnostics.shared.log("didFail: \(error.localizedDescription) (\((error as NSError).code))")
        stopBootWatch()
        showError(error)
    }

    // MARK: - 启动看门狗

    /// 导航开始后每 2 秒探一次页面状态，最多 10 次（20 秒）。
    ///
    /// 为什么不能只靠 didFinish：真机上出现过 didCommit 成功、didFinish 永不触发
    /// 的情况（页面一直没进 load 完成态），那时所有挂在 didFinish 上的诊断都不会跑，
    /// 用户只看到一片可缩放拖动的白屏。看门狗不依赖任何 delegate 回调。
    private func beginBootWatch() {
        stopBootWatch()
        bootWatchTick = 0
        scheduleBootWatch()
    }

    private func scheduleBootWatch() {
        guard bootWatchTick < 10 else {
            IOSDiagnostics.shared.log("bootWatch: 20 秒内未收到 didFinish，停止探测")
            return
        }
        bootWatchTick += 1
        bootWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.diagnoseIfBlank(tag: "bootWatch#\(self.bootWatchTick)")
            self.scheduleBootWatch()
        }
    }

    private func stopBootWatch() {
        bootWatchTimer?.invalidate()
        bootWatchTimer = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        IOSDiagnostics.shared.log("webContentProcessDidTerminate")
        onBootFailure?("renderer")
    }

    private func showError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // 本地快照读不出来（文件被清、权限问题）先自动回退线上，别让用户看白屏。
        if fallbackToNetwork() { return }
        bridge?.navigationFailed()
        BootHealth.failed(reason: "load_failed")
        onBootFailure?("load_failed")
    }

    /// 检查页面是否真的画出了东西；空的话把细节写进日志。
    /// 只读探测，不改页面状态。`tag` 用来区分触发时机（didFinish / bootWatch#N）。
    private func diagnoseIfBlank(tag: String = "didFinish") {
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
              hasZeehoShell: typeof window.ZeehoShell !== 'undefined',
              stage: !!document.querySelector('.stage'),
              phone: !!document.querySelector('.phone'),
              scroll: !!document.querySelector('#scroll'),
              fatal: !!document.getElementById('__zeeho_ios_fatal'),
              fatalText: (document.getElementById('__zeeho_ios_fatal') || {}).textContent || '',
              origin: location.origin, path: location.pathname,
              title: document.title || ''
            };
            return JSON.stringify(info);
          } catch (e) { return '{"probeError":"' + String(e && e.message || e) + '"}'; }
        })()
        """
        web.evaluateJavaScript(probe) { [weak self] value, error in
            guard let self = self else { return }
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
            if fatal, let detail = object["fatalText"] as? String, !detail.isEmpty {
                self.showDiagnosticBanner(detail)
                return
            }
            // 本地快照加载完但 body 是空的：多半是自定义 scheme 下某些能力不可用
            // （WebKit 对非 http(s) scheme 的存储/安全上下文限制）。
            // 直接切回线上 https，用户至少能进面板，而不是盯着白屏。
            let childCount = object["childCount"] as? Int ?? 0
            if childCount == 0, self.usingLocalSnapshot {
                IOSDiagnostics.shared.log("[\(tag)] body 为空且在用本地快照，回退线上")
                self.fallbackToNetwork()
                return
            }
            // 线上也空：这是真白屏，把日志弹给用户，让他能发给我。只弹一次。
            if childCount == 0, !self.diagnosticsShown {
                self.diagnosticsShown = true
                IOSDiagnostics.shared.log("[\(tag)] body 为空且已走线上——真白屏，弹出诊断")
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
        controller.modalPresentationStyle = .pageSheet
        present(controller, animated: true)
    }

    /// 把网页报告的致命错误显示成原生浮层，用户能直接截图。
    private func showDiagnosticBanner(_ detail: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "面板加载异常",
                                      message: String(detail.prefix(1200)),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.loadPanel()
        })
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }


    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // 子资源请求仍由 WebKit 的同源/CORS 策略处理，只限制主框架与新窗口导航。
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if PanelNavigation.isPanel(url) {
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else { return nil }
        if PanelNavigation.isPanel(url) { preparePanel(url) }
        else if PanelNavigation.isExternal(url) { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: IOSStrings.appTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: IOSStrings.appTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: IOSStrings.appTitle, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }
}
