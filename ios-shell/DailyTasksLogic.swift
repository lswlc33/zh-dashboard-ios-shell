import Foundation
import CoreFoundation

/// Pure response normalization for the offline daily-task fixture tests.
enum IOSDailyTasksLogic {
    static let actionCodes: Set<String> = ["1023", "1026", "1024"]
    static let actionOrder = ["1023", "1026", "1024"]

    static func actionableRows(_ rows: [[String: Any]]) -> [[String: Any]]? {
        let actionable = rows.filter { actionCodes.contains(text($0["code"]) ?? "") }
        guard !actionable.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for row in actionable {
            let code = text(row["code"]) ?? ""
            counts[code, default: 0] += 1
        }
        let unique = actionable.filter { counts[text($0["code"]) ?? ""] == 1 }
        return unique.isEmpty ? nil : unique
    }

    static func isComplete(_ row: [String: Any]) -> Bool {
        text(row["completeFlag"]) == "0"
    }

    // 已录回包的 null 与明确 1 表示待执行；缺键、布尔或其它值保持未知。
    static func isPending(_ row: [String: Any]) -> Bool {
        guard let flag = text(row["completeFlag"]) else { return row["completeFlag"] is NSNull }
        return flag == "1"
    }

    static func pendingActionCodes(_ rows: [[String: Any]]) -> [String] {
        actionOrder.filter { code in
            rows.contains { text($0["code"]) == code && isPending($0) }
        }
    }

    static func postBody(content: String) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: content, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "{\"postSubInfo\":{\"topicList\":[]},\"topicid\":\"\",\"postcontent\":\(quoted)}"
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }
}
