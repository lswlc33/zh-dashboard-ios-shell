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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !settled else { return }
        settled = true
        // 持久化的线路要在任何导航之前应用，否则白名单与起始地址会不一致。
        IOSPanelLine.applyPersisted()
        route()
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
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
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
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        return view
    }()
    private var bridge: IOSBridge?
    private var checkingUpdate = false
    private var checkedOnLaunch = false
    private var lastSafeArea = UIEdgeInsets.zero

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

    /// 有可用快照时把主文档改写到本地 scheme；否则返回 nil 表示走网络。
    /// 放在这里而不是 PanelNavigation，是因为它要读 IOSPanelCache，
    /// 而 Navigation.swift 必须能被 navigation-test.swift 单独编译。
    private static func localSnapshotURL(for url: URL) -> URL? {
        guard IOSPanelCache.shared.snapshotDirectory() != nil else { return nil }
        guard PanelNavigation.isPanel(url) else { return nil }
        guard url.scheme?.lowercased() != PanelNavigation.localScheme else { return nil }
        return PanelNavigation.localURL(matching: url)
    }

    private func preparePanel(_ url: URL) {
        web.stopLoading()
        guard let bridge = bridge else { return }
        // 有本地快照就把主文档改写到 zeeho-panel://，弱网/离线也能进；
        // 没快照保持线上 https，行为与以前一致。
        let target = Self.localSnapshotURL(for: url) ?? url
        bridge.prepareNavigation(to: target) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(target):
                self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            case let .failure(error): self.showError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面首帧就绪后清掉失败标记，下次冷启动直接进面板。
        BootHealth.clear()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onBootFailure?("renderer")
    }

    private func showError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        bridge?.navigationFailed()
        BootHealth.failed(reason: "load_failed")
        onBootFailure?("load_failed")
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
