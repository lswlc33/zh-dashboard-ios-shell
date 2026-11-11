import Foundation
import os

// 诊断日志：写进 App 沙盒的 Documents 目录，用户可以用「文件」App 或
// 系统分享直接导出，不需要连电脑、不需要 Xcode。
//
// 为什么不用 NSLog：TrollStore 装的包拿不到 Console.app，真机白屏时
// 用户唯一能给我的就是这份文件。
final class IOSDiagnostics {
    static let shared = IOSDiagnostics()

    private let queue = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.diagnostics", qos: .utility)
    private let fileURL: URL?
    /// 轮转后的上一份日志：`zeeho-ios-diagnostics.log` -> `zeeho-ios-diagnostics-1.log`。
    private let rotatedURL: URL?
    /// 主文件上限。超过就滚到 `-1.log`（覆盖上一份），保证总量不超过 2 倍。
    private static let maxBytes = 512 * 1024

    private init() {
        let manager = FileManager.default
        // Documents 可见（Info.plist 开了 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace）。
        let documents = try? manager.url(for: .documentDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
        let url = documents?.appendingPathComponent("zeeho-ios-diagnostics.log", isDirectory: false)
        fileURL = url
        rotatedURL = documents?.appendingPathComponent("zeeho-ios-diagnostics-1.log", isDirectory: false)
        if let url = url, !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        write("=== session start \(Self.stamp()) ===")
    }

    /// 公开路径，供界面显示。
    var path: String { fileURL?.path ?? "(unavailable)" }

    func log(_ message: String) {
        write(message)
    }

    private func write(_ message: String) {
        let line = "[\(Self.stamp())] \(message)\n"
        // 同时打到 os_log，接电脑时也能看。
        os_log("%{public}@", log: .default, type: .default, line)
        queue.async { [weak self] in
            guard let self = self, let url = self.fileURL else { return }
            guard let data = line.data(using: .utf8) else { return }
            var needsRotate = false
            if let handle = try? FileHandle(forWritingTo: url) {
                // 先写、再判大小，最后一定要把句柄关掉才 rename：
                // 句柄还开着就 moveItem 的话，随后 rotate() 里 createFile 写的是新 inode，
                // 旧句柄的脏页会落在已被移走的文件上（在部分存储卷上会丢掉刚写的这一行）。
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                needsRotate = ((try? handle.offset()) ?? 0) > Self.maxBytes
                try? handle.close()
            }
            guard needsRotate else { return }
            self.rotate()
        }
    }

    /// 超过上限时把主文件滚成 `-1.log` 再重开一个空主文件。
    ///
    /// 以前是 `truncate(atOffset: 0)`：文件直接变 0 字节，注释却写「保留最近的部分」。
    /// 而且截断发生在写完当前行之后，刚写进去的那行也被抹掉——用户被要求交日志时，
    /// 恰好在这一刻证据归零（文件跨启动累积，512KB 一定会到）。
    /// 现在改成整份滚动：旧的 `-1.log` 被覆盖，主文件从空开始，
    /// 上一份最多 512KB 的尾部完整保留，`read()` 会把两份拼起来给用户。
    private func rotate() {
        let manager = FileManager.default
        guard let url = fileURL else { return }
        // 滚动后立刻补一行说明，用户看到的日志里能解释「为什么前面断了」。
        let marker = "[\(Self.stamp())] === 日志已轮转，上一份保留在 -1.log ===\n"
        if let rotated = rotatedURL {
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        } else {
            try? manager.removeItem(at: url)
        }
        manager.createFile(atPath: url.path, contents: nil)
        guard let data = marker.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: data)
    }

    /// 读取日志（含轮转出去的那一份），给界面展示与分享。
    ///
    /// 必须走 `queue.sync`：写是异步的，直接 Data(contentsOf:) 可能读到半行
    /// （写入中途被读走），日志里出现截断的 timestamp 会误导排查。
    func read() -> String {
        queue.sync {
            var text = ""
            if let rotated = rotatedURL, let data = try? Data(contentsOf: rotated),
               let part = String(data: data, encoding: .utf8) {
                text += part
            }
            if let url = fileURL, let data = try? Data(contentsOf: url),
               let part = String(data: data, encoding: .utf8) {
                text += part
            }
            return text.isEmpty ? IOSStrings.diagnosticsEmpty : text
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
