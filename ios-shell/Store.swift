import Foundation
import CryptoKit
import Security
import Darwin
import CoreFoundation

// 整个存档（包括 token、账号和偏好）只在私有目录中加密落盘。
// 队列先读再写；损坏或 Keychain 不可用时保留原件，绝不拿空库覆盖。
final class IOSStore {
    static let maxArchiveBytes = 24 * 1024 * 1024
    static let maxValueBytes = 4 * 1024 * 1024
    private static let maxPlainBytes = 16 * 1024 * 1024
    private static let maxKeys = 4096
    private static let associatedData = Data("zeeho.ios.store.v1".utf8)

    struct Snapshot {
        let values: [String: String]
        let revision: Int
        let readError: String?
    }

    private struct Archive: Codable {
        let version: Int
        let revision: Int
        let values: [String: String]
    }

    private enum Failure: Error {
        case reason(String)
        var code: String { if case let .reason(value) = self { return value }; return "store_failed" }
    }

    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.store", qos: .userInitiated)
    private var loaded = false
    private var values: [String: String] = [:]
    private var revision = 0
    private var readError: String?
    private var directory: URL?
    private var archiveURL: URL?
    private var key: SymmetricKey?

    func snapshot(completion: @escaping (Snapshot) -> Void) {
        queue.async { [self] in
            self.loadIfNeeded()
            let snapshot = Snapshot(values: self.values, revision: self.revision, readError: self.readError)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func commit(_ object: [String: Any], completion: @escaping ([String: Any], Snapshot) -> Void) {
        queue.async { [self] in
            self.loadIfNeeded()
            var result: [String: Any]
            do {
                if let readError = self.readError { throw Failure.reason(readError) }
                guard Set(object.keys).isSubset(of: ["puts", "removes"]),
                      let puts = object["puts"] as? [String: String],
                      let removes = object["removes"] as? [String],
                      puts.count + removes.count <= Self.maxKeys,
                      Set(removes).count == removes.count else { throw Failure.reason("invalid_commit") }
                var next = self.values
                for (name, value) in puts {
                    guard Self.validKey(name), value.utf8.count <= Self.maxValueBytes,
                          !removes.contains(name) else { throw Failure.reason("invalid_store_value") }
                    next[name] = value
                }
                for name in removes {
                    guard Self.validKey(name) else { throw Failure.reason("invalid_store_key") }
                    next.removeValue(forKey: name)
                }
                guard next.count <= Self.maxKeys, self.revision < 9_007_199_254_740_990,
                      let key = self.key, let directory = self.directory, let archiveURL = self.archiveURL else {
                    throw Failure.reason("store_unavailable")
                }
                let nextRevision = self.revision + 1
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let plain = try encoder.encode(Archive(version: 1, revision: nextRevision, values: next))
                guard plain.count <= Self.maxPlainBytes else { throw Failure.reason("store_too_large") }
                let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.associatedData)
                guard let encrypted = sealed.combined, encrypted.count <= Self.maxArchiveBytes else {
                    throw Failure.reason("encryption_failed")
                }
                try self.atomicWrite(encrypted, to: archiveURL, directory: directory)
                // 只有文件和目录 fsync 成功才公布新内存快照和 revision。
                self.values = next
                self.revision = nextRevision
                result = ["ok": true, "revision": self.revision]
            } catch {
                let code = (error as? Failure)?.code ?? "store_write_failed"
                // rename 后若目录同步失败，磁盘状态不确定；冻结写入，下一次加载显式恢复。
                if code == "durability_uncertain" { self.readError = code }
                result = ["ok": false, "reason": code]
            }
            let snapshot = Snapshot(values: self.values, revision: self.revision, readError: self.readError)
            DispatchQueue.main.async { completion(result, snapshot) }
        }
    }

    private static func validKey(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && name.hasPrefix("zeeho.")
            && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            let manager = FileManager.default
            let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("ZeehoPrivate", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                                     .posixPermissions: 0o700])
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                       .posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var privateDirectory = directory
            try privateDirectory.setResourceValues(excluded)
            self.directory = directory
            let file = directory.appendingPathComponent("store-v1.aesgcm", isDirectory: false)
            archiveURL = file
            let exists = manager.fileExists(atPath: file.path)
            // 未确认无原档时绝不生成新密钥，否则原档会永远无法解密。
            key = try loadKey(archiveExists: exists)
            guard exists else { return }
            let fd = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
            guard fd >= 0 else { throw Failure.reason("store_read_failed") }
            defer { Darwin.close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size > 0, status.st_size <= Self.maxArchiveBytes else {
                throw Failure.reason("store_corrupt")
            }
            let encrypted = try read(fd, count: Int(status.st_size))
            guard let key = key else { throw Failure.reason("keychain_unavailable") }
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.associatedData)
            guard plain.count <= Self.maxPlainBytes else { throw Failure.reason("store_corrupt") }
            let archive = try JSONDecoder().decode(Archive.self, from: plain)
            guard archive.version == 1, archive.revision >= 0, archive.revision < 9_007_199_254_740_991,
                  archive.values.count <= Self.maxKeys,
                  archive.values.allSatisfy({ Self.validKey($0.key) && $0.value.utf8.count <= Self.maxValueBytes }) else {
                throw Failure.reason("store_corrupt")
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                                       .posixPermissions: 0o600], ofItemAtPath: file.path)
            values = archive.values
            revision = archive.revision
        } catch {
            values = [:]
            readError = (error as? Failure)?.code ?? "store_corrupt_or_locked"
        }
    }

    private func loadKey(archiveExists: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.lswlc33.dashboard.ios.encrypted-store",
            kSecAttrAccount as String: "aes-gcm-v1",
            kSecAttrSynchronizable as String: false
        ]
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecSuccess {
            guard let bytes = item as? Data, bytes.count == 32 else { throw Failure.reason("keychain_invalid_key") }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound else { throw Failure.reason("keychain_unavailable") }
        guard !archiveExists else { throw Failure.reason("keychain_missing_for_archive") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.reason("keychain_random_failed")
        }
        var insert = query
        insert[kSecValueData as String] = Data(bytes)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(insert as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try loadKey(archiveExists: true) }
        guard saved == errSecSuccess else { throw Failure.reason("keychain_save_failed") }
        return SymmetricKey(data: Data(bytes))
    }

    private func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let start = buffer.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, start.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        guard success else { throw Failure.reason("store_read_failed") }
        return data
    }

    private func atomicWrite(_ data: Data, to file: URL, directory: URL) throws {
        let temporary = directory.appendingPathComponent(".store-" + UUID().uuidString + ".tmp")
        let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw Failure.reason("store_open_failed") }
        defer {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: temporary)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: temporary.path)
        let success = data.withUnsafeBytes { buffer -> Bool in
            guard let start = buffer.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, start.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        guard success, fsync(fd) == 0 else { throw Failure.reason("store_sync_failed") }
        let directoryFD = directory.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard directoryFD >= 0 else { throw Failure.reason("directory_open_failed") }
        defer { Darwin.close(directoryFD) }
        let renamed = temporary.path.withCString { source in
            file.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else { throw Failure.reason("store_rename_failed") }
        guard fsync(directoryFD) == 0 else { throw Failure.reason("durability_uncertain") }
    }
}
