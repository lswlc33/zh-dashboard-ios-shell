import Foundation

// AccountBackup 的纯逻辑单测：不碰 UIKit / 存档 / 网络，可在 build.sh 里和其它 *-test.swift 一起跑。
// 覆盖三件事：
//   1. 备份文本解码/编码（新旧两种格式、上限、同 token 不同账号）
//   2. 账号池解析（网页写出来的文档形状、损坏判定、uid 字符串与数字两种形态）
//   3. 预览与恢复计划（新增/无变化/冲突、容量、stale、keep 与 replace 的差别）
@main
enum AccountBackupTest {
    static func main() {
        // 顶层兜底：main 不声明 throws，任何漏出的错误都变成一条明确失败，
        // 而不是 Swift 运行时那种只有栈、没有场景的崩溃输出。
        do {
            try run()
        } catch {
            preconditionFailure("account backup test threw unexpectedly: \(error)")
        }
        print("iOS account backup checks passed (pure logic, synthetic credentials only)")
    }

    static func run() throws {
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
        }
        // 只接受 AccountBackup.Failure：别的错误类型（比如写错的调用）也算测试失败。
        func rejects(_ message: String, _ action: () throws -> Any) {
            do {
                _ = try action()
                preconditionFailure("accepted invalid input: \(message)")
            } catch is AccountBackup.Failure {
            } catch {
                preconditionFailure("unexpected error type for \(message): \(error)")
            }
        }

        // ---- 解码：新格式 ----
        let two = try AccountBackup.decode(#"[{"token":"t1","userid":"u1"},{"token":"t2","userid":"u2"}]"#)
        expect(two.count == 2, "两个账号应全部解析")
        expect(two[0] == AccountBackup.Entry(token: "t1", userid: "u1"), "顺序要保持输入顺序")
        // 完全重复的条目只留一份（安卓同口径）
        let dup = try AccountBackup.decode(#"[{"token":"t1","userid":"u1"},{"token":"t1","userid":"u1"}]"#)
        expect(dup.count == 1, "完全相同的条目应去重")
        // 同一 token 换个 userid 是冲突而不是去重
        rejects("同 token 不同账号") {
            try AccountBackup.decode(#"[{"token":"t1","userid":"u1"},{"token":"t1","userid":"u2"}]"#)
        }
        // 同 userid 不同 token 允许进来，留给预览判冲突
        let conflicting = try AccountBackup.decode(#"[{"token":"t1","userid":"u1"},{"token":"t2","userid":"u1"}]"#)
        expect(conflicting.count == 2, "同 ID 不同凭据应保留，由预览阶段判冲突")

        // ---- 解码：旧格式（单个对象 + userId）----
        let legacy = try AccountBackup.decode(#"{"token":"old","userId":"legacy-uid"}"#)
        expect(legacy.count == 1 && legacy[0].userid == "legacy-uid", "旧格式的 userId 键要能读")
        // 旧格式不接受 userid 键：那是新格式的字段，混着写说明前端搞错了
        rejects("旧格式用 userid 键") { try AccountBackup.decode(#"{"token":"old","userid":"x"}"#) }

        // ---- 解码：拒绝的形状 ----
        rejects("空数组") { try AccountBackup.decode("[]") }
        rejects("不是 JSON") { try AccountBackup.decode("token=abc") }
        rejects("多余字段") { try AccountBackup.decode(#"[{"token":"t","userid":"u","note":"x"}]"#) }
        rejects("缺字段") { try AccountBackup.decode(#"[{"token":"t"}]"#) }
        rejects("数字 token") { try AccountBackup.decode(#"[{"token":1,"userid":"u"}]"#) }
        rejects("空 token") { try AccountBackup.decode(#"[{"token":"  ","userid":"u"}]"#) }
        rejects("空 userid") { try AccountBackup.decode(#"[{"token":"t","userid":" "}]"#) }
        rejects("token 带换行") { try AccountBackup.decode("[{\"token\":\"a\\nb\",\"userid\":\"u\"}]") }
        rejects("userid 带控制字符") { try AccountBackup.decode("[{\"token\":\"t\",\"userid\":\"a\\u0001b\"}]") }
        expectsAccountCount()

        // ---- 编码 ----
        let encoded = try AccountBackup.encode([AccountBackup.Entry(token: "a b\"c", userid: "u1")])
        expect(encoded == #"[{"token":"a b\"c","userid":"u1"}]"#, "编码要保持 token 在前、正确转义")
        let roundTrip = try AccountBackup.decode(encoded)
        expect(roundTrip[0].token == "a b\"c", "编码结果必须能被自己解码")
        // Bearer 前缀会被剥掉；只在确有空白的场合
        expect(try AccountBackup.checkedToken("Bearer abc") == "abc", "Bearer 前缀应被剥掉")
        expect(try AccountBackup.checkedToken("bearer  abc ") == "abc", "大小写与前后的空白都要处理")
        expect(try AccountBackup.checkedToken("BearerToken") == "BearerToken", "没有空白的 BearerX 不是前缀")
        rejects("超长 token") { try AccountBackup.checkedToken(String(repeating: "x", count: 9000)) }
        rejects("超长 userid") { try AccountBackup.checkedUserID(String(repeating: "x", count: 200)) }

        // ---- 账号池 ----
        let pool = #"""
        {"v":1,"active":"a_2","mode":"separate","rev":7,"accounts":[
          {"id":"a_1","token":"t1","uid":"u1","label":"","vin":"V1","vehicles":[],"credentialRev":2},
          {"id":"a_2","token":"t2","uid":10023,"label":"","vin":"","vehicles":[],"credentialRev":1}
        ]}
        """#
        let summary = AccountBackup.snapshot(values: [
            AccountBackup.poolKey: pool,
            AccountBackup.tokenKey: "t2"
        ], revision: 12, readError: nil)
        expect(summary.status == .ready, "正常账号池应判 ready")
        expect(summary.accounts.count == 2 && summary.activeID == "a_2", "应读出两个账号与当前账号")
        expect(summary.accounts[0].userid == "u1", "字符串 uid 要原样读")
        expect(summary.accounts[1].userid == "10023", "数字 uid 要转成十进制文本")
        expect(summary.activeToken == "t2" && summary.activeUserID == "10023", "当前账号凭据与 uid 要对上")
        expect(summary.revision == 12, "版本号要原样带出来给条件提交用")

        // 没有池子但有 token 镜像：这是网页还没建池子的干净安装
        let onlyMirror = AccountBackup.snapshot(values: [AccountBackup.tokenKey: "solo"],
                                               revision: 3, readError: nil)
        expect(onlyMirror.status == .empty, "只有 token 镜像时应判 empty")
        expect(onlyMirror.activeToken == "solo", "empty 状态也要能把最后一份凭据展示出来")

        // 读盘失败优先：不能把「存储坏了」说成「没有账号」
        let broken = AccountBackup.snapshot(values: [:], revision: 0, readError: "store_corrupt")
        expect(broken.status == .storageBroken, "readError 必须判 storageBroken")
        rejects("坏存储导出") { try AccountBackup.exportText(broken) }

        // 数据形状坏了
        let brokenPools = [
            #"{"v":2,"active":"","accounts":[]}"#,
            #"{"v":1,"active":"a_9","accounts":[]}"#,
            #"{"v":1,"active":"","accounts":[{"id":"a_1","token":"t","uid":"u"},{"id":"a_1","token":"t2","uid":"u2"}]}"#,
            #"{"v":1,"active":"a_1","accounts":[{"id":"a_1","token":"t","uid":"u1"},{"id":"a_2","token":"t","uid":"u2"}]}"#,
            #"{"v":1,"active":"a_1","accounts":[{"id":"bad id","token":"t","uid":"u1"}]}"#,
            #"{"v":1,"active":"a_1","accounts":[{"id":"a_1","token":"t","uid":true}]}"#,
            "not json"
        ]
        for bad in brokenPools {
            let value = AccountBackup.snapshot(values: [AccountBackup.poolKey: bad], revision: 1, readError: nil)
            expect(value.status == .poolBroken, "损坏的账号池必须判 poolBroken: \(bad)")
        }

        // ---- 导出 ----
        let exported = try AccountBackup.exportText(summary)
        expect(exported.count == 2, "导出应带上全部账号")
        let exportedEntries = try AccountBackup.decode(exported.text)
        expect(exportedEntries[0].userid == "10023", "当前账号要排首位（安卓同口径）")
        expect(exportedEntries[1].userid == "u1", "其余账号保持池内顺序")

        // 缺 userid 的账号拒绝整份导出
        let missingUID = #"{"v":1,"active":"a_1","accounts":[{"id":"a_1","token":"t","uid":""}]}"#
        let missing = AccountBackup.snapshot(values: [AccountBackup.poolKey: missingUID], revision: 2, readError: nil)
        rejects("缺 userid 导出") { try AccountBackup.exportText(missing) }

        // ---- 预览 ----
        // 空池 + 两个新账号
        let empty = AccountBackup.snapshot(values: [:], revision: 5, readError: nil)
        let fresh = try AccountBackup.preview([
            AccountBackup.Entry(token: "n1", userid: "new1"),
            AccountBackup.Entry(token: "n2", userid: "new2")
        ], snapshot: empty)
        expect(fresh.added == 2 && fresh.unchanged == 0 && !fresh.requiresPolicy, "空池应全是新增")
        expect(fresh.baseRevision == 5, "预览要冻结基线版本")

        // 对着已有池：一个新增、一个不变、一个冲突
        let mixed = try AccountBackup.preview([
            AccountBackup.Entry(token: "t1", userid: "u1"),        // 不变
            AccountBackup.Entry(token: "t9", userid: "u9"),        // 新增
            AccountBackup.Entry(token: "t2-new", userid: "10023")   // 冲突（本地是 t2）
        ], snapshot: summary)
        expect(mixed.added == 1 && mixed.unchanged == 1, "新增/无变化的计数要准")
        expect(mixed.requiresPolicy && mixed.replacementUserids == ["10023"], "同 ID 不同 token 必须要求明确选择")

        // 容量上限
        var many: [AccountBackup.Entry] = []
        for i in 0..<20 { many.append(AccountBackup.Entry(token: "tok\(i)", userid: "uid\(i)")) }
        rejects("超过 20 个账号") { try AccountBackup.preview(many, snapshot: summary) }
        // 刚好填满则允许（本地 2 个 + 18 个新增）
        _ = try AccountBackup.preview(Array(many.prefix(18)), snapshot: summary)

        // ---- 恢复计划 ----
        // KEEP：冲突账号保留本地凭据，其它新增照常写入
        let keepPlan = try AccountBackup.plan(mixed, policy: .keepExisting, snapshot: summary,
                                              now: 1_700_000_000_000, newAccountID: { "a_new" })
        let keptPool = try AccountBackup.parsePool(keepPlan.puts[AccountBackup.poolKey] ?? "")
        expect(keptPool.accounts.count == 3, "KEEP 也要把新账号加进去")
        let keptU2 = keptPool.accounts.first { (try? AccountBackup.rowUserID($0)) == "10023" }
        expect(keptU2?["token"] as? String == "t2", "KEEP 必须保留本地旧 token")
        expect(keepPlan.puts[AccountBackup.tokenKey] == "t2", "当前账号没换凭据时镜像保持原值")
        expect(keptPool.object["rev"] as? Int == 8, "文档 rev 要递增")

        // REPLACE：冲突账号换成备份凭据，并抬 credentialRev
        let replacePlan = try AccountBackup.plan(mixed, policy: .replaceExisting, snapshot: summary,
                                                 now: 1_700_000_000_000, newAccountID: { "a_new" })
        let replacedPool = try AccountBackup.parsePool(replacePlan.puts[AccountBackup.poolKey] ?? "")
        let replacedU2 = replacedPool.accounts.first { (try? AccountBackup.rowUserID($0)) == "10023" }
        expect(replacedU2?["token"] as? String == "t2-new", "REPLACE 要写入备份凭据")
        expect(replacedU2?["credentialRev"] as? Int == 2, "换凭据要把 credentialRev 抬一档")
        expect(replacePlan.puts[AccountBackup.tokenKey] == "t2-new", "当前账号换凭据后镜像必须同步")
        // 原有字段不能被抹掉（vin / label / 车辆缓存都是用户的资产）
        let preservedU1 = replacedPool.accounts.first { ($0["id"] as? String) == "a_1" }
        expect(preservedU1?["vin"] as? String == "V1", "未冲突账号的字段必须原样保留")
        expect(preservedU1?["credentialRev"] as? Int == 2, "未换凭据的账号不动 credentialRev")

        // 没有冲突时不传 policy 也能过；有冲突时必须是明确选择
        rejects("有冲突但没给策略") { try AccountBackup.plan(mixed, policy: nil, snapshot: summary) }

        // stale：预览之后存档版本变了
        let movedOn = AccountBackup.snapshot(values: [
            AccountBackup.poolKey: pool, AccountBackup.tokenKey: "t2"
        ], revision: 13, readError: nil)
        rejects("版本变了仍提交") { try AccountBackup.plan(mixed, policy: .keepExisting, snapshot: movedOn) }

        // 空池恢复：active 指向第一个新账号，legacyClosed 保持不写
        let emptyPlan = try AccountBackup.plan(fresh, policy: nil, snapshot: empty,
                                               now: 1_700_000_000_000, newAccountID: { "a_first" })
        let emptyPool = try AccountBackup.parsePool(emptyPlan.puts[AccountBackup.poolKey] ?? "")
        expect(emptyPool.active == "a_first", "空池恢复后 current 应指向第一个账号")
        expect(emptyPlan.puts[AccountBackup.clearedKey] == nil, "legacyClosed 为假时不能凭空写 cleared")
        expect(emptyPlan.puts[AccountBackup.tokenKey] == "n1", "空池恢复后镜像应指向 current")

        // 文档里的 legacyClosed=true（用户明确删过账号）要在恢复后保持
        let closedRaw = #"{"v":1,"active":"","mode":"separate","rev":3,"legacyClosed":true,"accounts":[]}"#
        let closed = AccountBackup.snapshot(values: [AccountBackup.poolKey: closedRaw], revision: 4, readError: nil)
        let closedPreview = try AccountBackup.preview([AccountBackup.Entry(token: "n", userid: "nu")], snapshot: closed)
        let closedPlan = try AccountBackup.plan(closedPreview, policy: nil, snapshot: closed,
                                                now: 1, newAccountID: { "a_c" })
        expect(closedPlan.puts[AccountBackup.clearedKey] == "1", "legacyClosed 的文档要保留 cleared 标记")
        let closedPool = try AccountBackup.parsePool(closedPlan.puts[AccountBackup.poolKey] ?? "")
        expect(closedPool.object["legacyClosed"] as? Bool == true, "legacyClosed 字段本身不能丢")

        // 上限：恢复后超过 20 个直接拒
        var nineteen: [AccountBackup.Entry] = []
        for i in 0..<18 { nineteen.append(AccountBackup.Entry(token: "ntok\(i)", userid: "nuid\(i)")) }
        let fullPool = makePool(accounts: (0..<3).map { ("a\($0)", "p\($0)", "pu\($0)") }, active: "a0", rev: 1)
        let full = AccountBackup.snapshot(values: [AccountBackup.poolKey: fullPool], revision: 2, readError: nil)
        rejects("恢复后超过上限") { try AccountBackup.preview(nineteen, snapshot: full) }
    }

    /// 拼一份合法的账号池 JSON，省得每处都手写。
    static func makePool(accounts: [(String, String, String)], active: String, rev: Int) -> String {
        let rows = accounts.map { id, token, uid in
            "{\"id\":\"\(id)\",\"token\":\"\(token)\",\"uid\":\"\(uid)\",\"label\":\"\",\"vin\":\"\",\"vehicles\":[],\"credentialRev\":1}"
        }
        return "{\"v\":1,\"active\":\"\(active)\",\"mode\":\"separate\",\"rev\":\(rev),\"accounts\":[\(rows.joined(separator: ","))]}"
    }

    /// 上限用单独一段，避免主流程被一屏的循环撑长。
    static func expectsAccountCount() {
        // 只接受 AccountBackup.Failure：别的错误类型（比如写错的调用）也算测试失败。
        func rejects(_ message: String, _ action: () throws -> Any) {
            do {
                _ = try action()
                preconditionFailure("accepted invalid input: \(message)")
            } catch is AccountBackup.Failure {
            } catch {
                preconditionFailure("unexpected error type for \(message): \(error)")
            }
        }
        var rows: [String] = []
        for i in 0..<21 { rows.append("{\"token\":\"t\(i)\",\"userid\":\"u\(i)\"}") }
        rejects("21 个账号") { try AccountBackup.decode("[" + rows.joined(separator: ",") + "]") }
        // 超过 1 MiB 的文本
        rejects("超过 1 MiB") { try AccountBackup.decode(String(repeating: "a", count: 1024 * 1024 + 1)) }
    }
}
