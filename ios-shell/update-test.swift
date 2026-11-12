import Foundation
import CryptoKit

@main
enum UpdateTest {
    static func main() throws {
        let bytes = Data("test ipa".utf8)
        let good: [String: Any] = [
            "version": "1.0.1", "build": "3", "bundleIdentifier": IOSRelease.bundleID,
            "minimumIOS": "15.4", "architecture": "arm64", "installer": "TrollStore",
            "file": "dashboard-trollstore.ipa", "size": bytes.count,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ]
        func decode(_ values: [String: Any]) throws -> IOSRelease {
            try JSONDecoder().decode(IOSRelease.self, from: JSONSerialization.data(withJSONObject: values))
        }
        func expect(_ value: Bool) { assert(value) }
        let release = try decode(good)
        try release.validate()
        try release.verify(bytes)
        try expect(release.isNewer(version: "1.0.0", build: "99"))
        try expect(release.isNewer(version: "1.0.1", build: "2"))
        try expect(!release.isNewer(version: "1.0.1", build: "3"))
        try expect(!release.isNewer(version: "1.0.1", build: "4"))
        try expect(!release.isNewer(version: "1.0.2", build: "1"))
        // build 现在默认来自 `git rev-list --count HEAD`，会很快超过 9：
        // 必须按数值比较，字符串比较会把 "10" 判成比 "9" 老（或反过来）。
        let numeric: [String: Any] = [
            "version": "1.0.1", "build": "10", "bundleIdentifier": IOSRelease.bundleID,
            "minimumIOS": "15.4", "architecture": "arm64", "installer": "TrollStore",
            "file": "dashboard-trollstore.ipa", "size": bytes.count,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ]
        let numericRelease = try decode(numeric)
        try expect(numericRelease.isNewer(version: "1.0.1", build: "9"))
        try expect(!numericRelease.isNewer(version: "1.0.1", build: "11"))
        assert(release.downloadURLs.map { $0.host! } == ["ghfast.top", "gh-proxy.com", "raw.githubusercontent.com", "cdn.jsdelivr.net", "lswlc33.github.io"])
        for url in release.downloadURLs {
            assert(url.scheme == "https")
            assert(url.path.hasSuffix("/app/ios/dashboard-trollstore.ipa"))
            assert(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first?.value == release.sha256)
        }
        assert(IOSUpdater.metadataURLs.map { $0.host! } == ["raw.githubusercontent.com", "lswlc33.github.io", "api.github.com"])
        // Release API 兜底源：CI 的 Release notes 里带机器可读段（version/build/sha256/
        // size/minimumIOS），releaseFromGitHubAPI 从中拼出合法清单。五键缺一即拒。
        func releaseBody(_ fields: [String: String]) -> String {
            fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        }
        func apiEnvelope(_ body: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "body": body,
                "assets": [["name": "dashboard-trollstore.ipa", "state": "uploaded"]]
            ])
        }
        let apiFields = [
            "version": "1.0.1", "build": "7", "sha256": good["sha256"] as! String,
            "size": String(bytes.count), "minimumIOS": "15.4"
        ]
        let apiRelease = try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(releaseBody(apiFields)))
        try expect(apiRelease.isNewer(version: "1.0.0", build: "99"))
        try expect(!apiRelease.isNewer(version: "1.0.1", build: "7"))
        for missing in ["version", "build", "sha256", "size", "minimumIOS"] {
            var broken = apiFields; broken[missing] = nil
            rejects { try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(releaseBody(broken))) }
        }
        // 资产名不对 / body 缺键 / 正文值带垃圾，都不允许假成功。
        rejects {
            try IOSUpdater.releaseFromGitHubAPI(try! JSONSerialization.data(withJSONObject: [
                "body": releaseBody(apiFields),
                "assets": [["name": "other.ipa", "state": "uploaded"]]
            ]))
        }
        rejects { try IOSUpdater.releaseFromGitHubAPI(Data("not json".utf8)) }
        func rejects(_ action: () throws -> Void) {
            do { try action(); assertionFailure("invalid update accepted") } catch { }
        }
        rejects { try release.verify(Data("bad ipa!".utf8)) }
        for (key, value) in [
            ("file", "../other.ipa"), ("file", "https://evil.example/a.ipa"),
            ("bundleIdentifier", "other.app"), ("sha256", String(repeating: "z", count: 64)),
            ("architecture", "x86_64"), ("installer", "Other"), ("version", "1.bad"),
            ("minimumIOS", "15..4"), ("build", "0"), ("build", "999999999999999999999999")
        ] {
            var invalid = good; invalid[key] = value
            rejects { try decode(invalid).validate() }
        }
        for size in [0, -1, 31_457_281] {
            var invalid = good; invalid["size"] = size
            rejects { try decode(invalid).validate() }
        }
        print("iOS update checks passed")
    }
}
