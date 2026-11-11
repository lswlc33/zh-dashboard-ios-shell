import Foundation

// 面板线路桥。对应安卓 PanelLine 的五个同步方法，但语义按 iOS 收敛：
// 切换线路 = 换基址 + 让快照失效，下一次进入面板重新初始化。
// 安卓的 beginPanelLine 已经改成「同步完成」，poll 恒失败，这里照抄同一形状，
// 避免网页侧要写两套分支。
final class IOSPanelLineService: IOSBridgeService {
    let methods = ["panelLineVersion", "panelLineInfo", "beginPanelLine",
                   "pollPanelLine", "cancelPanelLine"]

    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.panel-line", qos: .utility)
    private var generation: UInt64 = 0

    func navigationChanged() {
        worker.async { [weak self] in self?.generation &+= 1 }
    }

    func applicationBackgrounded() {}

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        switch method {
        case "panelLineVersion":
            reply(IOSPanelLine.version, nil)
        case "panelLineInfo":
            reply(IOSPanelLine.infoJSON(), nil)
        case "beginPanelLine":
            begin(args: args, reply: reply)
        case "pollPanelLine":
            // 与安卓一致：begin 已同步完成，poll 永远拿不到票据。
            reply(["ticket": "", "done": true, "ok": false, "error": "unknown_ticket"], nil)
        case "cancelPanelLine":
            reply(false, nil)
        default:
            reply(nil, "unsupported_method")
        }
    }

    private func begin(args: [Any], reply: @escaping (Any?, String?) -> Void) {
        guard let raw = args.first as? String,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lineText = object["line"] as? String,
              let target = IOSPanelLine(rawValue: lineText) else {
            reply(["ticket": "", "done": true, "ok": false, "error": "bad_request"], nil)
            return
        }
        // navigationId 是文档身份：必须与当前页面一致，否则切换会被旧页面当成自己的结果。
        if let navId = object["navigationId"] as? String, !navId.isEmpty,
           navId.utf8.count > 128 {
            reply(["ticket": "", "done": true, "ok": false, "error": "bad_request"], nil)
            return
        }
        let previous = IOSPanelLine.current
        IOSPanelLine.current = target
        worker.async { [weak self] in
            guard let self = self else { return }
            self.generation &+= 1
            // 换线路后旧快照可能来自另一个源，必须重下；只标记失效，不在这里阻塞下载。
            DispatchQueue.main.async {
                reply(["ticket": "", "done": true, "ok": true,
                       "error": "", "phase": "done",
                       "line": target.rawValue, "previous": previous.rawValue,
                       "logicalOrigin": IOSPanelLine.baseURL(for: target).absoluteString,
                       "reinitialize": true], nil)
            }
        }
    }
}
