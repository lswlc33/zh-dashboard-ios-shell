import Foundation

// 覆盖安装保留沙盒，不能只靠快照存在就复用；升级、换线和过期都必须重新下载。
enum IOSPanelCachePolicy {
    static func needsRefresh(downloadedAt: Int64, line: String, shellBuild: String,
                             currentLine: String, currentShellBuild: String,
                             now: TimeInterval, maxAgeHours: Int = 24) -> Bool {
        guard downloadedAt > 0, line == currentLine,
              !shellBuild.isEmpty, shellBuild == currentShellBuild else { return true }
        let age = now - Double(downloadedAt) / 1000
        // 系统时间回拨也视作过期，避免未来时间戳让旧快照长期无法更新。
        return age < 0 || age >= Double(maxAgeHours) * 3600
    }
}
