import Foundation

// 面板线路桥。切换只保存后续更新来源，当前文档与账号保持不变。
// begin 回执就是终态；poll 保留旧接口但不制造轮询票据。
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
        guard !IOSPanelCache.shared.snapshot().busy else {
            reply(["ticket": "", "done": true, "ok": false, "error": "panel_update_busy"], nil)
            return
        }
        let previous = IOSPanelLine.current
        // markChosen 而不是直接赋 current：选中默认值（GitHub）时 setter 会直接 return，
        // 偏好键不落盘 → 网页永远认为「还没选过」→ 每次检查都再弹选择页。
        IOSPanelLine.markChosen(target)
        worker.async { [weak self] in
            guard let self = self else { return }
            self.generation &+= 1
            // 只确认已保存偏好，不启动下载或重载当前文档。
            DispatchQueue.main.async {
                reply(["ticket": "", "done": true, "ok": true,
                       "error": "", "phase": "done",
                       "line": target.rawValue, "previous": previous.rawValue,
                       "logicalOrigin": IOSPanelLine.baseURL(for: target).absoluteString,
                       "reinitialize": false], nil)
            }
        }
    }
}
