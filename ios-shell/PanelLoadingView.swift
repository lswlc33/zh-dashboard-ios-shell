import UIKit

// 远程 HTML 到达前也有首屏；不依赖网络、网页脚本或安全区 env()。
final class PanelLoadingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        clipsToBounds = true
        let title = UILabel()
        title.text = "正在加载面板…"
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .secondaryLabel
        let status = UIStackView(arrangedSubviews: [spinner, title])
        status.spacing = 10
        let content = UIStackView(arrangedSubviews: [status, block(height: 150)])
        content.axis = .vertical
        content.spacing = 16
        let actions = UIStackView(arrangedSubviews: (0..<4).map { _ in block(height: 68) })
        actions.spacing = 12
        actions.distribution = .fillEqually
        content.addArrangedSubview(actions)
        let details = UIStackView(arrangedSubviews: (0..<2).map { _ in block(height: 90) })
        details.spacing = 12
        details.distribution = .fillEqually
        content.addArrangedSubview(details)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
        spinner.startAnimating()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading(_ active: Bool) {
        isHidden = !active
        if active { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func block(height: CGFloat) -> UIView {
        let placeholder = UIView()
        placeholder.backgroundColor = .tertiarySystemFill
        placeholder.layer.cornerRadius = 20
        placeholder.heightAnchor.constraint(equalToConstant: height).isActive = true
        placeholder.accessibilityElementsHidden = true
        return placeholder
    }
}
