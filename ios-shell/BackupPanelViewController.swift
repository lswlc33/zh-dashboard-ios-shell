import UIKit
import UniformTypeIdentifiers

// 「备份与迁移」独立页。对照安卓 RecoveryUi 的备份弹窗做成整页，
// 与隔壁 UpdatePanelViewController 同一套外观（insetGrouped 表格 + 分节标题）。
//
// 为什么原生做而不是让网页做：面板进不去的时候（资源坏了、白屏、壳更新后壳与网页不匹配）
// 网页自己也跑不起来，这份备份是用户**最后的回退通道**。所以这里不碰 WebView，
// 不读网页状态，只跟 IOSStore 的一份加密存档打交道。
//
// 协议与安卓 AccountBackupService / 网页 domain-migration.js 完全一致，
// 三端可以互相导出/导入：新格式 [{token,userid}]，旧格式 {token,userId}。
final class BackupPanelViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable {
        case active, accounts, tools
        var title: String {
            switch self {
            case .active: return IOSStrings.backupSectionActive
            case .accounts: return IOSStrings.backupSectionAccounts
            case .tools: return IOSStrings.backupSectionTools
            }
        }
        var footer: String? {
            // 说明只挂在「本地账号」下面一次：放在页顶会挤掉真正要看的内容。
            self == .accounts ? IOSStrings.backupHint : nil
        }
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let store = IOSStore.shared
    /// 当前存档摘要。nil = 还没读出来（首次读盘可能因 Keychain 冷启而慢一拍）。
    private var snapshot: AccountBackup.Snapshot?
    private var loadError: String?
    private var busy = false
    private var closed = false
    /// 每轮读取/操作一个代号，避免旧回执覆盖新状态（与恢复页同一套做法）。
    private var generation = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = IOSStrings.recoveryBackupTitle
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: IOSStrings.confirm, style: .done, target: self, action: #selector(dismissSelf))

        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 从剪贴板回来（系统粘贴授权框）或分享页回来后，状态可能已经变了。
        if !busy { reload() }
    }

    @objc private func dismissSelf() {
        guard !busy else { return }
        dismiss(animated: true)
    }

    // MARK: - 数据

    private func reload() {
        generation += 1
        let id = generation
        store.snapshot { [weak self] value in
            guard let self = self, !self.closed, self.generation == id else { return }
            // 读盘失败（readError != nil）时 IOSStore 会把内存档清空；
            // AccountBackup.snapshot 会把这种情况标成 storageBroken 而不是「没有账号」。
            let summary = AccountBackup.snapshot(values: value.values, revision: value.revision,
                                                 readError: value.readError)
            self.snapshot = summary
            self.loadError = value.readError
            self.table.reloadData()
        }
    }

    /// 提交一次恢复。`expectedRevision` 让「预览后存档被别人改过」直接失败而不是覆盖。
    private func apply(_ plan: AccountBackup.Plan, baseRevision: Int, completion: @escaping (Bool, String?) -> Void) {
        store.commit(["puts": plan.puts, "removes": plan.removes], expectedRevision: baseRevision) { result, _ in
            if (result["ok"] as? Bool) == true { completion(true, nil); return }
            let reason = result["reason"] as? String ?? ""
            // IOSStore 的条件提交用 "stale" 区分「版本变了」与真正的写盘失败。
            completion(false, reason == "stale" ? IOSStrings.backupStale : IOSStrings.backupFailed)
        }
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        // 账号数放标题里：用户一进来就知道本地有几个能备份的账号。
        if section == .accounts, let summary = snapshot, !summary.accounts.isEmpty {
            return String(format: IOSStrings.backupAccountCount, summary.accounts.count)
        }
        return section.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        guard section == .accounts else { return nil }
        if busy { return IOSStrings.backupProcessing }
        return section.footer
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .active: return rows(for: .active).count
        case .accounts:
            guard let snapshot = snapshot else { return 1 }
            return max(1, snapshot.accounts.count)
        case .tools: return rows(for: .tools).count
        }
    }

    private func rows(for section: Section) -> [(String, String)] {
        switch section {
        case .active:
            guard let summary = snapshot else { return [(IOSStrings.backupAccountLoading, "")] }
            let hasAccount = !summary.activeID.isEmpty
            let uid = hasAccount && !summary.activeUserID.isEmpty ? summary.activeUserID : IOSStrings.backupValueNone
            // 默认只露头尾各几位：整条 token 很长，铺在表格里既看不全也不安全；
            // 要核对或复制时点「显示凭据」进可选中文本页。
            let masked = hasAccount && !summary.activeToken.isEmpty
                ? Self.masked(summary.activeToken) : IOSStrings.backupValueNone
            var out: [(String, String)] = [
                (IOSStrings.backupUserIDLabel, hasAccount ? uid : IOSStrings.backupActiveNone),
                (IOSStrings.backupTokenLabel, masked)
            ]
            if hasAccount && !summary.activeToken.isEmpty {
                out.append((IOSStrings.backupShowToken, ""))
                out.append((IOSStrings.backupCopyToken, ""))
            }
            return out
        case .accounts:
            return []
        case .tools:
            return [
                (IOSStrings.backupCopyAll, ""),
                (IOSStrings.backupPasteRestore, ""),
                (IOSStrings.backupManualInput, "")
            ]
        }
    }

    /// 掩码规则：短于 16 位就整体遮掉（露头尾也等于泄露一半），长 token 露前 6 后 4。
    static func masked(_ token: String) -> String {
        guard token.count >= 16 else { return "••••" }
        return String(token.prefix(6)) + "……" + String(token.suffix(4))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.selectionStyle = .none
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .accounts:
            guard let summary = snapshot else {
                cell.textLabel?.text = IOSStrings.backupAccountLoading
                cell.textLabel?.textColor = .secondaryLabel
                return cell
            }
            if summary.accounts.isEmpty {
                cell.textLabel?.text = IOSStrings.backupAccountEmpty
                cell.textLabel?.font = .preferredFont(forTextStyle: .footnote)
                cell.textLabel?.textColor = .secondaryLabel
                cell.textLabel?.numberOfLines = 0
                return cell
            }
            guard summary.accounts.indices.contains(indexPath.row) else { return cell }
            let account = summary.accounts[indexPath.row]
            let current = account.id == summary.activeID
            cell.textLabel?.text = account.userid.isEmpty ? account.id : account.userid
            cell.textLabel?.numberOfLines = 0
            cell.detailTextLabel?.text = current ? IOSStrings.backupActiveLabel : ""
            cell.accessoryType = current ? .checkmark : .none
            cell.accessibilityValue = current ? IOSStrings.backupActiveLabel : nil
            return cell
        case .active:
            let items = rows(for: .active)
            guard items.indices.contains(indexPath.row) else { return cell }
            let item = items[indexPath.row]
            cell.textLabel?.text = item.0
            cell.detailTextLabel?.text = item.1
            // 动作行（没有值的那两行）用主题色，和更新页的操作段一致。
            if item.1.isEmpty && indexPath.row >= 2 {
                cell.textLabel?.textColor = .tintColor
                cell.selectionStyle = .default
            }
            return cell
        case .tools:
            let items = rows(for: .tools)
            guard items.indices.contains(indexPath.row) else { return cell }
            cell.textLabel?.text = items[indexPath.row].0
            cell.textLabel?.textColor = .tintColor
            cell.selectionStyle = .default
            return cell
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy, !closed, view.window != nil else { return }
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .active:
            guard let summary = snapshot, !summary.activeToken.isEmpty else { return }
            switch indexPath.row {
            case 2: presentToken(summary: summary)
            case 3: copyToken(summary)
            default: break
            }
        case .tools:
            switch indexPath.row {
            case 0: copyAll()
            case 1: pasteRestore()
            case 2: manualInput()
            default: break
            }
        case .accounts:
            break
        }
    }

    // MARK: - 复制

    /// 只写不读：options 里的 localOnly 禁止通用剪贴板把凭据同步到用户的其他设备。
    private func writeClipboard(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }

    private func copyAll() {
        guard let summary = snapshot else { return }
        do {
            let result = try AccountBackup.exportText(summary)
            writeClipboard(result.text)
            IOSDiagnostics.shared.log("账号备份：已复制 \(result.count) 个账号")
            presentMessage(IOSStrings.backupCopyAll, String(format: IOSStrings.backupCopiedCount, result.count))
        } catch {
            presentMessage(IOSStrings.backupCopyAll, Self.message(for: error))
        }
    }

    private func copyToken(_ summary: AccountBackup.Snapshot) {
        writeClipboard(summary.activeToken)
        IOSDiagnostics.shared.log("账号备份：已复制当前账号凭据")
        presentMessage(IOSStrings.backupCopyToken, IOSStrings.backupCopiedToken)
    }

    /// 完整 token 放在一次性的可选中文本页里：既是「显示」也是「手动复制」的出口。
    private func presentToken(summary: AccountBackup.Snapshot) {
        let controller = BackupTextSheetViewController(
            title: IOSStrings.backupTokenLabel,
            hint: IOSStrings.backupCopyToken,
            text: summary.activeToken,
            editable: false)
        controller.onCopy = { [weak self, weak controller] text in
            guard let self = self else { return }
            self.writeClipboard(text)
            controller?.dismiss(animated: true) {
                self.presentMessage(IOSStrings.backupCopyToken, IOSStrings.backupCopiedToClipboard)
            }
        }
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // MARK: - 恢复

    /// 读剪贴板只在用户点了这一行之后发生；iOS 还可能再弹一次系统粘贴授权。
    private func pasteRestore() {
        guard !busy else { return }
        guard let text = UIPasteboard.general.string else {
            presentMessage(IOSStrings.backupPasteRestore, IOSStrings.backupClipboardEmpty)
            return
        }
        guard !text.isEmpty else {
            presentMessage(IOSStrings.backupPasteRestore, IOSStrings.backupClipboardEmpty)
            return
        }
        preview(text)
    }

    private func manualInput() {
        guard !busy else { return }
        let controller = BackupTextSheetViewController(
            title: IOSStrings.backupManualTitle,
            hint: IOSStrings.backupManualHint,
            text: "",
            editable: true)
        controller.placeholder = IOSStrings.backupManualPlaceholder
        controller.confirmTitle = IOSStrings.backupPreview
        controller.onConfirm = { [weak self, weak controller] text in
            guard let self = self else { return }
            controller?.dismiss(animated: true) {
                self.preview(text)
            }
        }
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func preview(_ text: String) {
        guard let summary = snapshot else {
            presentMessage(IOSStrings.recoveryBackupTitle, IOSStrings.backupAccountLoading)
            return
        }
        busy = true
        table.reloadData()
        generation += 1
        let id = generation
        // 解析放后台：这段可能跑在旧机型上，JSONSerialization 的失败路径也不该卡住首帧。
        // 两件事一起做：解码文本 + 对着**当前**存档算差异，产出的预览自带基线版本号。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pending: Result<(AccountBackup.Preview, AccountBackup.Snapshot), Error>
            do {
                let entries = try AccountBackup.decode(text)
                pending = .success((try AccountBackup.preview(entries, snapshot: summary), summary))
            } catch {
                pending = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self = self, !self.closed, self.generation == id else { return }
                self.busy = false
                self.table.reloadData()
                switch pending {
                case let .success((preview, base)):
                    self.showPreview(preview, base: base)
                case let .failure(error):
                    self.presentMessage(IOSStrings.backupRestoreTitle, Self.message(for: error))
                }
            }
        }
    }

    private func showPreview(_ preview: AccountBackup.Preview, base: AccountBackup.Snapshot) {
        let details = String(format: IOSStrings.backupRestoreDetails, preview.userids.count,
                             preview.userids.joined(separator: "\n"), preview.added, preview.unchanged)
        let alert = UIAlertController(title: IOSStrings.backupRestoreTitle, message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.backupCancel, style: .cancel))
        if preview.requiresPolicy {
            // 同 ID 不同凭据必须让用户明说，不能替他挑一个：挑错了就是拿旧 token 覆盖新 token。
            let conflicts = String(format: IOSStrings.backupRestoreConflicts,
                                   preview.replacementUserids.joined(separator: "\n"))
            alert.message = details + "\n\n" + conflicts
            alert.addAction(UIAlertAction(title: IOSStrings.backupKeepExisting, style: .default) { [weak self] _ in
                self?.commit(preview, base: base, policy: .keepExisting)
            })
            alert.addAction(UIAlertAction(title: IOSStrings.backupReplaceExisting, style: .destructive) { [weak self] _ in
                self?.commit(preview, base: base, policy: .replaceExisting)
            })
        } else {
            alert.addAction(UIAlertAction(title: IOSStrings.backupApply, style: .default) { [weak self] _ in
                self?.commit(preview, base: base, policy: nil)
            })
        }
        present(alert, animated: true)
    }

    private func commit(_ preview: AccountBackup.Preview, base: AccountBackup.Snapshot,
                        policy: AccountBackup.Policy?) {
        guard !busy else { return }
        busy = true
        table.reloadData()
        do {
            let plan = try AccountBackup.plan(preview, policy: policy, snapshot: base)
            // 当前账号的凭据被换掉时，网页的后台任务镜像（钥匙串里那份）还是旧 token，
            // 必须让用户知道要重新授权，否则签到会静默失败。
            let activeReplaced = policy == .replaceExisting && preview.replacementUserids.contains(base.activeUserID)
            apply(plan, baseRevision: preview.baseRevision) { [weak self] saved, message in
                guard let self = self else { return }
                self.busy = false
                IOSDiagnostics.shared.log("账号备份：恢复\(saved ? "已保存" : "未完成")")
                // 无论成败都重读：失败时也可能只是别人刚写过，界面要反映真实版本。
                self.reload()
                guard saved else {
                    self.presentMessage(IOSStrings.backupRestoreTitle, message ?? IOSStrings.backupFailed)
                    return
                }
                self.presentMessage(IOSStrings.backupRestoreTitle,
                                    activeReplaced ? IOSStrings.backupRestoredTokenChanged : IOSStrings.backupRestored)
            }
        } catch {
            busy = false
            table.reloadData()
            presentMessage(IOSStrings.backupRestoreTitle, Self.message(for: error))
        }
    }

    /// 失败分类 -> 用户可读文案。原始错误码不进界面，只写诊断日志。
    private static func message(for error: Error) -> String {
        guard let failure = error as? AccountBackup.Failure else { return IOSStrings.backupFailed }
        switch failure {
        case .invalidInput: return IOSStrings.backupInvalidInput
        case .tooLarge: return IOSStrings.backupTooLarge
        case .accountCount: return IOSStrings.backupInvalidInput
        case .tokenOwnerConflict: return IOSStrings.backupOwnerConflict
        case .missingUserID: return IOSStrings.backupMissingUserID
        case .storageBroken: return IOSStrings.backupStorageBroken
        case .poolBroken: return IOSStrings.backupPoolBroken
        case .capacity: return IOSStrings.backupAccountLimit
        case .stale: return IOSStrings.backupStale
        case .policyRequired: return IOSStrings.backupPolicyRequired
        }
    }

    private func presentMessage(_ title: String, _ message: String) {
        // 已经有一个弹窗时不要硬 present：UIKit 会刷 already presenting 并静默丢掉这次提示。
        guard !closed, presentedViewController == nil else {
            IOSDiagnostics.shared.log("账号备份：有弹窗在前，提示未展示")
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }

    deinit { closed = true }
}

// 一个「一次性文本框」：既用于展示完整 token（可选中复制），也用于手动粘贴备份。
// 单独成类是因为两处除了 editable 与按钮文案之外完全一样，复制粘贴一份会分叉。
final class BackupTextSheetViewController: UIViewController, UITextViewDelegate {
    private let headingHint: String
    private let text: String
    private let editable: Bool
    private let textView = UITextView()

    var placeholder: String?
    var confirmTitle: String?
    /// 用户点了「复制」（只读态）。
    var onCopy: ((String) -> Void)?
    /// 用户点了确认按钮（可编辑态），参数是当前文本。
    var onConfirm: ((String) -> Void)?

    init(title: String, hint: String, text: String, editable: Bool) {
        self.headingHint = hint
        self.text = text
        self.editable = editable
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: IOSStrings.backupClose, style: .done, target: self, action: #selector(close))

        // 提示语放顶部：用户点「显示凭据」时最需要先看到「别分享」。
        let hint = UILabel()
        hint.text = headingHint
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        textView.text = text
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.delegate = self
        // 凭据不参与系统智能填充/键盘预测，减少误上传到云输入法候选词的概率。
        textView.textContentType = .oneTimeCode
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.backgroundColor = .secondarySystemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        view.addSubview(textView)

        let actions = UIStackView()
        actions.axis = .vertical
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)

        if editable {
            let confirm = makeFilledButton(title: confirmTitle ?? IOSStrings.backupPreview,
                                           action: #selector(confirmTapped))
            actions.addArrangedSubview(confirm)
        } else {
            let copy = makeFilledButton(title: IOSStrings.backupCopyToken, action: #selector(copyTapped))
            actions.addArrangedSubview(copy)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            textView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            actions.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 12),
            actions.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            // 文本框吃掉中间所有剩余高度：横屏和大字号下按钮仍然可见。
            textView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12)
        ])
        updatePlaceholder()
    }

    private func makeFilledButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .large
        button.configuration = config
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func updatePlaceholder() {
        // UITextView 没有内建 placeholder；可编辑态用灰色提示文本顶替，输入后就清掉。
        guard editable, text.isEmpty else { return }
        let empty = textView.text.isEmpty
        textView.textColor = empty ? .secondaryLabel : .label
        if empty, let placeholder = placeholder { textView.text = placeholder }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard editable, let placeholder = placeholder, textView.text == placeholder else { return }
        textView.text = ""
        textView.textColor = .label
    }

    private var currentText: String {
        guard editable else { return text }
        if let placeholder = placeholder, textView.text == placeholder { return "" }
        return textView.text
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func copyTapped() {
        onCopy?(currentText)
    }

    @objc private func confirmTapped() {
        onConfirm?(currentText)
    }
}
