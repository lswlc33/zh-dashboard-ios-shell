import Foundation
import Security
import CryptoKit

// 通用的本机随机标识，不读取 Android ID、IDFV 或 MAC。
// 不同步、不迁往其他设备，不把账号/VIN 明文写入 Keychain；无法读取不能临时换 ID。
//
// 作用域与安卓 InductiveKeyIdentity 对齐：**一份安装一个 ID，所有车辆共用**。
// 旧实现按 SHA256(账号+VIN) 分片，同一辆车换账号重登就会拿到新 ID，
// 于是同一台车会被悄悄登记成第二把手机钥匙（车端钥匙名额有上限）。
//
// 迁移是单向且保旧的：先查本车旧分片 key，查到时把同一字节写入尚为空的安装槽位，
// 仍返回本车已经登记的值。已有安装槽位不覆盖，旧分片也不删除，避免更换车端钥匙。
final class IOSInductiveIdentity {
    private static let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ble.identity")
    private static let service = "io.github.lswlc33.dashboard.ble.identity.v1"
    // 全机唯一槽位名。ownerHash 是 64 位 hex，不会与这个字面量撞车。
    private static let installAccount = "install"

    static func load(scope: IOSRideScope, completion: @escaping (Result<Data, IOSBLEPipeFailure>) -> Void) {
        guard scope.valid else { completion(.failure(IOSBLEPipeFailure("authorized_vehicle_required"))); return }
        let legacy = scope.ownerHash
        queue.async {
            let result: Result<Data, IOSBLEPipeFailure>
            do { result = .success(try resolve(legacy: legacy)) }
            catch { result = .failure(IOSBLEPipeFailure("identity_storage_failed")) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    // 读取顺序即兼容性策略：已登记过的旧 key 优先，其次全机唯一 key，最后新建全机唯一 key。
    private static func resolve(legacy: String) throws -> Data {
        if let data = try read(account: legacy) {
            if try read(account: installAccount) == nil {
                var item = query(account: installAccount)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                item[kSecValueData as String] = data
                let saved = SecItemAdd(item as CFDictionary, nil)
                guard saved == errSecSuccess || saved == errSecDuplicateItem else {
                    throw IOSBLEPipeFailure("identity_unavailable")
                }
                // 竞争者已写入也只核验可读，绝不替换现存安装 ID 或本车旧 ID。
                guard try read(account: installAccount) != nil else { throw IOSBLEPipeFailure("identity_unavailable") }
            }
            return data
        }
        if let data = try read(account: installAccount) { return data }
        return try create(account: installAccount)
    }

    private static func read(account: String) throws -> Data? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data, data.count == 8 else {
            throw IOSBLEPipeFailure("identity_corrupt")
        }
        return data
    }

    private static func create(account: String) throws -> Data {
        var bytes = Data(count: 8)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw IOSBLEPipeFailure("random_unavailable") }
        var item = query(account: account)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = bytes
        let saved = SecItemAdd(item as CFDictionary, nil)
        // 跨实例竞争只接受已经存下来的真实 ID，绝不覆盖它。
        if saved == errSecDuplicateItem {
            bytes.resetBytes(in: 0..<bytes.count)
            guard let existing = try read(account: account) else { throw IOSBLEPipeFailure("identity_unavailable") }
            return existing
        }
        guard saved == errSecSuccess else { bytes.resetBytes(in: 0..<bytes.count); throw IOSBLEPipeFailure("identity_unavailable") }
        return bytes
    }
}
