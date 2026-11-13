import Foundation
import UIKit
import UniformTypeIdentifiers
import CommonCrypto
import Darwin

// 通用文件票据不解释车辆协议。只有系统选择器给出的 URL 可进入复制流程，网页永远拿不到路径。
final class IOSNativeFileStreamService: NSObject, IOSBridgeCancellableService,
                                        UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    let methods = ["blob.pick", "blob.poll", "blob.read", "blob.release"]
    static let maxFileBytes = 512 * 1024 * 1024
    static let maxChunkBytes = 65536
    static let maxTypes = 256

    private typealias Reply = (Any?, String?) -> Void
    private struct Failure: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }
    private struct Lease: Equatable {
        let scope: IOSRideScope
        let navigationID: String
        let epoch: Int
        let frame: String
        let revision: UInt64
    }
    private struct Options {
        let mimeTypes: [UTType]
        let pickerTypes: [UTType]
        let extensions: Set<String>
        let maxBytes: Int
    }
    private enum State: Equatable { case picking, preparing, ready, failed }

    // 桥可能先超时；系统 delegate 与 worker 都只消费一次回执。
    private final class Receipt {
        private var callback: Reply?
        init(_ callback: @escaping Reply) { self.callback = callback }
        func finish(_ value: Any) {
            precondition(Thread.isMainThread)
            guard let callback = callback else { return }
            self.callback = nil
            callback(value, nil)
        }
    }
    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        private var coordinator: NSFileCoordinator?
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw Failure("cancelled") }
        }
        func attach(_ value: NSFileCoordinator) throws {
            lock.lock()
            let stopped = cancelled
            if !stopped { coordinator = value }
            lock.unlock()
            if stopped { value.cancel(); throw Failure("cancelled") }
        }
        func detach() { lock.lock(); coordinator = nil; lock.unlock() }
        func cancel() {
            lock.lock(); cancelled = true; let value = coordinator; coordinator = nil; lock.unlock()
            value?.cancel()
        }
    }
    private final class OwnedDirectory {
        let url: URL
        let file: URL
        private var removed = false // 创建、删除均在本服务的串行 worker，不能接受外部路径。
        init() throws {
            let manager = FileManager.default
            let base = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
            url = base.appendingPathComponent("native-blob-" + UUID().uuidString, isDirectory: true)
            file = url.appendingPathComponent("payload", isDirectory: false)
            try manager.createDirectory(at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            do {
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var directory = url; try directory.setResourceValues(values)
            } catch {
                try? manager.removeItem(at: url)
                throw error
            }
        }
        func remove() {
            guard !removed else { return }; removed = true
            try? FileManager.default.removeItem(at: url)
        }
    }
    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ value: stat) throws {
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else {
                throw Failure("not_regular_file")
            }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    private struct Prepared {
        let directory: OwnedDirectory
        let size: Int
        let md5: String
        let fingerprint: Fingerprint
    }
    private final class Job {
        let ticket = UUID().uuidString
        let lease: Lease
        let options: Options
        let cancellation = Cancellation()
        let started = ProcessInfo.processInfo.systemUptime
        var preparingSince: TimeInterval?
        var state = State.picking
        var name = ""
        var error = ""
        var prepared: Prepared?
        var picker: UIDocumentPickerViewController?
        var pickReceipt: Receipt?
        var readReceipt: Receipt?
        init(lease: Lease, options: Options, receipt: Receipt) {
            self.lease = lease; self.options = options; pickReceipt = receipt
        }
    }

    private var scopeProvider: (() -> IOSRideScope?)?
    private var metadataProvider: (() -> [String: Any]?)?
    private var presenterProvider: (() -> UIViewController?)?
    private let worker = DispatchQueue(label: "io.github.lswlc33.dashboard.ios.blob", qos: .userInitiated)
    private var revision: UInt64 = 0
    private var job: Job?
    private var watch: DispatchWorkItem?

    override init() { super.init() }
    func configureScopeProvider(_ provider: @escaping () -> IOSRideScope?) {
        precondition(Thread.isMainThread); navigationChanged(); scopeProvider = provider
    }
    // 使用 IOSBridge.nativeSessionMetadata 的 navId / epoch / frame；页面参数只用于匹配，不能授予 scope。
    func configureMetadataProvider(_ provider: @escaping () -> [String: Any]?) {
        precondition(Thread.isMainThread); navigationChanged(); metadataProvider = provider
    }
    func configurePresenter(_ provider: @escaping () -> UIViewController?) {
        precondition(Thread.isMainThread); presenterProvider = provider
    }
    func navigationChanged() {
        precondition(Thread.isMainThread); revision &+= 1; close("stale_context")
    }
    func applicationBackgrounded() { navigationChanged() }
    func cancel(method: String, args: [Any]) {
        precondition(Thread.isMainThread)
        guard methods.contains(method), let j = job, args.count == 1,
              let object = args.first as? [String: Any], matches(object, j.lease) else { return }
        if method != "blob.pick" && object["ticket"] as? String != j.ticket { return }
        close("cancelled")
    }

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        precondition(Thread.isMainThread)
        let receipt = Receipt(reply)
        do {
            // 没有有效原生归属时先撤销旧票据，也不允许弹出系统选择器。
            if let j = job, !current(j) { close("stale_context") }
            guard methods.contains(method), args.count == 1, let object = args.first as? [String: Any] else {
                throw Failure("invalid_args")
            }
            let common: Set<String> = ["navigationId", "epoch", "frame"]
            let fields: Set<String> = method == "blob.pick" ? ["mime", "extensions", "maxBytes"]
                : method == "blob.read" ? ["ticket", "offset", "length"] : ["ticket"]
            guard Set(object.keys).isSubset(of: common.union(fields)) else { throw Failure("invalid_args") }
            let lease = try capture(object)
            if method == "blob.pick" {
                guard job == nil else { throw Failure("blob_busy") }
                let options = try Self.options(object)
                guard let presenter = presenterProvider?(), presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil, !presenter.isBeingDismissed,
                      !presenter.isBeingPresented else { throw Failure("presenter_unavailable") }
                let j = Job(lease: lease, options: options, receipt: receipt)
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: options.pickerTypes, asCopy: false)
                picker.allowsMultipleSelection = false
                picker.delegate = self
                picker.modalPresentationStyle = .formSheet
                j.picker = picker; job = j
                presenter.present(picker, animated: true) { [weak self, weak j, weak picker] in
                    guard let self = self, let j = j, let picker = picker,
                          self.current(j), j.picker === picker else { return }
                    picker.presentationController?.delegate = self
                }
                picker.presentationController?.delegate = self
                armWatch(j)
                return
            }
            guard let ticket = object["ticket"] as? String, let j = job,
                  ticket == j.ticket, j.lease == lease, current(j) else { throw Failure("invalid_blob_ticket") }
            switch method {
            case "blob.poll": receipt.finish(info(j))
            case "blob.release":
                close("released")
                var result = Self.failure("", ticket: ticket)
                result["ok"] = true; result["released"] = true
                receipt.finish(result)
            case "blob.read":
                guard j.state == .ready, let prepared = j.prepared, j.error.isEmpty else { throw Failure("blob_not_ready") }
                guard j.readReceipt == nil else { throw Failure("blob_busy") }
                guard let offset = IOSBridgePolicy.integer(object["offset"]), offset >= 0, offset <= prepared.size,
                      let length = IOSBridgePolicy.integer(object["length"]), length > 0,
                      length <= Self.maxChunkBytes else { throw Failure("invalid_blob_range") }
                j.readReceipt = receipt
                let queue = worker
                queue.async { [weak self] in
                    let result = Result { try Self.read(prepared, offset: offset, length: length, cancellation: j.cancellation) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.current(j), j.readReceipt === receipt else {
                            receipt.finish(Self.failure("stale_context", ticket: j.ticket)); return
                        }
                        j.readReceipt = nil
                        switch result {
                        case .success(let data):
                            var value = self.info(j)
                            value["offset"] = offset; value["base64"] = data.base64EncodedString()
                            value["length"] = data.count; value["eof"] = offset + data.count == prepared.size
                            receipt.finish(value)
                        case .failure(let error):
                            self.fail(j, Self.code(error)); receipt.finish(self.info(j))
                        }
                    }
                }
            default: throw Failure("unsupported_method")
            }
        } catch { receipt.finish(Self.failure(Self.code(error))) }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        precondition(Thread.isMainThread)
        guard let j = job, j.picker === controller else { return }
        guard current(j) else { close("stale_context"); return }
        detachPicker(j)
        guard urls.count == 1, let source = urls.first, source.isFileURL else { close("invalid_selection"); return }
        let name = source.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              j.options.extensions.isEmpty || j.options.extensions.contains(source.pathExtension.lowercased()) else {
            close("invalid_file_extension_or_name"); return
        }
        j.name = name; j.state = .preparing; j.preparingSince = ProcessInfo.processInfo.systemUptime
        // 回执只有小元数据；复制和摘要完成前 ready 绝不为真，后续用 poll 观察。
        j.pickReceipt?.finish(info(j)); j.pickReceipt = nil
        let queue = worker
        queue.async { [weak self] in
            let result = Result { try Self.prepare(source: source, options: j.options, cancellation: j.cancellation) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current(j), j.state == .preparing else {
                    if case .success(let prepared) = result { queue.async { prepared.directory.remove() } }
                    return
                }
                switch result {
                case .success(let prepared): j.prepared = prepared; j.state = .ready
                case .failure(let error): self.fail(j, Self.code(error))
                }
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        precondition(Thread.isMainThread)
        if job?.picker === controller { close("cancelled") }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        precondition(Thread.isMainThread)
        if job?.picker === presentationController.presentedViewController { close("cancelled") }
    }

    private func capture(_ object: [String: Any]) throws -> Lease {
        guard UIApplication.shared.applicationState == .active,
              let scope = scopeProvider?(), scope.valid,
              let metadata = metadataProvider?(),
              let navigation = metadata["navId"] as? String ?? metadata["navigationId"] as? String,
              IOSBridgePolicy.identifier(navigation),
              let epoch = IOSBridgePolicy.integer(metadata["epoch"]), epoch >= 0,
              scope.generation == String(epoch), let frame = metadata["frame"] as? String,
              !frame.isEmpty, frame.utf8.count <= 256,
              !frame.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("authorized_scope_required")
        }
        let lease = Lease(scope: scope, navigationID: navigation, epoch: epoch, frame: frame, revision: revision)
        guard matches(object, lease) else { throw Failure("stale_context") }
        return lease
    }
    private func matches(_ object: [String: Any], _ lease: Lease) -> Bool {
        object["navigationId"] as? String == lease.navigationID
            && IOSBridgePolicy.integer(object["epoch"]) == lease.epoch && object["frame"] as? String == lease.frame
    }
    private func current(_ j: Job) -> Bool {
        guard job === j, revision == j.lease.revision, scopeProvider?() == j.lease.scope,
              let lease = try? capture(["navigationId": j.lease.navigationID, "epoch": j.lease.epoch,
                                        "frame": j.lease.frame]) else { return false }
        return lease == j.lease
    }
    private func info(_ j: Job) -> [String: Any] {
        var result = Self.failure(j.error, ticket: j.ticket)
        result["name"] = j.name
        result["ready"] = j.state == .ready && j.prepared != nil && j.error.isEmpty
        result["busy"] = j.state == .picking || j.state == .preparing || j.readReceipt != nil
        result["fileSize"] = j.prepared?.size ?? 0; result["md5"] = j.prepared?.md5 ?? ""
        return result
    }
    private static func failure(_ code: String, ticket: String = "") -> [String: Any] {
        let error: Any = code.isEmpty ? NSNull() : ["code": code, "message": code]
        return ["ok": code.isEmpty, "ticket": ticket, "name": "", "fileSize": 0, "md5": "", "ready": false,
                "busy": false, "error": error]
    }
    private static func code(_ error: Error) -> String { (error as? Failure)?.code ?? "file_io_failed" }
    private func detachPicker(_ j: Job) {
        guard let picker = j.picker else { return }; j.picker = nil
        picker.delegate = nil; picker.presentationController?.delegate = nil
        if picker.presentingViewController != nil { picker.dismiss(animated: false) }
    }
    private func close(_ code: String) {
        watch?.cancel(); watch = nil
        guard let j = job else { return }; job = nil; j.cancellation.cancel()
        detachPicker(j)
        let result = Self.failure(code, ticket: j.ticket)
        j.pickReceipt?.finish(result); j.pickReceipt = nil
        j.readReceipt?.finish(result); j.readReceipt = nil
        if let prepared = j.prepared { worker.async { prepared.directory.remove() } }; j.prepared = nil
    }
    private func fail(_ j: Job, _ code: String) {
        guard current(j) else { return }
        j.error = code; j.state = .failed; j.cancellation.cancel()
        if let prepared = j.prepared { worker.async { prepared.directory.remove() } }; j.prepared = nil
    }
    private func armWatch(_ j: Job) {
        let item = DispatchWorkItem { [weak self, weak j] in
            guard let self = self, let j = j, self.job === j else { return }
            guard self.current(j) else { self.close("stale_context"); return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - j.started >= 900 { self.close("blob_expired"); return }
            if j.state == .picking && now - j.started >= 120 { self.close("picker_timeout"); return }
            if j.state == .preparing, let start = j.preparingSince, now - start >= 180 {
                self.fail(j, "file_prepare_timeout")
            }
            self.armWatch(j)
        }
        watch = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private static func options(_ object: [String: Any]) throws -> Options {
        guard let maxBytes = IOSBridgePolicy.integer(object["maxBytes"]), maxBytes > 0,
              maxBytes <= maxFileBytes else { throw Failure("invalid_max_bytes") }
        let mime = object["mime"] ?? ["application/octet-stream"]
        let extensions = object["extensions"] ?? [String]()
        guard let mime = mime as? [String], !mime.isEmpty, mime.count <= maxTypes,
              let extensions = extensions as? [String], extensions.count <= maxTypes else { throw Failure("invalid_file_types") }
        var requested: [UTType] = [], picker: [UTType] = [], allowed = Set<String>()
        for text in mime {
            let value = text.lowercased()
            guard value.utf8.count <= 128,
                  value == "*/*" || value.range(of: "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$", options: .regularExpression) != nil else {
                throw Failure("invalid_mime")
            }
            let type: UTType?
            if value == "*/*" || value == "application/octet-stream" { type = .data }
            else { type = UTType(mimeType: value) }
            guard let type = type, type.conforms(to: .data) else { throw Failure("unsupported_mime") }
            if !requested.contains(where: { $0.identifier == type.identifier }) { requested.append(type); picker.append(type) }
        }
        for text in extensions {
            let value = text.lowercased()
            guard value.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
                throw Failure("invalid_extension")
            }
            allowed.insert(value)
            if let type = UTType(filenameExtension: value, conformingTo: .data),
               !picker.contains(where: { $0.identifier == type.identifier }) { picker.append(type) }
        }
        guard !picker.isEmpty, picker.count <= maxTypes else { throw Failure("too_many_file_types") }
        return Options(mimeTypes: requested, pickerTypes: picker, extensions: allowed, maxBytes: maxBytes)
    }

    private static func prepare(source: URL, options: Options, cancellation: Cancellation) throws -> Prepared {
        try cancellation.check()
        // sandbox 内部的 picker URL 可能无需 scope；false 不是越权放行，后面的协调读取仍须真实成功。
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try cancellation.attach(coordinator)
        defer { cancellation.detach() }
        var coordinationError: NSError?
        var result: Result<Prepared, Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { selected in
            result = Result {
                try cancellation.check()
                guard selected.isFileURL else { throw Failure("invalid_selection") }
                if !options.mimeTypes.contains(where: { $0 == .data }) {
                    let values = try selected.resourceValues(forKeys: [.contentTypeKey])
                    let type = values.contentType ?? UTType(filenameExtension: source.pathExtension, conformingTo: .data)
                    guard let type = type, options.mimeTypes.contains(where: { type.conforms(to: $0) }) else {
                        throw Failure("file_type_not_allowed")
                    }
                }
                let input = try openRead(selected)
                defer { try? input.close() }
                let before = try fingerprint(input.fileDescriptor)
                guard before.size <= off_t(options.maxBytes) else { throw Failure("file_too_big") }
                guard before == (try fingerprint(selected)) else { throw Failure("source_file_changed") }
                let directory = try OwnedDirectory()
                var committed = false
                defer { if !committed { directory.remove() } }
                let output = try openWrite(directory.file)
                do {
                    let (size, md5) = try streamBoundedMD5(input: input, output: output,
                        expectedSize: Int(before.size), maxBytes: options.maxBytes, cancellation: cancellation)
                    guard before == (try fingerprint(input.fileDescriptor)), before == (try fingerprint(selected)) else {
                        throw Failure("source_file_changed")
                    }
                    try output.synchronize(); try output.close(); try cancellation.check()
                    let cached = try fingerprint(directory.file)
                    guard cached.size == off_t(size) else { throw Failure("cache_file_changed") }
                    let prepared = Prepared(directory: directory, size: size, md5: md5, fingerprint: cached)
                    committed = true
                    return prepared
                } catch { try? output.close(); throw error }
            }
        }
        do {
            try cancellation.check()
            if coordinationError != nil { throw Failure("file_coordination_failed") }
            guard let result = result else { throw Failure("file_coordination_failed") }
            return try result.get()
        } catch {
            if case .success(let prepared)? = result { prepared.directory.remove() }
            throw error
        }
    }
    // 单次最多一个 64 KiB 缓冲；MD5 只代表复制内容的摘要，不是发布者签名或文件业务验证。
    private static func streamBoundedMD5(input: FileHandle, output: FileHandle, expectedSize: Int,
                                         maxBytes: Int, cancellation: Cancellation) throws -> (Int, String) {
        var context = CC_MD5_CTX()
        guard CC_MD5_Init(&context) == 1 else { throw Failure("md5_failed") }
        var total = 0
        while true {
            try cancellation.check()
            let part = try autoreleasepool { try input.read(upToCount: maxChunkBytes) ?? Data() }
            if part.isEmpty { break }
            guard part.count <= maxBytes - total else { throw Failure("file_too_big") }
            guard part.count <= expectedSize - total else { throw Failure("source_file_changed") }
            try output.write(contentsOf: part)
            let success = part.withUnsafeBytes { CC_MD5_Update(&context, $0.baseAddress, CC_LONG(part.count)) }
            guard success == 1 else { throw Failure("md5_failed") }
            total += part.count
        }
        guard total == expectedSize else { throw Failure("source_file_changed") }
        try cancellation.check()
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let success = digest.withUnsafeMutableBufferPointer { CC_MD5_Final($0.baseAddress, &context) }
        guard success == 1 else { throw Failure("md5_failed") }
        return (total, digest.map { String(format: "%02x", $0) }.joined())
    }
    private static func read(_ prepared: Prepared, offset: Int, length: Int, cancellation: Cancellation) throws -> Data {
        try cancellation.check()
        let handle = try openRead(prepared.directory.file)
        defer { try? handle.close() }
        guard prepared.fingerprint == (try fingerprint(handle.fileDescriptor)) else { throw Failure("cache_file_changed") }
        try handle.seek(toOffset: UInt64(offset))
        let count = min(length, prepared.size - offset)
        var data = Data()
        while data.count < count {
            try cancellation.check()
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { throw Failure("cache_file_changed") }
            data.append(part)
        }
        try cancellation.check()
        guard prepared.fingerprint == (try fingerprint(handle.fileDescriptor)),
              prepared.fingerprint == (try fingerprint(prepared.directory.file)) else { throw Failure("cache_file_changed") }
        return data
    }
    private static func openRead(_ url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure("file_not_readable") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func openWrite(_ url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure("cache_create_failed") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func fingerprint(_ descriptor: Int32) throws -> Fingerprint {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw Failure("file_stat_failed") }
        return try Fingerprint(value)
    }
    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &value) } ?? -1 }
        guard status == 0 else { throw Failure("file_stat_failed") }
        return try Fingerprint(value)
    }
    deinit {
        watch?.cancel()
        guard let j = job else { return }
        j.cancellation.cancel()
        if let prepared = j.prepared { worker.async { prepared.directory.remove() } }
        DispatchQueue.main.async {
            j.picker?.delegate = nil; j.picker?.presentationController?.delegate = nil
            if j.picker?.presentingViewController != nil { j.picker?.dismiss(animated: false) }
            j.pickReceipt?.finish(IOSNativeFileStreamService.failure("service_closed", ticket: j.ticket))
            j.readReceipt?.finish(IOSNativeFileStreamService.failure("service_closed", ticket: j.ticket))
        }
    }
}
