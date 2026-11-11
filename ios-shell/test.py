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

# 壳负责完整安全区，避免网页视口推断将 Home 指示条留白清零。
controller = (root / 'Dashboard.swift').read_text(encoding='utf-8')
for edge in ('top', 'bottom', 'leading', 'trailing'):
    assert f'web.{edge}Anchor.constraint(equalTo: view.safeAreaLayoutGuide.{edge}Anchor)' in controller
    assert f'loading.{edge}Anchor.constraint(equalTo: web.{edge}Anchor)' in controller
for event, active in [('didStartProvisionalNavigation', 'true'), ('didFinish', 'false')]:
    assert re.search(r'func webView\([^\n]*' + event + r'[^\n]*loading.setLoading\(' + active + r'\)', controller)
load = controller.split('private func loadPanel()', 1)[1].split('\n    }', 1)[0]
assert load.index('loading.setLoading(true)') < load.index('preparePanel(PanelNavigation.home)')
# 新文档先异步准备可信快照，只有成功才 load；失败显示错误，不绕过桥门禁启动网页。
prepare = controller.split('private func preparePanel(_ url: URL)', 1)[1].split('\n    }', 1)[0]
assert prepare.index('loading.setLoading(true)') < prepare.index('bridge.prepareNavigation(to: url)')
assert prepare.index('bridge.prepareNavigation(to: url)') < prepare.index('case let .success(target):') < prepare.index('self.web.load(')
assert 'URLRequest(url: target' in prepare
failure = prepare.split('case let .failure(error):', 1)[1]
assert 'self.showError(error)' in failure and 'web.load(' not in failure
error = controller.split('private func showError', 1)[1].split('\n    }', 1)[0]
assert error.index('NSURLErrorCancelled') < error.index('loading.setLoading(false)') < error.index('UIAlertController')
assert 'webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadPanel() }' in controller
loading = (root / 'PanelLoadingView.swift').read_text(encoding='utf-8')
assert 'backgroundColor = .systemBackground' in loading
assert 'clipsToBounds = true' in loading
assert 'PanelLoadingView.swift' in (root / 'build.sh').read_text(encoding='utf-8')
if len(sys.argv) > 1:
    report = helper.verify_artifacts(sys.argv[1], expected_info=info if pathlib.Path(sys.argv[1]).name == helper.IPA_NAME else None)
    print('Real IPA ZIP/Mach-O/appex/SDK/signature structure/hash checks passed; cryptographic verification depends on the recorded build backend')
print('iOS source/package contract checks passed (no Apple compilation or device validation)')
