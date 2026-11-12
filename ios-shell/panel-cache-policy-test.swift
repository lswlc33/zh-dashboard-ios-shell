import Foundation

// PanelCachePolicy.swift 的独立回归：只链接 Foundation 与 policy，不需要 UIKit 或下载资源。
// 和 navigation-test.swift 一样用 assert，让真实 macOS CI 直接编译执行，不新增测试 target。
@main
enum PanelCachePolicyTest {
    static func main() {
        // 固定时间且保留毫秒尾数：不依赖系统时钟，也能抓住把毫秒当秒或提前取整的回归。
        let downloadedAtSeconds: TimeInterval = 1_800_000_000.125
        func needsRefresh(downloadedAt: Int64 = 1_800_000_000_125,
                          line: String = "github", shellBuild: String = "45",
                          currentLine: String = "github", currentShellBuild: String = "45",
                          now: TimeInterval = 1_800_000_060.125) -> Bool {
            // 不传 maxAgeHours，下面的 24 小时边界必须验证 API 自己的默认值。
            IOSPanelCachePolicy.needsRefresh(downloadedAt: downloadedAt, line: line,
                                             shellBuild: shellBuild, currentLine: currentLine,
                                             currentShellBuild: currentShellBuild, now: now)
        }

        assert(!needsRefresh(), "same_build_line_fresh: 同 build、同线路且只过了 60 秒应复用")
        assert(!needsRefresh(now: downloadedAtSeconds),
               "just_downloaded: 刚下载完成不应刷新")
        assert(!needsRefresh(now: downloadedAtSeconds + 24 * 3600 - 0.001),
               "before_24h: 到期前 1 毫秒仍应复用")
        assert(needsRefresh(now: downloadedAtSeconds + 24 * 3600),
               "at_24h: 恰好 24 小时必须刷新，不能等到超过边界")
        assert(needsRefresh(now: downloadedAtSeconds + 25 * 3600),
               "expired: 已过期的同 build、同线路快照也必须刷新")

        // 旧 IPA 留下的元数据可能不完整；不能把未知值当成可长期复用的快照。
        assert(needsRefresh(downloadedAt: 0), "missing_download_time: 时间 0 必须刷新")
        assert(needsRefresh(shellBuild: ""), "missing_shell_build: 缺少下载时的 IPA build 必须刷新")
        assert(needsRefresh(shellBuild: "", currentShellBuild: ""),
               "both_shell_builds_unknown: 两个空 build 相等也不能复用")
        assert(needsRefresh(shellBuild: "44", currentShellBuild: "45"),
               "shell_upgrade_44_to_45: 覆盖安装升级后必须刷新，即使快照很新")

        assert(needsRefresh(line: "github", currentLine: "cf"),
               "github_to_cf: 换到 Cloudflare 必须刷新")
        assert(needsRefresh(line: "cf", currentLine: "github"),
               "cf_to_github: 换回 GitHub 也必须刷新")
        assert(!needsRefresh(line: "cf", currentLine: "cf"),
               "same_cf_line_fresh: Cloudflare 同线路的新快照应正常复用")
        assert(needsRefresh(now: downloadedAtSeconds - 0.001),
               "clock_rollback: 时钟回拨 1 毫秒也必须刷新，未来时间戳不能永久保鲜")

        // 非默认期限仍要遵守同样的闭区间边界，不能在 policy 内写死 24 小时。
        assert(!IOSPanelCachePolicy.needsRefresh(
            downloadedAt: 1_800_000_000_125, line: "github", shellBuild: "45",
            currentLine: "github", currentShellBuild: "45",
            now: downloadedAtSeconds + 6 * 3600 - 0.001, maxAgeHours: 6),
               "before_custom_6h: 自定义期限到期前仍应复用")
        assert(IOSPanelCachePolicy.needsRefresh(
            downloadedAt: 1_800_000_000_125, line: "github", shellBuild: "45",
            currentLine: "github", currentShellBuild: "45",
            now: downloadedAtSeconds + 6 * 3600, maxAgeHours: 6),
               "at_custom_6h: 自定义 6 小时期限到点必须刷新")

        print("iOS panel cache policy checks passed (15 cases)")
    }
}
