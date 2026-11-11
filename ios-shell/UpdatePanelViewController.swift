import UIKit

// 「版本与更新」独立页。对照安卓 RecoveryUi 的版本弹窗，但做成整页：
// 安卓那边是 Dialog，iOS 上整页能容纳更多信息且不会在 iPad 变成 popover。
//
// 内容分四段：
//   1. 四行版本信息（软件 / 面板 / WebView / 最低要求）
//   2. 面板资源（本地快照的构建号、资源数、大小、上次更新时间）
//   3. 软件更新线路（单选，切换后立刻重新初始化资源）
//   4. 操作（检查更新 / 重新初始化 / 查看诊断日志）
final class UpdatePanelViewController: UIViewController,
                                       UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable {
        case versions, resources, line, actions
        var title: String {
            switch self {
            case .versions: return "版本信息"
            case .resources: return "面板资源"
            case .line: return "软件更新线路"
            case .actions: return "操作"
            }
        }
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var resourceInfo: [String: String] = [:]
    private var checking = false

    /// 关闭时通知调用方刷新（线路/资源可能变了）。
    var onChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = IOSStrings.recoveryVersionTitle
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成", style: .done, target: self, action: #selector(dismissSelf))

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
        loadResourceInfo()
    }

    @objc private func dismissSelf() {
        onChange?()
        dismiss(animated: true)
    }

    // MARK: - 数据

    private func loadResourceInfo() {
        let cache = IOSPanelCache.shared
        let directory = cache.snapshotDirectory()
        var bytes: Int64 = 0
        var count = 0
        if let directory = directory {
            let enumerator = FileManager.default.enumerator(at: directory,
                                                            includingPropertiesForKeys: [.fileSizeKey])
            while let file = enumerator?.nextObject() as? URL {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += Int64(size)
                    count += 1
                }
            }
        }
        let build = cache.snapshotBuild()
        let modified: String
        if let directory = directory,
           let date = try? FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            modified = formatter.string(from: date)
        } else {
            modified = "—"
        }
        resourceInfo = [
            "build": build.isEmpty ? IOSStrings.recoveryPanelVersionNone : build,
            "files": "\(count) 个",
            "size": ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
            "updated": modified
        ]
        table.reloadData()
    }

    private func appVersionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version)（\(build)）"
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .versions: return 4
        case .resources: return 4
        case .line: return 2
        case .actions: return 3
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section) {
        case .versions:
            let rows: [(String, String)] = [
                (IOSStrings.recoveryAppVersionLabel, appVersionLine()),
                (IOSStrings.recoveryPanelVersionLabel, resourceInfo["build"] ?? "—"),
                (IOSStrings.recoveryWebviewLabel, "WKWebView · iOS \(UIDevice.current.systemVersion)"),
                (IOSStrings.recoveryMinimumLabel, "iOS 15.4")
            ]
            cell.textLabel?.text = rows[indexPath.row].0
            cell.detailTextLabel?.text = rows[indexPath.row].1

        case .resources:
            let rows: [(String, String)] = [
                ("已下载资源", resourceInfo["files"] ?? "—"),
                ("占用空间", resourceInfo["size"] ?? "—"),
                ("上次更新", resourceInfo["updated"] ?? "—"),
                ("资源清单", "\(IOSPanelCache.resources.count) 项")
            ]
            cell.textLabel?.text = rows[indexPath.row].0
            cell.detailTextLabel?.text = rows[indexPath.row].1

        case .line:
            let lines = [IOSPanelLine.github, IOSPanelLine.cf]
            let line = lines[indexPath.row]
            cell.textLabel?.text = line.displayName
            cell.detailTextLabel?.text = line == IOSPanelLine.current ? "当前" : ""
            cell.accessoryType = line == IOSPanelLine.current ? .checkmark : .none

        case .actions:
            cell.textLabel?.textColor = .tintColor
            cell.detailTextLabel?.text = ""
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = checking ? "正在检查…" : "检查软件更新"
            case 1:
                cell.textLabel?.text = "重新初始化面板资源"
            default:
                cell.textLabel?.text = "查看诊断日志"
            }

        case .none:
            break
        }
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .line:
            let lines = [IOSPanelLine.github, IOSPanelLine.cf]
            selectLine(lines[indexPath.row])
        case .actions:
            switch indexPath.row {
            case 0: checkUpdate()
            case 1: reinitialize()
            default: showDiagnostics()
            }
        default:
            break
        }
    }

    // MARK: - 动作

    private func selectLine(_ line: IOSPanelLine) {
        guard line != IOSPanelLine.current else { return }
        IOSPanelLine.current = line
        table.reloadData()
        let alert = UIAlertController(
            title: IOSStrings.recoveryVersionTitle,
            message: String(format: IOSStrings.recoveryLineChanged, line.displayName),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self] _ in
            // 换线路后旧快照可能来自另一个源，必须重下才能保证资源一致。
            IOSPanelCache.shared.initialize(force: true) { _ in
                self?.loadResourceInfo()
            }
        })
        present(alert, animated: true)
    }

    private func checkUpdate() {
        guard !checking else { return }
        checking = true
        table.reloadData()
        Task { @MainActor in
            defer {
                checking = false
                table.reloadData()
            }
            do {
                let release = try await IOSUpdater.latest()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                if try release.isNewer(version: version, build: build) {
                    let alert = UIAlertController(
                        title: "发现新版本",
                        message: "当前：\(version)（\(build)）\n新版：\(release.version)（\(release.build)）\n\n下载后请在分享菜单中选择 TrollStore 覆盖安装。",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
                    alert.addAction(UIAlertAction(title: "下载", style: .default) { [weak self] _ in
                        self?.downloadUpdate(release)
                    })
                    present(alert, animated: true)
                } else {
                    presentMessage("已是最新", "当前 iOS 软件版本：\(version)（\(build)）")
                }
            } catch {
                presentMessage("检查失败", error.localizedDescription)
            }
        }
    }

    private func downloadUpdate(_ release: IOSRelease) {
        Task { @MainActor in
            do {
                let file = try await IOSUpdater.download(release)
                let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = view
                    popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                }
                present(activity, animated: true)
            } catch {
                presentMessage("下载失败", error.localizedDescription)
            }
        }
    }

    private func reinitialize() {
        let alert = UIAlertController(
            title: "重新初始化",
            message: "将重新下载全部面板资源。账号和设置不会被清除。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default) { [weak self] _ in
            IOSPanelCache.shared.initialize(force: true) { _ in
                self?.loadResourceInfo()
            }
        })
        present(alert, animated: true)
    }

    private func showDiagnostics() {
        present(DiagnosticsViewController(), animated: true)
    }

    private func presentMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: IOSStrings.confirm, style: .default))
        present(alert, animated: true)
    }
}
