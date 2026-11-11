"""检查配置；提供 IPA 时检查实际安装包。"""
import pathlib
import plistlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent
with (root / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
assert info['CFBundlePackageType'] == 'APPL'
assert info['MinimumOSVersion'] == '15.4'
assert 'NSAppTransportSecurity' not in info
assert info['CFBundleIdentifier'] == 'io.github.lswlc33.dashboard.ios'
assert info['NSSupportsLiveActivities'] is True

# -I 不从 cwd 导入 helper；这里只验证源码合同，不冒充 Apple 编译或签名通过。
import importlib.util
sys.dont_write_bytecode = True
helper_spec = importlib.util.spec_from_file_location('zeeho_build_support', root / 'build-support.py')
helper = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(helper)
inputs = helper.inventory(root.parent)
assert all(path.count('/') == 1 for path in inputs['swiftSources'])
assert inputs['sharedSwiftSources'] and inputs['widgetSwiftSources']
assert 'ZeehoShared' not in inputs['sharedSwiftImports'] + inputs['widgetSwiftImports']
assert not any(r['path'].endswith('-test.swift') or '/commonTest/' in r['path'] or '/jvmTest/' in r['path'] for r in inputs['files'])
package = (root / 'Package.swift').read_text(encoding='utf-8')
assert '// swift-tools-version: 6.0' in package and 'swiftLanguageModes: [.v5]' in package
assert '.iOS("15.4")' in package and '.binaryTarget(name: "ZeehoShared", path: frameworkPath)' in package
assert 'dependencies: ["ZeehoSystemShared"]' in package and 'KMP_FRAMEWORK_MISSING' in package
assert 'canImport' not in package
config = (root / 'xtool.yml').read_text(encoding='utf-8')
assert 'product: DashboardIOS' in config and 'product: DashboardWidgets' in config
assert 'infoPath: Widgets/Info.plist' in config and 'entitlementsPath: XtoolSupport/Widgets.entitlements' in config

# 主界面完全沉浸：WebView 四边贴 view（不是 safeAreaLayoutGuide），
# 安全区改由 app.info.safeArea 交给网页，避免 WK 的 env() 给 0 或含导航栏高度。
controller = (root / 'Dashboard.swift').read_text(encoding='utf-8')
for edge in ('top', 'bottom', 'leading', 'trailing'):
    assert f'web.{edge}Anchor.constraint(equalTo: view.{edge}Anchor)' in controller
    assert f'view.safeAreaLayoutGuide.{edge}Anchor' not in controller
assert 'setNavigationBarHidden' not in controller and 'UINavigationController' not in controller
assert 'contentInsetAdjustmentBehavior = .never' in controller
# 安全区变化要通知网页重新取值，否则旋转后 --sat/--sab 会停在旧值。
assert "window.dispatchEvent(new Event('resize'))" in controller
assert 'viewSafeAreaInsetsDidChange' in controller

# 启动分流：有快照且非首次安装直接进面板，否则先走原生欢迎/恢复页。
assert 'RootRouter' in controller and 'RecoveryViewController' in controller
assert 'BootHealth.needsWelcome()' in controller
# 新文档先异步准备可信快照，只有成功才 load；失败显示错误，不绕过桥门禁启动网页。
prepare = controller.split('private func preparePanel(_ url: URL)', 1)[1].split('\n    }', 1)[0]
assert prepare.index('bridge.prepareNavigation(to: target)') < prepare.index('case let .success(target):') < prepare.index('self.web.load(')
assert 'URLRequest(url: target' in prepare
# 有本地快照时改写到自定义 scheme；没快照保持线上 https。
assert 'Self.localSnapshotURL(for: url) ?? url' in prepare
failure = prepare.split('case let .failure(error):', 1)[1]
assert 'self.showError(error)' in failure and 'web.load(' not in failure
error = controller.split('private func showError', 1)[1].split('\n    }', 1)[0]
assert error.index('NSURLErrorCancelled') < error.index('BootHealth.failed(reason: "load_failed")')
assert 'onBootFailure?("load_failed")' in error
assert 'webViewWebContentProcessDidTerminate(_ webView: WKWebView) {' in controller
assert 'onBootFailure?("renderer")' in controller

# 欢迎/恢复页：一个控制器承载两种语义，初始化与取消互斥。
recovery = (root / 'RecoveryView.swift').read_text(encoding='utf-8')
assert 'IOSStrings.recoveryTitle' in recovery and 'IOSStrings.recoverySubtitle' in recovery
assert 'initializeButton.isHidden = cancellable' in recovery
assert 'cancelButton.isHidden = !cancellable' in recovery
assert 'enterButton.isEnabled = ready && !busy' in recovery
# 初始化进度走推送而不是轮询。
assert 'IOSPanelCache.shared.onState' in recovery
# 「版本与更新」打开独立面板，不再是 Alert。
assert 'UpdatePanelViewController()' in recovery
assert 'UIAlertController' not in recovery.split('showVersion', 1)[1].split('private func showBackup', 1)[0]
# 更新面板要能看到版本、资源、线路、操作四段。
update_panel = (root / 'UpdatePanelViewController.swift').read_text(encoding='utf-8')
for text in ('版本信息', '面板资源', '软件更新线路', '检查软件更新', '重新初始化面板资源', '查看诊断日志'):
    assert text in update_panel, text
assert 'IOSPanelCache.resources.count' in update_panel
# 欢迎页不创建 WebView，也不调用 JS（文案里提到 WKWebView 是正常的，检查真实类型/调用）。
assert 'WKWebView(' not in recovery and 'evaluateJavaScript' not in recovery
assert 'import WebKit' not in recovery
# 每个加约束的子视图都必须关掉 autoresizing 转约束，否则 frame 保持 .zero、
# 约束被忽略，整页只剩 toolbar 可见且点不动（真机踩过）。
for name in ('toolbar', 'welcomeGroup', 'footerStack'):
    assert f'{name}.translatesAutoresizingMaskIntoConstraints = false' in recovery, name
# 欢迎区要落在「toolbar 与底栏之间」那块的中心（安卓以窗口中心定位 + 底栏避让）。
assert 'welcomeGroup.centerYAnchor.constraint(equalTo: welcomeRegion.centerYAnchor)' in recovery
assert 'welcomeRegion.topAnchor.constraint(equalTo: toolbar.bottomAnchor)' in recovery
assert 'welcomeRegion.bottomAnchor.constraint(equalTo: footerStack.topAnchor)' in recovery
# 底栏高度由内容撑开，只留 60% 屏高上限。
assert 'footerStack.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6)' in recovery
# 不允许再用两个 scrollView 互相用 contentLayoutGuide 定高（会形成循环约束、整页塌成 0）。
# 注释里提到这段历史是允许的，只检查真实代码。
recovery_code = '\n'.join(line for line in recovery.splitlines()
                          if not line.lstrip().startswith('//'))
assert 'contentLayoutGuide' not in recovery_code
assert 'UIScrollView()' not in recovery_code

# 资源快照：清单与自定义 scheme 必须一致，否则本地页面缺资源。
cache = (root / 'PanelCache.swift').read_text(encoding='utf-8')
scheme = (root / 'PanelSchemeHandler.swift').read_text(encoding='utf-8')
assert 'static let resources' in cache and '"index.html"' in cache
# 下载必须并发 + 预探总量，串行会让首屏等 11 个 RTT 且进度条不动。
assert 'maxConcurrent' in cache and 'probeSizes' in cache
assert 'httpMaximumConnectionsPerHost' in cache
# 进度要实时推给界面，不能只在最后回调一次。
assert 'var onState' in cache and 'throttledEmit' in cache
assert 'zeeho-panel' in scheme
assert 'didFailWithError' in scheme and 'resolvingSymlinksInPath' in scheme
navigation = (root / 'Navigation.swift').read_text(encoding='utf-8')
# Navigation 必须能被 navigation-test.swift 单独编译：只用字面量 scheme，
# 不 import PanelSchemeHandler / PanelCache / PanelLine 的类型。
assert 'static let localScheme = "zeeho-panel"' in navigation
assert 'IOSPanelSchemeHandler' not in navigation.replace('`IOSPanelLine.baseURL()`', '')
assert 'IOSPanelCache' not in navigation
# 线上基址可被线路切换覆写，但默认值仍是 GitHub Pages。
assert 'https://lswlc33.github.io/zeeho-3d-models/' in navigation

# 线路选择：五个同步方法齐全，begin 同步完成（与安卓现状一致）。
line = (root / 'PanelLineService.swift').read_text(encoding='utf-8')
for method in ('panelLineVersion', 'panelLineInfo', 'beginPanelLine', 'pollPanelLine', 'cancelPanelLine'):
    assert method in line
assert 'unknown_ticket' in line

# 系统服务：safeArea 与外观通道必须在白名单里，否则网页永远拿不到。
system = (root / 'System.swift').read_text(encoding='utf-8')
assert '"safeArea": safeAreaJSON()' in system
assert '"app.appearance"' in system
assert '"app.diag"' in system
assert 'overrideUserInterfaceStyle' in system

# 诊断：日志落盘 + 文件共享 + 白屏兜底页，三者缺一用户就交不出线索。
diagnostics = (root / 'Diagnostics.swift').read_text(encoding='utf-8')
assert 'zeeho-ios-diagnostics.log' in diagnostics
assert 'documentDirectory' in diagnostics
diag_controller = (root / 'DiagnosticsViewController.swift').read_text(encoding='utf-8')
assert 'UIActivityViewController' in diag_controller and 'IOSDiagnostics.shared.read()' in diag_controller
assert info.get('UIFileSharingEnabled') is True and info.get('LSSupportsOpeningDocumentsInPlace') is True
# 主文档必须始终走线上 https：自定义 scheme 下网页会白屏。
assert 'return nil' in controller.split('private static func localSnapshotURL', 1)[1].split('\n    }', 1)[0]
assert 'didFinish: ' in controller and 'didFailProvisionalNavigation: ' in controller

# 全部 Swift 源文件都要进构建清单，新增文件漏了会静默不编译。
# build.sh 从 build-support.py 的 inventory 读文件表，所以检查 inventory 而不是 shell 脚本。
# inventory 里的路径带 `ios-shell/` 前缀（相对仓库根）。
listed = set(inputs['swiftSources'])
for name in ('RecoveryView.swift', 'PanelCache.swift', 'PanelSchemeHandler.swift',
             'PanelLine.swift', 'PanelLineService.swift', 'Dashboard.swift',
             'Diagnostics.swift', 'DiagnosticsViewController.swift', 'UpdatePanelViewController.swift'):
    assert f'ios-shell/{name}' in listed, name
# 首屏骨架已由欢迎页取代，不能留孤儿文件。
assert not (root / 'PanelLoadingView.swift').exists()

# App 图标必须用「满出血、无圆角」的 iOS 专用源：
# 普通 icon-512 自带 radius=0.28 的透明圆角，iOS 底下衬白底 → 四角白边。
build_sh = (root / 'build.sh').read_text(encoding='utf-8')
assert 'public/icons/icon-ios-1024.png' in build_sh
assert 'public/icons/icon-512.png' not in build_sh
assert 'public/icons/apple-touch-icon.png' not in build_sh
# 图标源必须真的存在，缺失时 build.sh 会 BLOCKED 退出。
assert (root.parent / 'public/icons/icon-ios-1024.png').is_file()
if len(sys.argv) > 1:
    report = helper.verify_artifacts(sys.argv[1], expected_info=info if pathlib.Path(sys.argv[1]).name == helper.IPA_NAME else None)
    print('Real IPA ZIP/Mach-O/appex/SDK/signature structure/hash checks passed; cryptographic verification depends on the recorded build backend')
print('iOS source/package contract checks passed (no Apple compilation or device validation)')
