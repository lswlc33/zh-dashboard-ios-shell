import Foundation
import CryptoKit

@main
enum UpdateTest {
    static func main() throws {
        let bytes = Data("test ipa".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let good: [String: Any] = [
            "version": "1.0.1", "build": "3", "bundleIdentifier": IOSRelease.bundleID,
            "minimumIOS": "15.4", "architecture": "arm64", "installer": "TrollStore",
            "file": "zeehowebnext.ipa", "size": bytes.count, "sha256": hash
        ]
        func expect(_ value: Bool) { precondition(value) }
        func json(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values) }
        func decode(_ values: [String: Any]) throws -> IOSRelease { try JSONDecoder().decode(IOSRelease.self, from: json(values)) }
        func rejects<T>(_ action: () throws -> T) {
            do { _ = try action(); preconditionFailure("invalid update accepted") } catch { }
        }
        let release = try decode(good)
        try release.validate()
        try release.verify(bytes)
        expect(release.notes == IOSStrings.updateDefaultNotes)
        var withNotes = good; withNotes["notes"] = "release notes"
        expect(try decode(withNotes).notes == "release notes")
        for (version, build, newer) in [
            ("1.0.0", "99", true), ("1.0.1", "2", true), ("1.0.1", "3", false),
            ("1.0.1", "4", false), ("1.0.2", "1", false), ("1.0", "99", true), ("2.0", "1", false)
        ] {
            let actual = try release.isNewer(version: version, build: build)
            expect(actual == newer)
        }
        var numeric = good; numeric["build"] = "10"
        let numericRelease = try decode(numeric)
        for (build, newer) in [("9", true), ("10", false), ("11", false)] {
            let actual = try numericRelease.isNewer(version: "1.0.1", build: build)
            expect(actual == newer)
        }
        for valid in ["1", "10", "9007199254740991"] {
            expect(try IOSRelease.safeBuild(valid) == Int(valid))
        }
        for invalid in ["", "0", "00", "01", "+1", "-1", " 1", "1 ", "1\n", "1.0", "1e3", "١", "１",
                        "9007199254740992", "9223372036854775808", "999999999999999999999999"] {
            rejects { try IOSRelease.safeBuild(invalid) }
            rejects { try release.isNewer(version: "1.0.1", build: invalid) }
            var broken = good; broken["build"] = invalid
            rejects { try decode(broken).validate() }
        }
        for (text, expected) in [("1.2", [1, 2, 0]), ("1.2.3", [1, 2, 3]), ("9999.0.9999", [9999, 0, 9999])] {
            expect(try IOSRelease.versionParts(text) == expected)
        }
        for invalid in ["1", "1.2.3.4", "1..2", "1.bad", "10000.1", "1.-1", " 1.2", "1.2\n", "١.2", "１.2"] {
            rejects { try IOSRelease.versionParts(invalid) }
        }
        let aliases: [Any] = [3, "3"]
        for alias in aliases {
            var matching = good; matching["versionName"] = "1.0.1"; matching["versionCode"] = alias
            matching["url"] = "https://evil.example/ignored.ipa"
            let decoded = try decode(matching)
            try decoded.validate()
            expect(decoded.file == "zeehowebnext.ipa")
        }
        let invalidAliases: [(String, Any)] = [
            ("versionName", "1.0.2"), ("versionName", NSNull()), ("versionCode", "4"),
            ("versionCode", "03"), ("versionCode", 4), ("versionCode", true), ("versionCode", 3.5),
            ("versionCode", NSNull()), ("build", 3), ("notes", ["not": "text"])
        ]
        for (key, value) in invalidAliases {
            var invalid = good; invalid[key] = value
            rejects { try decode(invalid).validate() }
        }
        rejects { try release.verify(Data("bad ipa!".utf8)) }
        rejects { try release.verify(Data()) }
        for (key, value) in [
            ("file", "../other.ipa"), ("file", "https://evil.example/a.ipa"),
            ("file", "app/zeehowebnext.ipa"), ("file", "dashboard-trollstore.ipa"), ("file", "zeehowebnext.apk"),
            ("bundleIdentifier", "other.app"), ("sha256", String(repeating: "z", count: 64)),
            ("sha256", hash.uppercased()), ("sha256", String(hash.dropLast())),
            ("architecture", "x86_64"), ("installer", "Other"), ("version", "1.bad"), ("minimumIOS", "15..4")
        ] {
            var invalid = good; invalid[key] = value
            rejects { try decode(invalid).validate() }
        }
        for size in [0, -1, IOSRelease.maximumSize + 1] {
            var invalid = good; invalid["size"] = size
            rejects { try decode(invalid).validate() }
        }
        var boundary = good; boundary["size"] = IOSRelease.maximumSize
        try decode(boundary).validate()

        let sourceVersion: [String: Any] = ["version": "1.0.1", "buildVersion": "3",
            "date": "2026-11-13T00:00:00Z", "localizedDescription": IOSStrings.updateDefaultNotes,
            "downloadURL": "https://zhb.xn--fiqz59cpva341l.top/app/zeehowebnext.ipa?sha256=" + hash,
            "size": bytes.count, "minOSVersion": "15.4"]
        let sourceApp: [String: Any] = ["name": "Synthetic app", "developerName": "Synthetic developer",
            "bundleIdentifier": IOSRelease.bundleID, "localizedDescription": "Synthetic introduction\nOfficial source URL",
            "iconURL": "https://zhb.xn--fiqz59cpva341l.top/app/icon-ios-1024.png", "versions": [sourceVersion]]
        let source: [String: Any] = ["name": "Synthetic source", "apps": [sourceApp], "news": [],
            "description": "Synthetic source URL\n\nSynthetic introduction"]
        let fromSource = try IOSRelease.fromSource(json(source))
        expect(fromSource.version == release.version && fromSource.build == release.build && fromSource.notes == IOSStrings.updateDefaultNotes)
        try fromSource.verify(bytes)
        for apps in [[], [sourceApp, sourceApp]] {
            var broken = source; broken["apps"] = apps
            rejects { try IOSRelease.fromSource(json(broken)) }
        }
        for versions in [[], [sourceVersion, sourceVersion]] {
            var brokenApp = sourceApp; brokenApp["versions"] = versions
            var broken = source; broken["apps"] = [brokenApp]
            rejects { try IOSRelease.fromSource(json(broken)) }
        }
        for (key, value) in [("buildVersion", "0"), ("date", "invalid"),
                             ("minOSVersion", "15..4"), ("downloadURL", "https://evil.example/latest.ipa"),
                             ("downloadURL", "https://zhb.xn--fiqz59cpva341l.top/app/zeehowebnext.ipa?sha256=invalid")] {
            var brokenVersion = sourceVersion; brokenVersion[key] = value
            var brokenApp = sourceApp; brokenApp["versions"] = [brokenVersion]
            var broken = source; broken["apps"] = [brokenApp]
            rejects { try IOSRelease.fromSource(json(broken)) }
        }
        rejects { try IOSRelease.fromSource(json(good)) }
        rejects { try IOSRelease.fromSource(Data(repeating: 32, count: 32_769)) }

        let sources = IOSUpdateSources.sources(for: .github)
        let roots = [
            "https://lswlc33.github.io/zeeho-3d-models/",
            "https://ghfast.top/https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/",
            "https://gh-proxy.com/https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/",
            "https://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/",
            "https://cdn.jsdelivr.net/gh/lswlc33/zeeho-3d-models@main/",
            "https://zhb.xn--fiqz59cpva341l.top/"
        ]
        expect(sources.map { $0.id } == ["origin", "ghfast", "ghproxy", "raw", "jsdelivr", "cf"])
        expect(sources.map { $0.name } == ["GitHub", "ghfast", "ghproxy", "raw", "jsDelivr", "Cloudflare"])
        expect(sources.map { $0.baseURL.absoluteString } == roots)
        expect(IOSUpdateSources.sources(for: .cf) == [sources[5]])
        expect(IOSUpdater.metadataURLs(for: .github).map { $0.absoluteString } == [roots[0], roots[3], roots[5]].map { $0 + "app/version2.json" })
        expect(IOSUpdater.metadataURLs(for: .cf).map { $0.absoluteString } == [roots[5] + "app/version2.json"])
        expect(IOSUpdater.maximumMetadataSize == 32_768 && IOSUpdater.maximumRedirects == 5)
        for (index, source) in sources.enumerated() {
            for relative in ["app/zeehowebnext.ipa", "app/version2.json", "version.json"] {
                let url = try source.url(for: relative)
                expect(url.absoluteString == roots[index] + relative)
                expect(IOSUpdateSources.allows(url, source: source, relative: relative))
            }
            let ipa = try source.url(for: IOSUpdateSources.ipaPath, token: hash)
            let query = URLComponents(url: ipa, resolvingAgainstBaseURL: false)!.queryItems!
            expect(query == [URLQueryItem(name: "sha256", value: hash)])
            expect(IOSUpdater.allowsRedirect(from: ipa, to: ipa, source: source, relative: IOSUpdateSources.ipaPath))
            for invalid in ["../zeehowebnext.ipa", "/app/zeehowebnext.ipa", "app/ios/version.json", "app/version.json",
                            "app/ios/zeehowebnext.ipa", "app/%2e%2e/zeehowebnext.ipa", "app//zeehowebnext.ipa",
                            "https://evil.example/app/zeehowebnext.ipa", "app/zeehowebnext.ipa?url=evil", "app/zeehowebnext.ipa#fragment"] {
                rejects { try source.url(for: invalid) }
            }
            rejects { try source.url(for: IOSUpdateSources.ipaPath, token: "invalid") }
        }
        let forged = IOSUpdateSource(id: "origin", name: "GitHub", baseURL: URL(string: "https://evil.example/")!)
        rejects { try forged.url(for: IOSUpdateSources.ipaPath) }
        let mislabeled = IOSUpdateSource(id: "raw", name: "raw", baseURL: sources[0].baseURL)
        rejects { try mislabeled.url(for: IOSUpdateSources.ipaPath) }
        let path = IOSUpdateSources.ipaPath
        let raw = try sources[3].url(for: path)
        for (sourceIndex, target, allowed) in [
            (1, raw.absoluteString, true), (2, raw.absoluteString, true),
            (0, raw.absoluteString, false), (5, raw.absoluteString, false),
            (3, roots[0] + path, false), (1, roots[2] + path, false),
            (4, "https://fastly.jsdelivr.net/gh/lswlc33/zeeho-3d-models@main/" + path, true),
            (4, "https://gcore.jsdelivr.net/gh/lswlc33/zeeho-3d-models@main/" + path, true)
        ] {
            let source = sources[sourceIndex], from = try source.url(for: path)
            expect(IOSUpdater.allowsRedirect(from: from, to: URL(string: target)!, source: source, relative: path) == allowed)
        }
        for target in [
            "http://raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/" + path,
            "https://user:password@raw.githubusercontent.com/lswlc33/zeeho-3d-models/main/" + path,
            "https://raw.githubusercontent.com:444/lswlc33/zeeho-3d-models/main/" + path,
            "https://raw.githubusercontent.com.evil.example/lswlc33/zeeho-3d-models/main/" + path,
            "https://raw.githubusercontent.com/other/repository/main/" + path,
            roots[3] + "app/ios/zeehowebnext.ipa", roots[3] + "app/%7aeehowebnext.ipa",
            roots[3] + path + "#fragment", roots[3] + path + "?url=https://evil.example/",
            roots[3] + path + "?sha256=bad", roots[3] + path + "?_=bad",
            roots[3] + path + "?sha256=" + hash + "&sha256=" + hash,
            "https://objects.githubusercontent.com/asset/zeehowebnext.ipa", "https://evil.example/" + path
        ] {
            expect(!IOSUpdater.allowsRedirect(from: raw, to: URL(string: target)!, source: sources[3], relative: path))
        }
        expect(!IOSUpdater.allowsRedirect(from: URL(string: "https://evil.example/" + path)!, to: raw, source: sources[3], relative: path))

        for valid in ["2026-11-12 00:00:00", "2024-02-29 23:59:59", "2000-02-29 12:34:56"] {
            let actual = try IOSUpdater.panelBuild(from: json(["build": valid, "extra": true]))
            expect(actual == valid)
        }
        for invalid in ["", "2026-02-29 12:00:00", "1900-02-29 12:00:00", "2026-04-31 12:00:00",
                        "2026-13-01 12:00:00", "2026-00-01 12:00:00", "2026-11-00 12:00:00",
                        "2026-11-12 24:00:00", "2026-11-12 23:60:00", "2026-11-12 23:59:60",
                        "2026-11-12T12:00:00", "2026-11-12 12:00:00Z", "2026-1-12 12:00:00",
                        "2026-11-12 12:00:00 ", "0000-01-01 00:00:00", "２０２６-11-12 12:00:00"] {
            rejects { try IOSUpdater.panelBuild(from: json(["build": invalid])) }
        }
        rejects { try IOSUpdater.panelBuild(from: json(["build": 3])) }
        rejects { try IOSUpdater.panelBuild(from: json(["version": "1.0.0"])) }
        rejects { try IOSUpdater.panelBuild(from: Data(repeating: 32, count: 32_769)) }

        func apiEnvelope(_ fields: [String: String], asset: String = "dashboard-trollstore.ipa") throws -> Data {
            try json(["body": fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"),
                      "assets": [["name": asset, "state": "uploaded", "browser_download_url": "https://evil.example/ignored.ipa"]]])
        }
        let apiFields = ["version": "1.0.1", "build": "7", "sha256": hash, "size": String(bytes.count), "minimumIOS": "15.4"]
        let legacy = try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(apiFields))
        try legacy.validate()
        expect(legacy.file == "zeehowebnext.ipa")
        for missing in ["version", "build", "sha256", "size"] {
            var broken = apiFields; broken[missing] = nil
            rejects { try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(broken)) }
        }
        var badMinimum = apiFields; badMinimum["minimumIOS"] = "15..4"
        rejects { try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(badMinimum)) }
        rejects { try IOSUpdater.releaseFromGitHubAPI(apiEnvelope(apiFields, asset: "other.ipa")) }
        rejects { try IOSUpdater.releaseFromGitHubAPI(Data("not json".utf8)) }
        print("iOS pure update checks passed (synthetic data only; no network or installation)")
    }
}
