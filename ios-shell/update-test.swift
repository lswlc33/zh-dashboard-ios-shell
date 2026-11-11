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
        assert(release.downloadURLs.map { $0.host! } == ["ghfast.top", "gh-proxy.com", "raw.githubusercontent.com", "cdn.jsdelivr.net", "lswlc33.github.io"])
        for url in release.downloadURLs {
            assert(url.scheme == "https")
            assert(url.path.hasSuffix("/app/ios/dashboard-trollstore.ipa"))
            assert(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first?.value == release.sha256)
        }
        assert(IOSUpdater.metadataURLs.map { $0.host! } == ["raw.githubusercontent.com", "lswlc33.github.io", "api.github.com"])
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
