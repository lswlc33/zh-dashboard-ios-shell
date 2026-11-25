"""编译生产 AppGroup 与 Cast 组解析器：python -I app-group-test.py。

真实临时 app/appex + CMS 内嵌 plist fixture；容器访问只经注入的 probe。
macOS 必须有 swiftc；其他平台缺工具链明确 SKIP，--require-swift 可禁止跳过。
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


SWIFT_TESTS = r'''
import Foundation

// 非 Apple Foundation 没有 App Group API；若测试漏注入 probe 必须失败，不能伪装授权。
#if !canImport(Darwin)
extension FileManager {
    public func containerURL(forSecurityApplicationGroupIdentifier identifier: String) -> URL? {
        fatalError("tests must inject containerProbe")
    }
}
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct Scenario {
    let name: String
    var info: [String: Any] = [:]
    var hostProfile: Data?
    var ownProfile: Data?
    let available: Set<String>
    let expected: String
    let source: String
    let probes: [String]
    var extensionExpected: String? = nil
    var extensionProbes: [String]? = nil
}

@main
private enum AppGroupTests {
    private static let fallback = "group.io.github.lswlc33.dashboard.ios"

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func profile(_ groups: [String]) throws -> Data {
        let plist: [String: Any] = ["Entitlements": ["com.apple.security.application-groups": groups]]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // 前后含非 UTF-8 的模拟 CMS 字节，确保生产代码仅解析内嵌 plist。
        return Data([0x30, 0x82, 0xFF, 0x00]) + xml + Data([0x00, 0xFE, 0xFF])
    }

    private static func bundles(_ scenario: Scenario, index: Int, at root: URL) throws -> [(String, Bundle)] {
        let host = root.appendingPathComponent("Fixture-\(index).app", isDirectory: true)
        let widget = host.appendingPathComponent("PlugIns/Widgets.appex", isDirectory: true)
        let broadcast = host.appendingPathComponent("PlugIns/Broadcast.appex", isDirectory: true)
        let targets = [("host", host), ("widget", widget), ("broadcast", broadcast)]
        for (name, url) in targets {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var info = scenario.info
            info["CFBundleIdentifier"] = "test.zeeho.fixture.\(index).\(name)"
            info["CFBundlePackageType"] = name == "host" ? "APPL" : "XPC!"
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Info.plist"))
            if let data = name == "host" ? scenario.hostProfile : scenario.ownProfile {
                try data.write(to: url.appendingPathComponent("embedded.mobileprovision"))
            }
        }
        // 所有文件就绪后才构造 Bundle，避免资源列表缓存干扰 own/host profile 验证。
        return try targets.map { name, url in
            guard let bundle = Bundle(url: url) else {
                throw TestFailure(description: "cannot open fixture bundle: \(url.path)")
            }
            return (name, bundle)
        }
    }

    private static func verify(_ scenario: Scenario, target: String, bundle: Bundle) throws {
        var calls: [String] = []
        let probe: (String) -> URL? = { identifier in
            calls.append(identifier)
            return scenario.available.contains(identifier) ? URL(fileURLWithPath: "/fixture-container") : nil
        }
        let label = scenario.name + " / " + target
        let expected = target == "host" ? scenario.expected : (scenario.extensionExpected ?? scenario.expected)
        let expectedProbes = target == "host" ? scenario.probes : (scenario.extensionProbes ?? scenario.probes)
        let identifier = AppGroup.current(bundle: bundle, containerProbe: probe)
        try check(identifier == expected, "\(label): Shared chose \(identifier), expected \(expected)")
        try check(calls == expectedProbes, "\(label): Shared probe order \(calls), expected \(expectedProbes)")

        calls.removeAll()
        let resolution = AppGroup.resolution(bundle: bundle, containerProbe: probe)
        try check(resolution["identifier"] as? String == expected, "\(label): diagnostics identifier diverged")
        try check(resolution["source"] as? String == scenario.source, "\(label): diagnostics source \(resolution)")
        try check(resolution["defaultIdentifier"] as? String == fallback, "\(label): wrong diagnostic default")
        try check(resolution["matched"] as? Bool == (expected != fallback), "\(label): wrong matched diagnostic")
        try check(calls == expectedProbes, "\(label): diagnostics probe order \(calls)")

        calls.removeAll()
        let cast = IOSCastMailbox.resolvedGroupID(bundle: bundle, containerProbe: probe)
        try check(cast == identifier, "\(label): Cast \(cast) disagrees with Shared \(identifier)")
        try check(calls == expectedProbes, "\(label): Cast probe order \(calls)")
    }

    static func main() throws {
        let old = "group.old.team"
        let altOld = "group.old.alt"
        let alt = "group.new.alt"
        let profileOld = "group.old.profile"
        let own = "group.own.profile"
        let active = "group.new.profile"
        let invalid = ["", "ordinary.bundle.id", "group.", "group..empty", "group.white space",
                       "group.a/b", "group.中文", "group.a\n", "group." + String(repeating: "x", count: 252)]
        // 生产判据是 utf8.count <= 256，"group." 占 6 字节，所以后缀只能是 250 个字符；
        // 旧值 251 实际是 257 字节，被 isValid 拒绝后回退 template_default（macOS CI 2026-11-25 实测）。
        let longValid = "group." + String(repeating: "x", count: 250)
        let scenarios = [
            Scenario(name: "accessible override keeps precedence",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": [alt]],
                     hostProfile: try profile([active]), available: [old, alt, active, fallback],
                     expected: old, source: "info_override", probes: [old]),
            Scenario(name: "stale override falls through every ALT candidate",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": invalid + [altOld, alt]],
                     hostProfile: try profile([active]), available: [alt, active, fallback],
                     expected: alt, source: "altstore_plist", probes: [old, altOld, alt]),
            Scenario(name: "single ALT string remains supported",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": alt], available: [alt, fallback],
                     expected: alt, source: "altstore_plist", probes: [old, alt]),
            Scenario(name: "unavailable plist groups fall through every profile group",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": [altOld]],
                     hostProfile: try profile(invalid + [profileOld, active]),
                     ownProfile: try profile(invalid + [profileOld, active]), available: [active, fallback],
                     expected: active, source: "mobileprovision", probes: [old, altOld, profileOld, active]),
            Scenario(name: "unavailable own profile continues into host profile",
                     info: ["ZeehoAppGroupID": old], hostProfile: try profile([active]),
                     ownProfile: try profile([profileOld]), available: [active, fallback],
                     expected: active, source: "mobileprovision", probes: [old, active],
                     extensionProbes: [old, profileOld, active]),
            Scenario(name: "accessible own profile precedes host profile",
                     hostProfile: try profile([active]), ownProfile: try profile([profileOld, own]),
                     available: [own, active, fallback], expected: active, source: "mobileprovision",
                     probes: [active], extensionExpected: own, extensionProbes: [profileOld, own]),
            Scenario(name: "all unavailable retain own profile before host for diagnostics",
                     hostProfile: try profile([active]), ownProfile: try profile([profileOld]),
                     available: [], expected: active, source: "mobileprovision", probes: [active, fallback],
                     extensionExpected: profileOld, extensionProbes: [profileOld, active, fallback]),
            Scenario(name: "missing appex profile reads host CMS plist",
                     hostProfile: try profile([active]), available: [active, fallback],
                     expected: active, source: "mobileprovision", probes: [active]),
            Scenario(name: "malformed appex profile does not hide host profile",
                     hostProfile: try profile([active]), ownProfile: Data("<?xml broken </plist>".utf8),
                     available: [active], expected: active, source: "mobileprovision", probes: [active]),
            Scenario(name: "invalid own profile groups do not hide host profile",
                     hostProfile: try profile([active]), ownProfile: try profile(invalid), available: [active],
                     expected: active, source: "mobileprovision", probes: [active]),
            Scenario(name: "accessible default follows unavailable configured groups",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": [altOld]],
                     hostProfile: try profile([profileOld]), available: [fallback],
                     expected: fallback, source: "template_default", probes: [old, altOld, profileOld, fallback]),
            Scenario(name: "all unavailable retain first valid override for diagnostics",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": [altOld]],
                     hostProfile: try profile([profileOld]), available: [],
                     expected: old, source: "info_override", probes: [old, altOld, profileOld, fallback]),
            Scenario(name: "all unavailable retain first valid ALT for diagnostics",
                     info: ["ZeehoAppGroupID": "invalid", "ALTAppGroups": invalid + [altOld]],
                     hostProfile: try profile([profileOld]), available: [],
                     expected: altOld, source: "altstore_plist", probes: [altOld, profileOld, fallback]),
            Scenario(name: "all unavailable retain first valid profile for diagnostics",
                     info: ["ZeehoAppGroupID": "invalid", "ALTAppGroups": invalid],
                     hostProfile: try profile(invalid + [profileOld]), available: [],
                     expected: profileOld, source: "mobileprovision", probes: [profileOld, fallback]),
            Scenario(name: "invalid metadata never reaches container probe",
                     info: ["ZeehoAppGroupID": "invalid", "ALTAppGroups": invalid],
                     hostProfile: try profile(invalid), available: [],
                     expected: fallback, source: "template_default", probes: [fallback]),
            Scenario(name: "duplicate groups are probed once with first source retained",
                     info: ["ZeehoAppGroupID": old, "ALTAppGroups": [old, old, altOld]],
                     hostProfile: try profile([altOld, old]), ownProfile: try profile([old]), available: [],
                     expected: old, source: "info_override", probes: [old, altOld, fallback]),
            Scenario(name: "duplicate default keeps its first configured source",
                     info: ["ZeehoAppGroupID": fallback, "ALTAppGroups": [fallback, altOld]],
                     hostProfile: try profile([fallback, profileOld]), available: [],
                     expected: fallback, source: "info_override", probes: [fallback, altOld, profileOld]),
            Scenario(name: "ASCII identifier at 256 byte limit stays valid",
                     info: ["ALTAppGroups": [longValid]], available: [longValid],
                     expected: longValid, source: "altstore_plist", probes: [longValid]),
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeeho-app-groups-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, scenario) in scenarios.enumerated() {
            for (target, bundle) in try bundles(scenario, index: index, at: root) {
                try verify(scenario, target: target, bundle: bundle)
            }
            print("PASS: \(scenario.name) (host / widget / broadcast; Shared / diagnostics / Cast)")
        }
        print("PASS: \(scenarios.count) production Swift App Group fixtures, 3 targets, 3 resolver entry points")
    }
}
'''


def extract_cast_resolver(source):
    # 只去掉依赖 Network/Security/Darwin 的投屏协议与 mailbox I/O；解析段保持逐字生产代码。
    starts = list(re.finditer(r'(?m)^final class IOSCastMailbox\s*\{', source))
    ends = list(re.finditer(r'(?m)^    static func validExtensionID\(', source))
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ValueError('expected one IOSCastMailbox resolver before validExtensionID')
    return 'import Foundation\n\n' + source[starts[0].start():ends[0].start()] + '}\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', help='swiftc executable path or command name')
    parser.add_argument('--require-swift', action='store_true',
                        help='fail instead of SKIP if swiftc is missing (always required on macOS)')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    shared = (root / 'Shared' / 'AppGroup.swift').read_text(encoding='utf-8-sig')
    cast = extract_cast_resolver((root / 'CastProtocol.swift').read_text(encoding='utf-8-sig'))
    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None:
        message = 'swiftc not found; production Swift App Group fixtures were NOT executed'
        if args.swiftc or args.require_swift or sys.platform == 'darwin':
            print('FAIL: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        return 0

    print('Testing production Shared/AppGroup.swift and CastProtocol.swift resolvers', flush=True)
    with tempfile.TemporaryDirectory(prefix='zeeho-app-group-tests-') as directory:
        work = pathlib.Path(directory)
        shared_file = work / 'AppGroup.swift'
        cast_file = work / 'CastAppGroup.swift'
        tests_file = work / 'AppGroupTests.swift'
        executable = work / ('app-group-test.exe' if sys.platform == 'win32' else 'app-group-test')
        shared_file.write_text(shared, encoding='utf-8')
        cast_file.write_text(cast, encoding='utf-8')
        tests_file.write_text(SWIFT_TESTS, encoding='utf-8')
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                        str(shared_file), str(cast_file), str(tests_file), '-o', str(executable)],
                       cwd=work, check=True, timeout=60)
        subprocess.run([str(executable)], cwd=work, check=True, timeout=20)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
