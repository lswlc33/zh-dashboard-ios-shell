import Foundation
import CryptoKit

struct IOSRelease: Decodable {
    static let bundleID = "io.github.lswlc33.dashboard.ios"
    static let maximumSize = 30 * 1024 * 1024
    static let maximumBuild = 9_007_199_254_740_991
    let version: String
    let build: String
    let bundleIdentifier: String
    let minimumIOS: String
    let architecture: String
    let installer: String
    let file: String
    let size: Int
    let sha256: String
    let notes: String

    init(version: String, build: String, bundleIdentifier: String, minimumIOS: String,
         architecture: String, installer: String, file: String, size: Int, sha256: String,
         notes: String = IOSStrings.updateDefaultNotes) {
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.minimumIOS = minimumIOS
        self.architecture = architecture
        self.installer = installer
        self.file = file
        self.size = size
        self.sha256 = sha256
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case version, build, bundleIdentifier, minimumIOS, architecture, installer, file, size, sha256, notes
        case versionName, versionCode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        build = try values.decode(String.self, forKey: .build)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        minimumIOS = try values.decode(String.self, forKey: .minimumIOS)
        architecture = try values.decode(String.self, forKey: .architecture)
        installer = try values.decode(String.self, forKey: .installer)
        file = try values.decode(String.self, forKey: .file)
        size = try values.decode(Int.self, forKey: .size)
        sha256 = try values.decode(String.self, forKey: .sha256)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? IOSStrings.updateDefaultNotes
        if values.contains(.versionName) {
            guard try values.decode(String.self, forKey: .versionName) == version else {
                throw UpdateError.invalidRelease
            }
        }
        if values.contains(.versionCode) {
            let code: String
            if let text = try? values.decode(String.self, forKey: .versionCode) {
                code = text
            } else {
                code = String(try values.decode(Int.self, forKey: .versionCode))
            }
            guard code == build else { throw UpdateError.invalidRelease }
            _ = try Self.safeBuild(code)
        }
    }

    private struct Source: Decodable { let apps: [SourceApp] }
    private struct SourceApp: Decodable {
        let name: String
        let bundleIdentifier: String
        let developerName: String
        let localizedDescription: String
        let iconURL: String
        let versions: [SourceVersion]
    }
    private struct SourceVersion: Decodable {
        let version: String
        let buildVersion: String
        let date: String
        let localizedDescription: String?
        let downloadURL: String
        let size: Int
        let minOSVersion: String
    }

    // 单 App、单最新版的 AltStore Classic 源；地址仍限于认可产物，不接受任意下载 URL。
    static func fromSource(_ bytes: Data) throws -> IOSRelease {
        guard bytes.count <= IOSUpdater.maximumMetadataSize else { throw UpdateError.tooLarge }
        let source = try JSONDecoder().decode(Source.self, from: bytes)
        guard source.apps.count == 1, let app = source.apps.first, app.versions.count == 1,
              let release = app.versions.first, app.bundleIdentifier == bundleID,
              !app.name.isEmpty, !app.developerName.isEmpty, !app.localizedDescription.isEmpty,
              app.iconURL == "https://zhb.xn--fiqz59cpva341l.top/app/icon-ios-1024.png",
              let url = URLComponents(string: release.downloadURL),
              let items = url.queryItems, items.count == 1, items[0].name == "sha256",
              let hash = items[0].value, validHash(hash),
              release.downloadURL == "https://zhb.xn--fiqz59cpva341l.top/app/zeehowebnext.ipa?sha256=" + hash,
              ISO8601DateFormatter().date(from: release.date) != nil else { throw UpdateError.invalidRelease }
        let value = IOSRelease(version: release.version, build: release.buildVersion,
            bundleIdentifier: app.bundleIdentifier, minimumIOS: release.minOSVersion,
            architecture: "arm64", installer: "TrollStore", file: "zeehowebnext.ipa",
            size: release.size, sha256: hash,
            notes: release.localizedDescription ?? IOSStrings.updateDefaultNotes)
        try value.validate()
        return value
    }

    static func safeBuild(_ text: String) throws -> Int {
        guard let first = text.utf8.first, (49...57).contains(first), text.utf8.count <= 16,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), (1...maximumBuild).contains(number) else {
            throw UpdateError.invalidRelease
        }
        return number
    }

    static func versionParts(_ text: String) throws -> [Int] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ Int($0).map { (0...9999).contains($0) } == true }) else {
            throw UpdateError.invalidRelease
        }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }

    func validate() throws {
        _ = try Self.versionParts(version)
        _ = try Self.versionParts(minimumIOS)
        _ = try Self.safeBuild(build)
        // installer 只是清单里的随附说明字段，App 内既不展示也不安装：
        // 不要求它等于某个具体安装器名字，只要是有界的 ASCII 文本即可。
        let installText = installer.utf8
        guard bundleIdentifier == Self.bundleID, architecture == "arm64",
              !installText.isEmpty, installText.count <= 32, installText.allSatisfy({ (32...126).contains($0) }),
              file == "zeehowebnext.ipa", (1...Self.maximumSize).contains(size),
              Self.validHash(sha256) else { throw UpdateError.invalidRelease }
    }

    static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }

    func requireSupportedSystem() throws {
        let parts = try Self.versionParts(minimumIOS)
        let required = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts[2])
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else { throw UpdateError.systemTooOld }
    }

    func isNewer(version installed: String, build installedBuild: String) throws -> Bool {
        try validate()
        let remote = try Self.versionParts(version), local = try Self.versionParts(installed)
        let remoteBuild = try Self.safeBuild(build), localBuild = try Self.safeBuild(installedBuild)
        return remote == local ? remoteBuild > localBuild : local.lexicographicallyPrecedes(remote)
    }

    func verify(_ bytes: Data) throws {
        try validate()
        guard bytes.count == size else { throw UpdateError.checksum }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw UpdateError.checksum }
    }
}

struct IOSUpdateSource: Equatable {
    let id: String
    let name: String
    let baseURL: URL
    let description: String?

    init(id: String, name: String, baseURL: URL, description: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.description = description
    }

    func url(for relative: String, token: String? = nil) throws -> URL {
        guard IOSUpdateSources.recognizes(self), IOSUpdateSources.paths.contains(relative),
              token.map({ IOSRelease.validHash($0) }) ?? true,
              var components = URLComponents(string: baseURL.absoluteString + relative) else {
            throw UpdateError.invalidRelease
        }
        if let token = token { components.queryItems = [URLQueryItem(name: "sha256", value: token)] }
        guard let url = components.url else { throw UpdateError.invalidRelease }
        return url
    }
}

enum IOSUpdateSources {
    static let manifestPath = "app/version2.json"
    static let ipaPath = "app/zeehowebnext.ipa"
    static let panelPath = "version.json"
    static let paths = [manifestPath, ipaPath, panelPath]
    private static let official: [IOSUpdateSource] = [
        IOSUpdateSource(id: "origin", name: "GitHub", baseURL: URL(string: "https://lswlc33.github.io/zeeho-3d-models/")!),
        IOSUpdateSource(id: "ghfast", name: "ghfast", baseURL: URL(string: "https://ghfast.top/https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/")!),
        IOSUpdateSource(id: "ghproxy", name: "ghproxy", baseURL: URL(string: "https://gh-proxy.com/https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/")!),
        IOSUpdateSource(id: "raw", name: "raw", baseURL: URL(string: "https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/")!),
        IOSUpdateSource(id: "jsdelivr", name: "jsDelivr", baseURL: URL(string: "https://cdn.jsdelivr.net/gh/lswlc33/zeeho-3d-models@main/")!),
        IOSUpdateSource(id: "cf", name: "Cloudflare", baseURL: URL(string: "https://zhb.xn--fiqz59cpva341l.top/")!)
    ]

    static func sources(for line: IOSPanelLine = .current) -> [IOSUpdateSource] {
        line == .cf ? [official[5]] : official
    }

    static func recognizes(_ source: IOSUpdateSource) -> Bool {
        official.contains { $0.id == source.id && $0.baseURL == source.baseURL }
    }

    static func metadataSources(for line: IOSPanelLine) -> [IOSUpdateSource] {
        line == .cf ? [official[5]] : [official[0], official[3], official[5]]
    }

    // 重定向只允许所选源的运输端点，不把重定向当成切换下载源的机会。
    static func allows(_ url: URL, source: IOSUpdateSource, relative: String) -> Bool {
        guard recognizes(source), paths.contains(relative),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.fragment == nil else { return false }
        let query = parts.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({ item in
            if item.name == "sha256" { return item.value.map { IOSRelease.validHash($0) } ?? false }
            if item.name == "_" {
                return item.value.map { !$0.isEmpty && $0.utf8.count <= 16 && $0.utf8.allSatisfy { (48...57).contains($0) } } ?? false
            }
            return false
        }) else { return false }
        var endpoints = [source.baseURL]
        if source.id == "ghfast" || source.id == "ghproxy" { endpoints.append(official[3].baseURL) }
        if source.id == "jsdelivr" {
            for host in ["fastly.jsdelivr.net", "gcore.jsdelivr.net", "testingcf.jsdelivr.net", "quantil.jsdelivr.net"] {
                endpoints.append(URL(string: "https://\(host)/gh/lswlc33/zeeho-3d-models@main/")!)
            }
        }
        return endpoints.contains { root in
            guard let expected = URLComponents(string: root.absoluteString + relative) else { return false }
            return parts.host == expected.host && parts.percentEncodedPath == expected.percentEncodedPath
        }
    }
}

enum UpdateError: LocalizedError {
    case invalidRelease, checksum, http, systemTooOld, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return IOSStrings.updateErrorInvalidRelease
        case .checksum: return IOSStrings.updateErrorChecksum
        case .http: return IOSStrings.updateErrorHTTP
        case .systemTooOld: return IOSStrings.updateErrorSystemTooOld
        case .tooLarge: return IOSStrings.updateErrorTooLarge
        }
    }
}

enum IOSUpdater {
    static let maximumMetadataSize = 32 * 1024
    static let maximumRedirects = 5

    static func metadataURLs(for line: IOSPanelLine = .current) -> [URL] {
        IOSUpdateSources.metadataSources(for: line).map { try! $0.url(for: IOSUpdateSources.manifestPath) }
    }

    static func allowsRedirect(from: URL, to: URL, source: IOSUpdateSource, relative: String) -> Bool {
        IOSUpdateSources.allows(from, source: source, relative: relative)
            && IOSUpdateSources.allows(to, source: source, relative: relative)
    }

    private static func metadata<T>(line: IOSPanelLine, relative: String, decode: (Data) throws -> T) async throws -> T {
        let sources = IOSUpdateSources.metadataSources(for: line)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var failure: Error = UpdateError.http
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            do {
                var parts = URLComponents(url: try source.url(for: relative), resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
                let timeout = remaining / Double(sources.count - index)
                let transfer = IOSUpdateTransfer(source: source, relative: relative, limit: maximumMetadataSize)
                let (bytes, _) = try await transfer.read(url: parts.url!, timeout: timeout)
                try Task.checkCancellation()
                let value = try decode(bytes)
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime <= deadline else { throw URLError(.timedOut) }
                return value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        try Task.checkCancellation()
        throw failure
    }

    static func latest(line: IOSPanelLine = .current) async throws -> IOSRelease {
        try await metadata(line: line, relative: IOSUpdateSources.manifestPath) { bytes in
            try IOSRelease.fromSource(bytes)
        }
    }

    static func latestPanelBuild(line: IOSPanelLine) async throws -> String {
        try await metadata(line: line, relative: IOSUpdateSources.panelPath) { try panelBuild(from: $0) }
    }

    static func panelBuild(from bytes: Data) throws -> String {
        guard bytes.count <= maximumMetadataSize,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let text = object["build"] as? String, text.utf8.count == 19 else { throw UpdateError.invalidRelease }
        let digits = Array(text.utf8)
        for index in digits.indices {
            let separator: UInt8? = [4: 45, 7: 45, 10: 32, 13: 58, 16: 58][index]
            guard separator.map({ digits[index] == $0 }) ?? (48...57).contains(digits[index]) else {
                throw UpdateError.invalidRelease
            }
        }
        guard Int(text.prefix(4)).map({ $0 > 0 }) == true else { throw UpdateError.invalidRelease }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw UpdateError.invalidRelease
        }
        return text
    }

    // 仅供旧版清单迁移；最新检查不调用 API，也不采用资产里的任意下载 URL。
    // 旧清单的 installer 字段已不再使用（App 内不安装），这里只接受历史值以免旧数据被拒。
    static func releaseFromGitHubAPI(_ bytes: Data) throws -> IOSRelease {
        guard bytes.count <= maximumMetadataSize,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let body = object["body"] as? String,
              (object["assets"] as? [[String: Any]])?.contains(where: {
                  ["dashboard-trollstore.ipa", "zeehowebnext.ipa"].contains($0["name"] as? String ?? "")
                      && (($0["state"] as? String) == "uploaded" || $0["state"] == nil)
              }) == true else { throw UpdateError.http }
        var fields: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            guard ["version", "build", "sha256", "size", "minimumIOS"].contains(key) else { continue }
            guard fields[key] == nil else { throw UpdateError.invalidRelease }
            fields[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard let version = fields["version"], let build = fields["build"], let sha256 = fields["sha256"],
              let sizeText = fields["size"], let size = Int(sizeText) else { throw UpdateError.http }
        let release = IOSRelease(version: version, build: build, bundleIdentifier: IOSRelease.bundleID,
                                 minimumIOS: fields["minimumIOS"] ?? "15.4", architecture: "arm64", installer: "TrollStore",
                                 file: "zeehowebnext.ipa", size: size, sha256: sha256)
        try release.validate()
        return release
    }
}

// 小清单与 IPA 都在接收过程中限量；HEAD 在响应头回调立即停止，不收完整包。
private final class IOSUpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: IOSUpdateSource
    private let relative: String
    private let limit: Int
    private let headersOnly: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private var deadline: TimeInterval = 0
    private var finished = false

    init(source: IOSUpdateSource, relative: String, limit: Int, headersOnly: Bool = false) {
        self.source = source
        self.relative = relative
        self.limit = limit
        self.headersOnly = headersOnly
        super.init()
    }

    func read(url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard timeout > 0, IOSUpdateSources.allows(url, source: source, relative: relative) else { throw UpdateError.http }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation, url: url, timeout: timeout)
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func request(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = headersOnly ? "HEAD" : "GET"
        request.httpShouldHandleCookies = false
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(relative == IOSUpdateSources.ipaPath ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func start(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>, url: URL, timeout: TimeInterval) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request(url: url, timeout: timeout))
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        self.session = session
        self.task = task
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        task.resume()
    }

    private func finish(_ proposed: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result: Result<(Data, HTTPURLResponse), Error>
        if case .success = proposed, ProcessInfo.processInfo.systemUptime > deadline {
            result = .failure(URLError(.timedOut))
        } else { result = proposed }
        let continuation = self.continuation, session = self.session, task = self.task, timer = self.timer
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.timer = nil
        bytes = Data()
        lock.unlock()
        timer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let active = !finished && redirects < IOSUpdater.maximumRedirects
        redirects += 1
        lock.unlock()
        guard active, [301, 302, 303, 307, 308].contains(response.statusCode),
              let from = response.url, let to = request.url,
              IOSUpdater.allowsRedirect(from: from, to: to, source: source, relative: relative) else {
            completionHandler(nil)
            finish(.failure(UpdateError.http))
            return
        }
        completionHandler(self.request(url: to, timeout: task.originalRequest?.timeoutInterval ?? 8))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url,
              IOSUpdateSources.allows(url, source: source, relative: relative) else {
            completionHandler(.cancel)
            finish(.failure(UpdateError.http))
            return
        }
        if !headersOnly && response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(.failure(UpdateError.tooLarge))
            return
        }
        lock.lock()
        let active = !finished
        self.response = http
        lock.unlock()
        guard active else { completionHandler(.cancel); return }
        if headersOnly {
            finish(.success((Data(), http)))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= limit - bytes.count else {
            lock.unlock()
            finish(.failure(UpdateError.tooLarge))
            return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let bytes = self.bytes, response = self.response
        lock.unlock()
        if let error = error { finish(.failure(error)) }
        else if let response = response { finish(.success((bytes, response))) }
        else { finish(.failure(UpdateError.http)) }
    }
}
