import UIKit

// 「版本与更新」独立页。对照安卓 RecoveryUi 的版本弹窗，但做成整页：
// 安卓那边是 Dialog，iOS 上整页能容纳更多信息且不会在 iPad 变成 popover。
//
// 内容分四段：
//   1. 四行版本信息（软件 / 面板 / WebView / 最低要求）
//   2. 面板资源（本地快照的构建号、资源数、大小、上次更新时间）
//   3. 软件更新线路（单选，只影响下次更新）
//   4. 操作（检查软件 / 面板更新 / 重新初始化 / 查看诊断日志）
//
// 所有可见文案都走 IOSStrings：这一页以前大段内联中文，
// 和恢复页同一句话会出现两种措辞，文案审计也没法统一改。
final class UpdatePanelViewController: UIViewController,
                                       UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable {
        case versions, resources, line, actions
        var title: String {
            switch self {
            case .versions: return IOSStrings.updateSectionVersions
            case .resources: return IOSStrings.updateSectionResources
            // 线路这一段与恢复页那行标签共用同一个常量，避免两处措辞分叉。
            case .line: return IOSStrings.recoverySoftwareLineLabel
            case .actions: return IOSStrings.updateSectionActions
            }
        }
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var resourceInfo: [String: String] = [:]
    private var checking = false
    private var panelChecking = false
    private var checkTask: Task<Void, Never>?
    private var panelCheckTask: Task<Void, Never>?
    private var checkID = UUID()
    private var panelCheckID = UUID()
    private var resourceLoadID = UUID()
    private var initializeID = UUID()
    private var initializing = false
    private var closed = false
    /// 关闭通知只发一次；展示其他页面不算关闭。
    private var changeNotified = false

    /// 关闭时通知调用方刷新（线路/资源可能变了）。
    var onChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = IOSStrings.recoveryVersionTitle
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: IOSStrings.updateDone, style: .done, target: self, action: #selector(dismissSelf))

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
        // 初始化在途时禁止下滑关闭：formSheet 下滑会打断正在跑的资源下载，
        // 用户看不到进度也回不到这个页面。
        NotificationCenter.default.addObserver(self, selector: #selector(cacheStateChanged),
            name: IOSPanelCache.stateDidChangeNotification, object: IOSPanelCache.shared)
        for name in [UIApplication.didEnterBackgroundNotification, IOSPanelLine.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelChecks), name: name, object: nil)
        }
        syncModalLock()
        loadResourceInfo()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        checkTask?.cancel()
        panelCheckTask?.cancel()
    }

    @objc private func cancelChecks() {
        checkID = UUID(); panelCheckID = UUID()
        checkTask?.cancel(); checkTask = nil
        panelCheckTask?.cancel(); panelCheckTask = nil
        checking = false; panelChecking = false
    }

    @objc private func cacheStateChanged() {
        guard !closed else { return }
        syncModalLock()
        if active && !IOSPanelCache.shared.snapshot().busy { loadResourceInfo() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncModalLock()
        table.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncModalLock()
        loadResourceInfo()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 分享页遮住整个屏幕不算关闭；只取消本页等待，不取消中心的共用检查。
        guard isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent else { return }
        checkTask?.cancel()
        panelCheckTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent else { return }
        closed = true
        checkTask?.cancel()
        panelCheckTask?.cancel()
        checkTask = nil
        panelCheckTask = nil
        notifyChange()
    }

    private var active: Bool {
        !closed && isViewLoaded && view.window != nil && !isBeingDismissed
            && navigationController?.isBeingDismissed != true && !isMovingFromParent
    }

    /// 初始化只在真实终态解锁，不能把准备 / 下载回执当作完成。
    private func syncModalLock() {
        guard !closed, isViewLoaded else { return }
        let busy = initializing || IOSPanelCache.shared.snapshot().busy
        isModalInPresentation = busy
        navigationController?.isModalInPresentation = busy
        navigationItem.rightBarButtonItem?.isEnabled = !busy
    }

    private func notifyChange() {
        guard !changeNotified else { return }
        changeNotified = true
        onChange?()
    }

    @objc private func dismissSelf() {
        guard active, !initializing, !IOSPanelCache.shared.snapshot().busy else { return }
        // onChange 留到真正消失再发，检查等待先取消以拦住晚到的弹窗。
        checkTask?.cancel()
        panelCheckTask?.cancel()
        dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.closed = true
            self.notifyChange()
        }
    }

    // MARK: - 数据

    /// 统计本地快照：只算 `IOSPanelCache.resources` 里列出的文件。
    ///
    /// 以前用 FileManager.enumerator 遍历，它会把 `icons/` 目录本身也返回成一项，
    /// 于是「已下载资源 12 个」紧挨着「资源清单 11 项」，看起来像自相矛盾。
    /// 按清单逐项 attributesOfItem 更准，也顺手把字节数对齐。
    ///
    /// 文件 IO 放后台：目录在 Application Support，走的可能是 encrypted 卷，
    /// 首帧同步扫十几个文件（含 2MB 的 index.html）会让页面停顿一拍。
    private func loadResourceInfo() {
        guard !closed else { return }
        let id = UUID()
        resourceLoadID = id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cache = IOSPanelCache.shared
            let directory = cache.snapshotDirectory()
            let manager = FileManager.default
            var bytes: Int64 = 0
            var count = 0
            if let directory = directory {
                for name in IOSPanelCache.resources {
                    let file = directory.appendingPathComponent(name, isDirectory: false)
                    guard let attributes = try? manager.attributesOfItem(atPath: file.path) else { continue }
                    count += 1
                    bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                }
            }
            let build = cache.snapshotBuild()
            let modified: String
            if let directory = directory,
               let date = try? manager.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                // 不钉 locale 时，非公历区域（佛历/和历）会把这个 pattern 解释成别的历法，
                // 显示出来的年份差几百年。POSIX 保证固定公历 + 固定数字。
                formatter.locale = Locale(identifier: "en_US_POSIX")
                modified = formatter.string(from: date)
            } else {
                modified = IOSStrings.updateValueNone
            }
            let info = [
                "build": build.isEmpty ? IOSStrings.recoveryPanelVersionNone : build,
                "files": String(format: IOSStrings.updateFilesCount, count),
                "size": ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                "updated": modified
            ]
            DispatchQueue.main.async {
                guard let self = self, self.active, self.resourceLoadID == id else { return }
                self.resourceInfo = info
                self.table.reloadData()
            }
        }
    }

    private func appVersionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? IOSStrings.updateValueNone
        let build = info["CFBundleVersion"] as? String ?? IOSStrings.updateValueNone
        return String(format: IOSStrings.updateAppVersionFormat, version, build)
    }

    /// 最低系统从 Info.plist 读。
    /// 以前这里写死 "iOS 15.4"，Package.swift 与 Info.plist 一旦抬高（比如升到 16.0），
    /// 面板上显示的还是一句过期承诺。
    private func minimumIOSLine() -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
        guard let version = value, !version.isEmpty else { return IOSStrings.updateMinimumIOSFallback }
        return String(format: IOSStrings.updateMinimumIOSFormat, version)
    }

    /// 每一段的行数据。行数与内容同源，`numberOfRowsInSection` 直接取 count，
    /// 不再「行数写 4、数组也写 4」两处独立维护（将来只改一处就 index out of range）。
    private func rows(for section: Section) -> [(String, String)] {
        switch section {
        case .versions:
            return [
                (IOSStrings.recoveryAppVersionLabel, appVersionLine()),
                (IOSStrings.recoveryPanelVersionLabel, resourceInfo["build"] ?? IOSStrings.updateValueNone),
                (IOSStrings.recoveryWebviewLabel,
                 String(format: IOSStrings.updateWebviewFormat, UIDevice.current.systemVersion)),
                (IOSStrings.recoveryMinimumLabel, minimumIOSLine())
            ]
        case .resources:
            return [
                (IOSStrings.updateResourceDownloaded, resourceInfo["files"] ?? IOSStrings.updateValueNone),
                (IOSStrings.updateResourceSize, resourceInfo["size"] ?? IOSStrings.updateValueNone),
                (IOSStrings.updateResourceUpdated, resourceInfo["updated"] ?? IOSStrings.updateValueNone),
                (IOSStrings.updateResourceManifest,
                 String(format: IOSStrings.updateManifestCount, IOSPanelCache.resources.count))
            ]
        case .line:
            return [IOSPanelLine.github, IOSPanelLine.cf].map { line in
                (line.displayName, line == IOSPanelLine.current ? IOSStrings.updateCurrentLine : "")
            }
        case .actions:
            return [
                (checking ? IOSStrings.updateChecking : IOSStrings.recoveryUpdate, ""),
                (panelChecking ? IOSStrings.updateChecking : IOSStrings.updatePanelChecking, ""),
                (IOSStrings.updateReinitializeRow, ""),
                (IOSStrings.updateShowDiagnostics, "")
            ]
        }
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        return rows(for: section).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.selectionStyle = .none

        guard let section = Section(rawValue: indexPath.section) else { return cell }
        let items = rows(for: section)
        // 防御：行数与 rows 现在同源，正常不会越界；留着避免以后有人只改一处。
        guard items.indices.contains(indexPath.row) else { return cell }
        cell.textLabel?.text = items[indexPath.row].0
        cell.detailTextLabel?.text = items[indexPath.row].1

        switch section {
        case .versions where indexPath.row < 2:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .line:
            let line = [IOSPanelLine.github, IOSPanelLine.cf][indexPath.row]
            cell.accessoryType = line == IOSPanelLine.current ? .checkmark : .none
            cell.selectionStyle = .default
        case .actions:
            cell.textLabel?.textColor = .tintColor
            cell.selectionStyle = .default
        default:
            break
        }
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard active else { return }
        switch Section(rawValue: indexPath.section) {
        case .versions:
            switch indexPath.row {
            case 0: checkUpdate()
            case 1: checkPanelUpdate()
            default: break
            }
        case .line:
            let lines = [IOSPanelLine.github, IOSPanelLine.cf]
            guard lines.indices.contains(indexPath.row) else { return }
            selectLine(lines[indexPath.row])
        case .actions:
            switch indexPath.row {
            case 0: checkUpdate()
            case 1: checkPanelUpdate()
            case 2: reinitialize()
            case 3: showDiagnostics()
            default: break
            }
        default:
            break
        }
    }

    // MARK: - 动作

    private func selectLine(_ line: IOSPanelLine) {
        guard active, presentedViewController == nil, line != IOSPanelLine.current else { return }
        guard !initializing, !IOSPanelCache.shared.snapshot().busy else {
            presentMessage(IOSStrings.updateLineChangedTitle, IOSStrings.busy)
            return
        }
        let alert = UIAlertController(
            title: IOSStrings.updateLineChangedTitle,
            message: String(format: IOSStrings.recoveryLineChanged, line.displayName),
            preferredStyle: .alert)
        // 取消不写偏好；确认也只影响下次更新，不重载当前面板和账号。
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self] _ in
            guard let self = self, self.active else { return }
            guard !self.initializing, !IOSPanelCache.shared.snapshot().busy else {
                self.presentMessage(IOSStrings.updateLineChangedTitle, IOSStrings.busy)
                return
            }
            // markChosen：选中默认线路时也要落偏好键，否则网页会一直当成「还没选过」。
            IOSPanelLine.markChosen(line)
            self.table.reloadData()
        })
        present(alert, animated: true)
    }

    private func checkUpdate() {
        guard active, !checking, presentedViewController == nil else { return }
        checking = true
        let id = UUID()
        checkID = id
        table.reloadData()
        checkTask = IOSUpdatePresentation.checkApp(from: self, manual: true, completion: { [weak self] in
            guard let self = self, !self.closed, self.checkID == id else { return }
            self.checking = false
            self.checkTask = nil
            if self.active { self.table.reloadData() }
        })
    }

    private func checkPanelUpdate() {
        guard active, !panelChecking, presentedViewController == nil else { return }
        panelChecking = true
        let id = UUID()
        panelCheckID = id
        table.reloadData()
        panelCheckTask = IOSUpdatePresentation.checkPanel(from: self, onUpdate: { [weak self] in
            guard let self = self, self.active else { return }
            self.reinitialize()
        }, completion: { [weak self] in
            guard let self = self, !self.closed, self.panelCheckID == id else { return }
            self.panelChecking = false
            self.panelCheckTask = nil
            if self.active { self.table.reloadData() }
        })
    }

    private func reinitialize() {
        guard active else { return }
        guard !initializing, !IOSPanelCache.shared.snapshot().busy else {
            presentMessage(IOSStrings.updateReinitializeTitle, IOSStrings.busy)
            return
        }
        let alert = UIAlertController(
            title: IOSStrings.updateReinitializeTitle,
            message: IOSStrings.updateReinitializeMessage,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self] _ in
            guard let self = self, self.active, !self.initializing,
                  !IOSPanelCache.shared.snapshot().busy else { return }
            let id = UUID()
            self.initializeID = id
            self.initializing = true
            self.syncModalLock()
            IOSPanelCache.shared.initialize(force: true) { [weak self] state in
                guard let self = self, !self.closed, self.initializeID == id else { return }
                // preparing/downloading 是进度回执；只有终态才能刷新资源信息和解锁。
                guard !state.busy else {
                    self.syncModalLock()
                    return
                }
                self.initializing = false
                self.syncModalLock()
                guard self.active else { return }
                self.loadResourceInfo()
                if !state.ready {
                    self.presentMessage(IOSStrings.updateReinitializeTitle, IOSStrings.recoveryInitErrorGeneric)
                }
            }
        })
        present(alert, animated: true)
    }

    private func showDiagnostics() {
        guard active, presentedViewController == nil else { return }
        // 裸 present 时看不到标题，也没有关闭按钮（唯一出口是那个名叫「重试」的按钮）。
        // 包一层导航容器，诊断页自己挂「完成」与标题。
        let controller = DiagnosticsViewController()
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func presentMessage(_ title: String, _ message: String) {
        // 已经有一个弹窗在显示时不要再 present，UIKit 会在控制台刷
        // 「Attempt to present ... which is already presenting」并且这次提示直接丢掉。
        guard active, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }
}
