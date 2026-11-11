#!/usr/bin/env python3
"""xtool 1.24.0 只读预检与隔离构建；不安装工具/SDK，不登录，不安装设备。"""
import argparse
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
SHELL = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('zeeho_build_support', SHELL / 'build-support.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def command(arguments, cwd=None, timeout=25):
    executable = shutil.which(arguments[0])
    if not executable:
        return {'code': 127, 'text': arguments[0] + ': not installed'}
    try:
        result = subprocess.run([executable, *arguments[1:]], cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', timeout=timeout)
        return {'code': result.returncode, 'text': result.stdout.strip()}
    except subprocess.TimeoutExpired:
        return {'code': 124, 'text': arguments[0] + ': read-only check timed out'}


def kmp_sources(root):
    names = {'native-shared/' + n for n in ('build.gradle.kts', 'settings.gradle.kts', 'gradle.properties',
             'gradlew', 'gradle/wrapper/gradle-wrapper.jar', 'gradle/wrapper/gradle-wrapper.properties')}
    for source_set in ('commonMain', 'iosMain', 'iosArm64Main'):
        for path in (root / 'native-shared/src' / source_set).rglob('*.kt'):
            names.add(path.relative_to(root).as_posix())
    return [{'path': n, 'size': support.regular_source(root, n).stat().st_size,
             'sha256': support.sha256_file(support.regular_source(root, n))} for n in sorted(names)]


def xcframework_info(path):
    support.require(path and pathlib.Path(path).is_absolute(), 'KMP_FRAMEWORK_MISSING: supply an absolute real XCFramework path')
    path = pathlib.Path(path).resolve()
    support.require(path.name == 'ZeehoShared.xcframework' and (path / 'Info.plist').is_file(),
                    'KMP_FRAMEWORK_MISSING: real ZeehoShared.xcframework/Info.plist is absent')
    with (path / 'Info.plist').open('rb') as stream:
        info = support.plistlib.load(stream)
    libraries = [v for v in info.get('AvailableLibraries', []) if v.get('SupportedPlatform') == 'ios'
                 and not v.get('SupportedPlatformVariant') and v.get('SupportedArchitectures') == ['arm64']]
    support.require(len(libraries) == 1, 'KMP_ARCHITECTURE_INVALID: expected one arm64 iOS device slice, not a simulator')
    library = libraries[0]
    relative = library['LibraryIdentifier'] + '/' + library['LibraryPath']
    framework = path.joinpath(*support.safe_relative(relative))
    support.require(framework.resolve().is_relative_to(path) and not framework.is_symlink(), 'KMP framework path escaped XCFramework')
    kind = support.framework_kind(framework)
    records = []
    for file in sorted(path.rglob('*')):
        support.require(not file.is_symlink(), 'KMP XCFramework links are not accepted')
        if file.is_file():
            records.append({'path': file.relative_to(path).as_posix(), 'size': file.stat().st_size, 'sha256': support.sha256_file(file)})
    return {'module': 'ZeehoShared', 'architectures': ['arm64'], 'platform': 'iOS',
            'libraryIdentifier': library['LibraryIdentifier'], 'linkage': kind,
            'binarySha256': support.sha256_file(framework / 'ZeehoShared'), 'files': records,
            'xcframeworkSha256': support.tree_digest(records)}


def validate_kmp(root, path, metadata_path):
    value = xcframework_info(path)
    support.require(metadata_path and pathlib.Path(metadata_path).is_absolute(), 'KMP_MANIFEST_MISSING: supply a source-hash manifest for the real XCFramework')
    metadata = support.load_json(metadata_path)
    records = kmp_sources(root)
    for key, expected in value.items():
        support.require(metadata.get(key) == expected, 'KMP_MANIFEST_MISMATCH: ' + key)
    support.require(metadata.get('schemaVersion') == 1 and metadata.get('sourceInputs') == records
                    and metadata.get('sourceTreeSha256') == support.tree_digest(records), 'KMP_SOURCE_HASH_MISMATCH: framework manifest does not match current KMP sources')
    return metadata


def preflight(root, product, framework=None, metadata=None, sdk_root_input=None):
    reasons, checks = [], []
    def check(name, available, detail, required=True):
        checks.append({'name': name, 'available': available, 'detail': detail, 'required': required})
        if required and not available:
            reasons.append(name)
    swift = command(['swift', '--version'])
    match = re.search(r'Swift version (\d+)\.(\d+)', swift['text'])
    check('SWIFT_MISSING' if swift['code'] == 127 else 'SWIFT_6_4_REQUIRED', swift['code'] == 0 and bool(match) and tuple(map(int, match.groups())) >= (6, 4), swift['text'])
    xtool = command(['xtool', '--version'])
    check('XTOOL_MISSING' if xtool['code'] == 127 else 'XTOOL_1_24_0_REQUIRED', xtool['code'] == 0 and bool(re.search(r'(?<![\d.])1\.24\.0(?![\d.])', xtool['text'])), xtool['text'])
    help_result = command(['xtool', '--help'])
    build_help = command(['xtool', 'dev', 'build', '--help'])
    check('XTOOL_BUILD_API', build_help['code'] == 0 and '--configuration' in build_help['text']
          and '--sign' in build_help['text'], build_help['text'])
    sdk_list = command(['swift', 'sdk', 'list'])
    darwin = sdk_list['code'] == 0 and 'darwin' in sdk_list['text'].split()
    sdk_status = command(['xtool', 'sdk', 'status'])
    check('NO_SDK', darwin, sdk_list['text'] + '\n' + sdk_status['text'])
    sdk = {}
    sdk_root_input = sdk_root_input or os.environ.get('XTOOL_DARWIN_SDK_ROOT')
    if not sdk_root_input:
        for line in sdk_status['text'].splitlines():
            paths = re.findall(r'(/[^\n]*?\.sdk)(?:[\s"\']|$)', line)
            for candidate in paths:
                if pathlib.Path(candidate).is_dir() and (pathlib.Path(candidate) / 'System/Library/Frameworks/UIKit.framework').is_dir():
                    sdk_root_input = candidate
                    break
    sdk_ok = False
    if sdk_root_input:
        sdk_root = pathlib.Path(sdk_root_input).resolve()
        sdk = {'id': 'darwin', 'root': str(sdk_root), 'source': 'explicit installed SDK root or xtool sdk status'}
        try:
            for name in ('SDKSettings.plist', 'SDKSettings.json'):
                settings = sdk_root / name
                if settings.is_file():
                    with settings.open('rb') as stream:
                        value = support.plistlib.load(stream) if name.endswith('.plist') else json.load(stream)
                    sdk['settings'] = value
                    sdk['settingsSha256'] = support.sha256_file(settings)
                    sdk['settingsFile'] = name
                    break
            settings = sdk.get('settings', {})
            canonical = settings.get('CanonicalName', '')
            platform = settings.get('DefaultProperties', {}).get('PLATFORM_NAME', '')
            required_frameworks = ('UIKit', 'WebKit') if product == 'SwiftProbe' else ('UIKit', 'WebKit', 'ActivityKit', 'WidgetKit')
            sdk_ok = darwin and (str(canonical).startswith('iphoneos') or platform == 'iphoneos') and all(
                (sdk_root / 'System/Library/Frameworks' / (name + '.framework')).is_dir() for name in required_frameworks)
            sdk['version'] = str(settings.get('Version', ''))
            sdk_ok = sdk_ok and bool(re.fullmatch(r'\d+\.\d+(?:\.\d+)?', sdk['version']))
        except (ValueError, OSError, TypeError, AttributeError):
            sdk_ok = False
    check('SDK_ROOT_REQUIRED', sdk_ok, 'Supply --sdk-root / -SwiftSDKRoot or XTOOL_DARWIN_SDK_ROOT for the legally installed iPhoneOS SDK; verify SDKSettings and real system frameworks. No SDK is downloaded.')
    inputs, kmp = None, None
    if product == 'DashboardIOS':
        try:
            inputs = support.inventory(root)
            check('SOURCE_CONTRACT', True, 'Root host Swift; Shared module; Widgets single NSExtension; no tests/config/fake framework')
        except (ValueError, OSError, KeyError) as error:
            check('SOURCE_CONTRACT', False, str(error))
        try:
            kmp = validate_kmp(root, framework, metadata)
            check('KMP_FRAMEWORK_MISSING', True, 'Real arm64 iOS XCFramework with matching headers, architecture and source hash')
        except (ValueError, OSError, KeyError) as error:
            check(str(error).split(':', 1)[0] if str(error).startswith('KMP_') else 'KMP_FRAMEWORK_MISSING', False, str(error))
        check('APP_GROUP_PROVISIONING_UNVERIFIED', False, 'Public entitlements are templates; no Apple profile/capability approval was performed', False)
        check('PLUGINS_NOT_BUILT', False, 'Build must contain real PlugIns/DashboardWidgets.appex; preflight does not fabricate it', False)
    else:
        check('PROBE_SOURCE', (SHELL / 'XtoolSupport/SwiftProbe/Probe.swift').is_file(), 'Independent UIKit/WebKit probe, no business/KMP/appex')
    return {'schemaVersion': 1, 'backend': 'xtool', 'checkedPlatform': sys.platform, 'product': product, 'readyForRequestedMode': not reasons,
            'reasons': reasons, 'checks': checks, 'tools': {'swift': swift, 'xtool': xtool, 'xtoolHelp': help_result,
            'buildHelp': build_help, 'sdkList': sdk_list, 'sdkStatus': sdk_status}, 'sdk': sdk,
            'kmp': kmp, 'sourceTreeSha256': inputs['sourceTreeSha256'] if inputs else None,
            'signing': 'No --sign; public entitlements invoke local ad-hoc signing only',
            'appleCryptographicVerification': False, 'deviceInstalled': False, 'authenticationAttempted': False}


def prepare_widget(source, destination, host):
    with pathlib.Path(source).open('rb') as stream:
        info = support.plistlib.load(stream)
    info.update({'CFBundleName': 'DashboardWidgets', 'CFBundleExecutable': 'DashboardWidgets',
                 'CFBundleIdentifier': host['CFBundleIdentifier'] + '.widgets', 'CFBundlePackageType': 'XPC!',
                 'CFBundleShortVersionString': host['CFBundleShortVersionString'], 'CFBundleVersion': host['CFBundleVersion'],
                 'MinimumOSVersion': '15.4', 'CFBundleSupportedPlatforms': ['iPhoneOS']})
    support.require(info.get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension', 'Widget Info.plist must be supplied by its source owner')
    with pathlib.Path(destination).open('wb') as stream:
        support.plistlib.dump(info, stream)


def build(root, product, framework, metadata, output, build_number, sdk_root):
    status = preflight(root, product, framework, metadata, sdk_root)
    output.mkdir(parents=True, exist_ok=True)
    support.write_json(output / 'xtool-preflight.json', status)
    if not status['readyForRequestedMode']:
        (output / 'xtool-blocked.log').write_text('BLOCKED: ' + ', '.join(status['reasons']) + '\n' + json.dumps(status, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('BLOCKED: ' + ', '.join(status['reasons']))
        return 2
    probe = product == 'SwiftProbe'
    inputs = support.inventory(root) if not probe else None
    with tempfile.TemporaryDirectory(prefix='zeeho-xtool-') as temp:
        stage = pathlib.Path(temp) / 'source'
        package = stage / 'ios-shell'
        package.mkdir(parents=True)
        if probe:
            for name in ('Package.swift', 'XtoolSupport/SwiftProbe/Probe.swift', 'XtoolSupport/SwiftProbe/Info.plist', 'XtoolSupport/Probe.entitlements'):
                destination = package / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SHELL / name, destination)
            shutil.copyfile(package / 'XtoolSupport/SwiftProbe/Info.plist', package / 'Info.plist')
            (package / 'xtool.yml').write_text('version: 1\nproduct: SwiftProbe\nbundleID: ' + support.BUNDLE_ID + '.swiftprobe\ninfoPath: Info.plist\nentitlementsPath: XtoolSupport/Probe.entitlements\nskipLSP: true\n', encoding='utf-8')
        else:
            for record in inputs['files']:
                destination = stage / record['path']
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = support.regular_source(root, record['path'])
                shutil.copyfile(source, destination)
                support.require(support.sha256_file(destination) == record['sha256'], 'Source changed during staging')
            with (package / 'Info.plist').open('rb') as stream:
                host = support.plistlib.load(stream)
            host['CFBundleExecutable'] = 'DashboardIOS'
            if build_number:
                host['CFBundleVersion'] = build_number
            support.validate_info(host, executable='DashboardIOS')
            with (package / 'Info.plist').open('wb') as stream:
                support.plistlib.dump(host, stream)
            prepare_widget(package / 'Widgets/Info.plist', package / 'Widgets/Info.plist', host)
        environment = os.environ.copy()
        environment['ZEEHO_XTOOL_PRODUCT'] = product
        if not probe:
            # SwiftPM local binaryTarget uses a package-relative path. Copy the validated REAL input, never generate one.
            shutil.copytree(pathlib.Path(framework).resolve(), package / 'XtoolSupport/KMP/ZeehoShared.xcframework')
            support.require(xcframework_info(package / 'XtoolSupport/KMP/ZeehoShared.xcframework') == xcframework_info(framework), 'KMP framework changed while staging')
            environment.update({'ZEEHO_KMP_XCFRAMEWORK': 'XtoolSupport/KMP/ZeehoShared.xcframework',
                                'ZEEHO_KMP_MANIFEST': str(pathlib.Path(metadata).resolve()),
                                'ZEEHO_KMP_SOURCE_SHA256': status['kmp']['sourceTreeSha256']})
        # 只调用显式 build 子命令；不使用默认 dev（会run/install），不调用auth/setup/--sign。
        with (output / 'xtool-build.log').open('w', encoding='utf-8') as log:
            result = subprocess.run([shutil.which('xtool'), 'dev', 'build', '--configuration', 'release'], cwd=package, env=environment, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            text = (output / 'xtool-build.log').read_text(encoding='utf-8')[-32768:]
            reason = 'APPLE_ID_REQUIRED' if re.search(r'requires logging|xtool auth|not.*logged in', text, re.I) else (
                'ENTITLEMENT_PROFILE_MISSING' if re.search(r'provisioning profile|entitlement.*(?:missing|denied|not.*supported)', text, re.I) else 'XTOOL_BUILD_FAILED')
            (output / 'xtool-blocked.log').write_text('BLOCKED: ' + reason + '\n' + text, encoding='utf-8')
            print('BLOCKED: ' + reason + ' (see xtool-build.log; no authentication/installation attempted)')
            return result.returncode
        app = package / 'xtool' / (product + '.app')
        support.require(app.is_dir(), 'XTOOL_OUTPUT_MISSING: expected ' + str(app))
        staged_ipa = pathlib.Path(temp) / ('swift-probe.ipa' if probe else 'dashboard-xtool.ipa')
        with zipfile.ZipFile(staged_ipa, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(app.rglob('*')):
                support.require(not file.is_symlink(), 'Unexpected link in built app')
                if file.is_file():
                    archive.write(file, 'Payload/' + product + '.app/' + file.relative_to(app).as_posix())
        report = support.validate_ipa(staged_ipa, backend='xtool', probe=probe)
        sdk_version = tuple(int(v) for v in status['sdk']['version'].split('.')[:2])
        support.require(all(tuple(int(v) for v in code['SDKVersion'].split('.')[:2]) == sdk_version
                            for code in report['machO'].values() if code['fileType'] == 'executable'),
                        'SDK_METADATA_MISMATCH: compiled executable SDK differs from the supplied installed SDK metadata')
        if inputs:
            support.inventory(root, inputs)
            validate_kmp(root, framework, metadata)
        manifest = {'schemaVersion': 1, 'backend': 'xtool', 'artifactKind': report['artifactKind'],
                    'file': staged_ipa.name, 'ipaSha256': support.sha256_file(staged_ipa), 'ipaSize': staged_ipa.stat().st_size,
                    'bundleIdentifier': report['info']['CFBundleIdentifier'], 'machO': report['machO'],
                    'sourceInputs': inputs['files'] if inputs else [], 'sourceTreeSha256': status['sourceTreeSha256'],
                    'sourceCommit': inputs['sourceCommit'] if inputs else None, 'sourceDirty': inputs['sourceDirty'] if inputs else None,
                    'sdk': status['sdk'], 'tools': status['tools'], 'kmp': status['kmp'],
                    'signing': status['signing'], 'appleCryptographicVerification': False,
                    'appGroupProvisioningVerified': False, 'trollStoreCompatibility': 'unverified',
                    'deviceInstalled': False, 'authenticationAttempted': False}
        # 名称/SDK/signature/源哈希结构全部通过才移交新产物；不写TrollStore的更新version.json。
        support.write_json(staged_ipa.parent / 'xtool-build-manifest.json', manifest)
        (staged_ipa.parent / 'SHA256SUMS').write_text(manifest['ipaSha256'] + '  ' + staged_ipa.name + '\n', encoding='utf-8')
        support.verify_artifacts(staged_ipa)
        support.validate_output_directory(root, output)
        for file in (staged_ipa, staged_ipa.parent / 'xtool-build-manifest.json', staged_ipa.parent / 'SHA256SUMS'):
            with file.open('rb') as source, (output / file.name).open('xb') as destination:
                shutil.copyfileobj(source, destination)
        print('Built ' + str(output / staged_ipa.name) + '; structural verification only, no Apple provisioning/device verification')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['preflight', 'build', 'record-kmp', 'prepare-widget'])
    parser.add_argument('--root', default=str(SHELL.parent))
    parser.add_argument('--product', choices=['DashboardIOS', 'SwiftProbe'], default='DashboardIOS')
    parser.add_argument('--xcframework')
    parser.add_argument('--kmp-manifest')
    parser.add_argument('--sdk-root')
    parser.add_argument('--output')
    parser.add_argument('--build-number')
    parser.add_argument('--source')
    parser.add_argument('--host-info')
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    if args.build_number:
        support.require(re.fullmatch(r'[1-9][0-9]*', args.build_number), 'Build number must be positive')
    if args.mode == 'preflight':
        status = preflight(root, args.product, args.xcframework, args.kmp_manifest, args.sdk_root)
        print(json.dumps(status, ensure_ascii=True, indent=2))
        return 0 if status['readyForRequestedMode'] else 2
    if args.mode == 'build':
        support.require(args.output, 'Build requires --output')
        output = support.validate_output_directory(root, args.output)
        return build(root, args.product, args.xcframework, args.kmp_manifest, output, args.build_number, args.sdk_root)
    if args.mode == 'prepare-widget':
        with pathlib.Path(args.host_info).open('rb') as stream:
            host = support.plistlib.load(stream)
        prepare_widget(args.source, args.output, host)
        return 0
    value = xcframework_info(args.xcframework)
    records = kmp_sources(root)
    value.update({'schemaVersion': 1, 'sourceInputs': records, 'sourceTreeSha256': support.tree_digest(records)})
    support.require(args.output, 'record-kmp requires --output; it only records an existing real XCFramework')
    support.write_json(args.output, value)
    print('Recorded real KMP XCFramework/source contract, no framework was compiled or generated')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(2)
