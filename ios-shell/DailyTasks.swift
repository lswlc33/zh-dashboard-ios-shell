import Foundation
import CoreFoundation

// 每日任务的社交侧执行体：任务列表、发帖、点赞、分享、删帖。
//
// ## 为什么单独一个文件
//
// BackgroundSigning.swift 只负责「签名 + 两个最基础的 GET/POST」，签到与车况采样属于
// 「一天一次、失败也无所谓」的那一类。每日任务是另一回事：它有 4 个可执行项、有顺序依赖
// （发帖要先读基线、分享要读广场）、有写操作（发帖/点赞/分享/删帖），还有「做没做成」
// 要靠服务端 completeFlag 复核。混进 BackgroundSigning 会让那个文件的职责变模糊。
//
// ## 与网页 tasks.js 的关系
//
// 算法与判据**逐条对齐** public/js/tasks.js（2026-11-15 对照），但刻意不复用它的代码：
// 后台没有 WebView、没有 Store 垫片、没有账号池，而且这里有 30 秒硬预算（见下）。
// 任何一处判据改动都要两边一起改，否则会出现「网页说我做完了、快捷指令说没做完」。
//
// ## 30 秒预算（真实约束，不是保守估计）
//
// Apple 文档（LongRunningIntent / IntentCancellationReason.timeout）与 WWDC26 逐字稿都写明：
// 「When your intent runs — from Siri, Shortcuts, or any system surface — it only has 30 seconds
// to finish.」**用户手动点快捷指令也一样**，不是只有系统调度的 BGAppRefreshTask 才受限
// （绕过它的 LongRunningIntent 是 iOS 27 起才有）。
//
// 所以这里的设计是「尽力在预算内做完 + 到点如实报进度」：
//   · 步骤间隔默认 0（网页默认 2s，那是给人看的节奏，后台不需要）；
//   · 每个请求自己 12s 超时、整轮有 deadline，到点就停下并把已完成项照实报出去；
//   · 发帖是唯一不可重放的写操作，先记 attempt 再发，超时后不猜删。
// 绝不做的事：为了「凑满 4/4」而重试写操作——多一条动态比少一个勾更糟。

/// 每日任务里可自动完成的四项。签到不在这个枚举里（它走 h5 域，由
/// IOSBackgroundRunner.runSignIn 负责），但进度统计要把签到算作其中一项。
enum IOSDailyTaskKind: String, CaseIterable {
    case post = "1023"   // 每日首次发帖
    case like = "1026"   // 点赞内容
    case share = "1024"  // 分享内容

    /// 与 tasks.js 的 ACTION 表同一个映射。不在这张表里的服务端任务都是被动项
    /// （车主生日/优质图文/个人信息完善/首次绑定车辆/注册/推荐注册），没有可调用的
    /// 完成接口，一律不做假完成。
    static func from(code: String) -> IOSDailyTaskKind? {
        switch code {
        case "1023": return .post
        case "1026": return .like
        case "1024": return .share
        default: return nil
        }
    }
}

/// 一个失败项。**必须是具名结构体而不是元组**：元组（含 label 的元组）不满足
/// `Equatable`，会让整个 `IOSDailyTasksReport` 的合成实现编译失败
/// （CI 实测 "stored property type '[(name: String, reason: String)]' does not conform"）。
struct IOSDailyTaskFailure: Equatable, Sendable {
    let name: String
    let reason: String
}

/// 一次每日任务运行的结果。字段都是「可直接拼进回执」的最终值，界面不做二次推断。
struct IOSDailyTasksReport: Equatable, Sendable {
    /// 本次实际尝试并成功的项。
    var completed: [String] = []
    /// 本次尝试但失败的项（带原因码）。
    var failed: [IOSDailyTaskFailure] = []
    /// 本次跳过的项（已完成过 / 缺 uid / 超时预算用尽）。
    var skipped: [String] = []
    /// 服务端**复核**后仍判为已完成的可执行项数（不含签到）。
    var confirmedServer: Int = 0
    /// 可执行项总数（服务端列表里命中 ACTION 表的项，通常 3）。
    var totalActions: Int = IOSDailyTaskKind.allCases.count
    /// 只有最后一次完整服务端复核确认三项都完成，才允许发完成通知。
    var serverVerifiedAll: Bool = false
    /// 签到是否完成（由调用方传入，签名里没有签到逻辑）。
    var signInDone: Bool = false
    /// 顶层结论码：ok / partial / budget_exhausted / no_credential / http_401 / ...
    var result: String = "ok"
    /// 是否因为 30 秒预算用尽而提前收尾（不是失败，但要如实告诉用户）。
    var budgetExhausted: Bool = false

    /// "N/M" 里的 N：签到 + 服务端确认完成的可执行项。
    ///
    /// 与安卓 AutoTaskRunner 的 `done = doneActions.size() + (signinDone ? 1 : 0)` 同口径，
    /// 所以上限正好是 4（签到 + 发帖 + 点赞 + 分享）。
    var doneCount: Int { confirmedServer + (signInDone ? 1 : 0) }
    /// "N/M" 里的 M：签到 1 项 + 服务端列表里的可执行项（被动项不算）。
    var totalCount: Int { 1 + totalActions }
}

/// 「我的动态」/「广场」里的一行。只保留定位新帖真正需要的三个字段。
private struct IOSSocialArticle {
    let id: String
    let at: Double        // 解析成时间戳（毫秒），解析不了就是 NaN
    let userID: String
    let content: String
}

/// 发送前落不可重放动作的账本。文件只存匿名 owner、北京时间日和动作，不含 token/VIN/正文。
/// 原子写后回读确认；存储缺失/损坏/写失败时禁止发帖，不能假装成功再发送。
private enum IOSDailyPostAttemptStore {
    private struct Attempt: Codable, Equatable {
        let ownerHash: String
        let day: String
        let action: String
    }

    private static func file(ownerHash: String, day: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BackgroundPostAttempts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(ownerHash)-\(day)-\(IOSDailyTaskKind.post.rawValue).json")
    }

    /// false 表示本日已尝试：结果未知也只复核，绝不重发。
    static func reserve(ownerHash: String, day: String) throws -> Bool {
        do {
            let url = try file(ownerHash: ownerHash, day: day)
            let expected = Attempt(ownerHash: ownerHash, day: day, action: IOSDailyTaskKind.post.rawValue)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 1024, try JSONDecoder().decode(Attempt.self, from: data) == expected else {
                    throw IOSDailyTasksError("attempt_persist_failed")
                }
                return false
            }
            let data = try JSONEncoder().encode(expected)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard try Data(contentsOf: url) == data else { throw IOSDailyTasksError("attempt_persist_failed") }
            return true
        } catch { throw IOSDailyTasksError("attempt_persist_failed") }
    }
}

actor IOSDailyTasksClient {
    static let shared = IOSDailyTasksClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // 整轮只有 25 秒：单个请求不能拿固定 12 秒，否则deadline末尾才发起的请求仍会越过总预算。
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    // MARK: - 对外入口

    /// 所有入口先在 Runner 领取同一个全局运行槽位；每次 await 前后检查不可变 context。
    func run(credential: IOSBackgroundCredential, signInDone: Bool,
             context: IOSBackgroundRunContext) async -> IOSDailyTasksReport {
        var report = IOSDailyTasksReport(); report.signInDone = signInDone
        guard credential.canRunDailyTasks else { report.result = "credential_partial"; return report }
        let initial: [[String: Any]]
        do {
            try context.check()
            initial = try await taskList(credential: credential, context: context)
        } catch { report.result = Self.code(of: error); return report }
        report.confirmedServer = initial.filter { Self.isComplete($0) }.count
        // 固定顺序：发帖→点赞→分享；列表已校验每个动作恰好一项。
        for kind in IOSDailyTaskKind.allCases {
            guard let item = initial.first(where: { Self.text($0["code"]) == kind.rawValue }),
                  !Self.isComplete(item) else { continue }
            let name = Self.text(item["name"]) ?? kind.rawValue
            do {
                try context.check()
                switch kind {
                case .post: try await ensurePost(credential: credential, context: context)
                case .like: try await ensureLike(credential: credential, context: context)
                case .share: try await ensureShare(credential: credential, context: context)
                }
                try context.check()
                report.completed.append(name)
            } catch {
                let reason = Self.code(of: error)
                if reason == "cancelled" { report.result = reason; return report }
                if reason == "budget_exhausted" || context.remaining <= 0 {
                    report.skipped.append(name); report.budgetExhausted = true
                    report.result = "budget_exhausted"; return report
                }
                report.failed.append(IOSDailyTaskFailure(name: name, reason: reason))
            }
        }
        // 初读已完成也必须再复核，缺键/空列表/重复动作都不能变成 0/4 完成。
        do {
            let final = try await taskList(credential: credential, context: context)
            try context.check()
            report.confirmedServer = final.filter { Self.isComplete($0) }.count
            report.serverVerifiedAll = report.confirmedServer == IOSDailyTaskKind.allCases.count
            if report.serverVerifiedAll {
                // 丢回包的发帖可被服务端最终状态纠正，不按本地回包猜完成。
                report.failed = []; report.result = "ok"
            } else { report.result = "verification_failed" }
        } catch {
            let reason = Self.code(of: error)
            report.result = ["cancelled", "budget_exhausted"].contains(reason) ? reason : "verification_failed"
            report.budgetExhausted = reason == "budget_exhausted"
            report.failed.append(IOSDailyTaskFailure(name: "服务端复核", reason: reason))
        }
        return report
    }

    // MARK: - 三项动作

    /// 每日首次发帖。发布响应**不带文章 id**，只能靠「发帖前 id 基线 + 作者 + 正文 + 时间窗」
    /// 回头定位（tasks.js:851-879 的同一套证据规则）。定位不到就不删——宁可留一条动态，
    /// 也不能凭猜测删别人的帖子。
    private func ensurePost(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws {
        try context.check()
        // 账本按开始时的北京时间日固定；跨午夜不把旧任务写成新一天的尝试。
        guard IOSBackgroundRunner.beijingDay(Date()) == context.day else { throw IOSDailyTasksError("day_changed") }
        let before = try await mineArticles(credential: credential, context: context)
        guard before.allSatisfy({ !$0.id.isEmpty }) else { throw IOSDailyTasksError("article_id_missing") }
        let baseline = Set(before.map { $0.id })
        let content = Self.defaultPostContent()
        let startedAt = Date().timeIntervalSince1970 * 1000
        try context.check()
        guard try IOSDailyPostAttemptStore.reserve(ownerHash: credential.ownerHash, day: context.day) else {
            // 前次可能已被服务端接收，只允许本轮末尾复核任务列表，不能补发或猜删。
            throw IOSDailyTasksError("post_attempt_unknown")
        }
        try context.check()
        let payload: [String: Any] = ["postSubInfo": ["topicList": [Any]()], "topicid": "", "postcontent": content]
        _ = try await post(credential: credential, path: "/v1.0/social/cfmotoserversocial/commonArticle", body: payload, context: context)
        let endedAt = Date().timeIntervalSince1970 * 1000
        var created: String?
        for attempt in 0..<2 {
            if attempt > 0 { try await sleep(0.6, context: context) }
            try context.check()
            guard let rows = try? await mineArticles(credential: credential, context: context) else { continue }
            try context.check()
            let matched = rows.filter { row in
                guard !baseline.contains(row.id), row.userID == credential.uid,
                      row.content == content, row.at.isFinite else { return false }
                return row.at >= startedAt - 2000 && row.at <= endedAt + 2000
            }
            if matched.count == 1 { created = matched[0].id; break }
            if matched.count > 1 { break }
        }
        if let id = created {
            try context.check()
            _ = try? await send(credential: credential, method: "DELETE",
                path: "/v1.0/social/cfmotoserversocial/commonArticle/deleteArticle",
                query: [("articleId", id), ("postType", "1")], body: nil, context: context)
        }
    }

    /// 点赞：每次重新读广场取最新帖，不缓存、不与分享共用目标（tasks.js:823-837 同款）。
    private func ensureLike(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws {
        let id = try await latestSquarePost(credential: credential, context: context)
        try await sendJSON(credential: credential, method: "POST",
                           path: "/v1.0/social/cfmotoserversocial/socialCommu/likeFavoriteInfo",
                           body: ["postId": id, "kindFlag": "0"], context: context)
    }

    /// 分享：分享成功后必须再补一次 adjustByShare 领积分，否则任务状态不变。
    private func ensureShare(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws {
        let id = try await latestSquarePost(credential: credential, context: context)
        try await sendJSON(credential: credential, method: "PUT",
                           path: "/v1.0/social/cfmotoserversocial/article/share/\(id)", body: nil, context: context)
        try await sendJSON(credential: credential, method: "GET",
                           path: "/v1.0/mine/cfmotoservermine/integral/adjustByShare", body: nil, context: context)
    }

    /// 广场最新一帖的 id。任何一行缺可靠 id 或发布时间就直接报错——
    /// 猜一个 id 去点赞等于替用户乱操作。
    private func latestSquarePost(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws -> String {
        let data = try await request(credential: credential, method: "GET",
                                     path: "/v1.0/social/cfmotoserversocial/community/qbTzInfoNewV2",
                                     query: [("postModule", "1"), ("slidingType", "0"), ("page", "1"), ("pageSize", "20")],
                                     body: nil, context: context)
        let rows = try Self.rows(from: data, key: nil)
        var latest: IOSSocialArticle?
        for row in rows {
            guard !row.id.isEmpty, row.at.isFinite else { throw IOSDailyTasksError("square_article_unusable") }
            if latest == nil || row.at > (latest?.at ?? 0) { latest = row }
        }
        guard let id = latest?.id else { throw IOSDailyTasksError("square_empty") }
        return id
    }

    // MARK: - 读列表

    private func taskList(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws -> [[String: Any]] {
        let data = try await request(credential: credential, method: "GET",
                                     path: "/v1.0/mine/cfmotoservermine/integral/getByUserId",
                                     query: [("userId", credential.uid)], body: nil, context: context)
        guard let object = data as? [String: Any],
              let rows = object["ps0003_01_002_VOList"] as? [[String: Any]], !rows.isEmpty else {
            throw IOSDailyTasksError("task_list_unusable")
        }
        let actionable = rows.filter { IOSDailyTaskKind.from(code: Self.text($0["code"]) ?? "") != nil }
        let codes = actionable.compactMap { Self.text($0["code"]) }
        guard actionable.count == IOSDailyTaskKind.allCases.count,
              Set(codes) == Set(IOSDailyTaskKind.allCases.map { $0.rawValue }),
              actionable.allSatisfy({ ["0", "1"].contains(Self.text($0["completeFlag"]) ?? "") }) else {
            throw IOSDailyTasksError("task_list_unusable")
        }
        return actionable
    }

    private func mineArticles(credential: IOSBackgroundCredential, context: IOSBackgroundRunContext) async throws -> [IOSSocialArticle] {
        let data = try await request(credential: credential, method: "GET",
                                     path: "/v1.0/social/cfmotoserversocial/community/mineArticleInfo",
                                     query: [("userId", credential.uid)], body: nil, context: context)
        return try Self.rows(from: data, key: nil)
    }

    // MARK: - HTTP

    private func post(credential: IOSBackgroundCredential, path: String, body: [String: Any],
                      context: IOSBackgroundRunContext) async throws -> Any? {
        try await request(credential: credential, method: "POST", path: path, query: [], body: body, context: context)
    }

    private func sendJSON(credential: IOSBackgroundCredential, method: String, path: String,
                          body: [String: Any]?, context: IOSBackgroundRunContext) async throws {
        _ = try await request(credential: credential, method: method, path: path, query: [], body: body, context: context)
    }

    private func send(credential: IOSBackgroundCredential, method: String, path: String,
                      query: [(String, String)], body: [String: Any]?, context: IOSBackgroundRunContext) async throws -> Any? {
        try await request(credential: credential, method: method, path: path, query: query, body: body, context: context)
    }

    /// 发一个 app 域请求并返回 `data` 字段。
    ///
    /// 签名规则与 sign.js 完全一致：`md5(sha1(query + body + "appId=..&nonce=..&timestamp=.." + SECRET))`。
    /// 注意 body 是**参与签名的原始 JSON 串**，所以必须先序列化再签，不能签完再补字段。
    private func request(credential: IOSBackgroundCredential, method: String, path: String,
                         query: [(String, String)], body: [String: Any]?, context: IOSBackgroundRunContext) async throws -> Any? {
        try context.check()
        guard IOSBackgroundRunner.beijingDay(Date()) == context.day else { throw IOSDailyTasksError("day_changed") }
        let bodyText: String
        if let body = body {
            // 键序不稳定会让同一次请求签不出同一个串，先排序再序列化。
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            bodyText = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            bodyText = ""
        }
        let queryText = query.filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let param = IOSBackgroundSigning.param(appID: credential.appID,
                                               nonce: IOSBackgroundSigning.nonce(), timestamp: timestamp)
        // GET 的 query 参与签名，其它方法把 body 拼在 query 后面（sign.js:119 的同一行逻辑）。
        let signed = (queryText + bodyText) + param + credential.appSecret
        let sign = IOSBackgroundSigning.md5Hex(IOSBackgroundSigning.sha1Hex(signed))
        var url = IOSBackgroundSigning.apiBase + path
        if !queryText.isEmpty { url += "?" + queryText }
        guard let target = URL(string: url) else { throw IOSDailyTasksError("bad_request") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        try context.check()
        request.timeoutInterval = min(12, context.remaining)
        if body != nil { request.httpBody = Data(bodyText.utf8) }
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("2", forHTTPHeaderField: "interfaceversion")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(param, forHTTPHeaderField: "cfmoto-x-param")
        request.setValue(sign, forHTTPHeaderField: "cfmoto-x-sign")
        request.setValue("0", forHTTPHeaderField: "cfmoto-x-sign-type")

        let data: Data
        let http: HTTPURLResponse
        do {
            let prepared = request
            let session = self.session
            let (payload, response) = try await iosBackgroundWithinDeadline(context) {
                try context.check()
                let value = try await session.data(for: prepared)
                try context.check()
                return value
            }
            try context.check()
            guard let value = response as? HTTPURLResponse else { throw IOSDailyTasksError("decode") }
            data = payload; http = value
        } catch {
            // 父取消、credential epoch 与绝对 deadline 不能被压成 network 后继续写。
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw IOSBackgroundError.cancelled
            }
            if error is IOSBackgroundError || error is IOSDailyTasksError { throw error }
            throw IOSDailyTasksError("network")
        }
        try context.check()
        switch http.statusCode {
        case 200...299: break
        case 401: throw IOSDailyTasksError("http_401")
        case 429: throw IOSDailyTasksError("http_429")
        default: throw IOSDailyTasksError("http_\(http.statusCode)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw IOSDailyTasksError("decode")
        }
        guard Self.text(object["code"]) == "10000" else {
            throw IOSDailyTasksError("rejected:" + (Self.text(object["code"]) ?? "unknown"))
        }
        return object["data"]
    }

    // MARK: - 小工具

    private func sleep(_ seconds: Double, context: IOSBackgroundRunContext) async throws {
        try context.check()
        guard context.remaining > seconds else { throw IOSBackgroundError.budgetExhausted }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try context.check()
    }

    /// `completeFlag == 0` 才算已完成（tasks.js:1319 的口径）。
    private static func isComplete(_ row: [String: Any]) -> Bool {
        text(row["completeFlag"]) == "0"
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    /// 把响应里的文章数组解出来。服务端两种形状都出现过：直接数组，或包一层对象。
    private static func rows(from data: Any?, key: String?) throws -> [IOSSocialArticle] {
        let array: [[String: Any]]
        if let list = data as? [[String: Any]] {
            array = list
        } else if let object = data as? [String: Any] {
            let candidate = key.flatMap { object[$0] } ?? object["list"] ?? object["records"]
            guard let list = candidate as? [[String: Any]] else { throw IOSDailyTasksError("decode") }
            array = list
        } else {
            throw IOSDailyTasksError("decode")
        }
        return array.map { row in
            // id 三个候选字段必须互相一致；不一致说明缺少唯一证据，交给调用方判失败。
            var ids = Set<String>()
            for field in ["tuuid", "articleId", "id"] {
                if let raw = text(row[field]), !raw.isEmpty, !Self.isPlaceholderID(raw) {
                    ids.insert(raw)
                }
            }
            let id = ids.count == 1 ? (ids.first ?? "") : ""
            return IOSSocialArticle(id: id, at: articleTime(row["createDate"]),
                                    userID: text(row["userid"]) ?? "", content: text(row["tcontent"]) ?? "")
        }
    }

    /// 占位值不能当 id：`0`/`true`/`null` 这类串在服务端脏数据里出现过，
    /// 拿它去点赞/删帖等于对不存在的对象发写请求。
    private static func isPlaceholderID(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["true", "false", "null", "undefined"].contains(lowered)
            || lowered.allSatisfy { $0 == "0" }
    }

    /// 服务端日期无时区、带微秒；显式按北京时间解析（与 tasks.js:840-853 同一规则），
    /// 避免手机时区把匹配窗口算歪。
    private static func articleTime(_ value: Any?) -> Double {
        guard let text = value as? String else { return .nan }
        let pattern = #"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let dateRange = Range(match.range(at: 1), in: text),
              let timeRange = Range(match.range(at: 2), in: text) else { return .nan }
        var frac = "000"
        if match.range(at: 3).location != NSNotFound, let range = Range(match.range(at: 3), in: text) {
            frac = String(text[range].padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let normalized = "\(text[dateRange]) \(text[timeRange]).\(frac)"
        return formatter.date(from: normalized).map { $0.timeIntervalSince1970 * 1000 } ?? .nan
    }

    /// 默认发帖文案：与安卓 AutoTaskRunner 一致，按日期生成「11月15号打卡！」。
    /// 用户没配置也能跑，不需要额外的设置项。
    static func defaultPostContent(_ now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        let parts = calendar.dateComponents([.month, .day], from: now)
        return "\(parts.month ?? 1)月\(parts.day ?? 1)号打卡！"
    }

    nonisolated static func code(of error: Error) -> String {
        if let error = error as? IOSBackgroundError { return error.code }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "cancelled" }
        return (error as? IOSDailyTasksError)?.code ?? "failed"
    }
}

/// 每日任务的稳定失败码。每个码都能直接进回执/日志，界面不做二次翻译。
struct IOSDailyTasksError: Error, Equatable {
    let code: String
    init(_ code: String) { self.code = code }
}
