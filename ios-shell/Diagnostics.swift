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
    private static let maxBytes = 512 * 1024

    private init() {
        let manager = FileManager.default
        // Documents 可见（Info.plist 开了 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace）。
        let documents = try? manager.url(for: .documentDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
        let url = documents?.appendingPathComponent("zeeho-ios-diagnostics.log", isDirectory: false)
        fileURL = url
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
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                // 超过上限就截断前半，保留最近的部分。
                if let size = try? handle.offset(), size > Self.maxBytes {
                    try? handle.truncate(atOffset: 0)
                }
            }
        }
    }

    /// 读取全部日志，给界面展示与分享。
    func read() -> String {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "(no log)" }
        return text
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
