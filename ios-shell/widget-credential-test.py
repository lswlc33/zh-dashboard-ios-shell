"""运行生产小组件凭据存储与 Keychain 撤销逻辑，绝不访问真实 Keychain。

文件容器、Security C API 和 UserDefaults suite 是测试边界；被测 Swift 方法保持原样。
macOS 构建必须执行；无 swiftc 的其他平台明确 SKIP，--require-swift 可禁止跳过。
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid


BOUNDARIES = r'''
import Foundation

private enum TestError: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestError.failed(message) }
}

// 只替换文件容器边界；生产 read/save/renew/clear 与材料比较完整参与编译。
public enum SystemSnapshotStore {
    private static let lock = NSLock()
    private static var hook: (() -> Void)?
    public static func containerURL() throws -> URL {
        lock.lock(); let callback = hook; lock.unlock()
        callback?()
        return URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    }
    public static func ownerIdentifier(_ value: String) -> String? { value.isEmpty ? nil : value }
    static func setHook(_ callback: (() -> Void)?) { lock.lock(); hook = callback; lock.unlock() }
}
public enum SystemSnapshotFreshness { public static let futureToleranceSeconds: Double = 30 }

// Security API 的确定性故障边界：真实 Store 的 outcome/save/remove 原样执行。
typealias CFDictionary = [String: Any]
typealias CFTypeRef = Any
let kSecClass = "class", kSecClassGenericPassword = "generic"
let kSecAttrService = "service", kSecAttrAccount = "account", kSecValueData = "data"
let kSecAttrAccessible = "accessible", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "firstUnlock"
let kSecReturnData = "returnData", kSecMatchLimit = "limit", kSecMatchLimitOne = "one"
let errSecSuccess: Int32 = 0, errSecItemNotFound: Int32 = -25300
private var fakeStatus: Int32 = errSecSuccess
private var fakeData: Data? = try! JSONEncoder().encode(IOSBackgroundCredential(token: "old"))
private let testDefaults = UserDefaults(suiteName: CommandLine.arguments[3])!

struct IOSBackgroundCredential: Codable, Equatable {
    let token: String
    var isValid: Bool { !token.isEmpty }
    var grantedScopes: [String] { isValid ? ["app"] : [] }
}
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> Int32 {
    guard let data = fakeData else { return errSecItemNotFound }
    result.pointee = data
    return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ update: CFDictionary) -> Int32 {
    guard fakeStatus == errSecSuccess else { return fakeStatus }
    guard fakeData != nil else { return errSecItemNotFound }
    fakeData = update[kSecValueData] as? Data
    return errSecSuccess
}
func SecItemAdd(_ item: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> Int32 {
    guard fakeStatus == errSecSuccess else { return fakeStatus }
    fakeData = item[kSecValueData] as? Data
    return errSecSuccess
}
func SecItemDelete(_ query: CFDictionary) -> Int32 {
    guard fakeStatus == errSecSuccess else { return fakeStatus }
    fakeData = nil
    return errSecSuccess
}
'''


SWIFT_TESTS = r'''
private final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func visit() {
        lock.lock(); count += 1; let shouldBlock = count == 2; lock.unlock()
        if shouldBlock {
            reached.signal()
            _ = release.wait(timeout: .now() + .seconds(3))
        }
    }
}

@main
private enum CredentialStorageTests {
    static func value(token: String = "old", time: Int64) -> WidgetCredential {
        WidgetCredential(ownerID: "test-owner.test-scope", vin: "VIN-A", token: token,
                         appID: "test-app", appSecret: "test-secret", updatedAt: time)
    }

    static func widgetStorage() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let old = value(time: now - 1_000)
        let renewal = value(time: now)
        WidgetCredentialStore.clear()
        try check(!WidgetCredentialStore.renew(matching: renewal), "absent mirror was recreated from Keychain")
        try check(WidgetCredentialStore.read() == nil, "missing mirror unexpectedly appeared")
        try check(WidgetCredentialStore.save(old), "initial projection save failed")
        try check(WidgetCredentialStore.renew(matching: renewal), "matching material could not renew")
        try check(WidgetCredentialStore.read()?.updatedAt == now, "renewal timestamp was not saved")
        try check(!WidgetCredentialStore.renew(matching: old), "renewal regressed the timestamp")

        let rotated = value(token: "new", time: now)
        try check(WidgetCredentialStore.save(rotated), "foreground token rotation failed")
        try check(!WidgetCredentialStore.renew(matching: renewal), "old token overwrote a new foreground token")
        try check(WidgetCredentialStore.read()?.token == "new", "new foreground token was lost")
        for field in 0..<4 {
            var changed = rotated
            switch field {
            case 0: changed.ownerID = "other-owner.other-scope"
            case 1: changed.vin = "VIN-B"
            case 2: changed.appID = "other-app"
            default: changed.appSecret = "other-secret"
            }
            changed.updatedAt += 1
            try check(!WidgetCredentialStore.renew(matching: changed), "mismatching material field accepted")
            try check(WidgetCredentialStore.read() == rotated, "rejected material mutated the mirror")
        }
        try check(WidgetCredentialStore.save(value(time: now - 31 * 24 * 3600 * 1000)), "expired fixture save failed")
        try check(WidgetCredentialStore.read() == nil, "expired mirror was usable before renewal")
        try check(WidgetCredentialStore.renew(matching: renewal), "matching expired mirror could not renew")
        try check(WidgetCredentialStore.read() == renewal, "expired mirror renewal did not persist")
        print("PASS: absent, rotated, mismatching, expired and backwards credential renewal")

        // 把续期停在读完旧值、准备 save 的容器边界；clear 必须排在整个续期之后。
        let barrier = Barrier()
        let renewed = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        SystemSnapshotStore.setHook(barrier.visit)
        DispatchQueue.global().async {
            _ = WidgetCredentialStore.renew(matching: renewal)
            renewed.signal()
        }
        let reached = barrier.reached.wait(timeout: .now() + .seconds(1)) == .success
        if !reached {
            barrier.release.signal()
            SystemSnapshotStore.setHook(nil)
            throw TestError.failed("renewal never reached read/write barrier")
        }
        DispatchQueue.global().async { WidgetCredentialStore.clear(); cleared.signal() }
        let clearWaited = cleared.wait(timeout: .now() + .milliseconds(120)) == .timedOut
        barrier.release.signal()
        let didRenew = renewed.wait(timeout: .now() + .seconds(1)) == .success
        let didClear = clearWaited && cleared.wait(timeout: .now() + .seconds(1)) == .success
        SystemSnapshotStore.setHook(nil)
        try check(clearWaited && didRenew && didClear, "clear interleaved the renewal read/write critical section")
        try check(WidgetCredentialStore.read() == nil, "renewal resurrected a cleared mirror")
        print("PASS: concurrent clear cannot interleave compare-and-renew or revive credentials")
    }

    static func main() throws {
        let phase = CommandLine.arguments[1]
        if phase == "cleanup" {
            testDefaults.removePersistentDomain(forName: CommandLine.arguments[3])
            _ = testDefaults.synchronize()
            return
        }
        if phase == "initial" {
            testDefaults.removePersistentDomain(forName: CommandLine.arguments[3])
            try widgetStorage()
            try check(IOSBackgroundCredentialStore.load()?.token == "old", "initial Keychain fixture unreadable")
            fakeStatus = -25293
            try check(!IOSBackgroundCredentialStore.remove(), "failed Keychain deletion reported success")
            try check(fakeData != nil && IOSBackgroundCredentialStore.load() == nil,
                      "failed deletion left old material authorized")
            print("PASS: failed Keychain deletion revokes access while preserving the error result")
        } else if phase == "failed-save" {
            testDefaults.removePersistentDomain(forName: CommandLine.arguments[3])
            try check(IOSBackgroundCredentialStore.load()?.token == "old", "old fixture missing before replacement")
            fakeStatus = -25293
            try check(!IOSBackgroundCredentialStore.save(IOSBackgroundCredential(token: "new")),
                      "failed Keychain replacement reported success")
            try check(IOSBackgroundCredentialStore.load() == nil, "failed replacement authorized old material")
            print("PASS: failed Keychain replacement revokes old material")
        } else if phase == "after-restart" {
            try check(fakeData != nil && IOSBackgroundCredentialStore.load() == nil,
                      "process restart revived revoked Keychain material")
            fakeStatus = errSecSuccess
            try check(IOSBackgroundCredentialStore.save(IOSBackgroundCredential(token: "new")),
                      "successful foreground reauthorization failed")
            try check(IOSBackgroundCredentialStore.load()?.token == "new", "reauthorization failed to clear revocation")
            try check(IOSBackgroundCredentialStore.remove() && IOSBackgroundCredentialStore.load() == nil,
                      "successful deletion did not clear authorization")
            print("PASS: persistent revocation survives restart and successful reauthorization restores access")
        } else { throw TestError.failed("unknown phase") }
        _ = testDefaults.synchronize()
    }
}
'''


def extract_keychain_store(source):
    start = re.search(r'(?m)^enum IOSBackgroundCredentialStore \{', source)
    end = re.search(r'(?m)^enum IOSBackgroundCredentialIssue:', source)
    if not start or not end or start.start() >= end.start():
        raise ValueError('expected credential store before credential issue enum')
    # suite 是可持久测试边界；不替换被测读写/撤销逻辑，也不触碰真实标准域。
    return source[start.start():end.start()].replace('UserDefaults.standard', 'testDefaults')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc')
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    widget_source = (root / 'Shared' / 'WidgetCredential.swift').read_text(encoding='utf-8-sig')
    keychain_source = extract_keychain_store((root / 'BackgroundSigning.swift').read_text(encoding='utf-8-sig'))
    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None:
        message = 'swiftc not found; production Swift credential storage tests were NOT executed'
        if args.swiftc or args.require_swift or sys.platform == 'darwin':
            print('FAIL: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        return 0
    with tempfile.TemporaryDirectory(prefix='zeeho-widget-credential-') as directory:
        work = pathlib.Path(directory)
        swift_file = work / 'CredentialStorageTests.swift'
        executable = work / ('credential-storage-test.exe' if sys.platform == 'win32' else 'credential-storage-test')
        swift_file.write_text(BOUNDARIES + '\n' + widget_source + '\n' + keychain_source + '\n' + SWIFT_TESTS,
                              encoding='utf-8')
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library', str(swift_file), '-o', str(executable)],
                       cwd=work, check=True, timeout=60)
        suite = 'io.zeeho.credential-test.' + uuid.uuid4().hex
        command = [str(executable), '', str(work / 'container'), suite]
        try:
            for phase in ('initial', 'after-restart', 'failed-save', 'after-restart'):
                command[1] = phase
                subprocess.run(command, cwd=work, check=True, timeout=10)
        finally:
            command[1] = 'cleanup'
            subprocess.run(command, cwd=work, check=True, timeout=10)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
