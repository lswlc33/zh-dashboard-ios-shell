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
    assert info.get('NSLocalNetworkUsageDescription', '').strip(), '局域网 TCP 缺少用途说明'
    assert 'NSBonjourServices' not in info, '纯 TCP 不应新增 Bonjour 服务发现'

    # -I 不从 cwd 导入 helper；这里只验证源码合同，不冒充 Apple 编译或签名通过。
    helper_spec = importlib.util.spec_from_file_location('zeeho_build_support', root / 'build-support.py')
    helper = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(helper)
    inputs = helper.inventory(repo)
    assert all(path.count('/') == 1 for path in inputs['swiftSources'])
    assert inputs['sharedSwiftSources'] and inputs['widgetSwiftSources'] and inputs['broadcastSwiftSources']
    assert 'ZeehoShared' not in inputs['sharedSwiftImports'] + inputs['widgetSwiftImports'] + inputs['broadcastSwiftImports']
    assert set(inputs['swiftSources']) & set(inputs['broadcastSwiftSources']) == {'ios-shell/CastProtocol.swift'}
    assert 'ios-shell/CastEncoder.swift' not in inputs['swiftSources']
    assert {'ios-shell/CastEncoder.swift', 'ios-shell/Broadcast/SampleHandler.swift'} <= set(inputs['broadcastSwiftSources'])
    assert set(inputs['hostModuleImports']) | set(inputs['sharedSwiftImports']) == set(inputs['swiftImports'])
    assert {'Network', 'NetworkExtension', 'CoreBluetooth', 'ReplayKit'} <= set(inputs['systemFrameworks'])
    assert {'ReplayKit', 'Network', 'VideoToolbox'} <= set(inputs['broadcastSystemFrameworks'])
    assert 'CommonCrypto' not in inputs['systemFrameworks'], 'CommonCrypto 是 SDK module，不是 framework'
    assert not any('/InductiveCloud.swift' in r['path'] or '/InductiveSession.swift' in r['path'] for r in inputs['files'])
    # 新增更新业务源仍由 inventory 自动发现，不维护另一份硬编码上传表。
    for name in ('UpdateService.swift', 'UpdateSourceViewController.swift'):
        if (root / name).is_file():
            assert 'ios-shell/' + name in inputs['swiftSources'], name
    assert not any(r['path'].endswith('-test.swift') or '/commonTest/' in r['path'] or '/jvmTest/' in r['path'] for r in inputs['files'])

    # iOS 图标源必须进上传白名单：build.sh 把它当硬闸门，漏了会让远程 Mac 构建
    # 在跑完 Gradle + swiftc 之后才失败，而且「上传快照 = 完整构建输入」也不成立。
    assert 'public/icons/icon-ios-1024.png' in helper.FIXED_INPUTS
    assert 'public/icons/icon-ios-1024.png' in {r['path'] for r in inputs['files']}

    # ② Shell 脚本必须按 LF 打包。read_text 会自动归一换行，撒谎，
    # 所以这里必须用 read_bytes 看真实工作树字节。
    for name in ('ios-shell/build.sh', 'native-shared/gradlew'):
        data = (repo / name).read_bytes()
        assert b'\r\n' not in data, name + ' 含 CRLF：bash 会把反斜杠续行打断'
    # .gitattributes 只在私有仓库根存在（公开镜像仓库是白名单复制，不带它）。
    # 缺文件不算失败：字节检查已经直接验了工作树；有文件时再核对规则齐全。
    attributes_path = repo / '.gitattributes'
    if attributes_path.exists():
        attributes = attributes_path.read_text(encoding='utf-8')
        for rule in ('*.sh text eol=lf', '*/gradlew text eol=lf', 'ios-shell/*.py text eol=lf'):
            assert rule in attributes, rule

    # ① build.sh 必须真的用这张满出血图，且归上传白名单管。
    build_sh = (root / 'build.sh').read_text(encoding='utf-8')
    assert 'public/icons/icon-ios-1024.png' in build_sh
    assert 'public/icons/icon-512.png' not in build_sh
    assert 'public/icons/apple-touch-icon.png' not in build_sh
    # 图标源必须真的存在，缺失时 build.sh 会 BLOCKED 退出。
    assert (repo / 'public/icons/icon-ios-1024.png').is_file()

    # version/build 只由 host plist 决定；显式参数只能断言一致，不用 CI 运行次数抬号。
    assert '--build-number' in build_sh and 'prepare-plist' in build_sh
    assert 'build-number --source "$script_dir/Info.plist"' in build_sh
    assert 'rev-list --count' not in build_sh and 'github.run_number' not in build_sh
    support_source = (root / 'build-support.py').read_text(encoding='utf-8')
    assert "p.add_argument('--build-number')" in support_source
    assert "args.build_number == info['CFBundleVersion']" in support_source
    assert inputs['version'] == info['CFBundleShortVersionString']
    assert inputs['sourceBuild'] == info['CFBundleVersion']
    assert helper.IPA_NAME == 'zeehowebnext.ipa' and helper.VERSION_NAME == 'version2.json'
    assert helper.PUBLISHED_ARTIFACTS == ('zeehowebnext.ipa', 'version2.json', 'build-manifest.json', 'source-commit.txt', 'SHA256SUMS')
    assert helper.IPA_URL == 'https://zhb.xn--fiqz59cpva341l.top/app/zeehowebnext.ipa'
    assert helper.RELEASE_NOTES == '解决了一些已知问题。\n\n目前软件处于快速更新迭代中，请及时更新并反馈问题'
    # 源简介只保留事实描述：仓库地址与 ad-hoc 免责声明不再塞进客户端介绍。
    assert helper.SOURCE_DESCRIPTION == ('几何面板是独立的极核电动车数据面板，提供车况、电量、骑行记录和已适配车辆设置。'
                                         'iOS 客户端使用 WKWebView 与原生桥，支持账号管理、面板资源更新和 iOS App 更新')
    assert 'http' not in helper.SOURCE_DESCRIPTION, '客户端介绍里不放链接'
    # 公告位用可换行的 message（全能签读），不写 nsfw 冒充公告。
    assert helper.SOURCE_MESSAGE.count('\n') == 3
    assert helper.SOURCE_MESSAGE.startswith('本软件完全免费，请勿购买和付费。')
    assert 'ios-shell/publish-artifacts.py' in helper.FIXED_INPUTS, '移交闸门必须进指纹白名单'
    assert 'dashboard-trollstore.ipa' not in build_sh

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
    for name in ('App.entitlements', 'Widgets.entitlements', 'Broadcast.entitlements'):
        with (root / 'Entitlements' / name).open('rb') as f:
            entitlements = plistlib.load(f)
        assert entitlements.get('com.apple.security.application-groups') == [app_group], name
        assert entitlements == (helper.HOST_ENTITLEMENTS if name == 'App.entitlements' else helper.EXTENSION_ENTITLEMENTS)
    assert helper.BROADCAST_ID == bundle_id + '.broadcast'
    with (root / 'Broadcast/Info.plist').open('rb') as f:
        broadcast_info = plistlib.load(f)
    helper.validate_extension_info(broadcast_info, helper.EXTENSIONS['broadcast'], template=True)
    assert helper.MAX_IPA_BYTES == 30 * 1024 * 1024, '未实测新产物不能上调 Update.swift 大小闸门'
    for token in ('--broadcast-list', '--broadcast-framework-list', '--host-module-imports-list',
                  '-module-name ZeehoCastBroadcast', 'prepare-extension --target broadcast',
                  '--scan-executable "$broadcast_dir/ZeehoCastBroadcast"',
                  '--scan-folder "$broadcast_dir/Frameworks"', 'Entitlements/Broadcast.entitlements'):
        assert token in build_sh, token
    # Widget 统一 StaticConfiguration：bundle 只注册 StaticConfiguration 控件与 Live Activity，
    # 不再有条件注册的 AppIntentConfiguration，也不调用 metadata 处理器。
    widget_bundle = (root / 'Widgets/ZeehoWidgets.swift').read_text(encoding='utf-8')
    assert 'ZeehoVehicleWidget()' in widget_bundle, 'Widget bundle 必须注册 StaticConfiguration 控件'
    assert 'AppIntentConfiguration(' not in widget_bundle, 'StaticConfiguration 之外不应再有 AppIntent 控件'
    assert 'appintentsmetadataprocessor' not in build_sh and 'Metadata.appintents' not in build_sh, \
        'StaticConfiguration 不需要 AppIntents metadata，构建脚本不应再依赖它'
    assert build_sh.index('--entitlements "$script_dir/Entitlements/Broadcast.entitlements"') < \
        build_sh.index('--entitlements "$script_dir/Entitlements/Widgets.entitlements"') < \
        build_sh.index('--entitlements "$script_dir/Entitlements/App.entitlements"'), '签名必须 Broadcast/Widget/App 由内到外'
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

    # viewDidLoad / viewWillAppear 都会刷新状态；自动下载只能每页一次，失败或取消不循环重试。
    assert re.search(r'(?m)^\s*private\s+var\s+checkedCacheRefresh\s*=\s*false\b', recovery_code), \
        '欢迎页必须持有初始为 false 的一次性刷新标记'
    assert not re.search(r'(?m)^\s*(?:self\??\.)?checkedCacheRefresh\s*=\s*false\b', recovery_code), \
        '本页不能重置 checkedCacheRefresh，否则返回页面会反复自动下载'
    refresh_cache = recovery_code.split('private func refreshCache()', 1)[1].split('\n    }', 1)[0]
    assert refresh_cache.index('cacheRefreshGeneration += 1') < refresh_cache.index('IOSPanelCache.shared.refresh'), \
        '每次预检先推进代次，旧 ready 回执不得覆盖自动下载状态'
    assert 'self.cacheRefreshGeneration == generation' in refresh_cache, \
        '欢迎页只能渲染最新预检回执'
    auto_refresh = re.search(
        r'if\s+!self\.checkedCacheRefresh\s*,\s*!state\.busy\s*\{\s*'
        r'self\.checkedCacheRefresh\s*=\s*true\s*'
        r'if\s+state\.ready\s*,\s*IOSPanelCache\.shared\.needsRefresh\(\)\s*\{'
        r'(.*?)\}\s*\}\s*self\.render\(state\)', refresh_cache, re.S)
    assert auto_refresh, '自动刷新必须在非 busy 时先消费一次性标记，再检查 ready + needsRefresh'
    automatic = auto_refresh.group(1)
    assert 'IOSPanelCache.shared.initialize(force: false)' in automatic, \
        '旧快照自动刷新必须调用非强制 initialize，使用共用的刷新判据'
    assert automatic.index('self.render(IOSPanelCache.State(phase: .preparing))') < \
        automatic.index('IOSPanelCache.shared.initialize(force: false)'), \
        '自动下载前必须先渲染 preparing，不能让旧 ready 状态继续放行'
    assert 'self?.render(next)' in automatic and automatic.rstrip().endswith('return'), \
        '自动刷新要渲染下载回执并早退，不能再用旧 ready 状态覆盖进度'

    # 资源快照：清单与自定义 scheme 必须一致，否则本地页面缺资源。
    cache_code = strip_comments((root / 'PanelCache.swift').read_text(encoding='utf-8'))
    scheme_code = strip_comments((root / 'PanelSchemeHandler.swift').read_text(encoding='utf-8'))
    assert 'static let resources' in cache_code and '"index.html"' in cache_code
    # 下载必须并发 + 预探总量，串行会让首屏等 11 个 RTT 且进度条不动。
    assert 'maxConcurrent' in cache_code and 'probeSizes' in cache_code
    assert 'httpMaximumConnectionsPerHost' in cache_code
    # 进度要实时推给界面，不能只在最后回调一次。
    assert 'var onState' in cache_code and 'throttledEmit' in cache_code

    # initialize 与对外 needsRefresh 共用 policy：有快照也不能跳过升级、过期或缺失元数据。
    refresh_policy = cache_code.split('private static func needsRefresh(meta:', 1)[1].split('\n    }', 1)[0]
    assert 'IOSPanelCachePolicy.needsRefresh(' in refresh_policy, '缓存刷新必须使用独立 policy'
    for argument in ('downloadedAt: meta.downloadedAt', 'line: meta.line', 'shellBuild: meta.shellBuild',
                     'currentLine: IOSPanelLine.current.rawValue', 'currentShellBuild: shellBuild',
                     'now: Date().timeIntervalSince1970', 'maxAgeHours: maxAgeHours'):
        assert argument in refresh_policy, '刷新 policy 缺少实际元数据或当前环境参数：' + argument
    public_refresh = cache_code.split('func needsRefresh(maxAgeHours:', 1)[1].split('\n    }', 1)[0]
    assert 'guard let meta = snapshotMeta() else { return true }' in public_refresh, \
        '缺失元数据必须要求刷新'
    assert 'Self.needsRefresh(meta: meta, maxAgeHours: maxAgeHours)' in public_refresh, \
        '对外 needsRefresh 与 initialize 必须走同一刷新判据'
    initialize = cache_code.split('func initialize(force:', 1)[1].split('\n    }', 1)[0]
    assert re.search(r'let\s+refreshNeeded\s*=\s*meta\.map\s*\{\s*Self\.needsRefresh\(meta:\s*\$0\)\s*\}\s*\?\?\s*true', initialize), \
        'initialize 必须用共用 policy 计算 refreshNeeded，缺 meta 时不能复用'
    reuse = re.search(r'if\s+([^{}]*self\.snapshotDirectory\(\)\s*!=\s*nil)\s*\{([^{}]*)\}', initialize, re.S)
    assert reuse and '!force' in reuse.group(1) and '!refreshNeeded' in reuse.group(1) and 'return' in reuse.group(2), \
        'initialize 有快照时早退必须带 !refreshNeeded，不能只检查 !force 或 !lineChanged'

    # shellBuild 是成功下载时的 IPA build，不是网页 version.json 的 build；旧记录缺字段时保留未知值。
    snapshot_meta = cache_code.split('struct SnapshotMeta', 1)[1].split('\n    }', 1)[0]
    assert re.search(r'var\s+shellBuild\s*:\s*String\s*=\s*""', snapshot_meta), \
        'SnapshotMeta 必须保存下载时的 shellBuild，旧记录默认未知'
    shell_build = cache_code.split('private static var shellBuild:', 1)[1].split('\n    }', 1)[0]
    assert 'Bundle.main.infoDictionary?["CFBundleVersion"]' in shell_build, \
        'shellBuild 必须来自当前 IPA 的 CFBundleVersion'
    read_meta = cache_code.split('private static func readMeta(', 1)[1].split('\n    }', 1)[0]
    assert 'meta.shellBuild = object["shellBuild"] as? String ?? ""' in read_meta, \
        '读取 meta 必须恢复 shellBuild；旧字段缺失不能伪装成当前 build'
    write_meta = cache_code.split('private static func writeMeta(', 1)[1].split('\n    }', 1)[0]
    assert re.search(r'"shellBuild"\s*:\s*shellBuild\b', write_meta), '成功写入的 meta 必须包含当前 shellBuild'
    commit = cache_code.split('private func commit(', 1)[1].split('\n    }', 1)[0]
    before_commit, after_commit = commit.split('try manager.moveItem(at: staging, to: current)', 1)
    committed, commit_failed = after_commit.split('} catch {', 1)
    assert 'Self.writeMeta(root: root, build: build, line: downloadLine.rawValue)' in committed, \
        '新快照成功成为 current 后必须按实际下载线路写入 meta'
    assert 'self.downloadLine = IOSPanelLine.current' in initialize and 'self.downloadLineRevision = IOSPanelLine.revision' in initialize
    assert 'IOSPanelLine.current == downloadLine' in before_commit and 'IOSPanelLine.revision == downloadLineRevision' in before_commit, \
        '发布快照前必须拒绝已切换线路或代次的旧下载'
    assert 'Self.writeMeta(' not in initialize + before_commit + commit_failed, \
        '下载或提交失败时不能写新 shellBuild，把旧快照伪装成已更新'

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

    # 小消息按真实 JSON 上界预留，而不是 txn/store 的 12MB/24MB 方法上限；
    # Foundation 行为由 bridge-budget-test.swift 验证，这里只钉住生产桥确实接入它。
    bridge_code = strip_comments((root / 'Bridge.swift').read_text(encoding='utf-8'))
    receive = bridge_code.split('fileprivate func receive(', 1)[1].split('private func authorized(', 1)[0]
    measurement = re.search(r'measuredSize\s*=\s*try\s+IOSBridgeBudget\.measure\(object,\s*limit:\s*limit\)', receive)
    reservation_size = re.search(r'let\s+size\s*=\s*measuredSize\b', receive)
    assert measurement and reservation_size and measurement.start() < reservation_size.start(), \
        'receive 必须用 IOSBridgeBudget 测量本条消息，size = measuredSize 才能让小请求并发入队'
    assert not re.search(r'\blet\s+size\s*=\s*limit\b|\bpendingBytes\s*\+=\s*limit\b|bytes:\s*limit\b', receive), \
        '不能退回按方法上限预扣 pending 字节'
    assert 'bytes: size' in receive and 'pendingBytes += size' in receive
    assert receive.index('let size = measuredSize') < receive.index('pendingBytes += size') < receive.index('worker.async'), \
        '必须在 worker 开始前按 measuredSize 预留整条消息'
    assert re.search(r'size\s*<=\s*IOSBridgePolicy\.maxPendingBytes\s*-\s*pendingBytes', receive), \
        'pending 字节闸门必须 overflow-safe，不能先相加再比较'
    assert 'pending.count < IOSBridgePolicy.maxPending' in receive, '48 条 pending 闸门不能绕过'
    assert '!pending.values.contains(where: { IOSBridgePolicy.fileMethods.contains($0.method) })' in receive, \
        '文件消息的单条并发闸门不能放宽'
    for selector in ('IOSBridgePolicy.maxFileEnvelopeBytes', 'IOSBridgePolicy.maxRequestBytes',
                     'IOSStore.maxArchiveBytes', 'IOSBridgePolicy.maxServiceBytes'):
        assert selector in receive, '本条消息仍必须遵守原方法上限：' + selector
    worker = receive.split('worker.async', 1)[1]
    assert re.search(r'validatedBytes\s*=\s*try\s+IOSBridgePolicy\.json\(object,\s*limit:\s*limit\)\.utf8\.count', worker), \
        'worker 必须保留实际 JSON 编码与原 limit 校验'
    validation_guard = re.search(r'guard\s+validatedBytes\s*<=\s*size\s+else\s*\{\s*throw\s+IOSBridgePolicy\.Failure\("request_too_large"\)\s*\}', worker)
    shrink = re.search(r'self\.pendingBytes\s*\+=\s*validatedBytes\s*-\s*reply\.bytes', worker)
    assert validation_guard and shrink and validation_guard.start() < shrink.start(), \
        '实际 JSON 不能超过预留；只允许验证成功后缩小 pending 总量'
    assert 'self.isCurrent(reply)' in worker and 'if let error = validationError' in worker
    assert worker.index('self.reject(reply, error)') < shrink.start(), '验证失败必须释放原预留，不能先改账'
    assert 'reply.bytes = validatedBytes' in worker and worker.index('reply.bytes = validatedBytes') < worker.index('self.dispatch(reply)')
    assert 'pendingBytes -= reply.bytes' in bridge_code, '完成时必须释放更新后的实际字节数'
    policy_code = strip_comments((root / 'BridgePolicy.swift').read_text(encoding='utf-8'))
    for name, value in (('maxPending', '48'), ('maxRequestBytes', '12 * 1024 * 1024'),
                        ('maxServiceBytes', '512 * 1024'), ('maxFileEnvelopeBytes', '28 * 1024 * 1024'),
                        ('maxPendingBytes', '32 * 1024 * 1024')):
        expression = r'\s*'.join(re.escape(part) for part in value.split())
        assert re.search(r'static\s+let\s+' + name + r'\s*=\s*' + expression + r'\s*(?://[^\n]*)?$', policy_code, re.M), \
            '修正预留不能放宽安全上限：' + name

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
    for name in ('RecoveryView.swift', 'PanelCache.swift', 'PanelCachePolicy.swift', 'PanelSchemeHandler.swift',
                 'PanelLine.swift', 'PanelLineService.swift', 'Dashboard.swift', 'BridgeBudget.swift',
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
