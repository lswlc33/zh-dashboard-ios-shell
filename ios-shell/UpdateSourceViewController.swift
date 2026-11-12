import UIKit

// 原生中心确认过清单后才打开此页；测速只更新读数，不代替用户选择下载源。
@MainActor
final class UpdateSourceViewController: UIViewController,
                                        UITableViewDataSource, UITableViewDelegate {
    private let release: IOSRelease
    private let line: IOSPanelLine
    private let sources: [IOSUpdateSource]
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var latencyTasks: [Task<Void, Never>] = []
    private var latencyValues: [String: Int] = [:]
    private var measuredSources: Set<String> = []
    private var latencyID = UUID()
    private var downloadTask: Task<Void, Never>?
    private var runningDownloadID: UUID?
    private var downloadID = UUID()
    private var chosenSource: IOSUpdateSource?
    private var ownedFile: URL?
    private var sharing = false
    private var closed = false
    private var statusMessage: String?

    init(release: IOSRelease, line: IOSPanelLine) {
        self.release = release
        self.line = line
        sources = IOSUpdateSources.sources(for: line)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = IOSStrings.updateSourceTitle
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: IOSStrings.updateDone, style: .done, target: self, action: #selector(dismissSelf))
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBackgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationForegrounded),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 交互式下滑若被撤回仍可继续用；上一代已取消，晚回执不会落到重开的页。
        closed = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !closed else { return }
        if line != IOSPanelLine.current {
            statusMessage = IOSStrings.updateLineStale
            cancelLatencies()
            cancelDownload(showMessage: false)
            table.reloadData()
        } else if latencyTasks.isEmpty, !sharing {
            measureSources()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 全屏分享也会触发消失；它交给 TrollStore 时仍需要这个临时 IPA。
        guard isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent else { return }
        closeTasks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        latencyTasks.forEach { $0.cancel() }
        downloadTask?.cancel()
        if let file = ownedFile { Self.removeOwnedFile(file) }
    }

    private var active: Bool {
        !closed && isViewLoaded && view.window != nil && !isBeingDismissed
            && navigationController?.isBeingDismissed != true && !isMovingFromParent
            && UIApplication.shared.applicationState == .active
    }

    private func measureSources() {
        guard active, line == IOSPanelLine.current else { return }
        let id = UUID()
        latencyID = id
        for source in sources {
            let release = self.release
            let task = Task { @MainActor [weak self] in
                let value = await IOSUpdater.latency(release, source: source)
                guard !Task.isCancelled, let self = self, !self.closed, self.latencyID == id,
                      self.line == IOSPanelLine.current else { return }
                self.measuredSources.insert(source.id)
                self.latencyValues[source.id] = value
                if self.active { self.table.reloadData() }
            }
            latencyTasks.append(task)
        }
    }

    private func cancelLatencies() {
        latencyID = UUID()
        latencyTasks.forEach { $0.cancel() }
        latencyTasks.removeAll()
    }

    // MARK: - UITableView

    func numberOfSections(in tableView: UITableView) -> Int {
        chosenSource == nil ? 1 : 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return sources.count
        case 1: return chosenSource == nil ? 0 : 2
        default: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? (statusMessage ?? IOSStrings.updateSourceHint) : nil
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? IOSStrings.updateDownloadingTitle : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            guard sources.indices.contains(indexPath.row) else { return cell }
            let source = sources[indexPath.row]
            let latency: String
            if let value = latencyValues[source.id] {
                latency = String(format: IOSStrings.updateSourceLatency, value)
            } else {
                latency = measuredSources.contains(source.id)
                    ? IOSStrings.updateSourceUnavailable : IOSStrings.updateSourceMeasuring
            }
            cell.textLabel?.text = source.name
            cell.detailTextLabel?.text = [source.description, source.baseURL.host, latency]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            cell.accessoryType = chosenSource?.id == source.id ? .checkmark : .none
            cell.selectionStyle = chosenSource == nil && !sharing ? .default : .none
        } else if indexPath.section == 1, let source = chosenSource {
            cell.selectionStyle = .none
            if indexPath.row == 0 {
                cell.textLabel?.text = source.name
                cell.detailTextLabel?.text = String(format: IOSStrings.updateDownloadingMessage, source.name)
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.startAnimating()
                cell.accessoryView = indicator
            } else if indexPath.row == 1 {
                cell.textLabel?.text = IOSStrings.cancel
                cell.textLabel?.textColor = .systemRed
                cell.selectionStyle = .default
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard active, !sharing else { return }
        if indexPath.section == 1, indexPath.row == 1 {
            cancelDownload(showMessage: true)
        } else if indexPath.section == 0, sources.indices.contains(indexPath.row) {
            download(from: sources[indexPath.row])
        }
    }

    // MARK: - 单源下载与分享

    private func download(from source: IOSUpdateSource) {
        // 测速没结束也能点；只有显式点击才固定所选源，绝不并行下载或自动换源。
        guard active, downloadTask == nil, chosenSource == nil, !sharing else { return }
        guard line == IOSPanelLine.current else {
            statusMessage = IOSStrings.updateLineStale
            table.reloadData()
            return
        }
        chosenSource = source
        statusMessage = nil
        let id = UUID()
        downloadID = id
        runningDownloadID = id
        table.reloadData()
        let release = self.release
        downloadTask = Task { @MainActor [weak self] in
            // 取消后也等旧任务实际退出才允许下次下载，不能把 cancel 受理当成已停止。
            defer {
                if let self = self, self.runningDownloadID == id {
                    self.downloadTask = nil
                    self.runningDownloadID = nil
                    if self.active, self.downloadID == id { self.table.reloadData() }
                }
            }
            do {
                // 核心层核对清单、大小和 SHA-256 后，才交付唯一的原生临时路径。
                let file = try await IOSUpdater.download(release, source: source)
                guard !Task.isCancelled, let self = self, !self.closed, self.downloadID == id else {
                    Self.removeOwnedFile(file)
                    return
                }
                self.downloadTask = nil
                self.chosenSource = nil
                guard self.active, self.line == IOSPanelLine.current else {
                    Self.removeOwnedFile(file)
                    if self.line != IOSPanelLine.current { self.statusMessage = IOSStrings.updateLineStale }
                    if self.active { self.table.reloadData() }
                    return
                }
                self.ownedFile = file
                self.table.reloadData()
                self.share(file, id: id)
            } catch {
                guard let self = self, !self.closed, self.downloadID == id else { return }
                self.downloadTask = nil
                self.chosenSource = nil
                if Task.isCancelled || error is CancellationError {
                    self.statusMessage = IOSStrings.updateDownloadCancelled
                } else if self.line != IOSPanelLine.current {
                    self.statusMessage = IOSStrings.updateLineStale
                } else {
                    self.statusMessage = error.localizedDescription
                    if self.active {
                        IOSUpdatePresentation.message(from: self, title: IOSStrings.updateDownloadFailedTitle,
                                                      text: error.localizedDescription)
                    }
                }
                if self.active { self.table.reloadData() }
            }
        }
    }

    private func share(_ file: URL, id: UUID) {
        guard active, downloadID == id, line == IOSPanelLine.current, presentedViewController == nil else {
            clearOwnedFile()
            return
        }
        sharing = true
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        activity.completionWithItemsHandler = { [weak self] _, _, _, error in
            Task { @MainActor [weak self] in
                // 分享完成仅代表系统回执，不声称 TrollStore 已安装。
                Self.removeOwnedFile(file)
                guard let self = self, !self.closed, self.downloadID == id else { return }
                self.ownedFile = nil
                self.sharing = false
                self.isModalInPresentation = false
                self.navigationController?.isModalInPresentation = false
                if let error = error {
                    self.statusMessage = error.localizedDescription
                }
                if self.active { self.table.reloadData() }
            }
        }
        present(activity, animated: true)
    }

    private func cancelDownload(showMessage: Bool) {
        guard !sharing else { return }
        downloadID = UUID()
        downloadTask?.cancel()
        // 保留任务句柄到 defer：请求取消与底层传输停止不是同一时刻。
        chosenSource = nil
        clearOwnedFile()
        if showMessage { statusMessage = IOSStrings.updateDownloadCancelled }
        if active { table.reloadData() }
    }

    private func clearOwnedFile() {
        if let file = ownedFile { Self.removeOwnedFile(file) }
        ownedFile = nil
    }

    // 只接收本类从 IOSUpdater 成功取得的 URL，不接受网页路径或清扫其他任务目录。
    private nonisolated static func removeOwnedFile(_ file: URL) {
        let directory = file.deletingLastPathComponent().standardizedFileURL
        guard file.isFileURL, directory.lastPathComponent.hasPrefix("ios-update-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst("ios-update-".count))) != nil,
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    @objc private func applicationForegrounded() {
        guard active, !sharing, latencyTasks.isEmpty, line == IOSPanelLine.current else { return }
        measureSources()
    }

    @objc private func applicationBackgrounded() {
        guard !closed, !sharing else { return }
        cancelLatencies()
        cancelDownload(showMessage: chosenSource != nil)
        table.reloadData()
    }

    private func closeTasks() {
        guard !closed else { return }
        closed = true
        cancelLatencies()
        downloadID = UUID()
        downloadTask?.cancel()
        // 保留任务句柄到 defer：请求取消与底层传输停止不是同一时刻。
        chosenSource = nil
        clearOwnedFile()
    }

    @objc private func dismissSelf() {
        guard !closed, !sharing else { return }
        closeTasks()
        dismiss(animated: true)
    }
}
