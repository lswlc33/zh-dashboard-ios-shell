import UIKit

// 原生欢迎与恢复页：不创建 WebView，不读取网页状态或调用 JS。
// 结构逐项对照安卓 RecoveryUi.build()：
//   root(垂直) = toolbar + ScrollView(weight=1, 欢迎区垂直居中) + footer(≤60% 屏高)
//   footer = 资源卡(状态/错误/进度/字节/初始化/取消) + 「进入面板」
// 一个控制器两种语义：reason 为空是欢迎页，非空是恢复页。
final class RecoveryViewController: UIViewController {
    private let reason: String
    private var cacheState = IOSPanelCache.State()

    // toolbar
    private let versionButton = UIButton(type: .system)
    private let backupButton = UIButton(type: .system)

    // 欢迎区（在 toolbar 与底栏之间垂直居中）
    private let welcomeGroup = UIStackView()

    // 底栏
    private let footerStack = UIStackView()
    private let statusLabel = UILabel()
    private let errorCard = UIView()
    private let errorLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let bytesLabel = UILabel()
    private let initializeButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let enterButton = UIButton(type: .system)

    /// 进入面板回调。由 RootRouter 注入，负责切换到全屏 WebView。
    var onEnter: (() -> Void)?

    // 安卓：卡片圆角 24dp、按钮圆角 28dp（MD3 filled 的 full 圆角）。
    // iOS 上按用户要求再大一点：卡片 28、按钮 22（高度 52 → 近似胶囊）。
    private static let cardRadius: CGFloat = 28
    private static let buttonRadius: CGFloat = 22
    private static let buttonHeight: CGFloat = 52

    init(reason: String) {
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        // 初始化期间每 100ms 推一次进度；不用轮询，避免空转。
        IOSPanelCache.shared.onState = { [weak self] state in
            self?.render(state)
        }
        refreshCache()
    }

    deinit {
        // 页面销毁后不要再往它身上回调。
        if IOSPanelCache.shared.onState != nil {
            IOSPanelCache.shared.onState = nil
        }
    }

    // MARK: - 布局

    private func buildUI() {
        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        // 欢迎区：用普通容器 + centerY 约束落在剩余空间中心。
        // 不再嵌套 UIScrollView——两个 scrollView 互相用 contentLayoutGuide 定高会形成
        // 循环约束（Auto Layout 解不出来，真机上表现为整页塌成 0 只剩 toolbar）。
        welcomeGroup.axis = .vertical
        welcomeGroup.alignment = .center
        welcomeGroup.spacing = 0
        welcomeGroup.translatesAutoresizingMaskIntoConstraints = false
        welcomeGroup.isLayoutMarginsRelativeArrangement = true
        welcomeGroup.layoutMargins = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        view.addSubview(welcomeGroup)

        let logo = UIImageView(image: Self.appIcon())
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 80).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let title = UILabel()
        title.text = IOSStrings.recoveryTitle
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true

        let subtitle = UILabel()
        subtitle.text = IOSStrings.recoverySubtitle
        subtitle.font = .systemFont(ofSize: 16, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.adjustsFontForContentSizeCategory = true

        welcomeGroup.addArrangedSubview(logo)
        welcomeGroup.setCustomSpacing(20, after: logo)
        welcomeGroup.addArrangedSubview(title)
        welcomeGroup.setCustomSpacing(4, after: title)
        welcomeGroup.addArrangedSubview(subtitle)

        // 底栏：普通容器，高度由内容撑开。
        footerStack.axis = .vertical
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerStack)
        footerStack.addArrangedSubview(makeResourceCard())
        footerStack.addArrangedSubview(enterButton)

        // 欢迎区的参考系：toolbar 与底栏之间那块不可交互的空白区。
        // 用一个透明容器而不是 UIScrollView，是为了避开两个 scrollView 互相
        // 用 contentLayoutGuide 定高形成的循环约束（真机上会整页塌成 0）。
        let welcomeRegion = UIView()
        welcomeRegion.isUserInteractionEnabled = false
        welcomeRegion.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(welcomeRegion)
        // 欢迎区叠在参考系上，靠 centerY 落在中间。
        view.addSubview(welcomeGroup)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: guide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // 底栏贴底、左右留 24（与安卓 footer padding 一致）。
            footerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footerStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            // 60% 屏高上限：大字体时底栏不会吃掉整个屏幕。
            footerStack.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6),

            // 参考系 = toolbar 下沿 到 底栏上沿。
            welcomeRegion.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            welcomeRegion.bottomAnchor.constraint(equalTo: footerStack.topAnchor),
            welcomeRegion.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            welcomeRegion.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // 欢迎区在参考系里垂直居中；上下各留 8 防止贴边。
            welcomeGroup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            welcomeGroup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            welcomeGroup.centerYAnchor.constraint(equalTo: welcomeRegion.centerYAnchor),
            welcomeGroup.topAnchor.constraint(greaterThanOrEqualTo: welcomeRegion.topAnchor, constant: 8),
            welcomeGroup.bottomAnchor.constraint(lessThanOrEqualTo: welcomeRegion.bottomAnchor, constant: -8)
        ])
    }

    private func makeToolbar() -> UIView {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        bar.translatesAutoresizingMaskIntoConstraints = false

        styleTextButton(versionButton, title: IOSStrings.recoveryVersionTitle, action: #selector(showVersion))
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        styleTextButton(backupButton, title: IOSStrings.recoveryBackupTitle, action: #selector(showBackup))

        bar.addArrangedSubview(versionButton)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(backupButton)
        return bar
    }

    private func styleTextButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .tintColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .medium)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// MD3 filled 按钮：高度 52、圆角 22（近胶囊）、整宽。
    private func styleFilledButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = Self.buttonRadius
        config.baseBackgroundColor = .tintColor
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 16, weight: .semibold)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
    }

    /// MD3 tonal 按钮：同尺寸但次要底色。
    private func styleTonalButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = Self.buttonRadius
        config.baseForegroundColor = .tintColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 16, weight: .semibold)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
    }

    private func makeResourceCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = Self.cardRadius
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        // 状态字段本身就是卡片标题（安卓同一份文案，不出现两处状态）。
        statusLabel.font = .systemFont(ofSize: 20, weight: .bold)
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        errorLabel.font = .systemFont(ofSize: 16, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorCard.backgroundColor = .tertiarySystemBackground
        errorCard.layer.cornerRadius = 16
        errorCard.layer.cornerCurve = .continuous
        errorCard.isHidden = true
        errorCard.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorCard.topAnchor, constant: 12),
            errorLabel.bottomAnchor.constraint(equalTo: errorCard.bottomAnchor, constant: -12),
            errorLabel.leadingAnchor.constraint(equalTo: errorCard.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: errorCard.trailingAnchor, constant: -16)
        ])

        progressBar.progressViewStyle = .default
        progressBar.progressTintColor = .tintColor
        progressBar.trackTintColor = .tertiarySystemFill
        progressBar.layer.cornerRadius = 3
        progressBar.clipsToBounds = true
        progressBar.isHidden = true
        progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        bytesLabel.font = .preferredFont(forTextStyle: .footnote)
        bytesLabel.textColor = .secondaryLabel
        bytesLabel.numberOfLines = 0
        bytesLabel.adjustsFontForContentSizeCategory = true

        styleFilledButton(initializeButton, title: IOSStrings.recoveryInitialize, action: #selector(initializeTapped))
        styleTonalButton(cancelButton, title: IOSStrings.recoveryCancel, action: #selector(cancelTapped))
        cancelButton.isHidden = true

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
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20)
        ])

        styleFilledButton(enterButton, title: IOSStrings.recoveryEnter, action: #selector(enterTapped))
        enterButton.isEnabled = false
        return card
    }

    private static func appIcon() -> UIImage? {
        // 构建时把 icon-512 缩成 Icon180.png 塞进 bundle；缺失时用系统符号兜底。
        if let icon = UIImage(named: "Icon180") { return icon }
        return UIImage(systemName: "bolt.car.fill")
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

        // 百分比一律走 state.progress（以「已完成文件数」为主），
        // 不再自己拿 done/total 算——Content-Length 在 CDN 压缩时不可信，
        // 真机上曾因此卡在 90% 不动。
        if state.phase == .downloading {
            let percent = max(0, min(100, Int(state.progress * 100)))
            statusLabel.text = String(format: IOSStrings.recoveryStatusProgress, percent)
        } else if ready {
            statusLabel.text = IOSStrings.recoveryStatusDone
        } else {
            statusLabel.text = IOSStrings.recoveryStatusPending
        }

        // 资源行：优先显示「已完成 N/M 个」，字节数只作为附加信息。
        if state.phase == .downloading {
            let doneText = Self.formatBytes(state.done)
            let detail: String
            if state.total > 0 {
                detail = String(format: IOSStrings.recoveryBytes, doneText, Self.formatBytes(state.total))
            } else {
                detail = String(format: IOSStrings.recoveryBytesUnknown, doneText)
            }
            bytesLabel.text = String(format: IOSStrings.recoveryResourceProgress,
                                     state.completedFiles, max(1, state.resourceCount), detail)
        } else {
            bytesLabel.text = ready ? IOSStrings.recoveryReadyHint : ""
        }
        bytesLabel.isHidden = (bytesLabel.text ?? "").isEmpty

        progressBar.isHidden = !busy
        progressBar.progress = busy ? Float(state.progress) : 0

        let message = state.error.isEmpty ? reasonMessage() : initErrorMessage(state.error)
        errorLabel.text = message
        errorCard.isHidden = message.isEmpty

        // 初始化 / 取消互斥：只在真正下载中允许取消。
        let cancellable = busy
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

    /// 「版本与更新」：打开独立更新面板（版本信息 / 资源状态 / 线路 / 操作）。
    @objc private func showVersion() {
        let panel = UpdatePanelViewController()
        panel.onChange = { [weak self] in self?.refreshCache() }
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func showBackup() {
        let alert = UIAlertController(title: IOSStrings.recoveryBackupTitle,
                                      message: IOSStrings.recoveryBackupUnavailable,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }
}
