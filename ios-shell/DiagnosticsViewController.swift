import UIKit

// 白屏诊断页：显示诊断日志全文，并提供「复制」「分享」「关闭」。
// 用户不需要连电脑，点分享就能把日志发出来。
final class DiagnosticsViewController: UIViewController {
    private let textView = UITextView()
    private let header = UILabel()
    /// 当前正在显示的 toast。连点「复制」时如果各自 present，
    /// 第二次会被 UIKit 拒掉（already presenting），所以只保留一个并复用它。
    private var toast: UIAlertController?

    /// 「重试」出口。由调用方注入真正的重试动作（Dashboard 传 loadPanel）。
    ///
    /// 以前这个按钮只 `dismiss`，名字叫「重试」却什么都不重试。
    /// 从更新面板打开的诊断页没有可重试的加载流程，那边不设 onRetry，按钮显示为「关闭」。
    var onRetry: (() -> Void)? {
        didSet { syncRetryButtonTitle() }
    }

    /// 第三个按钮（重试/关闭）。标题取决于 `onRetry` 是否已注入，
    /// 而调用方可能在 present 之前才赋值——所以用 syncRetryButtonTitle 统一刷新，
    /// 不依赖「赋值一定早于 viewDidLoad」这个时序假设。
    private let retryButton = UIButton(type: .system)
    /// 日志是否已经读完。正文先是占位文案，读完才替换；复制/分享要等它。
    private var logLoaded = false
    /// 从更新面板「查看诊断日志」手动进来时为 true：只说「最近的运行日志」，
    /// 不要声称「面板加载异常」——那时 App 是好的，文案与场景不符。
    var manualEntry = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = IOSStrings.diagnosticsTitle
        // 从更新面板进来时是包在 UINavigationController 里的，
        // 需要自己给出退出路径；从 Dashboard 以 pageSheet 直接 present 时没有导航栏，
        // 这里挂的按钮不会显示，但第三个「重试/关闭」按钮仍在。
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: IOSStrings.updateDone, style: .done, target: self, action: #selector(closeTapped))

        header.text = manualEntry ? IOSStrings.diagnosticsHeaderManual : IOSStrings.diagnosticsHeader
        header.font = .preferredFont(forTextStyle: .subheadline)
        header.textColor = .secondaryLabel
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        textView.isEditable = false
        // 11pt 低于可读下限，且 .monospacedSystemFont 配 adjustsFontForContentSizeCategory
        // 是无效组合（那个属性只对 UIFontMetrics 缩放出的字体生效）——大字号用户看不了日志。
        textView.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        // 先给一句占位，日志在后台读完再替换：最多 512KB 的同步读放在 viewDidLoad
        // 会让弹窗出现前卡一拍（首帧白屏），而这一页本来就是「白屏时给人看」的。
        textView.text = IOSStrings.diagnosticsEmpty
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        loadLog()

        let copy = makeButton(IOSStrings.diagnosticsCopy, filled: true) { [weak self] in
            guard let self = self else { return }
            // 还没读完（占位文案仍在）时把「复制」当读完后再说：
            // 否则用户复制到的是「（暂无日志）」这一句占位，拿去分享什么都没有。
            guard self.logLoaded else {
                self.showToast(IOSStrings.diagnosticsLoading)
                return
            }
            UIPasteboard.general.string = self.textView.text
            self.showToast(IOSStrings.diagnosticsCopied)
        }
        let share = makeButton(IOSStrings.diagnosticsShare, filled: false) { [weak self] in
            guard let self = self else { return }
            guard self.logLoaded else {
                self.showToast(IOSStrings.diagnosticsLoading)
                return
            }
            // 连点或在 toast 展示期间点：UIKit 会拒绝第二个 present 并静默丢掉分享。
            guard self.presentedViewController == nil, self.view.window != nil else { return }
            let activity = UIActivityViewController(activityItems: [self.textView.text ?? ""],
                                                    applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY,
                                            width: 1, height: 1)
            }
            self.present(activity, animated: true)
        }
        // 第三个按钮：有 onRetry 叫「重试」，没有就是从更新面板进来的只读日志页，叫「关闭」。
        styleSecondaryButton(retryButton) { [weak self] in
            guard let self = self else { return }
            if let retry = self.onRetry {
                // 先关页面再重试：loadPanel 会重新加载 WebView，
                // 诊断页还盖在上面的话用户看不到任何变化。
                self.dismiss(animated: true) { retry() }
            } else {
                self.dismiss(animated: true)
            }
        }
        syncRetryButtonTitle()

        let buttons = UIStackView(arrangedSubviews: [copy, share, retryButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)

        // 水平方向也贴安全区：横屏刘海侧（47pt）和 iPad 圆角会切掉正文与按钮，
        // 而同 App 的其它页（RecoveryView）本来就用安全区，这里不该例外。
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            textView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])
    }

    /// 日志读取放后台，读完回主线程。
    ///
    /// `IOSDiagnostics.read()` 内部是 `queue.sync`，会等正在写的文件句柄关掉，
    /// 最多涉及两份 512KB 文件——在主线程做就是一次可见的卡顿。
    private func loadLog() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = IOSDiagnostics.shared.read()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.textView.text = text
                self.logLoaded = true
                // 回到顶部：轮转后的日志是「旧 + 新」拼接，停在末尾会让人以为开头缺了。
                self.textView.setContentOffset(.zero, animated: false)
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func makeButton(_ title: String, filled: Bool,
                            action: @escaping () -> Void) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = 20
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config)
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.isActive = true
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        height.isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// 给外部持有的按钮套同一套 tonal 样式（重试按钮的标题要能后改，不能走局部 let）。
    private func styleSecondaryButton(_ button: UIButton, action: @escaping () -> Void) {
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .fixed
        config.background.cornerRadius = 20
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        button.configuration = config
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        height.isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    /// `onRetry` 可能在 viewDidLoad 之前或之后注入，两处都要能刷到按钮标题。
    private func syncRetryButtonTitle() {
        guard isViewLoaded else { return }
        var config = retryButton.configuration
        config?.title = onRetry == nil ? IOSStrings.diagnosticsClose : IOSStrings.diagnosticsRetry
        retryButton.configuration = config
    }

    private func showToast(_ text: String) {
        // 已经有一个 toast 在显示就复用：连点不再各自 present（会被 UIKit 拒掉），
        // 也不会出现两个叠在一起同时淡出的画面。
        if let toast = toast, toast.presentingViewController != nil {
            toast.message = text
            toast.view.accessibilityLabel = text
            return
        }
        // 分享面板/别的弹层正开着时不能抢 presentation（会被 UIKit 丢弃），只做播报。
        guard presentedViewController == nil, view.window != nil else {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        toast = alert
        present(alert, animated: true)
        // 1.0 秒对「日志还在读取，请稍候再试。」这类句子太短，VoiceOver 也听不完。
        // 2.5 秒 + 主动播报，普通用户和辅助功能用户都够。
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak alert] in
            guard let alert = alert else { return }
            alert.dismiss(animated: true) {
                if self?.toast === alert { self?.toast = nil }
            }
        }
    }
}
