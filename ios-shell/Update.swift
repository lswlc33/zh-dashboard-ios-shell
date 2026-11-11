import Foundation
import CryptoKit

struct IOSRelease: Decodable {
    static let root = URL(string: "https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/app/ios/")!
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
        case .http: return "暂时无法读取 iOS 发布文件。若安装包 PR 尚未合并，请等待发布后重试。"
        case .systemTooOld: return "新版要求更高的 iOS 系统，当前设备无法安装。"
        case .tooLarge: return "更新文件超出大小限制，已停止更新。"
        }
    }
}

enum IOSUpdater {
    private static let session = URLSession(configuration: .ephemeral)
    // 小清单仅从官方 HTTPS 来源读取，第三方 CDN 只运输经过哈希校验的 IPA。
    static let metadataURLs = [
        IOSRelease.root.appendingPathComponent("version.json"),
        URL(string: "https://lswlc33.github.io/zeeho-3d-models/app/ios/version.json")!,
        URL(string: "https://api.github.com/repos/lswlc33/zeeho-3d-models/contents/app/ios/version.json?ref=main")!
    ]

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
                let release = try JSONDecoder().decode(IOSRelease.self, from: bytes)
                try release.validate()
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
