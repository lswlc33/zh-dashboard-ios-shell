import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

SWIFT = r"""
import Foundation

// 只替换 Runner 的日期入口；任务状态机、请求构造、签名、期限与去重均编译生产源码。
enum IOSBackgroundRunner {
    static func beijingDay(_ date: Date) -> String { IOSBackgroundCalendar.beijingDay(date) }
}

private final class FakeServer: @unchecked Sendable {
    enum Mode { case normal, rejected, unknown, serverError, unconfirmed, partial, missingFlag, duplicate }
    let mode: Mode
    var events: [String] = []
    var done = Set<String>()
    var postContent = ""
    var postedAt = Date()
    var created = false
    var removed = false
    let lock = NSLock()
    let credential: IOSBackgroundCredential

    init(_ mode: Mode, credential: IOSBackgroundCredential) { self.mode = mode; self.credential = credential }

    func reply(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let body = try Self.body(request)
        let param = request.value(forHTTPHeaderField: "cfmoto-x-param") ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query ?? ""
        let signature = IOSBackgroundSigning.md5Hex(IOSBackgroundSigning.sha1Hex(query + body + param + credential.appSecret))
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential.token)")
        precondition(request.value(forHTTPHeaderField: "cfmoto-x-sign") == signature, "signature/body mismatch")
        var payload: Any = true
        var code = "10000"
        if path.hasSuffix("getByUserId") {
            events.append("GET tasks")
            var rows: [[String: Any]] = ["1023", "1026", "1024"].map { action in
                var row: [String: Any] = ["code": action, "name": action]
                if mode != .missingFlag {
                    row["completeFlag"] = done.contains(action) && mode != .unconfirmed ? "0" : NSNull()
                }
                return row
            }
            if mode == .partial { rows.removeFirst() }
            if mode == .duplicate { rows.append(rows[0]) }
            payload = ["ps0003_01_002_VOList": rows]
        } else if path.hasSuffix("mineArticleInfo") {
            events.append("GET mine")
            payload = created && !removed ? [article(id: "new-post", content: postContent, at: postedAt)] : []
        } else if path.hasSuffix("commonArticle") && method == "POST" {
            events.append("POST post")
            let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            precondition(object["topicid"] as? String == "")
            precondition((object["postSubInfo"] as? [String: Any])?["topicList"] is [Any])
            precondition((object["postcontent"] as? String)?.isEmpty == false)
            if mode == .rejected { code = "40000" }
            else if mode == .unknown { throw URLError(.networkConnectionLost) }
            else if mode == .serverError { return (500, Data("unavailable".utf8)) }
            else {
                postContent = object["postcontent"] as! String
                postedAt = Date(); created = true; done.insert("1023")
            }
        } else if path.hasSuffix("deleteArticle") {
            events.append("DELETE own-post")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "articleId" })?.value == "new-post")
            removed = true
        } else if path.hasSuffix("qbTzInfoNewV2") {
            events.append("GET square")
            payload = [article(id: "square-post", content: "offline", at: Date())]
        } else if path.hasSuffix("likeFavoriteInfo") {
            events.append("POST like")
            let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            precondition(object["postId"] as? String == "square-post")
            precondition(object["kindFlag"] as? String == "0")
            done.insert("1026")
        } else if path.contains("/article/share/") {
            events.append("PUT share"); precondition(path.hasSuffix("square-post"))
        } else if path.hasSuffix("adjustByShare") {
            events.append("GET share-credit"); done.insert("1024")
        } else { fatalError("Unexpected offline request: \(method) \(path)") }
        return (200, try JSONSerialization.data(withJSONObject: ["code": code, "data": payload]))
    }

    private func article(id: String, content: String, at: Date) -> [String: Any] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 28800); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return ["tuuid": id, "userid": credential.uid, "tcontent": content, "createDate": formatter.string(from: at)]
    }

    private static func body(_ request: URLRequest) throws -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 1024); var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class OfflineProtocol: URLProtocol {
    static var server: FakeServer!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.server.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct DailyTasksFlowTest {
    static func main() async throws {
        let credential = IOSBackgroundCredential(accountID: "offline-account", vin: "OFFLINEVIN",
            token: "offline-token", signinToken: "offline-token", appSecret: "offline-secret",
            h5Secret: "offline-h5", appID: "offline-app", h5AppID: "offline-h5-app", uid: "12345678901234567", updatedAt: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let expected = ["GET tasks", "GET mine", "POST post", "GET mine", "DELETE own-post", "GET square", "POST like", "GET square", "PUT share", "GET share-credit", "GET tasks"]
        var count = 0
        for mode in [FakeServer.Mode.normal, .rejected, .unknown, .serverError, .unconfirmed, .partial, .missingFlag, .duplicate] {
            let root = directory.appendingPathComponent("case-\(count)")
            let server = FakeServer(mode, credential: credential); OfflineProtocol.server = server
            let client = IOSDailyTasksClient(session: session, attemptDirectory: root)
            let context = try IOSBackgroundRunCoordinator.shared.begin(source: .shortcut, budget: 25)
            let report = await client.run(credential: credential, signInDone: true, context: context)
            IOSBackgroundRunCoordinator.shared.finish(context)
            if mode == .normal {
                precondition(server.events == expected, "full flow order: \(server.events)")
                precondition(report.serverVerifiedAll && report.doneCount == 4 && report.result == "ok")
            } else if mode == .missingFlag {
                precondition(!server.events.contains(where: { $0.hasPrefix("POST") || $0.hasPrefix("PUT") }))
                precondition(!report.serverVerifiedAll)
            } else if mode == .partial || mode == .duplicate {
                precondition(!server.events.contains("POST post"))
                precondition(server.events.contains("POST like") && server.events.contains("PUT share"))
                precondition(!report.serverVerifiedAll)
            } else {
                precondition(server.events.contains("POST post") && server.events.contains("POST like") && server.events.contains("PUT share"))
                precondition(!report.serverVerifiedAll && report.doneCount == (mode == .unconfirmed ? 1 : 3))
                let before = server.events.filter { $0 == "POST post" }.count
                let retry = try IOSBackgroundRunCoordinator.shared.begin(source: .shortcut, budget: 25)
                _ = await client.run(credential: credential, signInDone: true, context: retry)
                IOSBackgroundRunCoordinator.shared.finish(retry)
                let after = server.events.filter { $0 == "POST post" }.count
                precondition(after == before + (mode == .rejected ? 1 : 0), "uncertain POST must not replay")
            }
            print("PASS offline Swift flow \(mode): \(server.events.joined(separator: " -> ")); result=\(report.result) done=\(report.doneCount)/\(report.totalCount)")
            count += 1
        }
        print("daily-tasks-flow-test: \(count) real production Swift/URLProtocol cases passed; no live API")
    }
}

"""

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    compiler = shutil.which('swiftc')
    if compiler is None and sys.platform == 'darwin':
        compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    if compiler is None:
        if args.require_swift:
            raise SystemExit('BLOCKED: real Swift compiler required')
        print('SKIP real Swift URLProtocol flow: no local Swift compiler; CI must run --require-swift')
        return
    root = pathlib.Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix='ios-daily-flow-') as directory:
        directory = pathlib.Path(directory)
        fixture = directory / 'flow-test.swift'
        fixture.write_text(SWIFT, encoding='utf-8')
        output = directory / 'flow-test'
        subprocess.run([compiler, '-swift-version', '5', str(root / 'BackgroundSigning.swift'),
                        str(root / 'DailyTasksLogic.swift'), str(root / 'DailyTasks.swift'),
                        str(fixture), '-o', str(output)], check=True)
        subprocess.run([str(output)], check=True, timeout=60)

if __name__ == '__main__':
    main()
