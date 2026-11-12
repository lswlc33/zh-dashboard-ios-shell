import Foundation

// 只链接 BridgeBudget.swift 与 Foundation；真实 macOS 用 swiftc 执行，不引入 XCTest target。
// 用实际 JSON 字节验证上界，再用小预留模型覆盖同批入队、缩账与释放，不依赖线程或时钟。
@main
enum BridgeBudgetTest {
    static func conservative(_ object: Any, limit: Int, name: String) throws -> (measured: Int, actual: Int) {
        let measured = try IOSBridgeBudget.measure(object, limit: limit)
        assert(JSONSerialization.isValidJSONObject(object), "\(name): 测试输入必须是有效 JSON")
        let actual = try JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes]).count
        assert(actual <= measured, "\(name): 实际 JSON \(actual) 字节超过预留 \(measured)")
        assert(measured > 0 && measured <= limit, "\(name): 预留必须在本条消息的上限内")
        return (measured, actual)
    }

    static func rejects(_ object: Any, limit: Int, code: String, name: String) {
        do {
            _ = try IOSBridgeBudget.measure(object, limit: limit)
            assertionFailure("\(name): 超限输入被接受")
        } catch let error as IOSBridgeBudget.Failure {
            assert(error.code == code, "\(name): 应返回 \(code)，实际 \(error.code)")
        } catch {
            assertionFailure("\(name): 未知错误 \(error)")
        }
    }

    // 与 receive 的容量条件同形；源码契约另行保证生产桥使用真实 measuredSize。
    struct Reservations {
        static let byteLimit = 32 * 1024 * 1024
        private(set) var bytes = 0
        private(set) var held: [String: Int] = [:]

        mutating func reserve(_ id: String, incoming: Int) -> Bool {
            guard held[id] == nil, held.count < 48, incoming > 0,
                  incoming <= Self.byteLimit - bytes else { return false }
            bytes += incoming
            held[id] = incoming
            return true
        }

        mutating func validate(_ id: String, actual: Int) -> Bool {
            guard let reserved = held[id], actual >= 0, actual <= reserved else { return false }
            bytes += actual - reserved
            held[id] = actual
            return true
        }

        mutating func release(_ id: String) {
            guard let reserved = held.removeValue(forKey: id) else { return }
            bytes -= reserved
        }
    }

    static func nested(_ depth: Int) -> Any {
        var object: Any = NSNull()
        for _ in 0..<depth { object = [object] }
        return object
    }

    static func main() throws {
        var cases = 0
        func accepts(_ name: String, _ object: Any, expected: Int? = nil,
                     limit: Int = 12 * 1024 * 1024) throws {
            let result = try conservative(object, limit: limit, name: name)
            if let expected = expected {
                assert(result.measured == expected, "\(name): 预算应为 \(expected)，实际 \(result.measured)")
            }
            cases += 1
        }
        func rejected(_ name: String, _ object: Any, limit: Int, code: String) {
            rejects(object, limit: limit, code: code, name: name)
            cases += 1
        }

        try accepts("empty_array", [Any](), expected: 2)
        try accepts("empty_dictionary", [String: Any](), expected: 2)
        try accepts("single_empty_string", [""], expected: 4)

        // 键和值都可能来自网页；斜线即使当前 serializer 不转义，也保留安全余量。
        let escaped = "\"\\/"
        try accepts("escaped_key_and_value", [escaped: escaped], expected: 19)
        let controls = String(String.UnicodeScalarView((0..<32).map { UnicodeScalar($0)! }))
        try accepts("all_control_keys_and_values", [controls: controls], expected: 391)
        let separators = "\u{2028}\u{2029}"
        try accepts("line_separator_keys_and_values", [separators: separators], expected: 31)
        let unicode = "中文é\u{1D11E}e\u{301}"
        try accepts("unicode_utf8_keys_and_values", [unicode: unicode], expected: 37)

        // NSDecimalNumber 不能先转 Double 再估长：38 位十进制数会超过通常的 32 字节余量。
        try accepts("long_decimal", [NSDecimalNumber(string: "12345678901234567890123456789012345678")],
                    expected: 42)
        try accepts("numbers_booleans_and_null", [NSNumber(value: Int64.min), NSNumber(value: UInt64.max),
                    NSNumber(value: Double.leastNonzeroMagnitude), NSNumber(value: Double.greatestFiniteMagnitude),
                    NSNumber(value: true), NSNumber(value: false), NSNull()] as [Any], expected: 204)
        try accepts("nested_mixed_containers", ["a": [[String: Any](), [Any](), ["k": "v"], NSNull()] as [Any],
                    "b": ["x": [true, false, 1] as [Any]]] as [String: Any])

        try accepts("inclusive_byte_limit", ["x"], expected: 5, limit: 5)
        rejected("oversize_request", ["body": String(repeating: "x", count: 12 * 1024 * 1024)],
                 limit: 12 * 1024 * 1024, code: "request_too_large")
        rejected("zero_limit", [Any](), limit: 0, code: "request_too_large")
        rejected("negative_limit_no_overflow", [Any](), limit: Int.min, code: "request_too_large")
        try accepts("depth_20_boundary", nested(20), expected: 44)
        rejected("depth_21_rejected", nested(21), limit: 1024, code: "invalid_json")
        // 根数组也占一个节点，因此 19,999 个 null 恰好达到 20,000 节点。
        try accepts("node_20000_boundary", [Any](repeating: NSNull(), count: 19_999), expected: 99_996)
        rejected("node_20001_rejected", [Any](repeating: NSNull(), count: 20_000),
                 limit: 1024 * 1024, code: "invalid_json")

        // 同一 tick 的八条小消息先全部预留，不能靠 worker 提前释放才放行。
        var reservations = Reservations()
        var actualSizes: [Int] = []
        for index in 0..<8 {
            let transaction = index % 2 == 0
            let args: [String: Any] = transaction
                ? ["id": "txn-\(index)", "bodyB64": String(repeating: "A", count: 1024)]
                : ["baseRevision": 0, "values": ["sample": String(repeating: "s", count: 2048)]]
            let envelope: [String: Any] = ["version": 1, "nonce": "fixture", "id": "rpc-\(index)",
                                          "method": transaction ? "txn.request" : "store.commit", "args": [args]]
            let result = try conservative(envelope, limit: (transaction ? 12 : 24) * 1024 * 1024,
                                          name: "same_tick_small_messages")
            assert(reservations.reserve("rpc-\(index)", incoming: result.measured),
                   "same_tick_small_messages: 第 \(index + 1) 条小请求不应触发 pending_bytes_limit")
            actualSizes.append(result.actual)
        }
        assert(reservations.held.count == 8 && reservations.bytes < 32 * 1024,
               "same_tick_small_messages: 八条约 1KB/2KB 请求只应预留几十 KB")
        var oldReservations = Reservations()
        assert(oldReservations.reserve("txn-1", incoming: 12 * 1024 * 1024))
        assert(!oldReservations.reserve("commit", incoming: 24 * 1024 * 1024),
               "old_method_limit_counterexample: 旧 12MB + 24MB 预扣会错误拒绝小消息")
        assert(oldReservations.reserve("txn-2", incoming: 12 * 1024 * 1024))
        assert(!oldReservations.reserve("txn-3", incoming: 12 * 1024 * 1024))

        let beforeInvalidValidation = reservations.bytes
        assert(!reservations.validate("rpc-0", actual: reservations.held["rpc-0"]! + 1))
        assert(reservations.bytes == beforeInvalidValidation, "validation_must_not_grow: 超预留回执不得加账")
        for index in 0..<8 {
            let before = reservations.bytes
            assert(reservations.validate("rpc-\(index)", actual: actualSizes[index]))
            assert(reservations.bytes <= before, "validation_only_shrinks: worker 只能缩小预留")
        }
        assert(reservations.bytes == actualSizes.reduce(0, +), "validated_sum: pending 总量必须等于实际 JSON 字节和")
        for index in [7, 1, 5, 3, 0, 6, 2, 4] {
            reservations.release("rpc-\(index)")
            assert(reservations.bytes == reservations.held.values.reduce(0, +), "release_sum: 任意完成顺序都要准确释放")
        }
        reservations.release("rpc-0")
        assert(reservations.bytes == 0 && reservations.held.isEmpty, "release_once: 重复完成不能负账")
        cases += 1

        var full = Reservations()
        assert(full.reserve("full", incoming: Reservations.byteLimit), "pending_32mb_boundary: 等于容量仍可预留")
        assert(!full.reserve("extra", incoming: 1), "pending_32mb_reject: 多一字节必须拒绝")
        assert(!full.reserve("overflow", incoming: Int.max), "pending_overflow_safe: 巨大 incoming 必须拒绝而非溢出")
        assert(full.bytes == Reservations.byteLimit)
        full.release("full")
        for index in 0..<48 { assert(full.reserve("rpc-\(index)", incoming: 1)) }
        assert(!full.reserve("rpc-48", incoming: 1), "pending_48_boundary: 第 49 条必须拒绝，即使字节很少")
        full.release("rpc-0")
        assert(full.reserve("replacement", incoming: 1), "pending_slot_release: 完成后应恢复一个名额")
        assert(full.bytes == 48 && full.held.count == 48)
        cases += 1

        assert(cases == 20)
        print("iOS bridge budget checks passed (20 cases)")
    }
}
