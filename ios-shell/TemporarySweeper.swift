import Foundation

// 临时文件的启动清扫。
//
// 背景：这几类临时目录各自的正常清理入口都是「拿到 lease 的那一方主动释放」——
//   - Caches/native-blob-<uuid>/payload      （IOSNativeFileStreamService，单文件上限 512MB）
//   - tmp/dashboard-system-<uuid>/           （System.prepareFile，图片/文件上传中转）
//   - tmp/native-asset-<uuid>/               （WallpaperTransfer，原生素材下载）
// App 在复制/下载/分享途中被系统杀掉（大文件时最容易被 jetsam 选中）就留下整份目录，
// 之后再没有任何代码看到它；反复发生可以堆出上 GB，而全仓没有任何收尾扫描。
// Caches/tmp 名义上「系统可以回收」，但那只是可能，不是上界。
//
// 这里在启动时扫一次：只认自己三个前缀、只删普通目录、且只删「老于 grace」的条目。
// 保留 grace 是为了不和「刚启动就立刻开始的复制/下载」抢目录；启动那一刻本来不可能
// 已有本进程创建的目录，所以实际上绝大多数上次会话的残留都会被清掉。
enum IOSTemporaryFileSweeper {
    /// 我们拥有的临时目录前缀。任何不匹配的条目一律不碰。
    private static let ownedPrefixes = ["native-blob-", "dashboard-system-", "native-asset-"]
    /// 有多旧才动手。只影响「进程刚被杀就立刻重启」这种极窄情况。
    private static let grace: TimeInterval = 60

    static func sweepAtLaunch() {
        let manager = FileManager.default
        let bases: [URL] = [
            manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            manager.temporaryDirectory
        ].compactMap { $0 }
        var removed = 0
        var failed = 0
        for base in bases {
            guard let entries = try? manager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: []) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard ownedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                // 只认普通目录：名字对上了但类型不对（符号链接/文件）就不动，交给原来的路径去判。
                guard let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                    values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if let modified = values.contentModificationDate,
                   Date().timeIntervalSince(modified) < grace {
                    // 刚改过的可能正被别的流程用着：跳过，下次启动再说。
                    continue
                }
                if (try? manager.removeItem(at: entry)) != nil {
                    removed += 1
                } else {
                    failed += 1
                }
            }
        }
        if removed > 0 || failed > 0 {
            IOSDiagnostics.shared.log("sweep: 启动清扫临时目录 删除=\(removed) 失败=\(failed)")
        }
    }
}