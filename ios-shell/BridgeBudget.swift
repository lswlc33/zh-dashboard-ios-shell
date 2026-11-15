import Foundation

// 预留的是本条消息的 JSON 安全上界，不是方法允许的最大值；小请求并发不能被误算成几十 MB。
enum IOSBridgeBudget {
    // 只给 txn.request 的公开资源回执使用；请求在途与其它 RPC 的预算不跟着放宽。
    static let maxTransactionResponseBytes = 20 * 1024 * 1024
    static let maxTransactionReplyBytes = ((maxTransactionResponseBytes + 2) / 3) * 4 + 64 * 1024

    struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    // 逐字节核验规范 Base64 与 padding 位，避免为 20MiB 回执再解码/重编码一整份二进制。
    static func transactionBodySize(_ text: String, limit: Int) -> Int? {
        let count = text.utf8.count
        guard limit > 0, limit <= maxTransactionResponseBytes,
              count % 4 == 0, count <= ((limit + 2) / 3) * 4 else { return nil }
        var padding = 0
        var last: UInt8 = 0
        for byte in text.utf8 {
            if byte == 61 {
                padding += 1
                guard padding <= 2 else { return nil }
                continue
            }
            guard padding == 0 else { return nil }
            switch byte {
            case 65...90: last = byte - 65
            case 97...122: last = byte - 97 + 26
            case 48...57: last = byte - 48 + 52
            case 43: last = 62
            case 47: last = 63
            default: return nil
            }
        }
        guard (padding != 1 || (last & 3) == 0), (padding != 2 || (last & 15) == 0) else { return nil }
        let decoded = count / 4 * 3 - padding
        return decoded >= 0 && decoded <= limit ? decoded : nil
    }

    static func measure(_ object: Any, limit: Int) throws -> Int {
        guard limit > 0 else { throw Failure("request_too_large") }
        var total = 0
        var nodes = 0
        func add(_ bytes: Int) throws {
            guard bytes >= 0, bytes <= limit - total else { throw Failure("request_too_large") }
            total += bytes
        }
        func string(_ text: String) throws {
            try add(text.utf8.count)
            try add(2)
            for scalar in text.unicodeScalars {
                if scalar.value < 32 { try add(5) }
                else if scalar.value == 34 || scalar.value == 92 || scalar.value == 47 { try add(1) }
                else if scalar.value == 0x2028 || scalar.value == 0x2029 { try add(3) }
            }
        }
        func visit(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 20, nodes <= 20_000 else { throw Failure("invalid_json") }
            if let text = value as? String {
                try string(text)
            } else if let array = value as? [Any] {
                try add(2 + max(0, array.count - 1))
                for item in array { try visit(item, depth: depth + 1) }
            } else if let dictionary = value as? [String: Any] {
                try add(2 + max(0, dictionary.count - 1))
                for (key, item) in dictionary {
                    // 键也可能含引号、反斜线和控制字符，必须和字符串值采用同一转义预算。
                    try string(key)
                    try add(1)
                    try visit(item, depth: depth + 1)
                }
            } else if let number = value as? NSNumber {
                try add(max(32, number.stringValue.utf8.count + 2))
            } else if value is NSNull {
                try add(4)
            } else { throw Failure("invalid_json") }
        }
        try visit(object, depth: 0)
        return total
    }
}
