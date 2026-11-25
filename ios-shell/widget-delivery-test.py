"""执行生产 Widget 完成闸门、新鲜度和 Timeline fixture：python -I widget-delivery-test.py。

macOS 必须有 swiftc；其他平台缺编译器时明确 SKIP，可用 --require-swift 禁止跳过。
--swiftc 可指定工具链路径。只在系统临时目录生成 Swift 源码和可执行文件。
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


# SwiftUI/WidgetKit 的形状替身；时间选择、展示属性和 Timeline 方法全部提取生产代码。
SWIFT_SUPPORT = r'''
// 替身类型必须是 internal（默认可见性）：被提取的生产类型 ZeehoVehicleEntry 是
// internal，它的存储属性/方法参数用到这些替身；若替身声明成 private，Swift 会报
// "property must be declared fileprivate because its type uses a private type"
// （macOS CI 2026-11-25 实测），夹具就编不过。
protocol TimelineEntry {}
enum ColorScheme { case light, dark }
enum WidgetFamily { case systemSmall, systemMedium, systemLarge }
enum WidgetStatField {
    case sample
    static let defaultLarge: [Self] = []
    static let defaultMedium: [Self] = []
    static let selectable: [Self] = []
}
struct WidgetDataSourceResult {
    enum Origin: String { case snapshot }
}
enum TimelineReloadPolicy { case after(Date) }
struct Timeline<Entry> {
    let entries: [Entry]
    let policy: TimelineReloadPolicy
}
'''


SWIFT_TESTS = r'''
private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

// 观察器独立于被测 gate 加锁，避免测试本身的数据竞争掩盖交付次数。
private final class Deliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    let event = DispatchSemaphore(value: 0)

    func record(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
        event.signal()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@main
private enum WidgetDeliveryTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func delivered(_ results: Deliveries, _ expected: Int) throws {
        try check(results.event.wait(timeout: .now() + .milliseconds(900)) == .success,
                  "completion did not arrive within 900ms")
        try check(results.values == [expected], "unexpected delivery: \(results.values)")
    }

    private static func staysSingle(_ results: Deliveries, _ expected: Int) throws {
        // 同时等待已取消的 timer / 迟到回调；每次 semaphore 等待均小于一秒。
        try check(results.event.wait(timeout: .now() + .milliseconds(120)) == .timedOut,
                  "completion fired more than once: \(results.values)")
        try check(results.values == [expected], "first result was overwritten")
    }

    private static func resultFirst() throws {
        let results = Deliveries()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        gate.scheduleFallback(seconds: 0.04, value: -1)
        try check(gate.finish(10), "first producer was rejected")
        try delivered(results, 10)
        try staysSingle(results, 10)
    }

    private static func timeoutFirst() throws {
        let results = Deliveries()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        gate.scheduleFallback(seconds: 0.02, value: -2)
        try delivered(results, -2)
        try check(!gate.finish(20), "late producer accepted after timeout")
        try staysSingle(results, -2)
    }

    // 单独的函数作用域保证返回后生产者没有持有 gate；timer 必须自行保持交付能力。
    private static func armWithoutProducer(_ results: Deliveries) {
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        gate.scheduleFallback(seconds: 0.04, value: -3)
    }

    private static func noProducerOwner() throws {
        let results = Deliveries()
        armWithoutProducer(results)
        try delivered(results, -3)
        try staysSingle(results, -3)
    }

    private static func hundredWayRace() throws {
        let results = Deliveries()
        let accepted = Deliveries()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        for value in 0..<100 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if start.wait(timeout: .now() + .milliseconds(900)) != .success {
                    accepted.record(-1000)
                    return
                }
                if gate.finish(value) { accepted.record(value) }
            }
        }
        for _ in 0..<100 { start.signal() }
        try check(group.wait(timeout: .now() + .milliseconds(900)) == .success,
                  "100 producers did not finish within 900ms")
        let winners = accepted.values
        try check(winners.count == 1 && (0..<100).contains(winners[0]),
                  "expected exactly one successful finish, got \(winners)")
        try delivered(results, winners[0])
        try staysSingle(results, winners[0])
    }

    private static func rearmNeverExtendsDeadline() throws {
        let results = Deliveries()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        let started = DispatchTime.now()
        gate.scheduleFallback(seconds: 0.6, value: -5)
        // 模拟慢读盘：首次期限只剩 0.1s 时，把兜底换成读到的旧快照。
        try check(results.event.wait(timeout: started + .milliseconds(500)) == .timedOut,
                  "initial fallback arrived before the local read finished")
        gate.scheduleFallback(seconds: 0.8, value: 50)
        // 应仍按原期限交付（允许 300ms 调度余量），不能重算成 0.5 + 0.8s。
        try check(results.event.wait(timeout: started + .milliseconds(900)) == .success,
                  "rearming extended the original absolute deadline")
        try check(results.values == [50], "rearm did not replace the fallback value: \(results.values)")
        try check(!gate.finish(51), "late producer accepted after rearmed fallback")
        // 等过原 timer 和重装所请求的更晚期限，确认交付仍恰好一次。
        try check(results.event.wait(timeout: started + .milliseconds(1_450)) == .timedOut,
                  "rearmed fallback delivered more than once: \(results.values)")
        try check(results.values == [50], "rearmed fallback was overwritten")
    }

    private static func rearmCanTightenDeadline() throws {
        let results = Deliveries()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        let started = DispatchTime.now()
        gate.scheduleFallback(seconds: 0.6, value: -6)
        gate.scheduleFallback(seconds: 0.02, value: 60)
        try check(results.event.wait(timeout: started + .milliseconds(250)) == .success,
                  "replacement fallback did not tighten the deadline")
        try check(results.values == [60], "unexpected tightened fallback: \(results.values)")
        try check(!gate.finish(61), "late producer accepted after tightened fallback")
        try check(results.event.wait(timeout: started + .milliseconds(750)) == .timedOut,
                  "cancelled original timer delivered again: \(results.values)")
        try check(results.values == [60], "tightened fallback was overwritten")
    }

    private static let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let fixtureNow: Int64 = 1_800_000_000_000

    private static func snapshot(_ vehicle: SystemVehicleSnapshot) throws -> SystemSnapshot {
        let owner = SystemSnapshotOwner(scopeID: "fixture", accountVINHash: String(repeating: "a", count: 64))
        let value = SystemSnapshot(owner: owner, capturedAt: fixtureNow, expiresAt: fixtureNow + 180_000,
            vehicle: vehicle,
            ride: SystemRideSnapshot(state: .recording, startedAt: fixtureNow - 60_000,
                updatedAt: fixtureNow, speedKph: 10, speedUpdatedAt: fixtureNow),
            gauge: SystemGaugeSnapshot(source: .ble, speedKph: 10, updatedAt: fixtureNow))
        return try value.validated(expectedOwner: owner, now: fixtureDate)
    }

    private static func coreSourceControlsLocalFreshnessAndTimeline() throws {
        let old = fixtureNow - 44 * 60_000
        // stats、vehicle.updatedAt、capturedAt、ride、gauge 都很新，但核心字段已旧 44 分钟。
        let value = try snapshot(SystemVehicleSnapshot(socPercent: 55, socUpdatedAt: old,
            charging: true, chargingUpdatedAt: old, chargeProgressPercent: 30,
            chargeProgressUpdatedAt: old, updatedAt: fixtureNow, statsUpdatedAt: fixtureNow))
        try check(!ZeehoVehicleProvider.isFreshLocalSnapshot(value, at: fixtureDate),
                  "unrelated updates made an old core snapshot win before the live fetch")
        let entry = ZeehoVehicleEntry(date: fixtureDate, snapshot: value, requiresRefresh: false)
        let timeline = ZeehoVehicleProvider.timeline(entry: entry, now: fixtureDate)
        try check(timeline.entries.count == 2, "core source did not schedule its 45-minute stale transition")
        try check(timeline.entries[1].date == fixtureDate.addingTimeInterval(60),
                  "unrelated updates moved the stale transition beyond the core source deadline")
        try check(timeline.entries[1].requiresRefresh && timeline.entries[1].snapshot == value,
                  "stale transition must retain the last known snapshot")

        // 核心中的充电状态确实刚收到时应能快速交付，不能只按更旧的 SOC 算。
        let recent = try snapshot(SystemVehicleSnapshot(socPercent: 55, socUpdatedAt: old,
            charging: false, chargingUpdatedAt: fixtureNow - 60_000, updatedAt: fixtureNow,
            statsUpdatedAt: fixtureNow))
        try check(ZeehoVehicleProvider.isFreshLocalSnapshot(recent, at: fixtureDate),
                  "a genuinely recent core field was not admitted")
    }

    private static func statsOnlyUsesStatsSource() throws {
        for (minutes, expectedFresh, expectedEntries) in [(1, true, 1), (44, false, 2)] {
            let value = try snapshot(SystemVehicleSnapshot(updatedAt: fixtureNow, voltage: 72,
                statsUpdatedAt: fixtureNow - Int64(minutes) * 60_000))
            try check(ZeehoVehicleProvider.isFreshLocalSnapshot(value, at: fixtureDate) == expectedFresh,
                      "stats-only local admission used the wrapper time instead of statsUpdatedAt")
            let entry = ZeehoVehicleEntry(date: fixtureDate, snapshot: value, requiresRefresh: false)
            let timeline = ZeehoVehicleProvider.timeline(entry: entry, now: fixtureDate)
            try check(timeline.entries.count == expectedEntries, "stats-only stale transition has the wrong source")
            if expectedEntries == 2 {
                try check(timeline.entries[1].date == fixtureDate.addingTimeInterval(60),
                          "stats-only stale transition did not use the actual stats source")
            }
        }
    }

    private static func unknownSourceDoesNotBecomeFresh() throws {
        let value = try snapshot(SystemVehicleSnapshot(updatedAt: fixtureNow))
        try check(!ZeehoVehicleProvider.isFreshLocalSnapshot(value, at: fixtureDate),
                  "wrapper-only data without a source timestamp was admitted as fresh")
        let entry = ZeehoVehicleEntry(date: fixtureDate, snapshot: value, requiresRefresh: false)
        let timeline = ZeehoVehicleProvider.timeline(entry: entry, now: fixtureDate)
        try check(timeline.entries.count == 1, "an unknown source invented a future stale transition")
    }

    private static func lateResultsDoNotOverwrite() throws {
        let results = Deliveries()
        let gate = WidgetCompletionGate<Int>(completion: results.record)
        try check(gate.finish(40), "initial result was rejected")
        try delivered(results, 40)
        // 完成后再武装 timer，以及随后到达的多个生产者，都不能覆盖首个值。
        gate.scheduleFallback(seconds: 0.02, value: -4)
        let lateDone = DispatchSemaphore(value: 0)
        let accepted = Deliveries()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(30)) {
            for value in 41..<51 {
                if gate.finish(value) { accepted.record(value) }
            }
            lateDone.signal()
        }
        try check(lateDone.wait(timeout: .now() + .milliseconds(900)) == .success,
                  "late producers did not run within 900ms")
        try check(accepted.values.isEmpty, "late finish incorrectly succeeded")
        try staysSingle(results, 40)
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("normal result first", resultFirst),
            ("timeout first", timeoutFirst),
            ("fallback without producer ownership", noProducerOwner),
            ("100 concurrent producers deliver once", hundredWayRace),
            ("rearming near the deadline never extends it", rearmNeverExtendsDeadline),
            ("rearming can tighten the deadline", rearmCanTightenDeadline),
            ("late results never overwrite", lateResultsDoNotOverwrite),
            ("core timestamps control local freshness and timeline", coreSourceControlsLocalFreshnessAndTimeline),
            ("stats-only snapshots use the stats source", statsOnlyUsesStatsSource),
            ("unknown source cannot become fresh", unknownSourceDoesNotBecomeFresh),
        ]
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                throw TestFailure(description: "FAIL: \(name): \(error)")
            }
        }
        print("PASS: \(tests.count) production Swift widget delivery/freshness tests")
    }
}
'''


def extract_gate(source):
    # 不依赖方法体、行号或大括号计数，容纳生产实现的小修及注释/闭包变化。
    starts = list(re.finditer(
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public|final)\s+)*'
        r'class\s+WidgetCompletionGate\s*<', source))
    ends = list(re.finditer(
        r'(?m)^[ \t]*(?:(?:private|fileprivate|internal|public)\s+)*'
        r'struct\s+ZeehoVehicleProvider\b', source))
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ValueError('expected one WidgetCompletionGate class before ZeehoVehicleProvider')
    return source[starts[0].start():ends[0].start()]


def extract_type(source, name):
    # 顶层类型以顶格右括号结束；保留真实属性/方法，不把生产算法改写进测试。
    pattern = (rf'(?ms)^(?:(?:public|private|fileprivate|internal|final)\s+)*'
               rf'(?:enum|struct)\s+{re.escape(name)}\b[^\n]*\{{.*?^\}}[ \t]*$')
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError('expected one production type: ' + name)
    return matches[0]


def extract_provider_function(source, name):
    pattern = rf'(?ms)^    (?:private )?static func {re.escape(name)}\(.*?^    \}}[ \t]*$'
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError('expected one production provider function: ' + name)
    return matches[0]


def extract_freshness_sources(root, source):
    presentation = (root / 'Widgets' / 'WidgetPresentation.swift').read_text(encoding='utf-8-sig')
    style = (root / 'Widgets' / 'WidgetStyle.swift').read_text(encoding='utf-8-sig')
    attributes = (root / 'Shared' / 'ZeehoActivityAttributes.swift').read_text(encoding='utf-8-sig')
    refresh = re.findall(r'(?m)^    private static let refreshInterval = [^\n]+$', source)
    if len(refresh) != 1:
        raise ValueError('expected one production provider refresh interval')
    provider = ['private enum ZeehoVehicleProvider {', refresh[0]]
    provider.extend(extract_provider_function(source, name) for name in
                    ('jitter', 'isFreshLocalSnapshot', 'timeline'))
    provider.append('}')
    return '\n\n'.join([
        SWIFT_SUPPORT,
        extract_type(attributes, 'ZeehoActivityKind'),
        extract_type(style, 'WidgetRefreshPolicy'),
        extract_type(presentation, 'WidgetStrings'),
        extract_type(presentation, 'WidgetValueText'),
        extract_type(presentation, 'WidgetVehiclePresentation'),
        extract_type(source, 'ZeehoVehicleEntry'),
        '\n'.join(provider),
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', help='swiftc executable path or command name')
    parser.add_argument('--require-swift', action='store_true',
                        help='fail instead of SKIP if swiftc is missing (always required on macOS)')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    source_path = root / 'Widgets' / 'ZeehoWidgets.swift'
    source = source_path.read_text(encoding='utf-8-sig')
    gate = extract_gate(source)
    freshness = extract_freshness_sources(root, source)
    shared_sources = [root / 'Shared' / name for name in ('SystemSnapshot.swift', 'SystemActivityPolicy.swift')]
    for path in shared_sources:
        if not path.is_file():
            raise ValueError('missing production Swift source: ' + str(path))
    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None:
        message = 'swiftc not found; production Swift tests were NOT executed'
        if args.swiftc or args.require_swift or sys.platform == 'darwin':
            print('FAIL: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        return 0

    print('Testing production gate and timeline logic from ' + str(source_path), flush=True)
    with tempfile.TemporaryDirectory(prefix='zeeho-widget-delivery-') as directory:
        work = pathlib.Path(directory)
        swift_file = work / 'WidgetDeliveryTests.swift'
        executable = work / ('widget-delivery-test.exe' if sys.platform == 'win32' else 'widget-delivery-test')
        swift_file.write_text('import Foundation\n\n' + gate + '\n' + freshness + '\n' + SWIFT_TESTS, encoding='utf-8')
        # 与 iOS 工程的 Swift 5 语言模式一致；@main 与生产 private 类放在同一文件。
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                        *[str(path) for path in shared_sources], str(swift_file), '-o', str(executable)],
                       cwd=work, check=True, timeout=60)
        subprocess.run([str(executable)], cwd=work, check=True, timeout=15)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
