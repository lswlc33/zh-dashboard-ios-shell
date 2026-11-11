import UIKit

// 原生欢迎与恢复页：不创建 WebView，不读取网页状态或调用 JS。
// 对应安卓 RecoveryActivity + RecoveryUi 的等价实现，但 iOS 没有 APK 升级概念，
// 所以「版本与更新」弹窗里换成 iOS 版本与面板版本，「备份与迁移」暂不提供。
//
// 一个页面两种语义：reason 为空是欢迎页，非空是恢复页（错误说明不同）。
final class RecoveryViewController: UIViewController {
    private let reason: String
    private var cacheState = IOSPanelCache.State()
    private var initializedRequested = false

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let welcomeStack = UIStackView()
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private let errorCard = UIView()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let bytesLabel = UILabel()
    private let initializeButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let enterButton = UIButton(type: .system)

    /// 进入面板回调。由 RootRouter 注入，负责切换到全屏 WebView。
    var onEnter: (() -> Void)?

    init(reason: String) {
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        refreshCache()
    }

    // MARK: - 布局

    private func buildUI() {
        let toolbar = makeToolbar()
        view.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        // 欢迎区：logo + 标题 + 副标题，在剩余空间里居中。
        let logo = UIImageView(image: UIImage(named: "Icon180") ?? UIImage(systemName: "bolt.car.fill"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 80).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let title = UILabel()
        title.text = IOSStrings.recoveryTitle
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .label
        title.textAlignment = .center
        title.adjustsFontForContentSizeCategory = true

        let subtitle = UILabel()
        subtitle.text = IOSStrings.recoverySubtitle
        subtitle.font = .systemFont(ofSize: 16, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.adjustsFontForContentSizeCategory = true

        welcomeStack.axis = .vertical
        welcomeStack.alignment = .center
        welcomeStack.spacing = 8
        welcomeStack.setCustomSpacing(20, after: logo)
        welcomeStack.addArrangedSubview(logo)
        welcomeStack.addArrangedSubview(title)
        welcomeStack.addArrangedSubview(subtitle)
        welcomeStack.isLayoutMarginsRelativeArrangement = true
        welcomeStack.layoutMargins = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)

        contentStack.addArrangedSubview(welcomeStack)
        contentStack.addArrangedSubview(makeResourceCard())
        contentStack.addArrangedSubview(enterButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    private func makeToolbar() -> UIView {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        let versionButton = UIButton(type: .system)
        versionButton.setTitle(IOSStrings.recoveryVersionTitle, for: .normal)
        versionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        versionButton.addTarget(self, action: #selector(showVersion), for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let backupButton = UIButton(type: .system)
        backupButton.setTitle(IOSStrings.recoveryBackupTitle, for: .normal)
        backupButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        backupButton.addTarget(self, action: #selector(showBackup), for: .touchUpInside)

        bar.addArrangedSubview(versionButton)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(backupButton)
        return bar
    }

    private func makeResourceCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 24

        statusLabel.font = .systemFont(ofSize: 20, weight: .bold)
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        errorLabel.font = .systemFont(ofSize: 16, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true

        errorCard.backgroundColor = .tertiarySystemBackground
        errorCard.layer.cornerRadius = 16
        errorCard.isHidden = true
        errorCard.addSubview(errorLabel)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorCard.topAnchor, constant: 12),
            errorLabel.bottomAnchor.constraint(equalTo: errorCard.bottomAnchor, constant: -12),
            errorLabel.leadingAnchor.constraint(equalTo: errorCard.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: errorCard.trailingAnchor, constant: -16)
        ])

        progressBar.progressViewStyle = .default
        progressBar.isHidden = true

        bytesLabel.font = .preferredFont(forTextStyle: .footnote)
        bytesLabel.textColor = .secondaryLabel
        bytesLabel.numberOfLines = 0
        bytesLabel.adjustsFontForContentSizeCategory = true

        var initConfig = UIButton.Configuration.filled()
        initConfig.title = IOSStrings.recoveryInitialize
        initConfig.cornerStyle = .large
        initializeButton.configuration = initConfig
        initializeButton.addTarget(self, action: #selector(initializeTapped), for: .touchUpInside)

        var cancelConfig = UIButton.Configuration.tinted()
        cancelConfig.title = IOSStrings.recoveryCancel
        cancelConfig.cornerStyle = .large
        cancelButton.configuration = cancelConfig
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [initializeButton, cancelButton])
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [statusLabel, errorCard, progressBar, bytesLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20)
        ])

        var enterConfig = UIButton.Configuration.filled()
        enterConfig.title = IOSStrings.recoveryEnter
        enterConfig.cornerStyle = .large
        enterButton.configuration = enterConfig
        enterButton.isEnabled = false
        enterButton.addTarget(self, action: #selector(enterTapped), for: .touchUpInside)
        return card
    }

    // MARK: - 状态

    private func refreshCache() {
        IOSPanelCache.shared.refresh { [weak self] state in
            self?.render(state)
        }
    }

    private func render(_ state: IOSPanelCache.State) {
        cacheState = state
        let busy = state.busy
        let ready = state.ready

        // 状态文案：进度可算时显示百分比，否则显示待完成/已完成。
        if state.phase == .downloading, state.total > 0 {
            let percent = max(0, min(100, Int(Double(state.done) * 100.0 / Double(state.total))))
            statusLabel.text = String(format: IOSStrings.recoveryStatusProgress, percent)
        } else if ready {
            statusLabel.text = IOSStrings.recoveryStatusDone
        } else {
            statusLabel.text = IOSStrings.recoveryStatusPending
        }

        // 字节数与资源序号（单资源字节，不是整包累计，与安卓一致）。
        let doneText = Self.formatBytes(state.done)
        if state.phase == .downloading, state.total > 0 {
            let totalText = Self.formatBytes(state.total)
            let bytes = String(format: IOSStrings.recoveryBytes, doneText, totalText)
            if state.resourceIndex > 0, state.resourceCount >= state.resourceIndex {
                bytesLabel.text = String(format: IOSStrings.recoveryResourceProgress,
                                         state.resourceIndex, state.resourceCount, bytes)
            } else {
                bytesLabel.text = bytes
            }
        } else if state.phase == .downloading {
            bytesLabel.text = String(format: IOSStrings.recoveryBytesUnknown, doneText)
        } else {
            bytesLabel.text = ready ? IOSStrings.recoveryReadyHint : ""
        }
        bytesLabel.isHidden = bytesLabel.text?.isEmpty ?? true

        progressBar.isHidden = !busy
        if busy {
            if state.total > 0 {
                progressBar.progress = Float(Double(state.done) / Double(state.total))
            } else {
                progressBar.progress = 0
            }
        }

        // 错误卡：恢复页 reason 优先，其次是初始化失败原因。
        let message = state.error.isEmpty ? reasonMessage() : initErrorMessage(state.error)
        errorLabel.text = message
        errorCard.isHidden = message.isEmpty

        // 初始化 / 取消互斥：只在真正下载中允许取消。
        let cancellable = state.busy && (state.phase == .downloading || state.phase == .preparing)
        initializeButton.isHidden = cancellable
        cancelButton.isHidden = !cancellable
        initializeButton.isEnabled = !busy
        var config = initializeButton.configuration
        config?.title = ready ? IOSStrings.recoveryReinitialize : IOSStrings.recoveryInitialize
        initializeButton.configuration = config

        enterButton.isEnabled = ready && !busy
    }

    private func reasonMessage() -> String {
        switch reason {
        case "": return ""
        case "unsafe": return IOSStrings.recoveryReasonUnsafe
        case "renderer": return IOSStrings.recoveryReasonRenderer
        case "ready_timeout": return IOSStrings.recoveryReasonTimeout
        case "resources": return IOSStrings.recoveryReasonResources
        case "engine", "webview": return IOSStrings.recoveryReasonEngine
        case "unfinished": return IOSStrings.recoveryReasonUnfinished
        default: return IOSStrings.recoveryReasonGeneric
        }
    }

    private func initErrorMessage(_ code: String) -> String {
        if code.hasPrefix("panel_") { return String(format: IOSStrings.recoveryInitError, code) }
        return IOSStrings.recoveryInitErrorGeneric
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    // MARK: - 动作

    @objc private func initializeTapped() {
        initializedRequested = true
        initializeButton.isEnabled = false
        IOSPanelCache.shared.initialize(force: true) { [weak self] state in
            self?.render(state)
        }
    }

    @objc private func cancelTapped() {
        IOSPanelCache.shared.cancel { [weak self] state in
            self?.render(state)
        }
    }

    @objc private func enterTapped() {
        guard cacheState.ready else { return }
        onEnter?()
    }

    @objc private func showVersion() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let panelBuild = IOSPanelCache.shared.snapshotBuild()
        let message = [
            "\(IOSStrings.recoveryAppVersionLabel)：\(version)（\(build)）",
            "\(IOSStrings.recoveryPanelVersionLabel)：\(panelBuild.isEmpty ? IOSStrings.recoveryPanelVersionNone : panelBuild)",
            "\(IOSStrings.recoveryLineLabel)：\(IOSPanelLine.current.displayName)"
        ].joined(separator: "\n")
        let alert = UIAlertController(title: IOSStrings.recoveryVersionTitle, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }

    @objc private func showBackup() {
        let alert = UIAlertController(title: IOSStrings.recoveryBackupTitle,
                                      message: IOSStrings.recoveryBackupUnavailable,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }
}
