"""编译并执行生产 WidgetCompletionGate：python -I widget-delivery-test.py。

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
            ("late results never overwrite", lateResultsDoNotOverwrite),
        ]
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                throw TestFailure(description: "FAIL: \(name): \(error)")
            }
        }
        print("PASS: 5 production Swift WidgetCompletionGate tests")
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', help='swiftc executable path or command name')
    parser.add_argument('--require-swift', action='store_true',
                        help='fail instead of SKIP if swiftc is missing (always required on macOS)')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    source_path = root / 'Widgets' / 'ZeehoWidgets.swift'
    gate = extract_gate(source_path.read_text(encoding='utf-8-sig'))
    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None:
        message = 'swiftc not found; production Swift tests were NOT executed'
        if args.swiftc or args.require_swift or sys.platform == 'darwin':
            print('FAIL: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        return 0

    print('Testing production class from ' + str(source_path), flush=True)
    with tempfile.TemporaryDirectory(prefix='zeeho-widget-delivery-') as directory:
        work = pathlib.Path(directory)
        swift_file = work / 'WidgetDeliveryTests.swift'
        executable = work / ('widget-delivery-test.exe' if sys.platform == 'win32' else 'widget-delivery-test')
        swift_file.write_text('import Foundation\n\n' + gate + '\n' + SWIFT_TESTS, encoding='utf-8')
        # 与 iOS 工程的 Swift 5 语言模式一致；@main 与生产 private 类放在同一文件。
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                        str(swift_file), '-o', str(executable)],
                       cwd=work, check=True, timeout=60)
        subprocess.run([str(executable)], cwd=work, check=True, timeout=15)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
