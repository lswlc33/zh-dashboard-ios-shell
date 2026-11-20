import Foundation
import WebKit

// 缓存管理允许清临时资源和指定诊断日志，不提供当前离线页面或私有存档的删除入口。
final class IOSCacheManagementService: IOSBridgeService {
    let methods = ["cache.stats", "cache.clear"]
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore) { self.dataStore = dataStore }

    private static let websiteTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache
    ]
    private static let clearable: Set<String> = ["webHttp", "panelLeftovers", "iosLogs"]

    // 只在主线程受理清理，并在主线程归还名额。磁盘和日志仍各走自己的队列。
    private static var clearing = false

    func navigationChanged() {}
    func applicationBackgrounded() {}

    func handle(method: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        switch method {
        case "cache.stats":
            guard args.isEmpty else { reply(nil, "invalid_arguments"); return }
            stats(reply: reply)
        case "cache.clear":
            guard args.count == 1, let values = args[0] as? [String], !values.isEmpty,
                  values.count <= Self.clearable.count,
                  Set(values).count == values.count,
                  Set(values).isSubset(of: Self.clearable) else {
                reply(nil, "invalid_categories")
                return
            }
            guard !Self.clearing else { reply(nil, "cache_busy"); return }
            Self.clearing = true
            clear(values: values, reply: reply)
        default:
            reply(nil, "unsupported_method")
        }
    }

    private func stats(reply: @escaping (Any?, String?) -> Void) {
        collect { rows, errors in
            reply(["ok": true, "categories": rows, "errors": errors,
                   "cleared": [String](), "clearErrors": [String](), "statsErrors": errors], nil)
        }
    }

    private func collect(completion: @escaping ([[String: Any]], [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var rows: [[String: Any]] = []
        var errors: [String] = []
        func append(_ values: [[String: Any]]) {
            lock.lock(); rows.append(contentsOf: values); lock.unlock()
        }
        func fail(_ value: String) {
            lock.lock(); errors.append(value); lock.unlock()
        }

        group.enter()
        dataStore.fetchDataRecords(ofTypes: Self.websiteTypes) { records in
            let count = records.count
            let bytes: Any = count == 0 ? (0 as Any) : NSNull()
            append([["id": "webHttp", "title": "网络资源缓存", "bytes": bytes,
                     "count": count, "clearable": count > 0,
                     "note": "图片等资源会按需下载，不删除登录信息。"]])
            group.leave()
        }

        group.enter()
        IOSPanelCache.shared.managementStats { values, statErrors in
            append(values)
            statErrors.forEach(fail)
            group.leave()
        }

        group.enter()
        IOSDiagnostics.shared.storageStats { bytes, files, error in
            append([["id": "iosLogs", "title": "App 启动日志", "bytes": bytes,
                     "count": files, "clearable": files > 0,
                     "note": "用于排查启动和页面加载异常，不包含已导出的副本。"]])
            if let error = error { fail("iosLogs: \(error)") }
            group.leave()
        }

        group.notify(queue: .main) { completion(rows, errors) }
    }

    private func clear(values: [String], reply: @escaping (Any?, String?) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var cleared: [String] = []
        var clearErrors: [String] = []
        func success(_ id: String) {
            lock.lock(); cleared.append(id); lock.unlock()
        }
        func failure(_ id: String, _ code: String) {
            lock.lock(); clearErrors.append("\(id): \(code)"); lock.unlock()
        }

        for id in values {
            group.enter()
            switch id {
            case "webHttp":
                dataStore.removeData(ofTypes: Self.websiteTypes, modifiedSince: .distantPast) {
                    success(id); group.leave()
                }
            case "panelLeftovers":
                IOSPanelCache.shared.clearManagement { error in
                    if let error = error { failure(id, error) } else { success(id) }
                    group.leave()
                }
            case "iosLogs":
                IOSDiagnostics.shared.clearStorage { error in
                    if let error = error { failure(id, error) } else { success(id) }
                    group.leave()
                }
            default:
                failure(id, "invalid_categories")
                group.leave()
            }
        }

        group.notify(queue: .main) {
            Self.clearing = false
            // 清理完成即回执；网页随后重新统计，不能让统计吞掉删除结果。
            reply(["ok": true, "categories": [[String: Any]](),
                   "cleared": cleared, "clearErrors": clearErrors, "statsErrors": [String]()], nil)
        }
    }
}
