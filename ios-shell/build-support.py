#!/usr/bin/env python3
"""构建输入白名单、真实 Apple 产物清单与跨平台完整性检查；不下载工具。"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import posixpath
import re
import shutil
import stat
import struct
import subprocess
import sys
import uuid
import zipfile
from urllib.parse import parse_qsl, urlsplit

BUNDLE_ID = 'io.github.lswlc33.dashboard.ios'
APP_PREFIX = 'Payload/Dashboard.app/'
MINIMUM_IOS = '15.4'
IPA_NAME = 'zeehowebnext.ipa'
VERSION_NAME = 'version2.json'
IPA_URL = 'https://zhb.xn--fiqz59cpva341l.top/app/zeehowebnext.ipa'
RELEASE_NOTES = '解决了一些已知问题。\n\n目前软件处于快速更新迭代中，请及时更新并反馈问题'
SOURCE_ICON_NAME = 'icon-ios-1024.png'
SOURCE_ICON_URL = 'https://zhb.xn--fiqz59cpva341l.top/app/icon-ios-1024.png'
SOURCE_DESCRIPTION = ('官方更新源仓库：https://github.com/lswlc33/zeeho-3d-models\n'
                  '官方 iOS 源码仓库：https://github.com/lswlc33/zh-dashboard-ios-shell\n\n'
                  '几何面板是独立的极核电动车数据面板，提供车况、电量、骑行记录和已适配车辆设置。'
                  'iOS 客户端使用 WKWebView 与原生桥，支持账号管理、面板资源更新和 iOS App 更新；'
                  '小组件与实时活动按系统能力和授权开放。\n\n'
                  '本 IPA 为 ad-hoc 构建，当前通过 TrollStore 侧载。采用 AltStore 源格式不代表已经验证 AltStore 重签安装；'
                  '下载后请按设备支持的方式确认覆盖安装。')
MAX_IPA_BYTES = 31_457_280  # 必须仍能通过 Update.swift 的下载大小闸门。
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
FRAMEWORK_RELATIVE = 'native-shared/build/bin/iosArm64/releaseFramework/ZeehoShared.framework'
WIDGET_ID = BUNDLE_ID + '.widgets'
WIDGET_DIRECTORY = 'PlugIns/DashboardWidgets.appex/'
APP_GROUP = 'group.io.github.lswlc33.dashboard.ios'
BROADCAST_PRODUCT = 'ZeehoCastBroadcast'
BROADCAST_ID = BUNDLE_ID + '.broadcast'
BROADCAST_DIRECTORY = 'PlugIns/ZeehoCastBroadcast.appex/'
CAST_SHARED_SOURCE = 'ios-shell/CastProtocol.swift'
CAST_ENCODER_SOURCE = 'ios-shell/CastEncoder.swift'
# 文件名由各原生代理拥有；目标归属显式声明，不能把 Encoder 或 Bridge 顺手塞进 extension。
EXTENSIONS = {
    'widgets': {'product': 'DashboardWidgets', 'bundleID': WIDGET_ID,
                'directory': WIDGET_DIRECTORY, 'point': 'com.apple.widgetkit-extension',
                'plist': 'ios-shell/Widgets/Info.plist', 'entitlements': 'ios-shell/Entitlements/Widgets.entitlements'},
    'broadcast': {'product': BROADCAST_PRODUCT, 'bundleID': BROADCAST_ID,
                  'directory': BROADCAST_DIRECTORY, 'point': 'com.apple.broadcast-services-upload',
                  'plist': 'ios-shell/Broadcast/Info.plist', 'entitlements': 'ios-shell/Entitlements/Broadcast.entitlements'},
}
HOST_ENTITLEMENTS = {'com.apple.security.application-groups': [APP_GROUP],
                     'com.apple.developer.networking.HotspotConfiguration': True,
                     'com.apple.developer.networking.wifi-info': True}
EXTENSION_ENTITLEMENTS = {'com.apple.security.application-groups': [APP_GROUP]}
PRIVATE_SOURCE_NAMES = {'InductiveCloud.swift', 'InductiveSession.swift'}
# 仅匹配本轮新增的私有协议标记；基线已公开 UUID/KMP codec 不在本轮追溯删除范围。
PRIVATE_SWIFT_RE = re.compile(r'\b(?:IOSWallpaperWire|IOSInductiveCloud|IOSInductiveSession)\b|'
                              r'0x(?:7000001[01]|1000004[3-6]|8000004[35])\b|'
                              r'\b(?:statusPort|dataPort|mediaPort|controlPort)\s*:\s*UInt16\s*=\s*109[0-9]{2}\b', re.I)
# iOS 图标源：必须满出血（radius=0）、1024×1024。build.sh 指向它。
IOS_ICON = 'public/icons/icon-ios-1024.png'
# 归档进 zip 时必须是 LF 的脚本：CRLF 会让 Mac/Linux 的 bash 把 `\` 续行吃掉。
SHELL_SCRIPTS = ('ios-shell/build.sh', 'native-shared/gradlew')
FIXED_INPUTS = {
    'ios-shell/Info.plist', 'ios-shell/build.sh', 'ios-shell/build-support.py',
    'ios-shell/test.py', 'ios-shell/bridge-bootstrap.js', 'test/ios-parity-build-contract.mjs',
    'ios-shell/Entitlements/App.entitlements', 'ios-shell/Entitlements/Widgets.entitlements',
    'ios-shell/Entitlements/Broadcast.entitlements', 'ios-shell/Broadcast/Info.plist',
    CAST_SHARED_SOURCE, CAST_ENCODER_SOURCE, 'ios-shell/CastSession.swift',
    'ios-shell/Broadcast/SampleHandler.swift', 'ios-shell/VehicleNetwork.swift',
    'ios-shell/WallpaperPackage.swift',
    # 后台续期：通用 secret 句柄 + 有界签名核验 + 蓝牙握手执行器都在公开构建输入内，
    # 但它们只含通用算法/状态机，vendor 字段与配方仍由私有网页下发。
    'ios-shell/SecretHandles.swift', 'ios-shell/SessionRenewal.swift', 'ios-shell/BLERecipe.swift',
    'test/ios-session-renewal-contract.mjs', 'test/ios-renewal-handoff-contract.mjs',
    'test/ios-renewal-driver-smoke.mjs',
    'ios-shell/Widgets/Info.plist',
    'native-shared/build.gradle.kts', 'native-shared/settings.gradle.kts',
    'native-shared/gradlew', 'native-shared/gradle/wrapper/gradle-wrapper.jar',
    'native-shared/gradle/wrapper/gradle-wrapper.properties',
    'public/icons/icon-512.png',
    # build.sh 在打包 sips 图标前对它做硬闸门；不进白名单的话，
    # `build-windows.ps1 -Mode Build -MacHost -AllowSourceUpload` 会先跑完 Gradle + swiftc，
    # 才在 Mac 上因为「缺 iOS 图标源」失败，而且「上传快照 = 完整构建输入」也不成立。
    'public/icons/icon-ios-1024.png',
}
OPTIONAL_INPUTS = {
    'native-shared/gradlew.bat', 'native-shared/gradle.properties',
    'native-shared/gradle/libs.versions.toml',
}
SOURCE_SETS = {'commonMain', 'jvmMain', 'iosMain', 'iosArm64Main', 'iosSimulatorArm64Main'}
BUILTIN_MODULES = {'Swift', 'Darwin', 'ObjectiveC', 'Dispatch', 'os', '_Concurrency', '_StringProcessing', 'CommonCrypto'}
SYSTEM_LIBRARIES = {'SQLite3': 'sqlite3', 'sqlite3': 'sqlite3', 'zlib': 'z'}
# iOS 15.4 已带 Swift ABI 与并发运行时；兼容/较新的库不在这里，必须实际嵌入。
IOS154_SWIFT_LIBRARIES = {
    'libswiftCore.dylib', 'libswift_Concurrency.dylib', 'libswiftFoundation.dylib',
    'libswiftUIKit.dylib', 'libswiftWebKit.dylib', 'libswiftObjectiveC.dylib',
    'libswiftDispatch.dylib', 'libswiftDarwin.dylib', 'libswiftCoreFoundation.dylib',
    'libswiftCoreGraphics.dylib', 'libswiftCoreImage.dylib', 'libswiftCoreLocation.dylib',
    'libswiftCoreBluetooth.dylib', 'libswiftAVFoundation.dylib', 'libswiftAVFAudio.dylib',
    'libswiftCoreAudio.dylib', 'libswiftCoreMedia.dylib', 'libswiftCoreVideo.dylib',
    'libswiftIOKit.dylib', 'libswiftsimd.dylib',
    'libswiftMetal.dylib', 'libswiftNetwork.dylib', 'libswiftos.dylib',
    'libswiftPhotos.dylib', 'libswiftPhotosUI.dylib', 'libswiftMapKit.dylib',
    'libswiftSwiftUI.dylib', 'libswiftWidgetKit.dylib',
    'libswiftUniformTypeIdentifiers.dylib', 'libswiftUserNotifications.dylib',
    'libswiftAudioToolbox.dylib', 'libswiftAccelerate.dylib', 'libswiftCompression.dylib',
    'libswiftCryptoTokenKit.dylib', 'libswiftFileProvider.dylib', 'libswiftSecurity.dylib',
    'libswiftNaturalLanguage.dylib', 'libswiftQuartzCore.dylib', 'libswiftSceneKit.dylib',
    'libswiftSIMD.dylib', 'libswiftSpriteKit.dylib', 'libswiftVision.dylib',
}
IMPORT_RE = re.compile(r'^\s*(?:(?:@_exported|@_implementationOnly|@preconcurrency)\s+)*import\s+(?:(?:class|enum|struct|protocol|var|func|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)', re.M)


def require(condition, message):
    if not condition:
        raise ValueError(message)


# 这些是真·文本：Windows（CRLF）与 CI/Mac（LF）对同一 commit 必须给出同一个指纹，
# 否则「上传快照 == 完整构建输入」这条安全前提在跨平台时永远对不上。
# 除常见源码扩展名外，还必须覆盖 .entitlements（XML 模板）、.toml（libs.versions）、
# .xml/.html/.css/.txt —— 仓库里都存在，漏掉就会让同一 commit 有两个指纹。
TEXT_EXTENSIONS = {
    '.swift', '.py', '.sh', '.js', '.mjs', '.json', '.plist', '.entitlements', '.yml', '.yaml',
    '.md', '.kt', '.kts', '.gradle', '.properties', '.toml', '.xml', '.html', '.css', '.txt', '.bat',
}


def is_text_input(name):
    base = str(name).replace('\\', '/').rsplit('/', 1)[-1]
    # Gradle wrapper 没有扩展名，但它是必须按 LF 执行的 Shell 脚本。
    return base == 'gradlew' or pathlib.PurePosixPath(base).suffix.lower() in TEXT_EXTENSIONS


def normalized_bytes(path):
    """读源文件字节；文本类把 CRLF 折成 LF，二进制（png/ipa/jar）原样返回。

    archive/extract/inventory 三处都走这里，归档里写的就是归一化后的字节，
    所以 Mac 上解包后重算哈希仍然等于清单；二进制不做归一，避免改动签名数据。
    """
    data = pathlib.Path(path).read_bytes()
    if is_text_input(pathlib.Path(path).name):
        return data.replace(b'\r\n', b'\n')
    return data


def sha256_file(path):
    """对磁盘内容取哈希；文本类先归一换行，二进制逐字节精确。"""
    digest = hashlib.sha256()
    path = pathlib.Path(path)
    if is_text_input(path.name):
        digest.update(normalized_bytes(path))
        return digest.hexdigest()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def load_json(path):
    path = pathlib.Path(path)
    require(path.is_file() and 0 < path.stat().st_size <= MAX_MANIFEST_BYTES, 'Missing/oversized JSON manifest: ' + str(path))
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def safe_relative(name):
    require(isinstance(name, str) and '\\' not in name and '\x00' not in name, 'Invalid archive path')
    parts = pathlib.PurePosixPath(name).parts
    require(parts and not name.startswith('/') and all(p not in ('.', '..') and ':' not in p for p in parts), 'Unsafe archive path: ' + name)
    require('/'.join(parts) == name.rstrip('/'), 'Non-canonical archive path: ' + name)
    return parts


def public_input(name):
    parts = safe_relative(name)
    if parts[-1] in PRIVATE_SOURCE_NAMES:
        return False
    if name in FIXED_INPUTS or name in OPTIONAL_INPUTS:
        return True
    if any(p.startswith('.') or p in {'private', 'config', 'node_modules', 'build', 'dist'} for p in parts):
        return False
    if parts[0] == 'ios-shell' and name.endswith('.swift') and not name.endswith('-test.swift'):
        return (len(parts) == 2) or (
            len(parts) == 3 and parts[1] in {'Shared', 'Widgets', 'Broadcast'})
    return (len(parts) >= 5 and parts[:2] == ('native-shared', 'src')
            and parts[2] in SOURCE_SETS and parts[3] == 'kotlin' and name.endswith('.kt')
            and all(not p.startswith('.') and p not in {'private', 'config', 'node_modules'} for p in parts))


def regular_source(root, relative):
    require(public_input(relative), 'Not in source upload allowlist: ' + relative)
    path = root.joinpath(*safe_relative(relative))
    require(path.is_file(), 'Missing required source: ' + relative)
    for component in [path, *path.parents]:
        if component == root.parent:
            break
        require(not component.is_symlink() and not getattr(component, 'is_junction', lambda: False)(), 'Source links/junctions are not allowed: ' + relative)
    require(path.resolve().is_relative_to(root), 'Source escaped repository: ' + relative)
    require(stat.S_ISREG(path.stat().st_mode), 'Source must be a regular file: ' + relative)
    return path


def check_public_properties(path):
    # 私有 Gradle 配置不能借“构建必要文件”随源码上传。
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '!')):
            continue
        key = re.split(r'[=:\s]', line, maxsplit=1)[0]
        require(re.fullmatch(r'(?:org\.gradle\.(?:jvmargs|parallel|caching|configuration-cache|workers\.max)|kotlin\.(?:code\.style|mpp\.[A-Za-z0-9_.-]+|native\.[A-Za-z0-9_.-]+|daemon\.jvmargs|incremental)|android\.useAndroidX)', key), 'Non-public Gradle property blocked: ' + key)
        require(not re.search(r'(?i)(password|credential|access[_-]?token|api[_-]?key|secret|keystore|signing|javaagent|(?:[A-Z]:[\\/])|/(?:Users|home|private|etc)/)', line), 'Private/credential-like Gradle property blocked')


def tree_digest(records):
    encoded = json.dumps(records, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return hashlib.sha256(encoded).hexdigest()


def source_record(root, name):
    """清单条目用「归一化后的字节」计数与取哈希，保证归档内容、清单、解包复算三者一致。"""
    data = normalized_bytes(regular_source(root, name))
    return {'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def inventory(root, expected=None):
    root = pathlib.Path(root).resolve()
    missing = sorted(name for name in FIXED_INPUTS if not root.joinpath(*name.split('/')).is_file())
    require(not missing, 'Missing build inputs (no replacement is generated):\n  ' + '\n  '.join(missing))
    names = set(FIXED_INPUTS)
    names.update(name for name in OPTIONAL_INPUTS if root.joinpath(*name.split('/')).is_file())
    for directory in ('', 'Shared', 'Widgets', 'Broadcast'):
        for path in (root / 'ios-shell' / directory).glob('*.swift'):
            name = path.relative_to(root).as_posix()
            if path.name.endswith('-test.swift') or path.name in PRIVATE_SOURCE_NAMES:
                continue
            require(public_input(name), 'Swift source outside public build paths: ' + name)
            names.add(name)
    for path in (root / 'native-shared' / 'src').rglob('*.kt'):
        name = path.relative_to(root).as_posix()
        if name.split('/')[2].endswith('Test'):
            continue
        require(public_input(name), 'Kotlin source outside supported KMP source sets: ' + name)
        names.add(name)
    require(any(n.startswith('native-shared/src/commonMain/kotlin/') for n in names), 'KMP commonMain Kotlin source is missing')
    require(any(n.startswith('native-shared/src/jvmMain/kotlin/') for n in names), 'KMP JVM source is missing')
    # 反向断言：iOS 图标源必须真的进清单（光有 FIXED_INPUTS 条目还不够，
    # 白名单被谁改窄时这里要立刻 BLOCKED，而不是等到 Mac 上 sips 之前才发现）。
    require(IOS_ICON in names, 'Missing iOS app icon source in the upload allowlist: ' + IOS_ICON)
    icon = regular_source(root, IOS_ICON)
    # 满出血 1024×1024 是 iOS 的唯一正确形状：带圆角会让系统再切一次角。
    with icon.open('rb') as stream:
        header = stream.read(24)
    require(header.startswith(b'\x89PNG\r\n\x1a\n') and struct.unpack_from('>II', header, 16) == (1024, 1024),
            IOS_ICON + ' must be a 1024x1024 PNG (full-bleed, radius=0)')
    swift = sorted(n for n in names if n.startswith('ios-shell/') and n.endswith('.swift')
                   and len(n.split('/')) == 2 and n != CAST_ENCODER_SOURCE)
    shared = sorted(n for n in names if n.startswith('ios-shell/Shared/') and n.endswith('.swift'))
    widgets = sorted(n for n in names if n.startswith('ios-shell/Widgets/') and n.endswith('.swift'))
    broadcast = sorted({CAST_SHARED_SOURCE, CAST_ENCODER_SOURCE} |
                       {n for n in names if n.startswith('ios-shell/Broadcast/') and n.endswith('.swift')})
    require(swift and len(shared) >= 3 and widgets and len(broadcast) >= 3,
            'Host/Shared/Widgets/Broadcast sources missing; no replacement extension is generated')
    require(set(swift) & set(broadcast) == {CAST_SHARED_SOURCE}, 'Only CastProtocol.swift may be shared by Host/Broadcast')
    target_modules = {}
    for target, source_names in (('host', swift), ('shared', shared), ('widgets', widgets), ('broadcast', broadcast)):
        modules = set()
        for name in source_names:
            source = regular_source(root, name).read_text(encoding='utf-8')
            require(not re.search(r'canImport\s*\(', source), 'Conditional framework fallback is forbidden: ' + name)
            require(not PRIVATE_SWIFT_RE.search(source), 'Private protocol Swift must stay outside build/upload inputs: ' + name)
            if target == 'broadcast':
                require(not re.search(r'\b(?:IOSBridge\w*|IOSStore|IOSRideScope|IOSVehicleNetworkService)\b', source),
                        'Broadcast must not depend on Host Bridge/business services: ' + name)
            modules.update(IMPORT_RE.findall(source))
        target_modules[target] = modules
    # Shared 的 object 真正链接进 Host；把 imports 合并，不能遗漏其系统框架。
    modules = target_modules['host'] | target_modules['shared']
    require('ZeehoShared' in target_modules['host'], 'Business Swift must import the real ZeehoShared framework; no fallback build')
    require('ZeehoShared' not in target_modules['shared'] | target_modules['widgets'] | target_modules['broadcast'],
            'Shared/Widgets/Broadcast must not import KMP')
    require('ZeehoSystemShared' not in target_modules['broadcast'], 'Broadcast must not depend on the Widget shared module')
    require({'SwiftUI', 'WidgetKit', 'ZeehoSystemShared'} <= target_modules['widgets'], 'Widget target/module contract is missing')
    require({'CoreBluetooth', 'Network', 'NetworkExtension', 'ReplayKit'} <= modules,
            'Host must link real generic BLE/Network/Hotspot/ReplayKit system APIs')
    require({'ReplayKit', 'Network', 'VideoToolbox', 'CoreMedia', 'CoreVideo'} <= target_modules['broadcast'],
            'Broadcast must compile its real ReplayKit/network/encoder sources')
    for name, contract in EXTENSIONS.items():
        with regular_source(root, contract['entitlements']).open('rb') as stream:
            entitlements = plistlib.load(stream)
        require(entitlements == EXTENSION_ENTITLEMENTS, 'Extension must contain only the public App Group template: ' + name)
        with regular_source(root, contract['plist']).open('rb') as stream:
            extension_info = plistlib.load(stream)
        validate_extension_info(extension_info, contract, template=True)
    with regular_source(root, 'ios-shell/Entitlements/App.entitlements').open('rb') as stream:
        host_entitlements = plistlib.load(stream)
    require(host_entitlements == HOST_ENTITLEMENTS,
            'Host template must contain exactly App Group, HotspotConfiguration and wifi-info; this is not provisioning approval')
    for name in ('native-shared/build.gradle.kts', 'native-shared/settings.gradle.kts'):
        text = regular_source(root, name).read_text(encoding='utf-8')
        require(not re.search(r'org\.jetbrains\.compose|androidx\.compose|compose\.multiplatform', text), 'Compose/CMP is not part of the UIKit shared-core architecture')
    wrapper_text = regular_source(root, 'native-shared/gradle/wrapper/gradle-wrapper.properties').read_text(encoding='utf-8')
    require(re.search(r'^distributionUrl=https\\://services\.gradle\.org/distributions/gradle-\d+(?:\.\d+)+-(?:bin|all)\.zip\s*$', wrapper_text, re.M), 'Only a public official Gradle distribution URL is allowed in the source snapshot')
    if 'native-shared/gradle.properties' in names:
        check_public_properties(regular_source(root, 'native-shared/gradle.properties'))
    records = [source_record(root, name) for name in sorted(names)]
    with regular_source(root, 'ios-shell/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    validate_info(info)
    if expected is not None:
        require(expected.get('schemaVersion') == 1, 'Unsupported source manifest schema')
        require(records == expected.get('files') and tree_digest(records) == expected.get('sourceTreeSha256'), 'Sources differ from the explicitly approved upload snapshot')
        commit, dirty = expected.get('sourceCommit'), expected.get('sourceDirty')
    else:
        commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True, encoding='utf-8').strip()
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all', '--', *sorted(names)], text=True, encoding='utf-8').strip())
    require(isinstance(commit, str) and re.fullmatch(r'[0-9a-f]{40,64}', commit), 'A real source commit is required')
    require(isinstance(dirty, bool), 'Invalid source dirty flag')
    return {
        'schemaVersion': 1, 'architecture': 'arm64', 'minimumIOS': MINIMUM_IOS,
        'sourceCommit': commit, 'sourceDirty': dirty, 'sourceTreeSha256': tree_digest(records),
        'sharedFramework': 'ZeehoShared', 'sharedFrameworkPath': FRAMEWORK_RELATIVE,
        'sharedTask': ':linkReleaseFrameworkIosArm64', 'jvmTestTask': ':jvmTest',
        'version': info['CFBundleShortVersionString'], 'sourceBuild': info['CFBundleVersion'],
        'swiftSources': swift, 'sharedSwiftSources': shared, 'widgetSwiftSources': widgets,
        'broadcastSwiftSources': broadcast, 'hostModuleImports': sorted(target_modules['host']),
        'swiftImports': sorted(modules), 'sharedSwiftImports': sorted(target_modules['shared']),
        'widgetSwiftImports': sorted(target_modules['widgets']),
        'broadcastSwiftImports': sorted(target_modules['broadcast']),
        'systemFrameworks': sorted(modules - BUILTIN_MODULES - set(SYSTEM_LIBRARIES) - {'ZeehoShared', 'ZeehoSystemShared'}),
        'sharedSystemFrameworks': sorted(target_modules['shared'] - BUILTIN_MODULES),
        'widgetSystemFrameworks': sorted((target_modules['widgets'] | target_modules['shared']) - BUILTIN_MODULES - {'ZeehoSystemShared'}),
        'broadcastSystemFrameworks': sorted(target_modules['broadcast'] - BUILTIN_MODULES - set(SYSTEM_LIBRARIES)),
        'systemLibraries': sorted({SYSTEM_LIBRARIES[m] for m in modules if m in SYSTEM_LIBRARIES}),
        'broadcastSystemLibraries': sorted({SYSTEM_LIBRARIES[m] for m in target_modules['broadcast'] if m in SYSTEM_LIBRARIES}),
        'extensions': EXTENSIONS,
        'files': records,
    }


def validate_output_directory(root, output):
    raw_output = pathlib.Path(output).absolute()
    for component in (raw_output, *raw_output.parents):
        require(not component.is_symlink() and not getattr(component, 'is_junction', lambda: False)(),
                'OUTPUT_DIRECTORY_FORBIDDEN: output paths must not contain links/junctions')
    root, output = pathlib.Path(root).resolve(), raw_output.resolve()
    require(output != root and not root.is_relative_to(output), 'OUTPUT_DIRECTORY_FORBIDDEN: source roots/parents are not artifact directories')
    if output.is_relative_to(root):
        relative = output.relative_to(root).parts
        require(len(relative) >= 2 and relative[:2] in {('ios-shell', 'dist'), ('ios-shell', '.build-local')},
                'OUTPUT_DIRECTORY_FORBIDDEN: only ios-shell/dist or .build-local may contain build output inside source')
    elif output.exists():
        require(output.is_dir() and not any(output.iterdir()),
                'OUTPUT_DIRECTORY_FORBIDDEN: external output must be a new/empty directory')
    if output.exists():
        require(not any(p.name.endswith(('.app', '.appex', '.ipa')) or p.name in {'version.json', VERSION_NAME, 'build-manifest.json'}
                        for p in output.iterdir()), 'OUTPUT_ARTIFACT_EXISTS: choose a fresh output directory; do not overwrite examined artifacts')
    return output


PUBLISHED_ARTIFACTS = (IPA_NAME, VERSION_NAME, 'build-manifest.json', 'source-commit.txt', 'SHA256SUMS')


def publish_artifacts(root, staged, output):
    """把暂存产物整体搬进输出目录，要么全有要么全无。

    逐文件 `xb` 拷贝在磁盘满/权限错误时会留下「有 ipa 但没有 version.json/SHA256SUMS」
    的半套产物，而下游（README、发布脚本）只看 ipa 存在就当成功。
    所以先写到输出目录里的临时子目录 `.publish-<uuid>`，全部写成功后再逐个
    `os.replace` 到最终路径；任何一步失败都删掉临时目录并让输出目录保持原状。
    """
    output = validate_output_directory(root, output)
    staged = pathlib.Path(staged).resolve()
    for name in PUBLISHED_ARTIFACTS:
        require((staged / name).is_file(), 'Staged artifact is missing: ' + name)
    output.mkdir(parents=True, exist_ok=True)
    temp = output / ('.publish-' + uuid.uuid4().hex)
    temp.mkdir()
    try:
        for name in PUBLISHED_ARTIFACTS:
            with (staged / name).open('rb') as source, (temp / name).open('xb') as destination:
                shutil.copyfileobj(source, destination)
        for name in PUBLISHED_ARTIFACTS:
            os.replace(temp / name, output / name)
    finally:
        # 成功时临时目录已空；失败时把半成品清掉，别留一个看起来像产物目录的残留。
        shutil.rmtree(temp, ignore_errors=True)
    return output


def validate_info(info, executable='Dashboard', bundle_id=BUNDLE_ID):
    require(info.get('CFBundlePackageType') == 'APPL' and info.get('CFBundleExecutable') == executable, 'Invalid app executable/package type')
    require(info.get('CFBundleIdentifier') == bundle_id, 'Unexpected bundle identifier')
    require(info.get('NSSupportsLiveActivities') is True, 'Host must declare NSSupportsLiveActivities')
    require(info.get('MinimumOSVersion') == MINIMUM_IOS, 'Deployment must be iOS 15.4')
    require('NSAppTransportSecurity' not in info, 'Do not package an ATS bypass')
    require(isinstance(info.get('NSLocalNetworkUsageDescription'), str)
            and bool(info['NSLocalNetworkUsageDescription'].strip()), 'Local TCP networking requires a user-facing purpose string')
    require('NSBonjourServices' not in info, 'Pure TCP networking must not declare Bonjour discovery')
    require(isinstance(info.get('NSBluetoothAlwaysUsageDescription'), str)
            and bool(info['NSBluetoothAlwaysUsageDescription'].strip()), 'Native BLE requires a user-facing purpose string')
    require(re.fullmatch(r'\d{1,4}\.\d{1,4}(?:\.\d{1,4})?', info.get('CFBundleShortVersionString', '')), 'Invalid release version')
    require(re.fullmatch(r'[1-9][0-9]*', info.get('CFBundleVersion', ''))
            and int(info['CFBundleVersion']) <= 2**53 - 1, 'Invalid/unsafe build number')


def validate_extension_info(info, contract, host=None, template=False):
    """按 extension point 精确验证，不能为了第二个 appex 放开所有嵌套 executable。"""
    extension = info.get('NSExtension', {})
    require(isinstance(extension, dict) and extension.get('NSExtensionPointIdentifier') == contract['point']
            and 'EXAppExtensionAttributes' not in info, 'Invalid extension point/type: ' + contract['product'])
    if contract['point'] == 'com.apple.broadcast-services-upload':
        principals = ({'$(PRODUCT_MODULE_NAME).SampleHandler', contract['product'] + '.SampleHandler'}
                      if template else {contract['product'] + '.SampleHandler'})
        require(extension.get('NSExtensionPrincipalClass') in principals
                and extension.get('RPBroadcastProcessMode') == 'RPBroadcastProcessModeSampleBuffer'
                and 'RPBroadcastProcessMode' not in extension.get('NSExtensionAttributes', {})
                and 'NSExtensionMainStoryboard' not in extension, 'Broadcast principal class/sample-buffer contract missing')
    else:
        require('NSExtensionPrincipalClass' not in extension and 'NSExtensionMainStoryboard' not in extension,
                'WidgetKit must retain its WidgetBundle entry contract')
    if not template:
        require(info.get('CFBundlePackageType') == 'XPC!' and info.get('CFBundleExecutable') == contract['product']
                and info.get('CFBundleIdentifier') == contract['bundleID']
                and info.get('MinimumOSVersion') == MINIMUM_IOS
                and info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Invalid appex identity/deployment')
        if host is not None:
            require(info.get('CFBundleVersion') == host['CFBundleVersion']
                    and info.get('CFBundleShortVersionString') == host['CFBundleShortVersionString'], 'Host/appex version mismatch')
    require('NSAppTransportSecurity' not in info and 'NSBonjourServices' not in info, 'Extension must not bypass ATS/add Bonjour')


def archive_sources(root, output, manifest_path):
    root, output, manifest_path = pathlib.Path(root).resolve(), pathlib.Path(output).resolve(), pathlib.Path(manifest_path).resolve()
    require(not output.exists() and not manifest_path.exists(), 'Archive/manifest must be new files in their own empty staging directories')
    require(output.parent != manifest_path.parent, 'Archive data and creator/control files must use separate directories')
    require(output.parent.is_dir() and not any(output.parent.iterdir()), 'Archive directory must be new and empty')
    manifest = inventory(root)
    normalized = []
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for record in manifest['files']:
            path = regular_source(root, record['path'])
            # 文本类先归一 CRLF→LF：Windows 工作树的脚本按原始字节打包，
            # 到 Mac 上 `bash build.sh` 会把 `\` + CRLF 的续行断掉（报
            # `--swift-list: command not found`）。归一后清单哈希也按同样字节算，
            # 解包端复算仍然一致；这里只警告不 BLOCKED，因为这是开发者本地配置
            # 差异，不是源码错误（.gitattributes 已声明 *.sh eol=lf）。
            raw = path.read_bytes()
            data = raw.replace(b'\r\n', b'\n') if is_text_input(record['path']) else raw
            if hashlib.sha256(data).hexdigest() != record['sha256']:
                raise ValueError('Source changed while making archive: ' + record['path'])
            # 归一后仍带孤立的 CR（老式 Mac 行尾 / 混写）无法安全修复：
            # bash 会把 `\` + CR 当成未知参数，症状与 CRLF 完全一样。
            # 这种才是真的源码问题，必须 BLOCKED 而不是静默归一。
            if record['path'] in SHELL_SCRIPTS and b'\r' in data:
                raise ValueError('BLOCKED: ' + record['path'] + ' 含 CRLF（或孤立 CR），Shell 脚本必须在 LF 下打包')
            if data != raw:
                normalized.append(record['path'])
            entry = zipfile.ZipInfo(record['path'])
            entry.create_system = 3
            mode = 0o755 if record['path'] in SHELL_SCRIPTS else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    require(output.stat().st_size <= MAX_ARCHIVE_BYTES, 'Source archive exceeds the bounded upload size')
    manifest['archiveSha256'] = sha256_file(output)
    manifest['archiveSize'] = output.stat().st_size
    if normalized:
        # 记在清单里，方便事后解释「上传字节与工作树字节为何不同」；
        # 终端只打一行摘要，别把几十个文件名刷满构建日志。
        manifest['normalizedLineEndings'] = sorted(normalized)
        preview = ', '.join(sorted(normalized)[:3])
        print(f'warning: normalized CRLF to LF in {len(normalized)} text input(s) before archiving ({preview}...)', file=sys.stderr)
    write_json(manifest_path, manifest)
    return manifest


def checked_zip(path, max_bytes):
    path = pathlib.Path(path)
    require(path.is_file() and 0 < path.stat().st_size <= max_bytes, 'Missing or oversized ZIP: ' + str(path))
    archive = zipfile.ZipFile(path)
    try:
        entries = archive.infolist()
        require(0 < len(entries) <= 4096, 'Invalid ZIP entry count')
        seen = set()
        for entry in entries:
            safe_relative(entry.filename)
            folded = entry.filename.rstrip('/').casefold()
            require(folded not in seen, 'Duplicate/case-colliding ZIP entry: ' + entry.filename)
            seen.add(folded)
            require(not entry.flag_bits & 1, 'Encrypted ZIP entries are not supported')
            mode = entry.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'ZIP links/special files are forbidden: ' + entry.filename)
            require(entry.file_size <= MAX_UNCOMPRESSED_BYTES, 'Oversized ZIP member')
        require(sum(e.file_size for e in entries) <= MAX_UNCOMPRESSED_BYTES, 'ZIP expanded size exceeds limit')
        require(archive.testzip() is None, 'ZIP CRC validation failed')
        return archive
    except BaseException:
        archive.close()
        raise


def extract_sources(archive_path, manifest_path, destination):
    manifest = load_json(manifest_path)
    destination = pathlib.Path(destination).resolve()
    require(destination.is_dir() and not any(destination.iterdir()), 'Extraction requires its own new, empty directory')
    require(sha256_file(archive_path) == manifest.get('archiveSha256'), 'Source archive SHA-256 mismatch')
    require(pathlib.Path(archive_path).stat().st_size == manifest.get('archiveSize'), 'Source archive size mismatch')
    records = manifest.get('files', [])
    require(isinstance(records, list) and records, 'Missing upload allowlist manifest')
    expected = {r['path']: r for r in records}
    require(len(expected) == len(records) and tree_digest(records) == manifest.get('sourceTreeSha256'), 'Invalid source tree manifest')
    with checked_zip(archive_path, MAX_ARCHIVE_BYTES) as archive:
        require(set(archive.namelist()) == set(expected), 'ZIP contains omitted or non-allowlisted inputs')
        for entry in archive.infolist():
            name = entry.filename
            require(public_input(name) and not entry.is_dir(), 'Source archive contains a forbidden path: ' + name)
            record, data = expected[name], archive.read(name)
            require(len(data) == record['size'] and hashlib.sha256(data).hexdigest() == record['sha256'], 'Source entry hash mismatch: ' + name)
            target = destination.joinpath(*safe_relative(name))
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream:
                stream.write(data)
            target.chmod(0o755 if name.endswith(('/gradlew', '/build.sh')) else 0o644)
    inventory(destination, manifest)
    return manifest


def unpack_version(value):
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'


def macho(data, expected_type, signed=True, expected_minimum=0x000F0400):
    require(len(data) >= 32, 'Truncated Mach-O')
    magic, cpu, subtype, filetype, ncmds, command_size, flags, reserved = struct.unpack_from('<8I', data)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and subtype & 0xFFFFFF in (0, 1), 'Expected a thin arm64 device Mach-O (not simulator/fat/placeholder)')
    require(filetype == expected_type, 'Unexpected Mach-O file type')
    require(0 < ncmds <= 8192 and command_size <= len(data) - 32, 'Invalid Mach-O load commands')
    offset, imports, rpaths, platform, minimum, sdk, signature, symtab, dysymtab, entrypoint = 32, [], [], None, None, None, None, None, None, False
    entry_offset, text_ranges, sections = None, [], []
    for _ in range(ncmds):
        require(offset + 8 <= 32 + command_size, 'Truncated load command')
        command, size = struct.unpack_from('<II', data, offset)
        require(size >= 8 and size % 4 == 0 and offset + size <= 32 + command_size, 'Invalid load command size')
        if command == 0x19:
            require(size >= 72, 'Truncated LC_SEGMENT_64')
            segment = data[offset + 8:offset + 24].split(b'\x00', 1)[0]
            vm_address = struct.unpack_from('<Q', data, offset + 24)[0]
            file_offset, file_size = struct.unpack_from('<QQ', data, offset + 40)
            require(file_offset + file_size <= len(data), 'Segment file range exceeds binary')
            if segment == b'__TEXT':
                text_ranges.append((file_offset, file_offset + file_size, vm_address))
            # 记下 S_SYMBOL_STUBS 段落：扩展的入口常常不是已定义符号，
            # 而是 lazy bind 的 `_NSExtensionMain` stub（真机产物实测就是这样）。
            section_count = struct.unpack_from('<I', data, offset + 64)[0]
            require(size >= 72 + section_count * 80, 'Truncated LC_SEGMENT_64 sections')
            for index in range(section_count):
                base = offset + 72 + index * 80
                section_addr, section_size = struct.unpack_from('<QQ', data, base + 32)
                section_flags = struct.unpack_from('<I', data, base + 64)[0]
                reserved1, reserved2 = struct.unpack_from('<II', data, base + 68)
                if section_flags & 0xFF == 0x8:  # S_SYMBOL_STUBS
                    sections.append((section_addr, section_size, reserved1, reserved2))
        elif command in (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20, 0x8000001C):
            require(size >= 12, 'Invalid dynamic import/rpath command')
            start = struct.unpack_from('<I', data, offset + 8)[0]
            require(12 <= start < size, 'Invalid load command string')
            text = data[offset + start:offset + size].split(b'\x00', 1)[0].decode('utf-8')
            require(text and '\x00' not in text, 'Empty dynamic import')
            if command == 0x8000001C:
                rpaths.append(text)
            else:
                imports.append({'path': text, 'weak': command == 0x80000018})
        elif command == 0x32:
            require(size >= 24, 'Truncated LC_BUILD_VERSION')
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
        elif command == 0x25 and platform is None:
            require(size >= 16, 'Truncated LC_VERSION_MIN_IPHONEOS')
            platform = 2
            minimum, sdk = struct.unpack_from('<II', data, offset + 8)
        elif command == 0x80000028:
            require(size >= 24, 'Truncated LC_MAIN')
            entry_offset = struct.unpack_from('<Q', data, offset + 8)[0]
            entrypoint = True
        elif command == 0x1D:
            require(size >= 16, 'Truncated LC_CODE_SIGNATURE')
            signature = struct.unpack_from('<II', data, offset + 8)
        elif command == 0x2:
            require(size >= 24, 'Truncated LC_SYMTAB')
            symtab = struct.unpack_from('<4I', data, offset + 8)
        elif command == 0xB:
            # LC_DYSYMTAB = cmd/cmdsize + 18 个 uint32（共 80 字节）。
            # 只解 18 个：写成 20 会读到命令之外，撞上后面命令的字节。
            require(size >= 80, 'Truncated LC_DYSYMTAB')
            dysymtab = struct.unpack_from('<18I', data, offset + 8)
        offset += size
    require(offset == 32 + command_size, 'Inconsistent Mach-O command table')
    require(platform == 2 and minimum is not None and minimum <= expected_minimum, 'Mach-O is not compatible with the required iOS device deployment')
    lc_main_address = None
    if entry_offset is not None:
        for start, end, base in text_ranges:
            if start <= entry_offset < end:
                lc_main_address = base + (entry_offset - start)
                break
    if expected_type == 2:
        require(minimum == expected_minimum and sdk is not None and sdk >= minimum, 'Executable deployment/SDK load-command record is missing or incorrect')
        require(entrypoint and entry_offset is not None and any(start <= entry_offset < end for start, end, _ in text_ranges),
                'Real executable LC_MAIN entrypoint must address the __TEXT file range')
    signature_metadata = {'present': signature is not None, 'cryptographicVerification': False}
    if signed:
        require(signature is not None, 'Mach-O is missing a code signature')
        start, size = signature
        require(size >= 20 and start >= 32 + command_size and start + size <= len(data), 'Invalid embedded code signature range')
        magic, length, count = struct.unpack_from('>3I', data, start)
        require(magic == 0xFADE0CC0 and 12 + count * 8 <= length <= size and count <= 128, 'Invalid code-signature SuperBlob')
        directories = []
        for index in range(count):
            kind, blob_offset = struct.unpack_from('>II', data, start + 12 + index * 8)
            require(blob_offset >= 12 + count * 8 and blob_offset + 8 <= length, 'Invalid signature slot')
            blob_magic, blob_size = struct.unpack_from('>II', data, start + blob_offset)
            require(blob_size >= 8 and blob_offset + blob_size <= length, 'Truncated signature blob')
            if kind == 0 or 0x1000 <= kind <= 0x1005:
                require(blob_magic == 0xFADE0C02 and blob_size >= 44, 'Missing CodeDirectory')
                directories.append(blob_offset)
                version, directory_flags = struct.unpack_from('>II', data, start + blob_offset + 8)
                identifier_offset = struct.unpack_from('>I', data, start + blob_offset + 20)[0]
                require(44 <= identifier_offset < blob_size, 'Invalid CodeDirectory identifier')
                blob = data[start + blob_offset:start + blob_offset + blob_size]
                identifier = blob[identifier_offset:].split(b'\x00', 1)[0].decode('utf-8')
                signature_metadata.update({'identifier': identifier, 'adHoc': bool(directory_flags & 2)})
                if version >= 0x20200 and blob_size >= 52:
                    team_offset = struct.unpack_from('>I', blob, 48)[0]
                    if team_offset:
                        require(team_offset < blob_size, 'Invalid CodeDirectory team offset')
                        signature_metadata['teamID'] = blob[team_offset:].split(b'\x00', 1)[0].decode('utf-8')
            elif kind == 5:
                require(blob_magic == 0xFADE7171, 'Invalid XML entitlements slot')
                entitlements = plistlib.loads(data[start + blob_offset + 8:start + blob_offset + blob_size])
                require(isinstance(entitlements, dict), 'Invalid signature entitlements')
                signature_metadata['entitlements'] = entitlements
        require(directories, 'Code signature has no CodeDirectory')
    shared_symbols, widget_symbols, main_symbols, objc_classes = [], [], [], []
    extension_entry_address = None
    if symtab:
        symbol_offset, count, string_offset, string_size = symtab
        require(count <= 1_000_000 and symbol_offset + count * 16 <= len(data) and string_offset + string_size <= len(data), 'Invalid Mach-O symbols')
        strings = data[string_offset:string_offset + string_size]

        def symbol_name(index):
            start = struct.unpack_from('<I', data, symbol_offset + index * 16)[0]
            require(start < len(strings), 'Invalid symbol name offset')
            end = strings.find(b'\x00', start)
            require(end >= start, 'Unterminated Mach-O symbol')
            return strings[start:end]

        for index in range(count):
            # 避免逐符号复制整个 string table；只统计真正定义的 KMP 类，非未解析 imports。
            symbol_type = data[symbol_offset + index * 16 + 4]
            name = symbol_name(index)
            if symbol_type & 0x0E == 0x0E and name.startswith(b'_OBJC_CLASS_$_'):
                objc_classes.append(name.decode('utf-8'))
            if symbol_type & 0x0E == 0x0E and name.startswith(b'_OBJC_CLASS_$_ZeehoShared'):
                shared_symbols.append(name.decode('utf-8'))
            if name == b'_NSExtensionMain':
                # 只认真正定义在某个 section 里的符号（`& 0x0E == 0x0E` ⇒ N_SECT）；
                # ld 自动为 `-e _NSExtensionMain` 生成的 stub 会让同名符号以 undef 出现，
                # 旧代码不过滤类型，等于「导入即算」，入口根本没被验证。
                if symbol_type & 0x0E == 0x0E:
                    extension_entry_address = struct.unpack_from('<Q', data, symbol_offset + index * 16 + 8)[0]
                    widget_symbols.append(name.decode('utf-8'))
            if symbol_type & 0x0E == 0x0E and name in (b'_main', b'_Dashboard_main'):
                main_symbols.append(name.decode('utf-8'))
        # 扩展的 LC_MAIN 通常落在 lazy 绑定的 `_NSExtensionMain` stub 上（真机产物实测），
        # 那种形态下符号表里只有 undef；这里用 __stubs + 间接符号表把入口解析回符号名。
        if entry_offset is not None and lc_main_address is not None and dysymtab and dysymtab[13]:
            indirect_offset, indirect_count = dysymtab[12], dysymtab[13]
            require(indirect_offset + indirect_count * 4 <= len(data), 'Invalid indirect symbol table')
            for section_address, section_size, first, stride in sections:
                if stride and section_address <= lc_main_address < section_address + section_size:
                    slot = first + (lc_main_address - section_address) // stride
                    require(slot < indirect_count, 'LC_MAIN stub index outside the indirect symbol table')
                    value = struct.unpack_from('<I', data, indirect_offset + slot * 4)[0] & 0x7FFFFFFF
                    require(value < count, 'Invalid stub symbol index')
                    if symbol_name(value) == b'_NSExtensionMain':
                        extension_entry_address = lc_main_address
                        if not widget_symbols:
                            widget_symbols.append('_NSExtensionMain')
                    break
    return {'architecture': 'arm64', 'platform': 'iOS', 'minimumIOS': unpack_version(minimum),
            'SDKVersion': unpack_version(sdk) if sdk is not None else None,
            'fileType': {1: 'object', 2: 'executable', 6: 'dylib'}[expected_type],
            'imports': imports, 'rpaths': rpaths, 'codeSignaturePresent': signature is not None,
            'signature': signature_metadata, 'entrypointPresent': entrypoint, 'mainSymbols': main_symbols,
            'extensionEntrypointSymbols': widget_symbols, 'entryAddress': lc_main_address,
            'extensionEntryAddress': extension_entry_address, 'definedObjCClasses': sorted(objc_classes),
            'sharedClassSymbolCount': len(shared_symbols), 'sharedClassSymbols': shared_symbols[:8]}


def objc_runtime_class(symbol):
    """解码符号表中的 ObjC runtime 名，不凭预计 module/class 长度构造证据。"""
    prefix = '_OBJC_CLASS_$_'
    if not symbol.startswith(prefix):
        return None
    name = symbol[len(prefix):]
    if not name.startswith('_TtC'):
        return name  # 显式 @objc 名称原样交由 Info 的 principal 精确匹配。
    tail, components = name[4:], []
    while tail:
        match = re.match(r'([1-9][0-9]*)', tail)
        if not match:
            return None
        length = int(match.group(1))
        tail = tail[match.end():]
        if length > len(tail):
            return None
        components.append(tail[:length])
        tail = tail[length:]
    return '.'.join(components) if len(components) == 2 else None


def framework_kind(path):
    path = pathlib.Path(path).resolve()
    require(path.name == 'ZeehoShared.framework', 'Unexpected KMP framework name')
    require((path / 'Headers' / 'ZeehoShared.h').is_file() and (path / 'Modules' / 'module.modulemap').is_file(), 'KMP framework headers/module map missing')
    require('ZeehoShared' in (path / 'Modules' / 'module.modulemap').read_text(encoding='utf-8'), 'Wrong KMP module map')
    binary = path / 'ZeehoShared'
    require(binary.is_file() and binary.stat().st_size > 4096, 'KMP framework binary is missing/empty')
    data = binary.read_bytes()
    if data.startswith(b'!<arch>\n'):
        offset, objects = 8, 0
        while offset < len(data):
            require(offset + 60 <= len(data) and data[offset + 58:offset + 60] == b'`\n', 'Invalid static KMP archive member')
            name = data[offset:offset + 16].decode('ascii').strip()
            size = int(data[offset + 48:offset + 58].decode('ascii').strip())
            member_start = offset + 60
            require(size >= 0 and member_start + size <= len(data), 'Truncated static KMP archive')
            if name.startswith('#1/'):
                name_size = int(name[3:])
                require(0 < name_size <= size, 'Invalid static archive extended name')
                name = data[member_start:member_start + name_size].rstrip(b'\x00').decode('utf-8')
                member_start += name_size
            member = data[member_start:offset + 60 + size]
            if member.startswith(b'\xcf\xfa\xed\xfe'):
                # arm64 simulator 也用相同 CPU；逐对象检查 Apple platform/minOS，不能只看 lipo 架构。
                macho(member, 1, signed=False)
                objects += 1
            else:
                require(name.startswith('__.SYMDEF') or name in ('/', '//', '/SYM64/'), 'Unexpected non-arm64 object in static KMP framework: ' + name)
            offset += 60 + size + (size % 2)
        require(offset == len(data) and objects > 0, 'Static KMP archive has no valid arm64 iOS object files')
        return 'static'
    macho(data, 6, signed=False)
    return 'dynamic'


def resolve_imports(reports, names, app_prefix=APP_PREFIX):
    def bundled(candidate):
        return posixpath.normpath(candidate) in names

    for name, report in reports.items():
        allowed_rpaths = {'@executable_path/Frameworks', '@executable_path/../../Frameworks', '/usr/lib/swift',
                          '@loader_path/Frameworks', '@loader_path', '@loader_path/..', '@loader_path/../..'}
        require(set(report['rpaths']) <= allowed_rpaths, 'Unexpected build-machine rpath in ' + name)
        executable_dir = posixpath.dirname(name)
        inherited = []
        if '.framework/' in name or name.endswith('.dylib'):
            executable_dir = app_prefix.rstrip('/')
            for contract in EXTENSIONS.values():
                prefix = app_prefix + contract['directory']
                if name.startswith(prefix):
                    executable_dir = prefix.rstrip('/')
                    break
            executable_name = next((n for n in reports if posixpath.dirname(n) == executable_dir
                                    and reports[n]['fileType'] == 'executable'), None)
            if executable_name:
                inherited = reports[executable_name]['rpaths']
        for item in report['imports']:
            dependency = item['path']
            require('/../' not in dependency and '\\' not in dependency, 'Unsafe dylib import')
            if dependency.startswith(('/System/Library/Frameworks/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/'):
                suffix = dependency[len('@rpath/'):]
                for rpath in set(report['rpaths'] + inherited):
                    candidate = rpath.replace('@executable_path', executable_dir).replace('@loader_path', posixpath.dirname(name))
                    if bundled(candidate + '/' + suffix):
                        break
                    if suffix in IOS154_SWIFT_LIBRARIES and candidate == '/usr/lib/swift':
                        break
                else:
                    raise ValueError('Unresolved/non-iOS dylib import in ' + name + ': ' + dependency)
                continue
            elif dependency.startswith('@executable_path/'):
                if bundled(executable_dir + '/' + dependency[len('@executable_path/'):]):
                    continue
            elif dependency.startswith('@loader_path/'):
                if bundled(posixpath.dirname(name) + '/' + dependency[len('@loader_path/'):]):
                    continue
            raise ValueError('Unresolved/non-iOS dylib import in ' + name + ': ' + dependency)


def validate_ipa(path, expected_info=None):
    path = pathlib.Path(path).resolve()
    product = 'Dashboard'
    app_prefix = APP_PREFIX
    base_id = BUNDLE_ID
    with checked_zip(path, MAX_IPA_BYTES) as archive:
        names = set(archive.namelist())
        require(all(n in ('Payload/', app_prefix) or n.startswith(app_prefix) for n in names), 'IPA contains files outside the expected app')
        require(not any(n.endswith(('.jks', '.p12', '.pem', '.key')) for n in names), 'IPA must not contain private signing material')
        require(not any(n.endswith('.mobileprovision') for n in names), 'Ad-hoc IPA must not contain provisioning profiles')
        info = plistlib.loads(archive.read(app_prefix + 'Info.plist'))
        actual_id = info.get('CFBundleIdentifier', '')
        require(actual_id == base_id, 'Unexpected bundle ID/prefix')
        validate_info(info, executable=product, bundle_id=actual_id)
        if expected_info:
            require(actual_id == expected_info['CFBundleIdentifier']
                    and info['CFBundleShortVersionString'] == expected_info['CFBundleShortVersionString']
                    and info['CFBundleVersion'] == expected_info['CFBundleVersion'], 'Packaged version/build/bundle differs from source')
        resource_name = app_prefix + '_CodeSignature/CodeResources'
        require(resource_name in names, 'App resource code signature missing')
        require(isinstance(plistlib.loads(archive.read(resource_name)), dict), 'Invalid app resource signature')
        # 包内必须存在图标 PNG，且每张都是正方形、边长 ≥ 60；
        # mac 后端额外钉住 sips 产出的四个固定尺寸——那是 build.sh 的既有契约。
        icon_entries = sorted(
            name for name in names
            if name.startswith(app_prefix) and '/_CodeSignature/' not in name
            and re.fullmatch(r'(?:Icon|AppIcon)[^/]*\.png', name.rsplit('/', 1)[-1]))
        require(icon_entries, 'App bundle has no icon PNG; iOS would show a blank icon')
        for name in icon_entries:
            icon = archive.read(name)
            require(icon.startswith(b'\x89PNG\r\n\x1a\n') and len(icon) >= 24, 'Invalid icon PNG: ' + name)
            width, height = struct.unpack_from('>II', icon, 16)
            require(width == height and width >= 60, 'Icon must be a square PNG at least 60px: ' + name)
        for size in (120, 152, 167, 180):
            name = app_prefix + f'Icon{size}.png'
            require(name in names, f'Missing fixed icon size: Icon{size}.png')
            icon = archive.read(name)
            require(struct.unpack_from('>II', icon, 16) == (size, size), f'Icon{size}.png is not {size}x{size}')
        bridge = archive.read(app_prefix + 'bridge-bootstrap.js')
        require(bridge.strip(), 'bridge-bootstrap.js is missing/empty')
        binary_name = app_prefix + product
        reports = {binary_name: macho(archive.read(binary_name), 2)}
        main = reports[binary_name]
        require({'_main'}.intersection(main['mainSymbols']), 'Host executable main/module entrypoint symbol missing')
        signature_id = main['signature'].get('identifier')
        require(signature_id == actual_id, 'CodeDirectory identifier must match actual Info.plist bundle ID')
        extension_prefixes = {key: app_prefix + contract['directory'] for key, contract in EXTENSIONS.items()}
        for name in names:
            extension_parts = [p for p in safe_relative(name) if p.endswith('.appex')]
            require(not extension_parts or (len(extension_parts) == 1 and
                    any(name.startswith(prefix) or name.rstrip('/') == prefix.rstrip('/')
                        for prefix in extension_prefixes.values())), 'Unexpected/nested extension bundle: ' + name)
        require(main['signature'].get('entitlements') == HOST_ENTITLEMENTS,
                'Host signature must match the scoped public networking/App Group template; not proof of provisioning approval')
        for key, contract in EXTENSIONS.items():
            prefix = extension_prefixes[key]
            binary = prefix + contract['product']
            require(binary in names and prefix + 'Info.plist' in names, 'Expected real appex executable/Info is missing: ' + key)
            extension_info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            validate_extension_info(extension_info, contract, host=info)
            resources = prefix + '_CodeSignature/CodeResources'
            require(resources in names and isinstance(plistlib.loads(archive.read(resources)), dict), 'Extension resource signature missing/invalid: ' + key)
            code = reports[binary] = macho(archive.read(binary), 2)
            # 导入符号本身不够；LC_MAIN 必须落在真正 _NSExtensionMain 定义或 stub 上。
            require(code['extensionEntrypointSymbols'] and code['extensionEntryAddress'] is not None
                    and code['entryAddress'] == code['extensionEntryAddress']
                    and code['signature'].get('identifier') == contract['bundleID'],
                    'Extension _NSExtensionMain must be the real LC_MAIN entrypoint and match the signature identity: ' + key)
            require(code['sharedClassSymbolCount'] == 0 and not any('ZeehoShared.framework' in i['path'] for i in code['imports']),
                    'KMP must not be linked into extensions: ' + key)
            require(code['signature'].get('entitlements') == EXTENSION_ENTITLEMENTS,
                    'Extension signature must contain only the matching App Group template; not proof of provisioning approval: ' + key)
            require({'@executable_path/Frameworks', '@executable_path/../../Frameworks', '/usr/lib/swift'} <= set(code['rpaths']),
                    'Extension runtime search paths are incomplete: ' + key)
            if key == 'widgets':
                # Widget 只用 StaticConfiguration，不再依赖 AppIntents；ActivityKit 仍需弱链接。
                imports = [i for i in code['imports'] if '/ActivityKit.framework/' in i['path']]
                require(imports and all(i['weak'] for i in imports), 'iOS 15.4 Widget must weak-link ActivityKit')
                require(not any('/AppIntents.framework/' in i['path'] for i in code['imports']),
                        'Widget no longer uses AppIntents; it must not link it')
            if key == 'broadcast':
                require(any('/ReplayKit.framework/' in i['path'] for i in code['imports'])
                        and any('/VideoToolbox.framework/' in i['path'] for i in code['imports']),
                        'Broadcast must link real ReplayKit/VideoToolbox')
                require(extension_info['NSExtension']['NSExtensionPrincipalClass'] in
                        {objc_runtime_class(symbol) for symbol in code['definedObjCClasses']},
                        'Broadcast principal class is not defined in the real executable')
        # 上游侧载边界适用于全部 executable，新增 Broadcast 不得漏验或冒充正式 Apple 签名。
        for code in reports.values():
            require(code['signature'].get('adHoc') is True and not code['signature'].get('teamID'),
                    'Expected team-free ad-hoc Host/Widget/Broadcast signature, not Apple distribution signing')
        for name in sorted(names):
            if name.endswith('/') or name in reports:
                continue
            data = archive.read(name)
            is_framework = '.framework/' in name and name.rsplit('/', 1)[-1] == name.split('.framework/', 1)[0].rsplit('/', 1)[-1]
            if name.endswith('.dylib') or is_framework:
                require(name.startswith(app_prefix + 'Frameworks/') or
                        any(name.startswith(prefix + 'Frameworks/') for prefix in extension_prefixes.values()),
                        'Embedded code must be under expected Frameworks')
                require('ZeehoSystemShared' not in name and not
                        (any(name.startswith(prefix) for prefix in extension_prefixes.values()) and 'ZeehoShared' in name),
                        'Swift shared sources are not an embedded binary/KMP extension dependency')
                reports[name] = macho(data, 6)
            elif data.startswith((b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'!<arch>\n')):
                raise ValueError('Unexpected executable/archive in IPA: ' + name)
        # Widget 已统一用 StaticConfiguration，不再声明 AppIntents 配置，因此包内不应出现
        # Metadata.appintents；如果出现了，说明构建还在用旧的 AppIntentConfiguration。
        metadata_prefix = extension_prefixes['widgets'] + 'Metadata.appintents/'
        require(not any(n.startswith(metadata_prefix) for n in names),
                'Widget must not embed AppIntents metadata: StaticConfiguration only')
        widget_metadata = []
        dynamic = app_prefix + 'Frameworks/ZeehoShared.framework/ZeehoShared'
        linkage = 'static'
        if dynamic in reports:
            require(any(i['path'].endswith('/ZeehoShared.framework/ZeehoShared') for i in main['imports']), 'Embedded ZeehoShared is not linked')
            require(reports[dynamic]['sharedClassSymbolCount'] > 0, 'Dynamic KMP framework has no real classes')
            linkage = 'dynamic'
        else:
            require(main['sharedClassSymbolCount'] > 0, 'KMP_FRAMEWORK_MISSING: no real ZeehoShared classes linked into app')
        resolve_imports(reports, names, app_prefix)
        return {'info': info, 'linkage': linkage, 'machO': reports, 'artifactKind': 'full-app',
                'widgetAppIntentsMetadata': widget_metadata,
                'bridgeSha256': hashlib.sha256(bridge).hexdigest(),
                'executableSha256': hashlib.sha256(archive.read(binary_name)).hexdigest()}


def validate_target_frameworks(reports, inputs):
    targets = [(APP_PREFIX + 'Dashboard', 'systemFrameworks')]
    targets.extend((APP_PREFIX + c['directory'] + c['product'],
                    {'widgets': 'widgetSystemFrameworks', 'broadcast': 'broadcastSystemFrameworks'}[key])
                   for key, c in EXTENSIONS.items())
    # Swift overlay 模块不一定以 .framework 形式出现在 LC_LOAD_DYLIB：
    # Network 的 Swift API 由 /usr/lib/swift/libswiftNetwork.dylib 承载，
    # 链接后没有 Network.framework 条目。这里按两种真实形态分别接受，
    # 不放松「必须真的链接」这条要求。
    swift_overlays = {'Network': '/usr/lib/swift/libswiftNetwork.dylib'}
    for binary, key in targets:
        linked = '\n'.join(item['path'] for item in reports[binary]['imports'])
        for name in inputs[key]:
            forms = ['/' + name + '.framework/']
            if name in swift_overlays:
                forms.append(swift_overlays[name])
            require(any(form in linked for form in forms),
                    'Imported system framework not linked into ' + binary + ': ' + name)


def release_metadata(path, info):
    """公开清单只由已验证包推导；Android 风格字段与原 iOS 九键必须同值。"""
    path = pathlib.Path(path)
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'bundleIdentifier': BUNDLE_ID, 'minimumIOS': MINIMUM_IOS, 'architecture': 'arm64',
            'installer': 'TrollStore', 'file': IPA_NAME, 'size': path.stat().st_size, 'sha256': sha256_file(path),
            'versionName': info['CFBundleShortVersionString'], 'versionCode': int(info['CFBundleVersion']),
            'url': IPA_URL, 'notes': RELEASE_NOTES}


def validate_release_date(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value),
            'Release date must be the recorded CI UTC ISO8601 timestamp')
    datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
    return value


def source_json(path, report, release_date):
    """生成 AltStore source；仅一个 App 和最新版本，介绍使用官方字段。"""
    info = report['info']
    metadata = release_metadata(path, info)
    entitlement_keys = set()
    for code in report['machO'].values():
        entitlement_keys.update(code['signature'].get('entitlements', {}))
    entitlement_keys -= {'application-identifier', 'com.apple.developer.team-identifier'}
    privacy = {key: value for key, value in info.items() if key.endswith('UsageDescription')}
    require(all(isinstance(value, str) and value.strip() for value in privacy.values()), 'Invalid privacy usage description')
    name = info.get('CFBundleDisplayName')
    require(isinstance(name, str) and name.strip(), 'App display name must come from host Info.plist')
    return {'name': '几何面板 iOS 官方源', 'subtitle': '几何面板 iOS 客户端与最新版本更新',
            'description': SOURCE_DESCRIPTION, 'iconURL': SOURCE_ICON_URL,
            'website': 'https://github.com/lswlc33/zeeho-3d-models',
            'apps': [{'name': name, 'bundleIdentifier': info['CFBundleIdentifier'], 'developerName': 'lswlc33',
                      'subtitle': '极核电动车车况与骑行数据面板', 'localizedDescription': SOURCE_DESCRIPTION,
                      'iconURL': SOURCE_ICON_URL, 'category': 'utilities',
                      'versions': [{'version': metadata['version'], 'buildVersion': metadata['build'],
                                    'date': validate_release_date(release_date), 'localizedDescription': RELEASE_NOTES,
                                    'downloadURL': IPA_URL + '?sha256=' + metadata['sha256'], 'size': metadata['size'],
                                    'minOSVersion': info['MinimumOSVersion']}],
                      'appPermissions': {'entitlements': sorted(entitlement_keys), 'privacy': privacy}}], 'news': []}


def from_source(value):
    """从单版本 source 提取内部校验报告，不把旧平面字段写回公开 source。"""
    require(isinstance(value, dict) and isinstance(value.get('apps'), list) and len(value['apps']) == 1,
            'AltStore source must contain exactly one App')
    app = value['apps'][0]
    require(isinstance(app, dict) and isinstance(app.get('versions'), list) and len(app['versions']) == 1,
            'AltStore source must contain only the latest version')
    latest = app['versions'][0]
    require(isinstance(latest, dict), 'Invalid AltStore version object')
    version, build = latest.get('version'), latest.get('buildVersion')
    require(isinstance(version, str) and re.fullmatch(r'\d{1,4}\.\d{1,4}(?:\.\d{1,4})?', version), 'Invalid AltStore release version')
    require(isinstance(build, str) and re.fullmatch(r'[1-9][0-9]*', build) and int(build) <= 2**53 - 1,
            'Invalid AltStore buildVersion')
    validate_release_date(latest.get('date'))
    download = latest.get('downloadURL')
    require(isinstance(download, str) and len(download) <= len(IPA_URL) + 72, 'Invalid AltStore download URL')
    parsed, base = urlsplit(download), urlsplit(IPA_URL)
    require(parsed.scheme == base.scheme and parsed.netloc == base.netloc and parsed.path == base.path
            and not parsed.fragment, 'Unexpected AltStore download origin/path')
    query = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=1)
    require(len(query) == 1 and query[0][0] == 'sha256' and re.fullmatch(r'[0-9a-f]{64}', query[0][1]),
            'AltStore download URL requires exactly one SHA-256 query')
    digest = query[0][1]
    require(download == IPA_URL + '?sha256=' + digest, 'Non-canonical AltStore download URL')
    require(type(latest.get('size')) is int and 0 < latest['size'] <= MAX_IPA_BYTES, 'Invalid AltStore IPA size')
    require(app.get('bundleIdentifier') == BUNDLE_ID and latest.get('minOSVersion') == MINIMUM_IOS
            and latest.get('localizedDescription') == RELEASE_NOTES,
            'Unexpected AltStore identity/deployment/notes contract')
    return {'version': version, 'build': build, 'bundleIdentifier': app['bundleIdentifier'],
            'minimumIOS': latest['minOSVersion'], 'architecture': 'arm64', 'installer': 'TrollStore',
            'file': IPA_NAME, 'size': latest['size'], 'sha256': digest,
            'versionName': version, 'versionCode': int(build), 'url': IPA_URL, 'notes': latest['localizedDescription']}


def verify_artifacts(path, expected_info=None, source_manifest=None):
    path = pathlib.Path(path).resolve()
    report = validate_ipa(path, expected_info)
    source, manifest = load_json(path.parent / VERSION_NAME), load_json(path.parent / 'build-manifest.json')
    require((path.parent / VERSION_NAME).stat().st_size <= 32_768, 'Release metadata exceeds Update.swift size limit')
    require(source == source_json(path, report, manifest.get('releaseDate')), 'AltStore source metadata differs from the actual package/CI date')
    metadata = from_source(source)
    info, digest = report['info'], sha256_file(path)
    for key, expected in release_metadata(path, info).items():
        require(type(metadata.get(key)) is type(expected) and metadata[key] == expected, 'Release metadata mismatch: ' + key)
    require(path.name == IPA_NAME, 'Unexpected IPA filename')
    for sidecar in ('source-commit.txt', 'SHA256SUMS'):
        require(0 < (path.parent / sidecar).stat().st_size <= 4096, 'Missing/oversized text sidecar: ' + sidecar)
    source_commit = (path.parent / 'source-commit.txt').read_text(encoding='utf-8').strip()
    require(manifest.get('executableSha256') == report['executableSha256'], 'Build manifest executable hash mismatch')
    require(manifest.get('tools', {}).get('xcode') and manifest.get('tools', {}).get('swift') and manifest.get('tools', {}).get('iphoneosSDK'), 'Actual Apple toolchain version record is missing')
    require(re.fullmatch(r'[0-9a-f]{40,64}', source_commit), 'Invalid source commit sidecar')
    sums = (path.parent / 'SHA256SUMS').read_text(encoding='utf-8')
    require(sums == digest + '  ' + IPA_NAME + '\n', 'SHA256SUMS mismatch')
    require(manifest.get('schemaVersion') == 1 and manifest.get('ipaSha256') == digest and manifest.get('ipaSize') == path.stat().st_size, 'Build manifest IPA hash/size mismatch')
    require(manifest.get('sourceCommit') == source_commit and manifest.get('sharedLinkage') == report['linkage'], 'Build manifest source/linkage mismatch')
    # AltStore source 不携带内部构建指纹/授权结论；这些仍在 CI manifest 与批准快照精确复核。
    require(isinstance(manifest.get('sourceDirty'), bool), 'Source dirty state is missing')
    require(manifest.get('extensions') == EXTENSIONS, 'Build manifest extension topology mismatch')
    require(all(manifest.get(key) is False for key in ('appGroupProvisioningVerified', 'networkingProvisioningVerified')),
            'Ad-hoc templates cannot claim Apple capability authorization')
    validate_target_frameworks(report['machO'], manifest)
    require(re.fullmatch(r'[0-9a-f]{64}', manifest.get('sharedFrameworkSha256', '')), 'Shared framework checksum missing')
    require(manifest.get('widgetAppIntentsMetadata') == report['widgetAppIntentsMetadata'], 'Widget AppIntents metadata checksum mismatch')
    require(manifest.get('machO') == report['machO'] and manifest.get('bridgeSha256') == report['bridgeSha256'], 'Build manifest Mach-O/resource mismatch')
    require(manifest.get('buildHostPlatform') == 'Darwin' and manifest.get('codeSigningVerifiedOnMac') is True, 'Missing actual macOS code-sign verification record')
    records = manifest.get('inputs', [])
    require(records and len({r['path'] for r in records}) == len(records)
            and all(public_input(r['path']) for r in records)
            and FIXED_INPUTS <= {r['path'] for r in records}
            and tree_digest(records) == manifest.get('sourceTreeSha256'), 'Invalid/incomplete build input manifest')
    record_names = {r['path'] for r in records}
    host_sources = set(manifest.get('swiftSources', []))
    broadcast_sources = set(manifest.get('broadcastSwiftSources', []))
    require(host_sources & broadcast_sources == {CAST_SHARED_SOURCE}
            and {CAST_ENCODER_SOURCE, 'ios-shell/Broadcast/SampleHandler.swift', CAST_SHARED_SOURCE} <= broadcast_sources
            and all(not n.startswith('ios-shell/Broadcast/') and n != CAST_ENCODER_SOURCE for n in host_sources),
            'Invalid Host/Broadcast source ownership in build manifest')
    require({n for n in record_names if n.endswith('.swift')} ==
            host_sources | broadcast_sources | set(manifest.get('sharedSwiftSources', [])) | set(manifest.get('widgetSwiftSources', [])),
            'Build manifest omitted or invented Swift compilation inputs')
    require(metadata == release_metadata(path, info), 'Release source/package report mismatch')
    bridge_record = next((r for r in records if r['path'] == 'ios-shell/bridge-bootstrap.js'), None)
    require(bridge_record and bridge_record['sha256'] == report['bridgeSha256'], 'Packaged bridge differs from build sources')
    if source_manifest is not None:
        approved = load_json(source_manifest)
        require(approved.get('files') == records and approved.get('sourceTreeSha256') == manifest['sourceTreeSha256']
                and approved.get('sourceCommit') == source_commit and approved.get('sourceDirty') == manifest['sourceDirty'], 'Returned artifact does not match the approved upload snapshot')
    return report


def write_release(ipa, inputs_path, framework, app):
    require(sys.platform == 'darwin', 'Release metadata can only be created after a real macOS build')
    ipa, app = pathlib.Path(ipa).resolve(), pathlib.Path(app).resolve()
    inputs = load_json(inputs_path)
    # 从内到外逐个验签；--deep 最终验 host，但不能取代逐个 extension/framework 检查。
    for directory in [app / 'Frameworks', *(app / c['directory'] / 'Frameworks' for c in EXTENSIONS.values())]:
        for path in sorted(directory.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if (path.is_dir() and path.name.endswith('.framework')) or (path.is_file() and path.name.endswith('.dylib')):
                subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
    for contract in EXTENSIONS.values():
        subprocess.run(['codesign', '--verify', '--strict', str(app / contract['directory'])], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    report = validate_ipa(ipa)
    require(report['linkage'] == framework_kind(framework), 'Linked/shared framework kind differs')
    require(report['info']['CFBundleShortVersionString'] == inputs['version']
            and report['info']['CFBundleVersion'] == inputs['sourceBuild'], 'Source version/build changed or was overridden during build')
    bridge_record = next(r for r in inputs['files'] if r['path'] == 'ios-shell/bridge-bootstrap.js')
    require(bridge_record['sha256'] == report['bridgeSha256'], 'Bridge changed during packaging')
    validate_target_frameworks(report['machO'], inputs)
    digest, info = sha256_file(ipa), report['info']
    tool_paths = {name: shutil.which(name) for name in ('xcrun', 'xcodebuild', 'codesign', 'java', 'python3', 'zip', 'sips')}
    tools = {
        'paths': tool_paths,
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True, encoding='utf-8').strip(),
        'swift': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'swiftc', '--version'], text=True, encoding='utf-8').strip(),
        'iphoneosSDK': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True, encoding='utf-8').strip(),
        'swiftStdlibTool': subprocess.check_output(['xcrun', '--find', 'swift-stdlib-tool'], text=True, encoding='utf-8').strip(),
        'java': subprocess.check_output(['java', '-version'], stderr=subprocess.STDOUT, text=True, encoding='utf-8').strip(),
        'python': sys.version.split()[0],
    }
    manifest = {'schemaVersion': 1, 'buildHostPlatform': 'Darwin', 'codeSigningVerifiedOnMac': True,
                'releaseDate': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'signing': 'ad-hoc; scoped entitlement templates only; Apple provisioning and TrollStore compatibility unverified',
                'appGroupProvisioningVerified': False, 'networkingProvisioningVerified': False,
                'trollStoreCompatibility': 'unverified', 'extensions': EXTENSIONS,
                'widgetSwiftSources': inputs['widgetSwiftSources'], 'sharedSwiftSources': inputs['sharedSwiftSources'],
                'broadcastSwiftSources': inputs['broadcastSwiftSources'],
                'broadcastSwiftImports': inputs['broadcastSwiftImports'],
                'broadcastSystemFrameworks': inputs['broadcastSystemFrameworks'],
                'broadcastSystemLibraries': inputs['broadcastSystemLibraries'],
                'hostModuleImports': inputs['hostModuleImports'],
                'widgetSystemFrameworks': inputs['widgetSystemFrameworks'],
                'sharedSwiftImports': inputs['sharedSwiftImports'], 'widgetSwiftImports': inputs['widgetSwiftImports'],
                'sourceCommit': inputs['sourceCommit'], 'sourceDirty': inputs['sourceDirty'],
                'sourceTreeSha256': inputs['sourceTreeSha256'], 'inputs': inputs['files'],
                'swiftSources': inputs['swiftSources'], 'swiftImports': inputs['swiftImports'],
                'systemFrameworks': inputs['systemFrameworks'], 'systemLibraries': inputs['systemLibraries'],
                'sharedTask': inputs['sharedTask'], 'sharedFramework': 'ZeehoShared',
                'sharedLinkage': report['linkage'], 'sharedFrameworkSha256': sha256_file(pathlib.Path(framework) / 'ZeehoShared'),
                'ipaSha256': digest, 'ipaSize': ipa.stat().st_size, 'bridgeSha256': report['bridgeSha256'],
                'executableSha256': report['executableSha256'],
                'widgetAppIntentsMetadata': report['widgetAppIntentsMetadata'],
                'machO': report['machO'], 'tools': tools}
    metadata = release_metadata(ipa, info)
    write_json(ipa.parent / VERSION_NAME, source_json(ipa, report, manifest['releaseDate']))
    write_json(ipa.parent / 'build-manifest.json', manifest)
    (ipa.parent / 'source-commit.txt').write_text(inputs['sourceCommit'] + '\n', encoding='utf-8')
    (ipa.parent / 'SHA256SUMS').write_text(digest + '  ' + IPA_NAME + '\n', encoding='utf-8')
    verify_artifacts(ipa)
    return metadata


def prepare_extension_info(source, destination, host, target):
    """版本与 host 一致；Broadcast 的 PRODUCT_MODULE_NAME 展开为真正 swiftc module。"""
    contract = EXTENSIONS[target]
    with pathlib.Path(source).open('rb') as stream:
        info = plistlib.load(stream)
    validate_extension_info(info, contract, template=True)
    info.update({'CFBundleName': contract['product'], 'CFBundleExecutable': contract['product'],
                 'CFBundleIdentifier': contract['bundleID'], 'CFBundlePackageType': 'XPC!',
                 'CFBundleShortVersionString': host['CFBundleShortVersionString'], 'CFBundleVersion': host['CFBundleVersion'],
                 'MinimumOSVersion': MINIMUM_IOS, 'CFBundleSupportedPlatforms': ['iPhoneOS']})
    if target == 'broadcast':
        info['NSExtension']['NSExtensionPrincipalClass'] = contract['product'] + '.SampleHandler'
    validate_extension_info(info, contract, host=host)
    with pathlib.Path(destination).open('wb') as stream:
        plistlib.dump(info, stream)


def prepare_widget_info(source, destination, host):
    # 保持旧命令/函数入口兼容，内部使用同一精确 appex map。
    prepare_extension_info(source, destination, host, 'widgets')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('publish')
    p.add_argument('--root', required=True)
    p.add_argument('--staged', required=True)
    p.add_argument('--output', required=True)
    p = commands.add_parser('output-check')
    p.add_argument('--root', required=True)
    p.add_argument('--output', required=True)
    p = commands.add_parser('inputs')
    p.add_argument('--root', required=True)
    p.add_argument('--source-manifest')
    p.add_argument('--manifest')
    p.add_argument('--swift-list')
    p.add_argument('--shared-list')
    p.add_argument('--widget-list')
    p.add_argument('--broadcast-list')
    p.add_argument('--host-module-imports-list')
    p.add_argument('--broadcast-framework-list')
    p.add_argument('--broadcast-library-list')
    p.add_argument('--shared-framework-list')
    p.add_argument('--widget-framework-list')
    p.add_argument('--framework-list')
    p.add_argument('--library-list')
    p = commands.add_parser('archive')
    p.add_argument('--root', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--manifest', required=True)
    p = commands.add_parser('extract')
    p.add_argument('--archive', required=True)
    p.add_argument('--manifest', required=True)
    p.add_argument('--destination', required=True)
    p = commands.add_parser('framework-kind')
    p.add_argument('--path', required=True)
    p = commands.add_parser('build-number')
    p.add_argument('--source', required=True)
    p.add_argument('--build-number')
    p = commands.add_parser('prepare-plist')
    p.add_argument('--source', required=True)
    p.add_argument('--destination', required=True)
    p.add_argument('--build-number')
    p = commands.add_parser('prepare-widget')
    p.add_argument('--source', required=True)
    p.add_argument('--destination', required=True)
    p.add_argument('--host-info', required=True)
    p = commands.add_parser('prepare-extension')
    p.add_argument('--target', choices=tuple(EXTENSIONS), required=True)
    p.add_argument('--source', required=True)
    p.add_argument('--destination', required=True)
    p.add_argument('--host-info', required=True)
    p = commands.add_parser('write-release')
    p.add_argument('--ipa', required=True)
    p.add_argument('--inputs', required=True)
    p.add_argument('--framework', required=True)
    p.add_argument('--app', required=True)
    p = commands.add_parser('verify')
    p.add_argument('--ipa', required=True)
    p.add_argument('--source-manifest')
    args = parser.parse_args()
    if args.command == 'publish':
        publish_artifacts(args.root, args.staged, args.output)
    elif args.command == 'output-check':
        print(validate_output_directory(args.root, args.output))
    elif args.command == 'inputs':
        value = inventory(args.root, load_json(args.source_manifest) if args.source_manifest else None)
        if args.manifest:
            write_json(args.manifest, value)
        for target, key in ((args.swift_list, 'swiftSources'), (args.shared_list, 'sharedSwiftSources'),
                            (args.widget_list, 'widgetSwiftSources'), (args.broadcast_list, 'broadcastSwiftSources'),
                            (args.host_module_imports_list, 'hostModuleImports'),
                            (args.broadcast_framework_list, 'broadcastSystemFrameworks'),
                            (args.broadcast_library_list, 'broadcastSystemLibraries'),
                            (args.shared_framework_list, 'sharedSystemFrameworks'),
                            (args.widget_framework_list, 'widgetSystemFrameworks'), (args.framework_list, 'systemFrameworks'),
                            (args.library_list, 'systemLibraries')):
            if target:
                pathlib.Path(target).write_text(''.join(name + '\n' for name in value[key]), encoding='utf-8')
        print(json.dumps({k: v for k, v in value.items() if k != 'files'}, ensure_ascii=True, indent=2))
    elif args.command == 'archive':
        value = archive_sources(args.root, args.output, args.manifest)
        print(f"Allowlisted snapshot: {len(value['files'])} files; SHA-256 {value['archiveSha256']}")
    elif args.command == 'extract':
        value = extract_sources(args.archive, args.manifest, args.destination)
        print(f"Validated/extracted {len(value['files'])} allowlisted files into an empty source directory")
    elif args.command == 'framework-kind':
        print(framework_kind(args.path))
    elif args.command in ('build-number', 'prepare-plist'):
        with pathlib.Path(args.source).open('rb') as stream:
            info = plistlib.load(stream)
        validate_info(info)
        require(args.build_number is None or args.build_number == info['CFBundleVersion'],
                'Build override differs from host Info.plist; update the source only during an authorized release')
        if args.command == 'build-number':
            print(info['CFBundleVersion'])
            return
        info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['Icon120', 'Icon180']}}
        info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['Icon152', 'Icon167']}}
        validate_info(info)
        with pathlib.Path(args.destination).open('wb') as stream:
            plistlib.dump(info, stream)
    elif args.command in ('prepare-widget', 'prepare-extension'):
        with pathlib.Path(args.host_info).open('rb') as stream:
            host = plistlib.load(stream)
        prepare_extension_info(args.source, args.destination, host,
                               'widgets' if args.command == 'prepare-widget' else args.target)
    elif args.command == 'write-release':
        value = write_release(args.ipa, args.inputs, args.framework, args.app)
        print(f"Verified real arm64 TrollStore IPA: {value['file']} ({value['sha256']})")
    elif args.command == 'verify':
        value = verify_artifacts(args.ipa, source_manifest=args.source_manifest)
        print(f"ZIP, arm64 Mach-O, linked ZeehoShared, imports, signature structure and SHA-256 checks passed ({value['linkage']})")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(2)
