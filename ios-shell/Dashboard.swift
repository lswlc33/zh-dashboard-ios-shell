import UIKit
import WebKit


@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: PanelController())
        window.makeKeyAndVisible()
        self.window = window
        if let identifiers = launchOptions?[.bluetoothCentrals] as? [String] {
            IOSBluetoothService.shared.restoreIfRequested(identifiers)
        }
        return true
    }
}

final class PanelController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let loading = PanelLoadingView()
    private var bridge: IOSBridge?
    private var checkingUpdate = false
    private var checkedOnLaunch = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "几何面板"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "软件更新", style: .plain, target: self, action: #selector(checkSoftwareUpdate))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "刷新面板", style: .plain, target: self, action: #selector(refreshPanel))
        web.navigationDelegate = self
        web.uiDelegate = self
        installBridge()
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            loading.topAnchor.constraint(equalTo: web.topAnchor),
            loading.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            loading.leadingAnchor.constraint(equalTo: web.leadingAnchor),
            loading.trailingAnchor.constraint(equalTo: web.trailingAnchor)
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

    private func installBridge() {
        let ride = IOSRideService()
        let history = IOSHistoryService()
        let bluetooth = IOSBluetoothService.shared
        let system = IOSSystemService(controller: { [weak self] in self })
        let surfaces = IOSSystemSurfacesService()
        let core = IOSBridge(webView: web, services: [IOSLocationService.shared, bluetooth, ride, history, system, surfaces])
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
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { @MainActor in
            defer {
                checkingUpdate = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                let release = try await IOSUpdater.latest()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                guard try release.isNewer(version: version, build: build) else {
                    if manual { updateMessage("当前 iOS 软件版本：\(version)（\(build)），已是最新。面板资源可通过“刷新面板”更新。") }
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
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "正在下载…"
        Task { @MainActor in
            defer {
                checkingUpdate = false
                navigationItem.rightBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItem?.title = "软件更新"
            }
            do {
                let file = try await IOSUpdater.download(release)
                guard presentedViewController == nil else {
                    navigationItem.prompt = "IPA 已下载，请关闭弹窗后重试软件更新"
                    return
                }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
                present(share, animated: true)
            } catch { updateMessage(error.localizedDescription) }
        }
    }

    private func loadPanel() {
        loading.setLoading(true)
        preparePanel(PanelNavigation.home)
    }

    private func preparePanel(_ url: URL) {
        loading.setLoading(true)
        web.stopLoading()
        guard let bridge = bridge else { return }
        bridge.prepareNavigation(to: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(target):
                self.web.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            case let .failure(error): self.showError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading.setLoading(true) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.setLoading(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadPanel() }

    private func showError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        bridge?.navigationFailed()
        loading.setLoading(false)
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "面板加载失败", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in self?.loadPanel() })
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
        let alert = UIAlertController(title: "几何面板", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "几何面板", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: "几何面板", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }
}
