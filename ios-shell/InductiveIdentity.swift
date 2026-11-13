import Foundation
import Security
import CryptoKit

// 通用的本机随机标识，按原生账号/VIN 隔离；不读取 Android ID、IDFV 或 MAC。
// 不同步、不迁往其他设备，不把账号/VIN 明文写入 Keychain；无法读取不能临时换 ID。
final class IOSInductiveIdentity {
    private static let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ble.identity")
    private static let service = "io.github.lswlc33.dashboard.ble.identity.v1"

    static func load(scope: IOSRideScope, completion: @escaping (Result<Data, IOSBLEPipeFailure>) -> Void) {
        guard scope.valid else { completion(.failure(IOSBLEPipeFailure("authorized_vehicle_required"))); return }
        let account = scope.ownerHash
        queue.async {
            let result: Result<Data, IOSBLEPipeFailure>
            do { result = .success(try readOrCreate(account: account)) }
            catch { result = .failure(IOSBLEPipeFailure("identity_storage_failed")) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private static func readOrCreate(account: String) throws -> Data {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &found)
        if status == errSecSuccess {
            guard let data = found as? Data, data.count == 8 else { throw IOSBLEPipeFailure("identity_corrupt") }
            return data
        }
        guard status == errSecItemNotFound else { throw IOSBLEPipeFailure("identity_unavailable") }
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
        if saved == errSecDuplicateItem { bytes.resetBytes(in: 0..<bytes.count); return try readOrCreate(account: account) }
        guard saved == errSecSuccess else { bytes.resetBytes(in: 0..<bytes.count); throw IOSBLEPipeFailure("identity_unavailable") }
        return bytes
    }
}
