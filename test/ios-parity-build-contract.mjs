// 只验构建契约与拒绝路径；不伪造 IPA/Mach-O，也不冒充 Apple 编译通过。
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const shell = path.join(repo, 'ios-shell');
const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const support = path.join(shell, 'build-support.py');
const readInventory = 'import importlib.util,json,pathlib,sys; sys.dont_write_bytecode=True; spec=importlib.util.spec_from_file_location("contract",sys.argv[1]); h=importlib.util.module_from_spec(spec); spec.loader.exec_module(h); print(json.dumps(h.inventory(sys.argv[2])))';
const input = JSON.parse(execFileSync(python, ['-I', '-X', 'utf8', '-c', readInventory, support, repo], { encoding: 'utf8' }));
const set = names => new Set(names);
const host = set(input.swiftSources);
const broadcast = set(input.broadcastSwiftSources);
assert.deepEqual([...host].filter(n => broadcast.has(n)), ['ios-shell/CastProtocol.swift']);
assert.ok(!host.has('ios-shell/CastEncoder.swift'));
assert.ok(broadcast.has('ios-shell/CastEncoder.swift') && broadcast.has('ios-shell/Broadcast/SampleHandler.swift'));
assert.ok(!input.broadcastSwiftImports.some(n => ['ZeehoShared', 'ZeehoSystemShared', 'UIKit', 'WebKit'].includes(n)));
assert.deepEqual(set(input.swiftImports), set([...input.hostModuleImports, ...input.sharedSwiftImports]));
assert.ok(input.systemLibraries.includes('z'));
assert.ok(!input.systemFrameworks.includes('CommonCrypto'));
assert.ok(input.widgetSystemFrameworks.includes('AppIntents'));
const records = set(input.files.map(r => r.path));
for (const name of ['Broadcast/Info.plist', 'Entitlements/Broadcast.entitlements', 'CastProtocol.swift', 'CastEncoder.swift', 'Widgets/WidgetVehicleIntent.swift']) {
  assert.ok(records.has('ios-shell/' + name), name);
}
assert.ok(![...records].some(n => /Inductive(?:Cloud|Session)\.swift$/.test(n)));
const build = readFileSync(path.join(shell, 'build.sh'), 'utf8');
for (const token of ['-module-name ZeehoCastBroadcast', '-Xlinker -e -Xlinker _NSExtensionMain',
  '--scan-executable "$broadcast_dir/ZeehoCastBroadcast"', '--scan-folder "$broadcast_dir/Frameworks"',
  'appintentsmetadataprocessor', '--source-files "${widget_sources[@]}"',
  'Metadata.appintents/extract.actionsdata', '-weak_framework -Xlinker AppIntents']) assert.ok(build.includes(token), token);
assert.ok(build.indexOf('appintentsmetadataprocessor \\') < build.indexOf('codesign --force'), 'Metadata must precede signing');
assert.ok(build.indexOf('Entitlements/Broadcast.entitlements') < build.indexOf('Entitlements/Widgets.entitlements'));
assert.ok(build.indexOf('Entitlements/Widgets.entitlements') < build.indexOf('Entitlements/App.entitlements'));

// 真函数的精确拒绝测试；只用内存 plist/report，不写假安装包或伪 framework。
const checks = String.raw`
import copy, importlib.util, pathlib, plistlib, sys, tempfile
sys.dont_write_bytecode = True
p = pathlib.Path(sys.argv[1]); spec = importlib.util.spec_from_file_location('contract', p)
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
def rejects(call, fragment):
    try: call()
    except ValueError as error: assert fragment in str(error), str(error)
    else: raise AssertionError('missing rejection: ' + fragment)
root = p.parent
host = plistlib.loads((root / 'Info.plist').read_bytes())
c = h.EXTENSIONS['broadcast']
info = plistlib.loads((root / 'Broadcast/Info.plist').read_bytes())
h.validate_extension_info(info, c, template=True)
for key, value in [('NSExtensionPointIdentifier', 'com.apple.widgetkit-extension'),
                   ('NSExtensionPrincipalClass', 'Other.SampleHandler'),
                   ('RPBroadcastProcessMode', 'RPBroadcastProcessModeMovieFile')]:
    bad = copy.deepcopy(info); bad['NSExtension'][key] = value
    rejects(lambda: h.validate_extension_info(bad, c, template=True), 'Broadcast' if key != 'NSExtensionPointIdentifier' else 'extension point')
with tempfile.TemporaryDirectory(prefix='ios-contract-') as directory:
    output = pathlib.Path(directory) / 'Info.plist'
    h.prepare_extension_info(root / 'Broadcast/Info.plist', output, host, 'broadcast')
    packaged = plistlib.loads(output.read_bytes())
    assert packaged['NSExtension']['NSExtensionPrincipalClass'] == 'ZeehoCastBroadcast.SampleHandler'
    assert packaged['CFBundleVersion'] == host['CFBundleVersion']
    bad = copy.deepcopy(packaged); bad['CFBundleIdentifier'] += '.wrong'
    rejects(lambda: h.validate_extension_info(bad, c, host=host), 'identity')
assert h.MAX_IPA_BYTES == 30 * 1024 * 1024
assert not h.public_input('ios-shell/InductiveCloud.swift')
assert not h.public_input('ios-shell/InductiveSession.swift')
assert not h.public_input('ios-shell/Broadcast/private/Secret.swift')
assert h.public_input('ios-shell/Broadcast/SampleHandler.swift')
assert h.PRIVATE_SWIFT_RE.search('static let statusPort: UInt16 = 10930')
assert h.PRIVATE_SWIFT_RE.search('0x70000010')
assert not h.PRIVATE_SWIFT_RE.search('enum IOSCastWire { static let frameMax = 2 * 1024 * 1024 }')
assert h.objc_runtime_class('_OBJC_CLASS_$__TtC18ZeehoCastBroadcast13SampleHandler') == 'ZeehoCastBroadcast.SampleHandler'
assert h.objc_runtime_class('_OBJC_CLASS_$_ExplicitHandler') == 'ExplicitHandler'
rejects(lambda: h.macho(b'fake executable', 2), 'Truncated Mach-O')
name = h.APP_PREFIX + c['directory'] + c['product']
dependency = '@rpath/libswiftCompatibilityExample.dylib'
bundled = h.APP_PREFIX + 'Frameworks/libswiftCompatibilityExample.dylib'
report = {'fileType': 'executable', 'rpaths': ['@executable_path/../../Frameworks'], 'imports': [{'path': dependency, 'weak': False}]}
h.resolve_imports({name: report}, {name, bundled})
bad = copy.deepcopy(report); bad['rpaths'] = []
rejects(lambda: h.resolve_imports({name: bad}, {name, bundled}), 'Unresolved')
bad = copy.deepcopy(report); bad['rpaths'] = ['@loader_path/../../../private']
rejects(lambda: h.resolve_imports({name: bad}, {name, bundled}), 'rpath')
print('Precise extension/template/private-input/Mach-O/rpath rejection checks passed')
`;
const result = execFileSync(python, ['-I', '-X', 'utf8', '-c', checks, support], { encoding: 'utf8' });
process.stdout.write(result);
console.log(`iOS parity build contract passed (${input.swiftSources.length} Host, ${input.widgetSwiftSources.length} Widget, ${input.broadcastSwiftSources.length} Broadcast sources; no Apple compilation)`);
