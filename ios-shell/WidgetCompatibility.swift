import Foundation
import CoreFoundation
import ZeehoSystemShared

// 主 router 对 compat.call 的 navId/frame/epoch/source 先核验，再传原 Android method + args。
// 本对象不替代同步 ZeehoShell、不持有 token、不启动录制、云任务或另一套账号存储。
// 所有 callback 都回主线程；cancel 把原参数译成与真正 surface Job 一样的参数，撤销实际操作。
final class IOSWidgetCompatibilityService: IOSBridgeService, IOSBridgeCancellableService {
    let methods = [
        "surfaces.status", "surfaces.control", "widget.status", "widget.settings", "widget.control",
        "liveUpdate.status", "liveUpdate.control", "channels.status", "channels.control",
        "widgetSettings", "widgetSettingsFor", "widgetSettingsForSize", "setWidgetSetting", "setWidgetSettingFor",
        "resetWidgetSettings", "requestAddWidget", "pinWidget", "widgetAddStatus", "refreshWidget", "refreshWidgets",
        "notifyGroups", "setNotifyGroup", "liveUpdateStatus", "liveUpdateStart", "liveUpdateUpdate", "liveUpdateEnd",
        "syncStatus"
    ]
    private let surfaces: IOSSystemSurfacesService
    private var forwards: [UUID: Forward] = [:]
    private var addStatus: [String: Any] = ["ok": false, "supported": true, "pinSupported": false,
        "queued": false, "requested": false, "added": false, "state": "idle"]

    private struct Forward {
        let method: String
        let args: NSArray
        let target: String
        let targetArgs: [Any]
    }
    init(systemSurfaces: IOSSystemSurfacesService) { surfaces = systemSurfaces }
    func navigationChanged() { cancelAll() }
    func applicationBackgrounded() { cancelAll() }
    private func cancelAll() {
        for value in Array(forwards.values) { surfaces.cancel(method: value.target, args: value.targetArgs) }
        forwards.removeAll()
    }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        let matching = forwards.filter { $0.value.method == method && $0.value.args.isEqual(to: args) }
        for (id, value) in matching { surfaces.cancel(method: value.target, args: value.targetArgs); forwards.removeValue(forKey: id) }
        surfaces.cancel(method: method, args: args)
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard methods.contains(method), args.count <= 4 else { throw SystemSnapshotError("unsupported_method") }
            switch method {
            case "surfaces.status", "liveUpdate.status", "liveUpdateStatus", "widget.status":
                try count(args, 0)
                forward(method, args: args, target: "system.surfaces.status", options: [:], reply: reply)
            case "notifyGroups", "channels.status":
                try count(args, 0)
                forward(method, args: args, target: "system.surfaces.status", options: [:]) { value, error in
                    guard var value = value as? [String: Any], value["ok"] as? Bool == true else { reply(value, error); return }
                    let live = value["liveActivities"] as? [String: Any] ?? [:]
                    // 不谎报本地通知各组已配置；只有 charge_progress 映射当前 charging Live Activity。
                    value["allowed"] = live["authorizationEnabled"] as? Bool == true
                    value["groups"] = ["service", "message", "charge_start", "charge_progress", "charge_full", "charge_stop"].map {
                        ["id": $0, "on": $0 == "charge_progress" && live["running"] as? Bool == true && live["kind"] as? String == "charging",
                         "supported": $0 == "charge_progress", "systemService": $0 == "charge_progress" ? "ActivityKit" : "unavailable"] as [String: Any]
                    }
                    reply(value, error)
                }
            case "setNotifyGroup":
                try count(args, 2)
                guard try text(args[0]) == "charge_progress" else { throw SystemSnapshotError("notification_channel_not_mapped") }
                let on = try boolean(args[1])
                var options = try surfaces.compatibilityScopeOptions()
                options["kind"] = "charging"
                forward(method, args: args, target: on ? "liveActivity.start" : "liveActivity.end", options: options, reply: reply)
            case "surfaces.control", "liveUpdate.control", "channels.control", "widget.control":
                let options = try objectArgs(args)
                try control(method, args: args, options: options, reply: reply)
            case "liveUpdateStart", "liveUpdateUpdate", "liveUpdateEnd":
                let options = try objectArgs(args, emptyAllowed: true)
                let action = method == "liveUpdateStart" ? "start" : method == "liveUpdateUpdate" ? "update" : "end"
                try liveAction(method, args: args, action: action, options: options, reply: reply)
            case "widgetSettings", "widgetSettingsFor", "widgetSettingsForSize", "widget.settings":
                if method == "widgetSettings" { try count(args, 0) }
                else if method == "widget.settings" {
                    let options = try objectArgs(args, emptyAllowed: true)
                    guard Set(options.keys).isSubset(of: ["id", "size"]), try widgetID(options["id"] ?? 0) == 0 else {
                        throw SystemSnapshotError("system_widget_editor_required")
                    }
                } else {
                    try count(args, method == "widgetSettingsFor" ? 1 : 2)
                    _ = try widgetID(args[0])
                    if args.count == 2 { _ = try size(args[1]) }
                }
                surfaces.handleWidgetCompatibility(method: method, args: args, operation: "settings", options: [:], reply: reply)
            case "resetWidgetSettings":
                try count(args, 1); _ = try widgetID(args[0])
                surfaces.handleWidgetCompatibility(method: method, args: args, operation: "reset", options: [:], reply: reply)
            case "setWidgetSetting", "setWidgetSettingFor":
                try count(args, method == "setWidgetSetting" ? 2 : 3)
                let offset = method == "setWidgetSetting" ? 0 : 1
                if offset == 1 { _ = try widgetID(args[0]) }
                let key = try text(args[offset])
                let value: Any = ["showName", "showTime"].contains(key) ? try boolean(args[offset + 1]) : try text(args[offset + 1], empty: true)
                guard ["vin", "vehicleID", "showName", "showTime"].contains(key) else {
                    throw SystemSnapshotError("system_widget_style_managed")
                }
                surfaces.handleWidgetCompatibility(method: method, args: args, operation: "set", options: ["key": key, "value": value], reply: reply)
            case "requestAddWidget", "pinWidget":
                guard args.count <= 1 else { throw SystemSnapshotError("invalid_args") }
                if let requested = args.first { _ = try size(requested) }
                surfaces.handleWidgetCompatibility(method: method, args: args, operation: "pin", options: [:]) { [weak self] value, error in
                    if let value = value as? [String: Any] { self?.addStatus = value }
                    reply(value, error)
                }
            case "widgetAddStatus": try count(args, 0); reply(addStatus, nil)
            case "refreshWidget", "refreshWidgets":
                guard args.count <= 1 else { throw SystemSnapshotError("invalid_args") }
                if let id = args.first { _ = try widgetID(id) }
                surfaces.handleWidgetCompatibility(method: method, args: args, operation: "reload", options: [:], reply: reply)
            case "syncStatus":
                try count(args, 1)
                let status = try object(args[0])
                let payload = try foregroundPayload(status)
                forward(method, args: args, target: "system.snapshot", options: payload, reply: reply)
            default: throw SystemSnapshotError("unsupported_method")
            }
        } catch {
            reply(IOSBridgePolicy.failure(method: method, code: (error as? SystemSnapshotError)?.code ?? "invalid_args"), nil)
        }
    }

    private func control(_ method: String, args: [Any], options: [String: Any], reply: @escaping (Any?, String?) -> Void) throws {
        let action = try text(options["action"] as Any)
        if method == "widget.control" || action == "refresh" || action == "pin" {
            guard Set(options.keys).isSubset(of: ["action", "id", "size"]), ["refresh", "pin", "reset"].contains(action) else {
                throw SystemSnapshotError("invalid_args")
            }
            _ = try widgetID(options["id"] ?? 0)
            if let sizeValue = options["size"] { _ = try size(sizeValue) }
            surfaces.handleWidgetCompatibility(method: method, args: args, operation: action == "refresh" ? "reload" : action,
                options: [:], reply: reply)
        } else if ["start", "update", "end"].contains(action) {
            var payload = options; payload.removeValue(forKey: "action")
            try liveAction(method, args: args, action: action, options: payload, reply: reply)
        } else if ["enable", "disable"].contains(action) {
            guard Set(options.keys).isSubset(of: ["action", "snapshot"]) else { throw SystemSnapshotError("invalid_args") }
            var payload: [String: Any]
            if action == "disable" { payload = try surfaces.compatibilityScopeOptions() }
            else { payload = try foregroundPayload(try object(options["snapshot"] as Any)) }
            payload["enable"] = action == "enable"
            forward(method, args: args, target: "system.snapshot", options: payload, reply: reply)
        } else { throw SystemSnapshotError("unsupported_action") }
    }

    private func liveAction(_ method: String, args: [Any], action: String, options: [String: Any], reply: @escaping (Any?, String?) -> Void) throws {
        guard Set(options.keys).isSubset(of: ["id", "kind"]), action != "update" || options["kind"] == nil else {
            throw SystemSnapshotError("invalid_args")
        }
        var scope = try surfaces.compatibilityScopeOptions()
        for (key, value) in options { scope[key] = value }
        forward(method, args: args, target: "liveActivity." + action, options: scope, reply: reply)
    }

    private func forward(_ method: String, args: [Any], target: String, options: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard forwards.count < 8 else { reply(IOSBridgePolicy.failure(method: method, code: "system_surfaces_busy"), nil); return }
        let id = UUID(), targetArgs: [Any] = options.isEmpty ? [] : [options]
        forwards[id] = Forward(method: method, args: args as NSArray, target: target, targetArgs: targetArgs)
        surfaces.handle(method: target, args: targetArgs) { [weak self] value, error in
            self?.forwards.removeValue(forKey: id)
            reply(value, error)
        }
    }

    // 兼容 Android StatusFeed 的真实域时钟；不拿页面调用时间补旧数值，不把 recording/GPS 传入 Shared。
    private func foregroundPayload(_ status: [String: Any]) throws -> [String: Any] {
        var payload = try surfaces.compatibilityScopeOptions()
        guard status["vin"] as? String == payload["vin"] as? String,
              (status["accountId"] as? String).map({ $0 == payload["accountId"] as? String }) ?? true else {
            throw SystemSnapshotError("stale_session")
        }
        let generation = status["generation"] ?? status["sessionId"]
        let generationText = generation as? String ?? IOSBridgePolicy.integer(generation).map(String.init)
        guard generationText == payload["generation"] as? String else { throw SystemSnapshotError("stale_session") }
        if status["source"] as? String == "foreground", status["capturedAt"] != nil {
            let allowed: Set<String> = ["source", "capturedAt", "name", "socPercent", "socUpdatedAt", "charging", "chargingUpdatedAt",
                "chargeProgressPercent", "chargeProgressUpdatedAt"]
            for key in allowed { if let value = status[key] { payload[key] = value } }
            return payload
        }
        if let source = status["source"], source as? String != "foreground" { throw SystemSnapshotError("invalid_snapshot_source") }
        let batteryAt = IOSBridgePolicy.integer(status["batteryAt"]) ?? 0
        let vehicleAt = IOSBridgePolicy.integer(status["vehicleAt"]) ?? 0
        let sampleAt = batteryAt > 0 ? batteryAt : vehicleAt
        guard sampleAt > 0 else { throw SystemSnapshotError("snapshot_timestamp_required") }
        payload["source"] = "foreground"; payload["capturedAt"] = max(sampleAt, vehicleAt)
        if let soc = status["soc"] as? NSNumber, CFGetTypeID(soc) != CFBooleanGetTypeID(), (0...100).contains(soc.doubleValue) {
            payload["socPercent"] = soc; payload["socUpdatedAt"] = sampleAt
        }
        var chargeCode: String?
        var chargeAt = vehicleAt
        if batteryAt > 0, let sample = status["sample"] as? [String: Any],
           IOSBridgePolicy.integer(sample["batteryAt"]) == batteryAt {
            if sample["chargeSource"] as? String == "battery" {
                chargeCode = sample["chargeCode"] as? String; chargeAt = batteryAt
            } else if sample["chargeSource"] as? String == "vehicle",
                      IOSBridgePolicy.integer(sample["vehicleAt"]) == vehicleAt, vehicleAt > 0,
                      abs(vehicleAt - batteryAt) <= 90_000 {
                chargeCode = sample["chargeCode"] as? String
            }
        } else if vehicleAt > 0 { chargeCode = status["chargeCode"] as? String }
        if let code = chargeCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            // 原始业务码只认字符串 1；不让网页 charging=true 或旧 A 的 charging 洗成 B 的新值。
            payload["charging"] = code == "1"; payload["chargingUpdatedAt"] = chargeAt
        }
        if let name = status["vehicleName"] as? String, !name.isEmpty { payload["name"] = name }
        return payload
    }
    private func count(_ args: [Any], _ expected: Int) throws {
        guard args.count == expected else { throw SystemSnapshotError("invalid_args") }
    }
    private func objectArgs(_ args: [Any], emptyAllowed: Bool = false) throws -> [String: Any] {
        if emptyAllowed && args.isEmpty { return [:] }
        try count(args, 1); return try object(args[0])
    }
    private func object(_ value: Any) throws -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        guard let text = value as? String, text.utf8.count <= 16 * 1024, let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SystemSnapshotError("invalid_args") }
        return object
    }
    private func text(_ value: Any, empty: Bool = false) throws -> String {
        guard let text = value as? String, (empty || !text.isEmpty), text.utf8.count <= 256,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SystemSnapshotError("invalid_args") }
        return text
    }
    private func boolean(_ value: Any) throws -> Bool {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        if let text = value as? String, ["0", "1", "false", "true"].contains(text) { return text == "1" || text == "true" }
        throw SystemSnapshotError("invalid_args")
    }
    private func widgetID(_ value: Any) throws -> Int {
        guard let id = IOSBridgePolicy.integer(value), id >= 0 else { throw SystemSnapshotError("invalid_widget_id") }
        guard id == 0 else { throw SystemSnapshotError("system_widget_editor_required") }
        return id
    }
    private func size(_ value: Any) throws -> String {
        let size = try text(value)
        guard ["1x1", "2x2", "4x2", "4x4", "systemSmall", "systemMedium", "systemLarge"].contains(size) else {
            throw SystemSnapshotError("unsupported_widget_family")
        }
        return size
    }
}
