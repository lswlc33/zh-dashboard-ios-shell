import Foundation
import UIKit
import CommonCrypto

// 两个平台的页面共用方法名；适配层只投影系统能力，不解释车辆帧或复制账号凭据。
final class IOSCompatibilityService: IOSBridgeCancellableService, IOSBridgeBackgroundHandoffService {
    private let ride: IOSRideService
    private let gps: IOSLocationService
    private let system: IOSSystemService
    private let widget: IOSBridgeService
    private let utility: IOSNativeUtilityService
    private var metadataProvider: (() -> [String: Any]?)?

    private static let rideMethods: [String: String] = [
        "beginRideRecording": "ride.begin", "pollRideRecording": "ride.poll",
        "rideRecordingAction": "ride.action", "detachRideRecording": "ride.poll",
        "listRideRecords": "ride.list", "readRideRecord": "ride.detail",
        "deleteRideRecord": "ride.delete", "exportRideRecord": "ride.share"
    ]
    private static let gpsMethods: [String: String] = [
        "beginGpsSpeed": "gps.begin", "pollGpsSpeed": "gps.poll", "endGpsSpeed": "gps.end"
    ]
    private static let systemMethods: [String: String] = [
        "appInfo": "app.info", "copyText": "clipboard.write", "openSettings": "app.settings",
        "setKeepScreenOn": "app.keepScreenOn"
    ]

    init(ride: IOSRideService, gps: IOSLocationService, system: IOSSystemService,
         widget: IOSBridgeService, utility: IOSNativeUtilityService) {
        self.ride = ride; self.gps = gps; self.system = system
        self.widget = widget; self.utility = utility
    }

    var methods: [String] {
        let names = Set(Self.rideMethods.keys).union(Self.gpsMethods.keys)
            .union(Self.systemMethods.keys).union(widget.methods.filter { !$0.contains(".") })
        return ["compat.call"] + names.sorted().map { "compat." + $0 }
    }

    func configureMetadataProvider(_ provider: @escaping () -> [String: Any]?) {
        metadataProvider = provider
    }

    func navigationChanged() {}
    func applicationBackgrounded() {}
    func canFinishInBackground(method: String, args: [Any]) -> Bool { false }

    func cancel(method: String, args: [Any]) {
        guard let value = args.first as? [String: Any], let name = value["method"] as? String,
              let parameters = value["args"] as? [Any] else { return }
        if let native = Self.rideMethods[name] { ride.cancel(method: native, args: rideArgs(name, parameters)) }
        if let native = Self.gpsMethods[name] { gps.cancel(method: native, args: gpsArgs(name, parameters)) }
        if let target = widget as? IOSBridgeCancellableService, widget.methods.contains(name) {
            target.cancel(method: name, args: parameters)
        }
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count == 1, let envelope = args.first as? [String: Any],
              Set(envelope.keys).isSubset(of: ["method", "args", "scope", "navId"]),
              let name = envelope["method"] as? String,
              let parameters = envelope["args"] as? [Any], parameters.count <= 8,
              let scope = envelope["scope"] as? [String: Any],
              let current = metadataProvider?(), IOSNativeUtilityService.matches(scope, current),
              envelope["navId"] as? String == current["navId"] as? String else {
            reply(["ok": false, "reason": "stale_session"], nil); return
        }
        guard method == "compat.call" || method == "compat." + name else {
            reply(["ok": false, "reason": "invalid_method"], nil); return
        }
        if let native = Self.rideMethods[name] {
            guard validNavigation(parameters, current) else { reply(["ok": false, "reason": "stale_navigation"], nil); return }
            if name == "beginRideRecording" {
                guard parameters.count == 4, parameters[1] as? String == current["vin"] as? String,
                      parameters[2] as? String == current["frame"] as? String,
                      parameters[3] is Bool else { reply(["ok": false, "reason": "invalid_arguments"], nil); return }
            }
            ride.handle(method: native, args: rideArgs(name, parameters)) { value, error in
                guard error == nil, let object = value as? [String: Any] else { reply(value, error); return }
                var projected = object
                if name == "detachRideRecording" {
                    // Android detach 只释放页面观察，不停止正在录制的系统服务。
                    projected["detached"] = true
                }
                projected["metadata"] = current
                if let id = object["id"] { projected["ticket"] = id; projected["recordingId"] = id }
                projected["finished"] = object["saved"] as? Bool == true
                projected["busy"] = object["busy"] as? Bool
                    ?? (["saving", "ending"].contains(object["nativeRecordState"] as? String
                        ?? object["recordState"] as? String ?? ""))
                if name == "rideRecordingAction" {
                    projected["accepted"] = object["accepted"] as? Bool == true
                }
                reply(projected, nil)
            }
            return
        }
        if let native = Self.gpsMethods[name] {
            guard validNavigation(parameters, current) else { reply(["ok": false, "reason": "stale_navigation"], nil); return }
            gps.handle(method: native, args: gpsArgs(name, parameters), reply: reply); return
        }
        if name == "setKeepScreenOn" {
            guard parameters.count == 1, let on = parameters.first as? Bool else { reply(nil, "invalid_arguments"); return }
            utility.handle(method: "app.keepScreenOn", args: [["on": on]], reply: reply); return
        }
        if let native = Self.systemMethods[name] {
            // openSettings 的 JS 侧传的是裸字符串 kind（'notifications'/'battery'/'autostart'/'app'），
            // 包成 {kind: …} 交给系统服务分流；其余系统方法保持原签名。
            let values: [Any] = name == "copyText" ? [["text": parameters.first as? String ?? ""]]
                : name == "openSettings" ? [["kind": parameters.first as? String ?? "app"]] : []
            system.handle(method: native, args: values, reply: reply); return
        }
        if widget.methods.contains(name) { widget.handle(method: name, args: parameters, reply: reply); return }
        reply(["ok": false, "reason": "unsupported_method"], nil)
    }

    private func validNavigation(_ args: [Any], _ current: [String: Any]) -> Bool {
        args.first as? String == current["navId"] as? String
    }

    private func rideArgs(_ name: String, _ args: [Any]) -> [Any] {
        if name == "beginRideRecording" {
            return [["vin": args.count > 1 ? args[1] : "", "confirmed": true,
                     "gps": args.count > 3 ? args[3] : true, "backgroundRecording": true]]
        }
        var options: [String: Any] = [:]
        if args.count > 1, let id = args[1] as? String, !id.isEmpty { options["id"] = id }
        if name == "rideRecordingAction", args.count > 2 {
            let action = args[2] as? String ?? ""
            // 自动 GPS 切换是页面偏好，不是 iOS 后台权限；运行中的源开关仍由原生记录控制。
            options["action"] = action
            options["confirmed"] = true
        }
        return [options]
    }

    private func gpsArgs(_ name: String, _ args: [Any]) -> [Any] {
        name == "beginGpsSpeed" ? [["confirmed": true]] : [[:]]
    }
}

// 通用确认/加解密只处理当前可信页面的有界数据，不包含任何车辆协议操作码。
final class IOSNativeUtilityService: IOSBridgeCancellableService {
    let methods = ["ui.confirm", "crypto.aes.decrypt", "crypto.aes.encrypt", "app.keepScreenOn"]
    private var metadataProvider: (() -> [String: Any]?)?
    private var presenterProvider: (() -> UIViewController?)?
    private var confirmation: UUID?
    private var completion: ((Bool) -> Void)?
    private weak var alert: UIAlertController?
    private let worker = DispatchQueue(label: "dashboard.ios.native.crypto", qos: .userInitiated)
    private var epoch: UInt64 = 0
    private var cryptoPending = false

    func configureMetadataProvider(_ provider: @escaping () -> [String: Any]?) { metadataProvider = provider }
    func configurePresenter(_ provider: @escaping () -> UIViewController?) { presenterProvider = provider }

    static func matches(_ supplied: [String: Any], _ current: [String: Any]) -> Bool {
        for key in ["navId", "frame", "accountId", "vin"] {
            guard let value = supplied[key] as? String, !value.isEmpty, value == current[key] as? String else { return false }
        }
        for key in ["epoch", "generation"] {
            guard let value = IOSBridgePolicy.integer(supplied[key]), value == IOSBridgePolicy.integer(current[key]) else { return false }
        }
        return true
    }

    private func accepts(_ options: [String: Any]) -> [String: Any]? {
        guard let current = metadataProvider?(),
              options["navigationId"] as? String == current["navId"] as? String,
              options["frame"] as? String == current["frame"] as? String,
              IOSBridgePolicy.integer(options["epoch"]) == IOSBridgePolicy.integer(current["epoch"]) else { return nil }
        return current
    }

    func navigationChanged() {
        epoch &+= 1
        cancelConfirmation()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func applicationBackgrounded() { epoch &+= 1; cancelConfirmation() }
    func cancel(method: String, args: [Any]) { if method == "ui.confirm" { cancelConfirmation() } }

    @discardableResult
    func requestConsent(title: String, message: String, completion: @escaping (Bool) -> Void) -> (() -> Void)? {
        precondition(Thread.isMainThread)
        guard UIApplication.shared.applicationState == .active, confirmation == nil,
              title.utf8.count <= 256, message.utf8.count <= 2048,
              let presenter = presenterProvider?(), presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else { completion(false); return nil }
        let id = UUID(); confirmation = id; self.completion = completion
        let sheet = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert = sheet
        sheet.addAction(UIAlertAction(title: IOSStrings.cancelButton, style: .cancel) { [weak self] _ in self?.finishConsent(id, approved: false) })
        sheet.addAction(UIAlertAction(title: IOSStrings.continueButton, style: .default) { [weak self] _ in self?.finishConsent(id, approved: true) })
        presenter.present(sheet, animated: true)
        return { [weak self] in
            let cancel = { if self?.confirmation == id { self?.cancelConfirmation() } }
            if Thread.isMainThread { cancel() } else { DispatchQueue.main.async(execute: cancel) }
        }
    }

    private func finishConsent(_ id: UUID, approved: Bool) {
        guard confirmation == id else { return }
        let callback = completion; confirmation = nil; completion = nil; alert = nil
        callback?(approved)
    }
    private func cancelConfirmation() {
        let sheet = alert, id = confirmation
        if let id = id { finishConsent(id, approved: false) }
        sheet?.dismiss(animated: true)
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard args.count == 1, let options = args.first as? [String: Any] else { reply(nil, "invalid_arguments"); return }
        if method == "app.keepScreenOn" {
            guard let on = options["on"] as? Bool else { reply(nil, "invalid_arguments"); return }
            UIApplication.shared.isIdleTimerDisabled = on
            reply(["ok": true, "enabled": on], nil); return
        }
        guard let captured = accepts(options) else { reply(["ok": false, "reason": "stale_session"], nil); return }
        let ticket = epoch
        if method == "ui.confirm" {
            guard let title = options["title"] as? String, let message = options["message"] as? String,
                  let operation = options["operation"] as? String, IOSBridgePolicy.identifier(operation) else {
                reply(nil, "invalid_arguments"); return
            }
            requestConsent(title: title, message: message) { [weak self] approved in
                let current = self?.metadataProvider?()
                let valid = self?.epoch == ticket && current.map { Self.matches(captured, $0) } == true
                reply(["ok": valid, "confirmed": approved && valid, "operation": operation,
                       "scope": captured, "reason": valid ? (approved ? "" : "user_cancelled") : "stale_session"], nil)
            }
            return
        }
        // crypto.aes.encrypt：本地快照（zeeho-panel: scheme）不是 secure context，
        // crypto.subtle 不存在，网页无法自己算车控 secret；由原生代算同样的
        // AES-ECB/PKCS7 单块序列。数据约束与 decrypt 对称（≤16KB、块对齐）。
        guard (method == "crypto.aes.decrypt" || method == "crypto.aes.encrypt"), !cryptoPending,
              options["mode"] as? String == "ecb", options["padding"] as? String == "pkcs7",
              let keyText = options["keyB64"] as? String, keyText.utf8.count <= 44,
              let key = Data(base64Encoded: keyText), [16, 24, 32].contains(key.count),
              let cipherText = options[(method == "crypto.aes.encrypt" ? "plainB64" : "cipherB64")] as? String,
              cipherText.utf8.count <= 24_576,
              let cipher = Data(base64Encoded: cipherText), !cipher.isEmpty, cipher.count <= 16_384,
              cipher.count % kCCBlockSizeAES128 == 0 else { reply(nil, "invalid_crypto_request"); return }
        cryptoPending = true
        worker.async { [weak self] in
            let encrypting = method == "crypto.aes.encrypt"
            var keyBytes = [UInt8](key), cipherBytes = [UInt8](cipher)
            var plain = [UInt8](repeating: 0, count: cipherBytes.count + kCCBlockSizeAES128)
            var written = 0
            let keyCount = keyBytes.count, cipherCount = cipherBytes.count, outputCount = plain.count
            // JS 侧（unlockSecret）自己按 PKCS7 填充后逐 16 字节块独立加密、取每块前 16 字节，
            // 等价于「无填充 ECB」；encrypt 不能再叠一层 PKCS7（会把输出撑长一块），
            // decrypt 保持原 PKCS7 语义不变。
            let options_: CCOptions = encrypting
                ? CCOptions(kCCOptionECBMode)
                : CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding)
            let status = keyBytes.withUnsafeBytes { keyPointer in
                cipherBytes.withUnsafeBytes { cipherPointer in
                    plain.withUnsafeMutableBytes { outputPointer in
                        CCCrypt(encrypting ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                options_,
                                keyPointer.baseAddress, keyCount, nil,
                                cipherPointer.baseAddress, cipherCount,
                                outputPointer.baseAddress, outputCount, &written)
                    }
                }
            }
            let output = status == kCCSuccess ? Data(plain.prefix(written)).base64EncodedString() : nil
            keyBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            cipherBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            plain.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { reply(nil, "service_closed"); return }
                self.cryptoPending = false
                guard self.epoch == ticket, let current = self.metadataProvider?(), Self.matches(captured, current) else {
                    reply(["ok": false, "reason": "stale_session"], nil); return
                }
                guard let output = output else { reply(["ok": false, "reason": "crypto_failed"], nil); return }
                reply(["ok": true, encrypting ? "cipherB64" : "plainB64": output], nil)
            }
        }
    }
}
