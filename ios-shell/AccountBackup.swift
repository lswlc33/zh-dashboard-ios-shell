import Foundation
import CoreFoundation

/// 账号备份的纯逻辑层：不碰 UIKit、不读写存档、不打日志，可在 CI 的 mac 上直接编译单测。
///
/// 协议与安卓 `AccountBackupService` / `AccountBackupCodec`、网页 `domain-migration.js`
/// 完全对齐，三端互相导入导出：
///   · 新格式 `[{"token":"…","userid":"…"}, …]`
///   · 旧格式（浏览器版留下的单账号）`{"token":"…","userId":"…"}`
/// 上限也照抄安卓：20 个账号、token 8192 字符、userid 128 字符、整段 1 MiB。
///
/// 这里只做「算」：解析、导出文本、预览差异、生成待提交的键值。
/// 真正落盘由调用方通过 `IOSStore.commit(_:expectedRevision:)` 一次原子写完，
/// 因为 iOS 的整份存档是一个 AES-GCM 文件，一次 commit 就是一次事务。
enum AccountBackup {
    static let maxAccounts = 20
    static let maxTokenLength = 8192
    static let maxUserIDLength = 128
    static let maxBytes = 1024 * 1024
    /// 账号池文档本身也设上界：它是加密存档里最大的单项值（IOSStore 单值上限 4MB）。
    static let maxPoolBytes = 2 * 1024 * 1024

    /// 存档键名。三端共用，改一个就会让另一端的恢复读不到。
    static let poolKey = "zeeho.accounts.v1"
    static let tokenKey = "zeeho.token"
    static let clearedKey = "zeeho.session.cleared.v1"

    struct Entry: Equatable {
        let token: String
        let userid: String
    }

    /// 失败只带固定分类，绝不回传输入内容（这里全是登录凭据）。
    enum Failure: Error, Equatable {
        /// 格式、字段、JSON 不合法
        case invalidInput
        case tooLarge
        case accountCount
        /// 同一个 token 在备份里对应了两个账号 ID
        case tokenOwnerConflict
        /// 待导出的账号缺 userid，导出会少一半身份
        case missingUserID
        case storageBroken
        case poolBroken
        case capacity
        /// 存档在预览之后被别人改过，必须重新预览
        case stale
        case policyRequired
    }

    enum Policy {
        case keepExisting
        case replaceExisting
    }

    // MARK: - 编解码

    static func decode(_ text: String) throws -> [Entry] {
        guard text.utf8.count <= maxBytes, let data = text.data(using: .utf8) else { throw Failure.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw Failure.invalidInput
        }
        // 旧格式是单对象，新格式是数组；其它根类型（数字/字符串/null）一律拒绝。
        let rows: [Any]
        let legacy: Bool
        if let array = root as? [Any] {
            rows = array
            legacy = false
        } else if let object = root as? [String: Any] {
            rows = [object]
            legacy = true
        } else {
            throw Failure.invalidInput
        }
        guard !rows.isEmpty, rows.count <= maxAccounts else { throw Failure.accountCount }
        var out: [Entry] = []
        var owners: [String: String] = [:]
        for value in rows {
            // 字段必须**恰好**两个：多带的备注/设置一概不认，避免把用户 token 塞进备注再被导出。
            guard let row = value as? [String: Any] else { throw Failure.invalidInput }
            let uidKey = legacy ? "userId" : "userid"
            guard row.count == 2,
                  let token = row["token"] as? String,
                  let userid = row[uidKey] as? String else { throw Failure.invalidInput }
            let entry = Entry(token: try checkedToken(token), userid: try checkedUserID(userid))
            if let owner = owners[entry.token], owner != entry.userid { throw Failure.tokenOwnerConflict }
            owners[entry.token] = entry.userid
            // 完全相同的条目只留一份（安卓同口径）；「同 ID 不同 token」保留给预览判冲突。
            if !out.contains(entry) { out.append(entry) }
        }
        return out
    }

    static func encode(_ entries: [Entry]) throws -> String {
        guard !entries.isEmpty, entries.count <= maxAccounts else { throw Failure.accountCount }
        var parts: [String] = []
        parts.reserveCapacity(entries.count)
        for entry in entries {
            let token = try checkedToken(entry.token)
            let userid = try checkedUserID(entry.userid)
            // 手写键序：安卓也是先 token 后 userid，保持字节级可读的稳定形状。
            parts.append("{\"token\":\(quote(token)),\"userid\":\(quote(userid))}")
        }
        let text = "[" + parts.joined(separator: ",") + "]"
        // 自己产出的文本也要过一遍解码：编码器有 bug 时宁可在这里失败，也不给用户一份坏备份。
        _ = try decode(text)
        return text
    }

    static func checkedToken(_ value: String) throws -> String {
        guard value.count <= maxTokenLength, value.utf8.count <= maxTokenLength * 4,
              !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
            throw Failure.invalidInput
        }
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只剥 `Bearer ` 前缀（安卓用 (?i)^bearer\s+）；`BearerX` 这种正文不能误伤。
        if clean.count > 6, clean.lowercased().hasPrefix("bearer") {
            let rest = clean.dropFirst(6)
            if rest.first?.isWhitespace == true {
                clean = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !clean.isEmpty else { throw Failure.invalidInput }
        return clean
    }

    static func checkedUserID(_ value: String, allowEmpty: Bool = false) throws -> String {
        guard value.count <= maxUserIDLength else { throw Failure.invalidInput }
        if !allowEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.invalidInput
        }
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Failure.invalidInput
        }
        return value
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - 账号池

    /// 账号池文档。`object` 保留整份原文（含 mode / legacyClosed 等字段），
    /// 恢复时只改 accounts/active/rev，别的内容原样写回。
    struct Pool {
        let object: [String: Any]
        let accounts: [[String: Any]]
        let active: String
    }

    struct Account: Equatable {
        let id: String
        let userid: String
    }

    /// 存档快照的只读摘要。**不含**普通账号的 token，
    /// 只有当前账号的凭据（activeToken）供界面展示/复制，用完不落盘。
    struct Snapshot {
        enum Status { case ready, empty, storageBroken, poolBroken }
        let status: Status
        let accounts: [Account]
        let activeID: String
        let activeUserID: String
        let activeToken: String
        /// `zeeho.token` 镜像：账号池损坏时仍能展示这最后一份可用凭据。
        let tokenMirror: String
        let poolRaw: String
        let cleared: String
        let revision: Int
        let readError: String?
    }

    static func snapshot(values: [String: String], revision: Int, readError: String?) -> Snapshot {
        let mirror = values[tokenKey] ?? ""
        let cleared = values[clearedKey] ?? ""
        let raw = values[poolKey] ?? ""
        guard readError == nil else {
            return Snapshot(status: .storageBroken, accounts: [], activeID: "", activeUserID: "",
                            activeToken: mirror, tokenMirror: mirror, poolRaw: raw, cleared: cleared,
                            revision: revision, readError: readError)
        }
        guard !raw.isEmpty else {
            return Snapshot(status: .empty, accounts: [], activeID: "", activeUserID: "",
                            activeToken: mirror, tokenMirror: mirror, poolRaw: raw, cleared: cleared,
                            revision: revision, readError: nil)
        }
        guard let pool = try? parsePool(raw) else {
            return Snapshot(status: .poolBroken, accounts: [], activeID: "", activeUserID: "",
                            activeToken: mirror, tokenMirror: mirror, poolRaw: raw, cleared: cleared,
                            revision: revision, readError: nil)
        }
        let accounts = pool.accounts.compactMap { row -> Account? in
            guard let id = row["id"] as? String, let uid = try? rowUserID(row) else { return nil }
            return Account(id: id, userid: uid)
        }
        let activeRow = pool.accounts.first { ($0["id"] as? String ?? "") == pool.active }
        let activeUserID = activeRow.flatMap { try? rowUserID($0) } ?? ""
        let activeToken = activeRow.flatMap { try? checkedToken($0["token"] as? String ?? "") } ?? mirror
        return Snapshot(status: accounts.isEmpty ? .empty : .ready, accounts: accounts,
                        activeID: pool.active, activeUserID: activeUserID, activeToken: activeToken,
                        tokenMirror: mirror, poolRaw: raw, cleared: cleared, revision: revision, readError: nil)
    }

    static func parsePool(_ raw: String) throws -> Pool {
        guard raw.utf8.count <= maxPoolBytes, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.poolBroken
        }
        guard let version = object["v"] as? NSNumber, version.doubleValue == 1,
              let rows = object["accounts"] as? [[String: Any]], rows.count <= maxAccounts,
              let active = object["active"] as? String else { throw Failure.poolBroken }
        var ids: Set<String> = [], tokens: Set<String> = [], uids: Set<String> = []
        for row in rows {
            guard let id = row["id"] as? String, validAccountID(id), ids.insert(id).inserted,
                  let token = row["token"] as? String else { throw Failure.poolBroken }
            // 整份文档的 token 都要能过凭据校验：网页桥就是按同一套规则在用的。
            guard tokens.insert(try checkedToken(token)).inserted else { throw Failure.poolBroken }
            let uid = try rowUserID(row)
            if !uid.isEmpty, !uids.insert(uid).inserted { throw Failure.poolBroken }
        }
        if rows.isEmpty {
            guard active.isEmpty else { throw Failure.poolBroken }
        } else {
            guard ids.contains(active) else { throw Failure.poolBroken }
        }
        return Pool(object: object, accounts: rows, active: active)
    }

    /// 和网页 `normalize` 的 id 规则一致：字母数字下划线连字符，1~80 位。
    static func validAccountID(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0.value == 95 || $0.value == 45
        }
    }

    /// 账号池里的 uid 可能是字符串或数字（安卓两种都收），布尔/其它类型按损坏处理。
    static func rowUserID(_ row: [String: Any]) throws -> String {
        if let text = row["uid"] as? String { return try checkedUserID(text, allowEmpty: true) }
        // JSON 里的 true/false 也是 NSNumber；先按 CFBoolean 排除，否则 `uid: true` 会被读成 "1"。
        if let number = row["uid"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return try checkedUserID(number.stringValue, allowEmpty: true)
        }
        throw Failure.poolBroken
    }

    // MARK: - 导出

    /// 导出文本。当前账号排首（安卓同口径），原始池顺序与 active 都不改。
    static func exportText(_ snapshot: Snapshot) throws -> (text: String, count: Int) {
        switch snapshot.status {
        case .storageBroken: throw Failure.storageBroken
        case .poolBroken: throw Failure.poolBroken
        case .empty: throw Failure.accountCount
        case .ready: break
        }
        let pool = try parsePool(snapshot.poolRaw)
        var entries: [Entry] = []
        entries.reserveCapacity(pool.accounts.count)
        for pass in 0..<2 {
            for row in pool.accounts {
                let isActive = (row["id"] as? String ?? "") == pool.active
                guard isActive == (pass == 0) else { continue }
                let uid = try rowUserID(row)
                // 缺 userid 时宁可整份失败：恢复端只认 userid 配对，导出去也认不回来。
                guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure.missingUserID
                }
                entries.append(Entry(token: try checkedToken(row["token"] as? String ?? ""), userid: uid))
            }
        }
        return (try encode(entries), entries.count)
    }

    // MARK: - 恢复

    struct Preview {
        let entries: [Entry]
        let userids: [String]
        /// 同 ID 但凭据不同，需要用户明说保留还是替换。
        let replacementUserids: [String]
        let added: Int
        let unchanged: Int
        /// 预览时看到的存档版本；提交前必须仍是这个版本。
        let baseRevision: Int
        var requiresPolicy: Bool { !replacementUserids.isEmpty }
    }

    struct Plan {
        let puts: [String: String]
        let removes: [String]
    }

    /// 只算差异，不写盘。容量与「同 token 不同账号」在这里就拒掉整批，绝不部分恢复。
    static func preview(_ entries: [Entry], snapshot: Snapshot) throws -> Preview {
        switch snapshot.status {
        case .storageBroken: throw Failure.storageBroken
        case .poolBroken: throw Failure.poolBroken
        case .ready, .empty: break
        }
        let rows: [[String: Any]]
        // 与 plan() 同口径：`.empty` 也可能是「文档存在但没有账号」，
        // 那种情况下要对着已有的 0 条记录算差异，不能当成「什么都没有」。
        if snapshot.status == .ready || !snapshot.poolRaw.isEmpty {
            rows = try parsePool(snapshot.poolRaw).accounts
        } else {
            rows = []
        }
        var userids: [String] = []
        var conflicts: [String] = []
        var added = 0
        var unchanged = 0
        var seen: [Entry] = []
        for entry in entries {
            if !userids.contains(entry.userid) { userids.append(entry.userid) }
            var oldToken: String?
            for row in rows {
                let token = try checkedToken(row["token"] as? String ?? "")
                let uid = try rowUserID(row)
                if token == entry.token, uid != entry.userid { throw Failure.tokenOwnerConflict }
                if uid == entry.userid { oldToken = token }
            }
            for previous in seen where previous.userid == entry.userid { oldToken = previous.token }
            if oldToken == nil { added += 1 }
            else if oldToken == entry.token { unchanged += 1 }
            else if !conflicts.contains(entry.userid) { conflicts.append(entry.userid) }
            seen.append(entry)
        }
        guard rows.count + added <= maxAccounts else { throw Failure.capacity }
        return Preview(entries: entries, userids: userids, replacementUserids: conflicts,
                       added: added, unchanged: unchanged, baseRevision: snapshot.revision)
    }

    /// 生成要一次提交的键值。`policy` 只在有冲突时必须给；调用方必须同步知道当前存档版本，
    /// 版本变了就是 `.stale`，要重新粘贴、重新预览，绝不自动重放。
    static func plan(_ preview: Preview, policy: Policy?, snapshot: Snapshot,
                     now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                     newAccountID: () -> String = { "a_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }) throws -> Plan {
        guard preview.baseRevision == snapshot.revision else { throw Failure.stale }
        if preview.requiresPolicy, policy == nil { throw Failure.policyRequired }
        switch snapshot.status {
        case .storageBroken: throw Failure.storageBroken
        case .poolBroken: throw Failure.poolBroken
        case .ready, .empty: break
        }
        var document: [String: Any]
        var rows: [[String: Any]]
        // `.empty` 有两种来源：完全没有账号池文档，或文档合法但账号数为 0。
        // 后者必须沿用原文档（legacyClosed / mode / aggregateVin 都在里面），
        // 只有 poolRaw 真的为空时才新建——CI 上正是这里把 legacyClosed 丢了。
        if snapshot.status == .ready || !snapshot.poolRaw.isEmpty {
            let pool = try parsePool(snapshot.poolRaw)
            document = pool.object
            rows = pool.accounts
        } else {
            document = ["v": 1, "active": "", "mode": "separate", "rev": 0, "accounts": [[String: Any]]()]
            rows = []
        }
        var usedIDs = Set(rows.compactMap { $0["id"] as? String })
        for entry in preview.entries {
            var index: Int?
            for (i, row) in rows.enumerated() where (try? rowUserID(row)) == entry.userid { index = i }
            if let index = index {
                var row = rows[index]
                let current = try checkedToken(row["token"] as? String ?? "")
                // 只替换凭据：备注/车辆缓存/账号历史都原样保留，也不猜新凭据是否已有效。
                if current != entry.token, policy == .replaceExisting {
                    row["token"] = entry.token
                    row["uid"] = entry.userid
                    row["credentialRev"] = incremented(row["credentialRev"])
                    rows[index] = row
                }
            } else {
                // 生成一个未被占用的 id。注入的生成器如果一直返回同一个已用 id
                // （单测里就传过固定值），无界 while 会死循环——CI 上实测卡在这个位置。
                // 所以只让注入生成器试有限次，之后退回真随机 UUID，保证一定终止。
                var id = newAccountID()
                var attempts = 0
                while usedIDs.contains(id), attempts < 8 {
                    id = newAccountID()
                    attempts += 1
                }
                while usedIDs.contains(id) { id = "a_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                usedIDs.insert(id)
                rows.append(newAccountRow(entry, id: id, now: now))
            }
        }
        if rows.first != nil, (document["active"] as? String ?? "").isEmpty {
            document["active"] = rows[0]["id"] as? String ?? ""
        }
        document["rev"] = incremented(document["rev"])
        document["accounts"] = rows
        // 提交前整份复校：容量、id、同 token 归属任何一条不过都不写盘。
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { throw Failure.poolBroken }
        let verified = try parsePool(text)
        guard let active = verified.accounts.first(where: { ($0["id"] as? String ?? "") == verified.active }),
              let token = active["token"] as? String else { throw Failure.poolBroken }
        var puts = [poolKey: text, tokenKey: try checkedToken(token)]
        // legacyClosed 的意思是「用户明确删过账号，别再拿旧源自动迁移」；恢复不能把它抹掉，
        // 但也不需要新写：保持原值即可（安卓在文档里带 true 时补写 cleared）。
        //
        // 判据要同时认 Bool 和 NSNumber：JSONSerialization 解析出来的是 NSNumber，
        // 而 `as? Bool` 在部分路径上会失败（CI 实测漏写 cleared）。只有 CFBoolean 才当布尔，
        // 其它 NSNumber 一律不算 true，避免 `"legacyClosed": 1` 被误认成开启。
        if isTrue(document["legacyClosed"]) { puts[clearedKey] = "1" }
        return Plan(puts: puts, removes: [])
    }

    static func newAccountRow(_ entry: Entry, id: String, now: Int64) -> [String: Any] {
        // 字段集合照抄网页 `normalize` + 安卓 apply 新建的那条记录，两端都能直接吃。
        ["id": id, "token": entry.token, "uid": entry.userid, "bindingUid": "", "label": "",
         "vin": "", "vehicles": [[String: Any]](), "credentialRev": 1, "addedAt": now,
         "invalidAt": 0, "invalidMsg": "", "noSign": false]
    }

    static func incremented(_ value: Any?) -> Int {
        let number = (value as? NSNumber)?.intValue ?? 0
        guard number >= 0, number < Int.max else { return 1 }
        return max(1, number + 1)
    }

    /// JSON 布尔判定：只认真布尔，不认 `1` / `"true"` 这类近似值。
    /// JSONSerialization 把 true 解成 NSNumber(CFBoolean)，`as? Bool` 不一定命中。
    static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return (value as? Bool) == true
        }
        return number.boolValue
    }
}
