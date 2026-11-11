import UIKit

// 白屏诊断页：显示诊断日志全文，并提供「复制」「分享」「重试」。
// 用户不需要连电脑，点分享就能把日志发出来。
final class DiagnosticsViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "面板诊断"

        let header = UILabel()
        header.text = "面板加载异常。请把下面的日志分享给开发者。"
        header.font = .preferredFont(forTextStyle: .subheadline)
        header.textColor = .secondaryLabel
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = IOSDiagnostics.shared.read()
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        let copy = makeButton("复制日志", filled: true) { [weak self] in
            UIPasteboard.general.string = self?.textView.text
            self?.toast("已复制")
        }
        let share = makeButton("分享日志", filled: false) { [weak self] in
            guard let self = self else { return }
            let activity = UIActivityViewController(activityItems: [self.textView.text ?? ""],
                                                    applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY,
                                            width: 1, height: 1)
            }
            self.present(activity, animated: true)
        }
        let retry = makeButton("重试", filled: false) { [weak self] in
            self?.dismiss(animated: true)
        }

        let buttons = UIStackView(arrangedSubviews: [copy, share, retry])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])
    }

    private func makeButton(_ title: String, filled: Bool,
                            action: @escaping () -> Void) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = 20
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func toast(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { alert.dismiss(animated: true) }
    }
}
