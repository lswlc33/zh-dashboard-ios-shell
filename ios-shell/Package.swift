// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
let selectedProduct = environment["ZEEHO_XTOOL_PRODUCT"] ?? "DashboardIOS"
let manager = FileManager.default

func sources(_ directory: String) -> [String] {
    let url = root.appendingPathComponent(directory)
    return ((try? manager.contentsOfDirectory(atPath: url.path)) ?? [])
        .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("-test.swift") && $0 != "Package.swift" }
        .sorted()
}

let activityLink: [LinkerSetting] = [
    // 15.4 仍能启动；ActivityKit 的源码调用另外由真实 16.1 availability guard 保护。
    .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "ActivityKit"]),
]
let probeTarget = Target.target(
    name: "SwiftProbe", path: "XtoolSupport/SwiftProbe", exclude: ["Info.plist"], sources: ["Probe.swift"],
    linkerSettings: [.linkedFramework("UIKit"), .linkedFramework("WebKit"),
                     .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])]
)
var products: [Product] = [.library(name: "SwiftProbe", targets: ["SwiftProbe"])]
var targets: [Target] = [probeTarget]

if selectedProduct == "DashboardIOS" {
    // 完整 App 不接受缺 KMP 回退。build-support.py 先验证真实二进制、iOS arm64 与源码哈希。
    guard let frameworkPath = environment["ZEEHO_KMP_XCFRAMEWORK"],
          frameworkPath == "XtoolSupport/KMP/ZeehoShared.xcframework",
          manager.fileExists(atPath: root.appendingPathComponent(frameworkPath).path + "/Info.plist"),
          let metadataPath = environment["ZEEHO_KMP_MANIFEST"],
          let metadataData = manager.contents(atPath: metadataPath),
          let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
          metadata["module"] as? String == "ZeehoShared",
          let sourceHash = metadata["sourceTreeSha256"] as? String,
          sourceHash == environment["ZEEHO_KMP_SOURCE_SHA256"] else {
        fatalError("KMP_FRAMEWORK_MISSING: provide a real ZeehoShared.xcframework and matching source-hash manifest; no fallback App is built")
    }
    let hostSources = sources(".")
    let sharedSources = sources("Shared")
    let widgetSources = sources("Widgets")
    guard !hostSources.isEmpty, sharedSources.count >= 3, !widgetSources.isEmpty else {
        fatalError("SOURCE_CONTRACT_MISSING: host, ZeehoSystemShared and DashboardWidgets sources are required")
    }
    let hostExcluded = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).filter { !hostSources.contains($0) }
    targets += [
        .binaryTarget(name: "ZeehoShared", path: frameworkPath),
        .target(
            name: "ZeehoSystemShared", path: "Shared", sources: sharedSources,
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.linkedFramework("Foundation")] + activityLink
        ),
        .target(
            name: "DashboardIOS", dependencies: ["ZeehoShared", "ZeehoSystemShared"],
            path: ".", exclude: hostExcluded, sources: hostSources,
            linkerSettings: [
                .linkedFramework("UIKit"), .linkedFramework("WebKit"), .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"), .linkedFramework("CoreBluetooth"), .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"), .linkedFramework("Photos"), .linkedFramework("UserNotifications"),
                .linkedFramework("CryptoKit"), .linkedFramework("Security"), .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("WidgetKit"),
                .linkedLibrary("c++"), .unsafeFlags(["-Xlinker", "-ObjC", "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]),
            ] + activityLink
        ),
        .target(
            name: "DashboardWidgets", dependencies: ["ZeehoSystemShared"],
            path: "Widgets", exclude: ["Info.plist"], sources: widgetSources,
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("SwiftUI"), .linkedFramework("UIKit"), .linkedFramework("WidgetKit"),
                             .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])] + activityLink
        ),
    ]
    products += [
        // xtool 1.24.0 Planner 读取 automatic library，再生成真实 executable/appex targets。
        .library(name: "DashboardIOS", targets: ["DashboardIOS"]),
        .library(name: "DashboardWidgets", targets: ["DashboardWidgets"]),
    ]
} else if selectedProduct != "SwiftProbe" {
    fatalError("PRODUCT_UNSUPPORTED: use DashboardIOS or the independent SwiftProbe")
}

let package = Package(
    name: "DashboardIOS", platforms: [.iOS("15.4")], products: products, targets: targets,
    swiftLanguageModes: [.v5]
)
