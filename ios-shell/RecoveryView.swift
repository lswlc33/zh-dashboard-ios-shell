import UIKit

// 原生欢迎与恢复页：不创建 WebView，不读取网页状态或调用 JS。
// 结构逐项对照安卓 RecoveryUi.build()：
//   root(垂直) = toolbar + ScrollView(weight=1, 欢迎区垂直居中) + footer(≤60% 屏高)
//   footer = 资源卡(状态/错误/进度/字节/初始化/取消) + 「进入面板」
// 一个控制器两种语义：reason 为空是欢迎页，非空是恢复页。
final class RecoveryViewController: UIViewController {
    private let reason: String
    private var cacheState = IOSPanelCache.State()
    /// 上一次写进诊断日志的错误码，避免进度推送把同一行刷进日志几十次。
    private var lastLoggedErrorCode: String?
    /// 本次欢迎页只自动更新一次；失败或取消后保留旧快照，由用户决定是否重试。
    private var checkedCacheRefresh = false
    /// 两个生命周期回调都可能预检；只接受最新一轮，不能让旧 ready 盖住下载中的状态。
    private var cacheRefreshGeneration = 0

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
        installStateHandler()
        refreshCache()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从更新面板 / 分享页回来时进度可能已经变了，重新挂上并刷一次。
        installStateHandler()
        refreshCache()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 用户进入面板后本页仍被 RootRouter 持有；摘掉回调免得后台
        // 还在往看不见的标签上写进度（每次推送都会触发一轮布局）。
        detachStateHandler()
    }

    deinit {
        detachStateHandler()
    }

    /// 当前挂给 `IOSPanelCache.onState` 的宿主（同一时刻只认一个）。
    ///
    /// 为什么需要它：`onState` 是单例上的**单个**闭包槽，没有「谁挂的」信息。
    /// 以前 `deinit` 无条件把它清空，靠的是「同一时刻只有一个欢迎页监听」这个隐含前提
    /// ——时序上恰好安全：RootRouter 每次先移除旧页再挂新页，更新面板也不碰这个槽。
    /// 只要有人再加第二个监听方（欢迎页与恢复页并存、常驻进度组件、或某个后台任务
    /// 也想听进度），旧页销毁就会把新监听者的回调一起抹掉，界面静默停止刷新。
    /// 现在靠 `activeOwner` 比对：只摘自己挂的那份，别人的回调不动。
    private static weak var activeOwner: RecoveryViewController?

    private func installStateHandler() {
        RecoveryViewController.activeOwner = self
        IOSPanelCache.shared.onState = { [weak self] state in
            // 被替换掉的旧闭包可能还在队列里，确认自己仍是宿主再渲染。
            guard let self = self, RecoveryViewController.activeOwner === self else { return }
            self.render(state)
        }
    }

    private func detachStateHandler() {
        guard RecoveryViewController.activeOwner === self else { return }
        RecoveryViewController.activeOwner = nil
        IOSPanelCache.shared.onState = nil
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

        let logo = UIImageView(image: Self.appIcon())
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 80).isActive = true
        // 高度用 750 而不是 required：横屏 + 超大字号时欢迎区只剩不到 100pt，
        // 80pt 的死高度会把护栏逼破；允许等比缩图是比「压到 toolbar 上」更好的降级。
        let logoHeight = logo.heightAnchor.constraint(equalToConstant: 80)
        logoHeight.priority = .defaultHigh
        logoHeight.isActive = true

        let title = UILabel()
        title.text = IOSStrings.recoveryTitle
        title.font = Self.scaledFont(size: 28, weight: .bold, textStyle: .title1)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true

        let subtitle = UILabel()
        subtitle.text = IOSStrings.recoverySubtitle
        subtitle.font = Self.scaledFont(size: 16, weight: .regular, textStyle: .body)
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
        // 添加顺序即层级：toolbar → welcomeRegion（透明、不可交互）→ welcomeGroup → footerStack。
        // 这里只加一次 welcomeGroup；以前 buildUI 顶部还有一次 addSubview，
        // 同一个视图被加两遍 UIKit 会把后加的挪到最上层（不报错），读代码却像有两个欢迎区。
        view.addSubview(welcomeGroup)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: guide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // 底栏贴底、左右留 24（与安卓 footer padding 一致），再叠加安全区：
            // 横屏左右安全区 47pt，只留 24 会让底栏压进圆角。
            footerStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            footerStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            footerStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            // 参考系左右也跟安全区：横屏左右安全区 47pt，写死 view 会让
            // welcomeGroup 的 24pt 内边距起点落在圆角/刘海里，卡片被切角。
            welcomeRegion.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            welcomeRegion.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            // 参考系 = toolbar 下沿 到 底栏上沿。
            welcomeRegion.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            welcomeRegion.bottomAnchor.constraint(equalTo: footerStack.topAnchor)
        ])
        // 60% 屏高上限只能给 defaultHigh：横屏 + 进度条 + 三行错误文案时，
        // footer 内容约 305pt 而 60% 只有 234pt，required 上限会把差值强行从标签身上扣，
        // 最后 numberOfLines = 0 的标签被硬裁（错误文案直接消失）。
        // 降到 750 后超出的部分转成「压过上限」，由标签的压缩优先级决定牺牲谁。
        let footerLimit = footerStack.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6)
        footerLimit.priority = .defaultHigh
        footerLimit.isActive = true

        // 欢迎区左右跟参考系的安全区走：横屏左右安全区有 47pt，
        // 写死 24 会让卡片压进刘海/圆角区。
        NSLayoutConstraint.activate([
            welcomeGroup.leadingAnchor.constraint(equalTo: welcomeRegion.leadingAnchor, constant: 24),
            welcomeGroup.trailingAnchor.constraint(equalTo: welcomeRegion.trailingAnchor, constant: -24)
        ])

        // 「居中」与「不越界」必须拆成不同优先级，否则横屏必炸：
        // welcomeGroup 自身最小高度是 16+80+20+4+16 = 136pt，
        // iPhone 14 横屏（844x390）里参考系只有约 112pt（更常见是 80 上下），
        // 减掉 8+8 护栏只剩 96pt。三条都 required 时居中与护栏互相打架，
        // 控制台报 unsatisfiable，界面上 logo 压 toolbar 或欢迎区被裁。
        // 现在：护栏 999（越界是最后手段，但允许被打破）、居中 750（先放弃居中）、
        // logo 高度 750（再退一步允许缩图）——空间不足时先偏移再缩图，不炸约束。
        let center = welcomeGroup.centerYAnchor.constraint(equalTo: welcomeRegion.centerYAnchor)
        center.priority = .defaultHigh
        let topGuard = welcomeGroup.topAnchor.constraint(greaterThanOrEqualTo: welcomeRegion.topAnchor,
                                                        constant: 8)
        topGuard.priority = UILayoutPriority(999)
        let bottomGuard = welcomeGroup.bottomAnchor.constraint(lessThanOrEqualTo: welcomeRegion.bottomAnchor,
                                                              constant: -8)
        bottomGuard.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([center, topGuard, bottomGuard])
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
        // 上下各 14（不是 8）：14pt 字号 + 8pt padding 只有约 33pt 高，
        // 低于 44pt 最小点击区，横屏单手点「版本与更新」经常点空。
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = Self.scaledFont(size: 14, weight: .medium, textStyle: .subheadline)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// MD3 filled 按钮：高度 52、圆角 22（近胶囊）、整宽。
    private func styleFilledButton(_ button: UIButton, title: String, action: Selector) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = Self.buttonRadius
        config.baseBackgroundColor = .tintColor
        // 白色是刻意选的：MD3 的 onPrimary 在 iOS 上没有对应语义槽，
        // 系统也没有「filled 按钮前景色」这种 token。tint 已经是品牌蓝，
        // 白字在浅色/深色下都还能读，所以保留 .white 不跟随 .label。
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = Self.scaledFont(size: 16, weight: .semibold, textStyle: .headline)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        // 52 是设计高度，同时兼作最小点击区（>= 44）。用 >= 而不是 ==：
        // 超大字号下标题换行时按钮需要能长高，写死等号会把文字裁掉。
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight).isActive = true
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
            out.font = Self.scaledFont(size: 16, weight: .semibold, textStyle: .headline)
            return out
        }
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight).isActive = true
    }

    /// 按字号 + 文本样式做 Dynamic Type 缩放。
    ///
    /// `.systemFont(ofSize:)` 配 `adjustsFontForContentSizeCategory = true` 是无效组合：
    /// 那个属性只对 `UIFontMetrics` 缩放出来的字体生效，固定字号永远不放大。
    /// 之前只有 bytesLabel 用 preferredFont，大字号下它会比状态标题还大（倒挂）。
    private static func scaledFont(size: CGFloat, weight: UIFont.Weight,
                                   textStyle: UIFont.TextStyle) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    private func makeResourceCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = Self.cardRadius
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        // 状态字段本身就是卡片标题（安卓同一份文案，不出现两处状态）。
        // 状态行允许 2 行 + 省略号：横屏空间不够时宁可看到「面板初始化（进度42…」
        // 也不要整块被裁。压缩阻力抬到 999，让 Auto Layout 优先去压别的东西。
        statusLabel.font = Self.scaledFont(size: 20, weight: .bold, textStyle: .title3)
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)

        errorLabel.font = Self.scaledFont(size: 16, weight: .regular, textStyle: .body)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
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

        // bytesLabel 一直用 preferredFont，是这里唯一会随字号变的字体；
        // 状态/错误改成 UIFontMetrics 缩放后四个字号重新回到同一比例，不再倒挂。
        bytesLabel.font = .preferredFont(forTextStyle: .footnote)
        bytesLabel.textColor = .secondaryLabel
        bytesLabel.numberOfLines = 0
        bytesLabel.adjustsFontForContentSizeCategory = true
        // 字节行是附加信息，空间不足时让它先被压缩（defaultLow）。
        bytesLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

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
        cacheRefreshGeneration += 1
        let generation = cacheRefreshGeneration
        IOSPanelCache.shared.refresh { [weak self] state in
            guard let self = self, self.cacheRefreshGeneration == generation else { return }
            if !self.checkedCacheRefresh, !state.busy {
                self.checkedCacheRefresh = true
                // 升级后的欢迎页不能直接放行旧网页；下载期间显示真实进度，账号不动。
                if state.ready, IOSPanelCache.shared.needsRefresh() {
                    self.render(IOSPanelCache.State(phase: .preparing))
                    IOSPanelCache.shared.initialize(force: false) { [weak self] next in
                        self?.render(next)
                    }
                    return
                }
            }
            self.render(state)
        }
    }

    private func render(_ state: IOSPanelCache.State) {
        cacheState = state
        let busy = state.busy
        let ready = state.ready
        // 文案/按钮的「可以用」语义统一走 canEnter（含「失败但旧快照可用」），
        // 而 ready 只用于「这次初始化成功了」相关的判断（如按钮文案「重新初始化」）。
        let usable = state.canEnter

        // 百分比一律走 state.progress（以「已完成文件数」为主），
        // 不再自己拿 done/total 算——Content-Length 在 CDN 压缩时不可信，
        // 真机上曾因此卡在 90% 不动。
        if state.phase == .downloading {
            let percent = max(0, min(100, Int(state.progress * 100)))
            statusLabel.text = String(format: IOSStrings.recoveryStatusProgress, percent)
        } else if usable {
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
            // ready 时把「缺了 N 个可选资源」说出来：State.skipped 的注释一直承诺这条提示，
            // 但之前没有任何界面读它，用户只看到「已就绪」，缺图标/清单时毫无线索。
            if usable, !state.skipped.isEmpty {
                bytesLabel.text = IOSStrings.recoverySkippedHint(state.skipped.count)
            } else {
                bytesLabel.text = usable ? IOSStrings.recoveryReadyHint : ""
            }
        }
        bytesLabel.isHidden = (bytesLabel.text ?? "").isEmpty

        progressBar.isHidden = !busy
        progressBar.progress = busy ? Float(state.progress) : 0

        let message = state.error.isEmpty ? reasonMessage() : initErrorMessage(state.error)
        errorLabel.text = message
        errorCard.isHidden = message.isEmpty
        // 原始错误码要留进诊断日志（界面只给翻译后的文案）。
        // 只在码变化时写一行：render 被进度推送高频调用，无脑写会把 512KB 的
        // 日志预算几分钟内刷干净，正好把出问题那一刻的上下文挤掉。
        if !state.error.isEmpty, state.error != lastLoggedErrorCode {
            lastLoggedErrorCode = state.error
            IOSDiagnostics.shared.log("recovery: 初始化失败 code=\(state.error)")
        } else if state.error.isEmpty {
            lastLoggedErrorCode = nil
        }

        // 初始化 / 取消互斥：只在真正下载中允许取消。
        let cancellable = busy
        initializeButton.isHidden = cancellable
        cancelButton.isHidden = !cancellable
        initializeButton.isEnabled = !busy
        var config = initializeButton.configuration
        // 「重新初始化」看的是磁盘上有没有快照（usable），而不是这次初始化成不成功：
        // 失败但有旧快照时，用户要做的正是「再初始化一次」。
        config?.title = usable ? IOSStrings.recoveryReinitialize : IOSStrings.recoveryInitialize
        initializeButton.configuration = config

        // 按钮只认「能不能进」，不认「这次初始化是否成功」：
        // 初始化失败时磁盘上的旧快照往往完好、能离线打开，此时仍应允许进入；
        // 而 `state.ready` 被 UpdateService/更新面板用来判断强制更新成败，不能在这里放宽。
        enterButton.isEnabled = state.canEnter && !busy
    }

    private func reasonMessage() -> String {
        switch reason {
        case "": return ""
        // 现在真正会被写进 BootHealth 的只有这三个：
        // load_failed（showError）、resources（fallbackToNetwork）、unfinished（启动超时）。
        case "load_failed": return IOSStrings.recoveryReasonLoadFailed
        case "resources": return IOSStrings.recoveryReasonResources
        case "unfinished": return IOSStrings.recoveryReasonUnfinished
        case "renderer": return IOSStrings.recoveryReasonRenderer
        // 以下三个是安卓遗留的 BootHealth 原因码，iOS 现在不再产生。
        // 保留是为了兼容旧版本写进 UserDefaults 的记录（用户升级后第一次启动仍可能读到），
        // 别删：删了旧记录会落到 default 分支，变成一句含糊的「上次未能正常打开」。
        case "unsafe": return IOSStrings.recoveryReasonUnsafe
        case "ready_timeout": return IOSStrings.recoveryReasonTimeout
        case "engine", "webview": return IOSStrings.recoveryReasonEngine
        default: return IOSStrings.recoveryReasonGeneric
        }
    }

    /// 错误码 → 用户能看懂的话。
    ///
    /// 以前直接把内部码拼在「资源初始化失败。」后面，用户看到的是
    /// 「资源初始化失败。panel_download_failed」——既没解释也没下一步。
    /// 原始码不止会进 IOSDiagnostics（`render` 里已有 `state.error` 的落盘日志），
    /// 所以这里只负责翻译，不再重复写一遍。
    private func initErrorMessage(_ code: String) -> String {
        switch code {
        case "panel_download_failed":
            return IOSStrings.recoveryInitErrorDownload
        case "panel_required_missing":
            return IOSStrings.recoveryInitErrorMissing
        case "panel_cache_cancelled":
            return IOSStrings.recoveryInitErrorCancelled
        case "panel_write_failed":
            return IOSStrings.recoveryInitErrorWrite
        case "panel_commit_failed":
            return IOSStrings.recoveryInitErrorCommit
        case "panel_resource_url_invalid":
            return IOSStrings.recoveryInitErrorUrl
        case "app_group_unavailable":
            return IOSStrings.recoveryInitErrorAppGroup
        default:
            return IOSStrings.recoveryInitErrorGeneric
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        return formatter.string(fromByteCount: max(0, bytes))
    }

    // MARK: - 动作

    @objc private func initializeTapped() {
        cacheRefreshGeneration += 1
        initializeButton.isEnabled = false
        IOSPanelCache.shared.initialize(force: true) { [weak self] state in
            self?.render(state)
        }
    }

    @objc private func cancelTapped() {
        cacheRefreshGeneration += 1
        IOSPanelCache.shared.cancel { [weak self] state in
            self?.render(state)
        }
    }

    @objc private func enterTapped() {
        // 守卫必须与按钮的 isEnabled 同判据（state.canEnter）。
        // 用 ready 会让「初始化失败但磁盘上有旧快照」时按钮亮着、点下去静默无效——
        // 比灰着更糟，用户会以为 App 坏了。
        guard cacheState.canEnter else { return }
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
