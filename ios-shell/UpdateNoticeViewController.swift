import UIKit

// 「发现新版本」全屏提示。App 内不提供下载或安装入口：
// 只把当前版本、新版版本和更新说明摆给用户看，按「我知道了」结束。
// 为什么不用 UIAlertController：需求是整屏提示且只有一个确认动作，
// 弹窗在 iPad 会变成 popover、在大屏手机上又显得太轻，整页更明确。
final class UpdateNoticeViewController: UIViewController {
    private let release: IOSRelease
    private let installedVersion: String
    private let installedBuild: String

    init(release: IOSRelease, installedVersion: String, installedBuild: String) {
        self.release = release
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        // 下滑关闭等于「我知道了」，但整页提示不该能被误拖走；只认按钮。
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
    }

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // 语义是「有新版本可用」，不是「点这里下载」——App 内不提供下载入口，
        // 用 arrow.down.circle 会和文案（去外部自签安装）直接矛盾。
        let icon = UIImageView(image: UIImage(systemName: "sparkles"))
        // 跟随全局 tint（品牌色），不写死 systemBlue：主题/深色模式下也不该固定一种蓝。
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        // 纯装饰，别让 VoiceOver 单独读一个图标名。
        icon.isAccessibilityElement = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = UILabel()
        title.text = IOSStrings.updateAppTitle
        // 与 RecoveryView 的整页标题同层级（28pt bold + 缩放），
        // 原来用 .title2 regular，两个「整页说明」看起来完全不是一套。
        title.font = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let message = UILabel()
        message.text = String(format: IOSStrings.updateNewVersionMessage, installedVersion,
                              installedBuild, release.version, release.build)
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        let notes = UILabel()
        notes.text = release.notes
        notes.font = .preferredFont(forTextStyle: .footnote)
        notes.adjustsFontForContentSizeCategory = true
        notes.textColor = .label
        notes.numberOfLines = 0

        let notesCard = UIView()
        notesCard.backgroundColor = .secondarySystemBackground
        notesCard.layer.cornerRadius = 16
        notesCard.translatesAutoresizingMaskIntoConstraints = false
        notes.translatesAutoresizingMaskIntoConstraints = false
        notesCard.addSubview(notes)
        NSLayoutConstraint.activate([
            notes.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 14),
            notes.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -14),
            notes.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 16),
            notes.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -16)
        ])

        // 唯一动作：知道有新版即可。下载与覆盖安装都在 App 外部完成。
        var config = UIButton.Configuration.filled()
        config.title = IOSStrings.updateAcknowledge
        config.cornerStyle = .fixed
        // 与 RecoveryView 的 filled 按钮用同一套几何（圆角 22 / 高度 >= 52 / semibold headline），
        // 原来 .large 圆角 + 写死 52 高度，和别的页面不是一套。
        config.background.cornerRadius = 22
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFontMetrics(forTextStyle: .headline)
                .scaledFont(for: .systemFont(ofSize: 16, weight: .semibold))
            return out
        }
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        // >= 而不是 ==：超大字号下标题换行会被写死高度裁掉。
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        for item in [icon, title, message, notesCard, button] { stack.addArrangedSubview(item) }
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(24, after: notesCard)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }
}