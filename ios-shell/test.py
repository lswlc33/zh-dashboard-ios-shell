"""检查配置；提供 IPA 时检查实际安装包。"""
import ast
import importlib.util
import pathlib
import plistlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True


def strip_comments(text):
    """去掉 Swift 源码里的注释，只留真实代码。

    为什么要这么做：很多断言只是「源码里出现某段字符串」，把代码注释掉测试照样通过，
    等于没有回归保护（RecoveryView 的 contentLayoutGuide 那组最早发现这个问题）。

    只处理「整行 `//`」与 `/* */` 块注释，不剪行尾 `//`——
    行尾注释里常出现 `https://...`，硬剪会把字符串字面量切坏。
    多行字符串（`\"\"\"`）内部原样保留：那里面的 `//` 是网页 JS 注释，不是 Swift 注释，
    剪掉会让「字符串里包含某段代码」这类断言误报。
    """
    output = []
    in_block = False
    in_multiline_string = False
    for line in text.splitlines():
        if in_multiline_string:
            if line.count('"""') % 2 == 1:
                in_multiline_string = False
            output.append(line)
            continue
        if line.count('"""') % 2 == 1:
            in_multiline_string = True
            output.append(line)
            continue
        if in_block:
            if '*/' not in line:
                continue
            line = line.split('*/', 1)[1]
            in_block = False
        while '/*' in line:
            head, _, tail = line.partition('/*')
            if '*/' in tail:
                line = head + tail.split('*/', 1)[1]
            else:
                line = head
                in_block = True
                break
        if line.lstrip().startswith('//'):
            continue
        output.append(line)
    return '\n'.join(output)


def literal_constant(path, name):
    """从 build-support.py 源码里取顶层字符串常量，不执行模块。

    用 ast 而不是 import：另一边（并行代理）随时可能改实现，
    只取契约常量不会把构建脚本的副作用（argparse/subprocess）带进测试进程。
    """
    tree = ast.parse(pathlib.Path(path).read_text(encoding='utf-8'))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            try:
                return ast.literal_eval(node.value)
            except ValueError:
                return None
    return None


def main():
    root = pathlib.Path(__file__).resolve().parent
    repo = root.parent
    with (root / 'Info.plist').open('rb') as f:
        info = plistlib.load(f)
    assert info['CFBundlePackageType'] == 'APPL'
    assert info['MinimumOSVersion'] == '15.4'
    assert 'NSAppTransportSecurity' not in info
    assert info['CFBundleIdentifier'] == 'io.github.lswlc33.dashboard.ios'
    assert info['NSSupportsLiveActivities'] is True

    # -I 不从 cwd 导入 helper；这里只验证源码合同，不冒充 Apple 编译或签名通过。
    helper_spec = importlib.util.spec_from_file_location('zeeho_build_support', root / 'build-support.py')
    helper = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(helper)
    inputs = helper.inventory(repo)
    assert all(path.count('/') == 1 for path in inputs['swiftSources'])
    assert inputs['sharedSwiftSources'] and inputs['widgetSwiftSources']
    assert 'ZeehoShared' not in inputs['sharedSwiftImports'] + inputs['widgetSwiftImports']
    assert not any(r['path'].endswith('-test.swift') or '/commonTest/' in r['path'] or '/jvmTest/' in r['path'] for r in inputs['files'])

    # iOS 图标源必须进上传白名单：build.sh 把它当硬闸门，漏了会让远程 Mac 构建
    # 在跑完 Gradle + swiftc 之后才失败，而且「上传快照 = 完整构建输入」也不成立。
    assert 'public/icons/icon-ios-1024.png' in helper.FIXED_INPUTS
    assert 'public/icons/icon-ios-1024.png' in {r['path'] for r in inputs['files']}

    # ② Shell 脚本必须按 LF 打包。read_text 会自动归一换行，撒谎，
    # 所以这里必须用 read_bytes 看真实工作树字节。
    for name in ('ios-shell/build.sh', 'ios-shell/build-xtool.sh', 'native-shared/gradlew'):
        data = (repo / name).read_bytes()
        assert b'\r\n' not in data, name + ' 含 CRLF：bash 会把反斜杠续行打断'
    attributes = (repo / '.gitattributes').read_text(encoding='utf-8')
    for rule in ('*.sh text eol=lf', '*/gradlew text eol=lf', 'ios-shell/*.py text eol=lf'):
        assert rule in attributes, rule

    package = (root / 'Package.swift').read_text(encoding='utf-8')
    assert '// swift-tools-version: 6.0' in package and 'swiftLanguageModes: [.v5]' in package
    assert '.iOS("15.4")' in package and '.binaryTarget(name: "ZeehoShared", path: frameworkPath)' in package
    assert 'dependencies: ["ZeehoSystemShared"]' in package and 'KMP_FRAMEWORK_MISSING' in package
    assert 'canImport' not in package
    config = (root / 'xtool.yml').read_text(encoding='utf-8')
    assert 'product: DashboardIOS' in config and 'product: DashboardWidgets' in config
    assert 'infoPath: Widgets/Info.plist' in config and 'entitlementsPath: XtoolSupport/Widgets.entitlements' in config
    # ⑥ xtool 后端也必须用满出血图标，否则会重新引入「四角白边」。
    # 只看 iconPath 那一行：注释里提到 icon-512.png（解释为什么不用它）是允许的。
    icon_lines = [line.strip() for line in config.splitlines() if line.strip().startswith('iconPath:')]
    assert icon_lines == ['iconPath: ../public/icons/icon-ios-1024.png'], \
        'xtool.yml 的 iconPath 必须唯一且指向满出血图标，实际: ' + repr(icon_lines)

    # ① build.sh 必须真的用这张满出血图，且归上传白名单管。
    build_sh = (root / 'build.sh').read_text(encoding='utf-8')
    assert 'public/icons/icon-ios-1024.png' in build_sh
    assert 'public/icons/icon-512.png' not in build_sh
    assert 'public/icons/apple-touch-icon.png' not in build_sh
    # 图标源必须真的存在，缺失时 build.sh 会 BLOCKED 退出。
    assert (repo / 'public/icons/icon-ios-1024.png').is_file()

    # ③ CFBundleVersion 必须能被 --build-number 覆盖。
    # 注意：绝不断言 plist 里的字面值不等于 1——本地不传参的构建会因此误杀；
    # 要检查的是「覆盖链路存在」，不是「某个具体数字」。
    assert '--build-number' in build_sh, 'build.sh 必须解析 --build-number'
    assert 'prepare-plist' in build_sh, 'build.sh 必须调用 prepare-plist 展开 Info.plist'
    # 只要求「plist_args 里追加了 --build-number 和某个变量」，不锁死变量名/引号写法，
    # 免得并行改脚本时因为格式调整误报；真正要防的是「解析了参数但没传给 plist」。
    assert re.search(r'plist_args\+=\s*\(\s*--build-number\s+"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"\s*\)', build_sh), \
        'prepare-plist 调用必须带 --build-number 变量'
    # 不传 --build-number 时的兜底必须是单调量：硬编码 1 会让 CI 永远「已是最新」。
    assert re.search(r'git -C "\$repo_dir" rev-list --count HEAD', build_sh), '默认 build number 必须来自提交数'
    support_source = (root / 'build-support.py').read_text(encoding='utf-8')
    assert "p.add_argument('--build-number')" in support_source
    assert "info['CFBundleVersion'] = args.build_number" in support_source

    # ④ 默认输出目录不能是固定 `dist/`：第二次构建必被 OUTPUT_ARTIFACT_EXISTS 拦下。
    assert 'date -u +%Y%m%d-%H%M%S' in build_sh, '默认输出目录必须带时间戳或用 --output-dir'
    assert 'output_dir="$script_dir/dist"' not in build_sh

    # ⑦ App Group / Widget Bundle ID 必须三处一致；UIBackgroundModes 与 UILaunchScreen
    # 属于「删掉只会静默降级」的键，必须显式断言。
    bundle_id = literal_constant(root / 'build-support.py', 'BUNDLE_ID')
    app_group = literal_constant(root / 'build-support.py', 'APP_GROUP')
    assert bundle_id == 'io.github.lswlc33.dashboard.ios' and bundle_id == info['CFBundleIdentifier']
    assert app_group == 'group.' + bundle_id, app_group
    widget_id = bundle_id + '.widgets'
    assert helper.WIDGET_ID == widget_id and helper.APP_GROUP == app_group
    for name in ('App.entitlements', 'Widgets.entitlements'):
        with (root / 'XtoolSupport' / name).open('rb') as f:
            entitlements = plistlib.load(f)
        assert entitlements.get('com.apple.security.application-groups') == [app_group], name
    assert app_group in (root / 'Shared/SystemSnapshotStore.swift').read_text(encoding='utf-8'), \
        'Shared/SystemSnapshotStore 必须用 build-support.APP_GROUP 同一个 App Group'
    assert widget_id in (root / 'SystemSurfaces.swift').read_text(encoding='utf-8'), \
        'SystemSurfaces 的运行时 Widget 探测必须用 build-support.WIDGET_ID 同一个 Bundle ID'
    assert 'UIBackgroundModes' in info, 'UIBackgroundModes 缺失：后台蓝牙/定位会静默降级'
    background = info.get('UIBackgroundModes') or []
    assert 'bluetooth-central' in background and 'location' in background, 'UIBackgroundModes 缺后台蓝牙/定位'
    assert 'UILaunchScreen' in info, 'UILaunchScreen 缺失：启动时会出现黑屏/兼容模式'

    # 主界面完全沉浸：WebView 四边贴 view（不是 safeAreaLayoutGuide），
    # 安全区改由 app.info.safeArea 交给网页，避免 WK 的 env() 给 0 或含导航栏高度。
    raw_controller = (root / 'Dashboard.swift').read_text(encoding='utf-8')
    controller = strip_comments(raw_controller)
    for edge in ('top', 'bottom', 'leading', 'trailing'):
        assert f'web.{edge}Anchor.constraint(equalTo: view.{edge}Anchor)' in controller, \
            f'WebView 必须四边贴 view（{edge}）；注释掉这一行会让页面被 safeArea 内缩'
        assert f'view.safeAreaLayoutGuide.{edge}Anchor' not in controller, edge
    assert 'setNavigationBarHidden' not in controller and 'UINavigationController' not in controller
    assert 'contentInsetAdjustmentBehavior = .never' in controller, 'contentInsetAdjustmentBehavior 被注释掉了会恢复系统自动 inset'
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
    # 只要求「本地快照地址参与 target 计算、且以原 url 兜底」，不锁死前置条件：
    # 现在前面多了一层一次性回退闸门（localFallbackUsed），写死整个表达式会把它判成违规。
    assert 'Self.localSnapshotURL(for: url)' in prepare and '?? url' in prepare
    failure = prepare.split('case let .failure(error):', 1)[1]
    assert 'self.showError(error)' in failure and 'web.load(' not in failure
    error = controller.split('private func showError', 1)[1].split('\n    }', 1)[0]
    assert error.index('NSURLErrorCancelled') < error.index('BootHealth.failed(reason: "load_failed")')
    assert 'onBootFailure?("load_failed")' in error
    assert 'webViewWebContentProcessDidTerminate(_ webView: WKWebView) {' in controller, \
        'WKWebView 渲染进程崩溃的回调必须存在，否则白屏时不会切恢复页'
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
    # 文案不再内联：改为断言「那四段标题引用了 IOSStrings 的对应常量」。
    # 原来那组断言钉的是中文字面量本身，等于把内联文案固定下来，
    # 与「可见文案必须走 IOSStrings」的约束正好相反。
    update_panel = (root / 'UpdatePanelViewController.swift').read_text(encoding='utf-8')
    for constant in ('updateSectionVersions', 'updateSectionResources',
                     'recoverySoftwareLineLabel', 'updateSectionActions',
                     'recoveryUpdate', 'updateReinitializeRow', 'updateShowDiagnostics'):
        assert 'IOSStrings.' + constant in update_panel, constant
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
    recovery_code = strip_comments(recovery)
    assert 'contentLayoutGuide' not in recovery_code
    assert 'UIScrollView()' not in recovery_code

    # 资源快照：清单与自定义 scheme 必须一致，否则本地页面缺资源。
    cache_code = strip_comments((root / 'PanelCache.swift').read_text(encoding='utf-8'))
    scheme_code = strip_comments((root / 'PanelSchemeHandler.swift').read_text(encoding='utf-8'))
    assert 'static let resources' in cache_code and '"index.html"' in cache_code
    # 下载必须并发 + 预探总量，串行会让首屏等 11 个 RTT 且进度条不动。
    assert 'maxConcurrent' in cache_code and 'probeSizes' in cache_code
    assert 'httpMaximumConnectionsPerHost' in cache_code
    # 进度要实时推给界面，不能只在最后回调一次。
    assert 'var onState' in cache_code and 'throttledEmit' in cache_code
    assert 'zeeho-panel' in scheme_code
    assert 'didFailWithError' in scheme_code and 'resolvingSymlinksInPath' in scheme_code
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
    # 主文档必须优先走本地快照：线上产物 3.56MB，window.APP 定义在 82%、
    # startBoot 在 99%，移动网络下首屏要等十几秒，期间 readyState 一直 loading
    # 不触发布局 → 用户看到可缩放拖动的白屏（真机日志实测）。
    snapshot_fn = controller.split('private static func localSnapshotURL', 1)[1].split('\n    }', 1)[0]
    assert 'return PanelNavigation.localURL(matching: url)' in snapshot_fn
    assert 'IOSPanelCache.shared.snapshotDirectory() != nil' in snapshot_fn
    # 加载进度要可观测，否则 didFinish 不触发时无从判断卡在哪。
    # 只断言 `estimatedProgress` 出现是不够的：闭包里读一次属性也算出现，
    # 真正管用的是 KVO 观察（`observe(\.estimatedProgress`）建立了进度回调。
    # 正则不写死接收者（`web.`），避免别人换个属性名就误判。
    assert re.search(r'\.observe\(\\\.estimatedProgress', controller), \
        '必须用 KVO 观察 estimatedProgress，否则卡在 loading 时没有任何日志线索'
    assert 'beginBootWatch' in controller
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

    if len(sys.argv) > 1:
        report = helper.verify_artifacts(sys.argv[1], expected_info=info if pathlib.Path(sys.argv[1]).name == helper.IPA_NAME else None)
        print('Real IPA ZIP/Mach-O/appex/SDK/signature structure/hash checks passed; cryptographic verification depends on the recorded build backend')
    print('iOS source/package contract checks passed (no Apple compilation or device validation)')


if __name__ == '__main__':
    # 非 git 目录 / 缺文件 / 别处改坏时，要给出可读的 BLOCKED 而不是一段 traceback。
    # CalledProcessError 单列：build-support 会跑 git 取提交号，在非仓库里就是它。
    try:
        main()
    except (AssertionError, ValueError, OSError, KeyError, SyntaxError, IndexError, subprocess.CalledProcessError) as error:
        message = str(error) or error.__class__.__name__
        print('BLOCKED: ' + message, file=sys.stderr)
        sys.exit(2)
