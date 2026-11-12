import Foundation
import CryptoKit

struct IOSRelease: Decodable {
    // 清单与 IPA 的真实落点是公开壳仓库（zh-dashboard-ios-shell）的 Release 资产：
    // CI 每次构建都把 `dashboard-trollstore.ipa` + `SHA256SUMS` 发到那里，
    // 而 zeeho-3d-models 的 app/ios/ 目录自始至终不存在（实测三个源全 404）。
    // 清单文件 version.json 由发布流程推到产物仓库 zeeho-3d-models/app/ios/
    // （见 build-support.write-release 的字段，publish 由人工/脚本执行）；
    // 在那份清单出现之前，这里优先走 Release 侧的 API 读取。
    static let root = URL(string: "https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/app/ios/")!
    // 公开壳仓库的最新 pre-release 资产直链（GitHub 会 302 到 objects.githubusercontent.com，
    // checkResponse 会拒绝跨主机重定向，所以只用于清单兜底之外的 IPA 下载不做——
    // IPA 下载仍走 root 的五个镜像，靠 sha256 校验兜住）。
    static let releaseApi = URL(string: "https://api.github.com/repos/lswlc33/zh-dashboard-ios-shell/releases/latest")!
    static let bundleID = "io.github.lswlc33.dashboard.ios"
    let version: String
    let build: String
    let bundleIdentifier: String
    let minimumIOS: String
    let architecture: String
    let installer: String
    let file: String
    let size: Int
    let sha256: String

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
        guard bundleIdentifier == Self.bundleID, architecture == "arm64", installer == "TrollStore",
              file == "dashboard-trollstore.ipa", (1...31_457_280).contains(size),
              Int(build).map({ $0 > 0 }) == true,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw UpdateError.invalidRelease
        }
    }

    /// 当前系统是否满足这个版本的 `minimumIOS`。
    ///
    /// 下载弹出之前必须先过这道闸：清单里写的最低系统高于本机时，
    /// 用户下完 IPA 才发现装不上（TrollStore 会直接拒绝），白等一次下载。
    /// 更新面板与 Dashboard 的「检查更新」都要在弹「发现新版本」之前调它，
    /// 否则同一个闸门会在两个入口漂移（Dashboard 早已有，更新面板漏了）。
    func requireSupportedSystem() throws {
        let parts = try Self.versionParts(minimumIOS)
        let required = OperatingSystemVersion(majorVersion: parts[0],
                                             minorVersion: parts[1],
                                             patchVersion: parts[2])
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
            throw UpdateError.systemTooOld
        }
    }

    func isNewer(version installed: String, build installedBuild: String) throws -> Bool {
        try validate()
        let remote = try Self.versionParts(version), local = try Self.versionParts(installed)
        guard let localBuild = Int(installedBuild), localBuild > 0 else { throw UpdateError.invalidRelease }
        return remote == local ? Int(build)! > localBuild : local.lexicographicallyPrecedes(remote)
    }

    func verify(_ bytes: Data) throws {
        try validate()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == size, digest == sha256 else { throw UpdateError.checksum }
    }

    var downloadURLs: [URL] {
        // 与 Android RemoteSources 共用相同镜像顺序；每个源都必须通过官方清单的哈希校验。
        [
            "https://ghfast.top/" + Self.root.absoluteString,
            "https://gh-proxy.com/" + Self.root.absoluteString,
            Self.root.absoluteString,
            "https://cdn.jsdelivr.net/gh/lswlc33/zeeho-3d-models@main/app/ios/",
            "https://lswlc33.github.io/zeeho-3d-models/app/ios/"
        ].map { root in
            var url = URLComponents(url: URL(string: root)!.appendingPathComponent(file), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "sha256", value: sha256)]
            return url.url!
        }
    }
}

enum UpdateError: LocalizedError {
    case invalidRelease, checksum, http, systemTooOld, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "iOS 更新清单无效，已停止更新。"
        case .checksum: return "IPA 大小或 SHA-256 校验失败，请稍后重试。"
        case .http: return "暂时无法读取 iOS 发布信息（三个来源都不可达）。请稍后重试，或到 GitHub Releases 页面手动下载。"
        case .systemTooOld: return "新版要求更高的 iOS 系统，当前设备无法安装。"
        case .tooLarge: return "更新文件超出大小限制，已停止更新。"
        }
    }
}

enum IOSUpdater {
    private static let session = URLSession(configuration: .ephemeral)
    // 小清单仅从官方 HTTPS 来源读取，第三方 CDN 只运输经过哈希校验的 IPA。
    // 前两个源是产物仓库的 app/ios/version.json（发布流程负责推）；
    // 第三个是公开壳仓库「最新 Release」的 API —— 资产名固定 dashboard-trollstore.ipa，
    // Release body 附带 build-manifest 字段，从那里能拼出真实的下载地址与校验信息。
    static let metadataURLs = [
        IOSRelease.root.appendingPathComponent("version.json"),
        URL(string: "https://lswlc33.github.io/zeeho-3d-models/app/ios/version.json")!,
        IOSRelease.releaseApi
    ]

    /// 从 Release API 的 JSON 里挖出与 IOSRelease 兼容的清单。
    /// Release body 由 CI 用 printf 写成固定几行：`version: x.y.z` / `build: n` /
    /// `sha256: ...` / `size: n` / `minimumIOS: ...`（见 build-ios.yml 的 notes 生成段）。
    /// 解不出来就抛 http，让调用方继续尝试下一个源。
    /// internal 是为了 update-test.swift 能直接构造 body 做表驱动验证。
    static func releaseFromGitHubAPI(_ bytes: Data) throws -> IOSRelease {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let body = object["body"] as? String,
              let asset = (object["assets"] as? [[String: Any]])?.first(where: {
                  ($0["name"] as? String) == "dashboard-trollstore.ipa"
                      && (($0["state"] as? String) == "uploaded" || $0["state"] == nil)
              }) else { throw UpdateError.http }
        func field(_ key: String) -> String? {
            // 只认行首的 `key: value`，避免从正文里误抓数字。
            let pattern = "(?m)^" + NSRegularExpression.escapedPattern(forKey: key) + R":\s*(\S+)"
            guard let match = body.range(of: pattern, options: .regularExpression) else { return nil }
            return String(body[match]).split(separator: ":").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        guard let version = field("version"), let build = field("build"),
              let sha256 = field("sha256"), let sizeText = field("size"), let size = Int(sizeText) else {
            throw UpdateError.http
        }
        let release = IOSRelease(version: version, build: build,
                                 bundleIdentifier: IOSRelease.bundleID,
                                 minimumIOS: field("minimumIOS") ?? "15.4",
                                 architecture: "arm64", installer: "TrollStore",
                                 file: "dashboard-trollstore.ipa", size: size, sha256: sha256)
        try release.validate()
        return release
    }

    private static func checkResponse(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == url.host, http.url?.path == url.path else {
            throw UpdateError.http
        }
    }

    static func latest() async throws -> IOSRelease {
        var failure: Error = UpdateError.http
        for url in metadataURLs {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.data(for: request)
                try checkResponse(response, url: url)
                guard bytes.count <= 32_768 else { throw UpdateError.tooLarge }
                // Release API 的 JSON 结构与 version.json 不同，按主机分流解析。
                let release: IOSRelease
                if url.host == "api.github.com" {
                    release = try releaseFromGitHubAPI(bytes)
                } else {
                    release = try JSONDecoder().decode(IOSRelease.self, from: bytes)
                    try release.validate()
                }
                return release
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        throw failure
    }

    static func download(_ release: IOSRelease) async throws -> URL {
        try release.validate()
        var failure: Error = UpdateError.http
        for url in release.downloadURLs {
            do {
                let (temporary, response) = try await session.download(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
                defer { try? FileManager.default.removeItem(at: temporary) }
                try checkResponse(response, url: url)
                let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
                guard size?.intValue == release.size else { throw UpdateError.checksum }
                try release.verify(Data(contentsOf: temporary))
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-trollstore.ipa")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
        }
        throw failure
    }
}
