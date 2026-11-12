import Foundation

// 预留的是本条消息的 JSON 安全上界，不是方法允许的最大值；小请求并发不能被误算成几十 MB。
enum IOSBridgeBudget {
    struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
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
