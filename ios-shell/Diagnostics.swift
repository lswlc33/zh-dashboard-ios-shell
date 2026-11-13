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
    /// 上次轮转失败的时间。失败后 60 秒内不再尝试，避免「每写一行就重试一次」的自激循环
    /// （主文件超限 → 写一行 → 又超限 → 再轮转 → 再失败）。
    /// 只在 queue 上访问，不需要额外加锁。
    private var rotateFailedAt: Date?
    private static let rotateRetryInterval: TimeInterval = 60

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
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        write("app: version=\(version) build=\(build) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
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
            // 文件只在 init 创建一次，而 Documents 对用户可见（文件 App 里能删、能换成别的文件）。
            // 以前这里 `try? FileHandle(...)` 失败就静默 return，之后整个进程的日志全丢，
            // read() 还显示「暂无日志」——正好把唯一取证通道伪装成「当时真的没日志」。
            //
            // 重建必须**只在文件确实不存在时**做：createFile(atPath:) 对已存在的路径是覆盖写
            // （截断成 0 字节），而 forWritingTo 失败也可能只是瞬时的（保护类未就绪/权限抖动），
            // 那时重建就等于把 512KB 历史清零——正是 rotate 那段注释声称修掉的「证据归零」。
            var handle = try? FileHandle(forWritingTo: url)
            if handle == nil, !FileManager.default.fileExists(atPath: url.path) {
                if FileManager.default.createFile(atPath: url.path, contents: nil),
                   let reopened = try? FileHandle(forWritingTo: url) {
                    handle = reopened
                    self.writeChannelRecovered()
                }
            }
            if let handle = handle {
                // 先写、再判大小，最后一定要把句柄关掉才 rename：
                // 句柄还开着就 moveItem 的话，随后 rotate() 里 createFile 写的是新 inode，
                // 旧句柄的脏页会落在已被移走的文件上（在部分存储卷上会丢掉刚写的这一行）。
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                needsRotate = ((try? handle.offset()) ?? 0) > UInt64(Self.maxBytes)
                try? handle.close()
            }
            guard needsRotate else { return }
            // 轮转失败后退避：主文件停在超限状态，每一行都会重新触发 rotate()。
            // 60 秒内只试一次，否则失败原因（-1.log 是目录/删不掉）会变成无限重试。
            if let failedAt = self.rotateFailedAt,
               Date().timeIntervalSince(failedAt) < Self.rotateRetryInterval { return }
            self.rotate()
        }
    }

    /// 日志文件被删后重建成功时补一行标记，让读日志的人知道前面断过。
    /// 必须同步写：此时仍在 queue 上，再走 write() 会递归派发到同一条串行队列。
    private func writeChannelRecovered() {
        guard let url = fileURL,
              let line = ("[\(Self.stamp())] === 日志文件丢失，已重建（用户可能删过或替换过） ===\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// 超过上限时把主文件滚成 `-1.log` 再重开一个空主文件。
    ///
    /// 以前是 `truncate(atOffset: 0)`：文件直接变 0 字节，注释却写「保留最近的部分」。
    /// 而且截断发生在写完当前行之后，刚写进去的那行也被抹掉——用户被要求交日志时，
    /// 恰好在这一刻证据归零（文件跨启动累积，512KB 一定会到）。
    /// 现在改成整份滚动：旧的 `-1.log` 被覆盖，主文件从空开始，
    /// 上一份最多 512KB 的尾部完整保留，`read()` 会把两份拼起来给用户。
    ///
    /// 关键是**任何一步失败都不许动主文件**：原来的写法先无条件 removeItem(-1.log)、
    /// 再 moveItem（`try?` 吞错），最后无条件 createFile —— 而 createFile 对已存在文件是覆盖写。
    /// 于是只要 -1.log 是目录或删不掉，主文件就被截成 0 字节，只剩一行 marker，
    /// 正好是这段注释声称已经修掉的「证据归零」换了个触发条件。
    /// 现在：move 失败就当作这次不轮转（保留两份、下次再试），总量上界靠「主文件超限才轮转」自然成立。
    private func rotate() {
        let manager = FileManager.default
        guard let url = fileURL, let rotated = rotatedURL else {
            // 没有备份路径（Documents 不可用）：保留主文件，不删除不截断。
            return
        }
        // 滚动后补一行说明，用户看到的日志里能解释「为什么前面断了」。
        let marker = "[\(Self.stamp())] === 日志已轮转，上一份保留在 -1.log ===\n"
        // 先尽量清掉旧的 -1.log。失败也没关系：下面 move 会明确失败，我们就不轮转。
        if manager.fileExists(atPath: rotated.path) {
            try? manager.removeItem(at: rotated)
        }
        // move 失败 = 旧备份清不掉/被占用：放弃本次轮转，主文件原样保留。
        guard (try? manager.moveItem(at: url, to: rotated)) != nil else {
            // 绝不能在这里走 write()/log() 记一行：主文件仍然超过 maxBytes，那一行写完
            // 又会让 needsRotate 成立 → 再次 rotate() → 再次失败，形成自激循环
            // （串行队列永远有活、日志每圈长一行、read() 被饿死）。
            // 失败状态只在内存里记时间戳，由 rotateFailedAt 控制重试频率。
            rotateFailedAt = Date()
            return
        }
        rotateFailedAt = nil
        // move 已成功，主文件路径现在是空的：这里才允许创建新文件。
        guard manager.createFile(atPath: url.path, contents: nil),
              let data = marker.data(using: .utf8),
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
            var mainMissing = false
            if let url = fileURL {
                if let data = try? Data(contentsOf: url), let part = String(data: data, encoding: .utf8) {
                    text += part
                } else {
                    mainMissing = !FileManager.default.fileExists(atPath: url.path)
                }
            }
            // 有内容就先给内容：主日志被用户删掉时 `-1.log` 里往往还留着完整的上一次会话，
            // 只因为主文件缺失就回「文件不存在」会把现有证据藏起来。
            if !text.isEmpty { return text }
            // 两者都空时才区分「文件不存在」（通道坏了）和「文件是空的」（这次真没写）。
            // 混成同一句会把故障伪装成正常。
            if mainMissing { return IOSStrings.diagnosticsMissing }
            return IOSStrings.diagnosticsEmpty
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
