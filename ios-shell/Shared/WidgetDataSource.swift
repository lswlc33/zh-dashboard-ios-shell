import Foundation

// 小组件的取数策略：「自己拉 + 快照兜底」。
//
// 顺序（每一步失败都往下退，绝不因为上层失败就把卡片清空）：
//   1. 有可用凭据 → 扩展自己调接口（官方 `ZHWidgetExtension` 同款做法）；
//   2. 接口失败/没凭据 → 读上一次自己拉到的缓存（30 分钟内有效）；
//   3. 都没有 → 读主 App 写的前台快照（原有链路，也是现在唯一的数据来源）。
//
// 这样既拿到「自己拉」的三个好处（无 180 秒 TTL、无残留 vehicleID、不依赖宿主存活），
// 又保留了弱网/未授权时的老行为。**任何异常都不得让卡片变成空白**——只有三条路
// 都真的没有数据时才如实显示「车况暂无数据」。
public struct WidgetDataSourceResult: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        /// 扩展自己拉的（最新）。
        case live
        /// 扩展自己拉过的缓存。
        case cache
        /// 主 App 前台快照。
        case snapshot
        case none
    }

    public let snapshot: SystemSnapshot?
    public let origin: Origin
    /// 诊断码：live 成功为空；失败时是 `WidgetFetchError.code` 或 `snapshot_*`。
    public let reason: String

    public init(snapshot: SystemSnapshot?, origin: Origin, reason: String) {
        self.snapshot = snapshot
        self.origin = origin
        self.reason = reason
    }
}

public enum WidgetDataSource {
    /// 自己拉的缓存有效期：与小组件统计窗口同口径（30 分钟）。
    public static let cacheMaxAgeSeconds = SystemSnapshotFreshness.widgetStatsMaxAgeSeconds
    /// 快照兜底的有效期：与 `WidgetFreshness.maxAgeSeconds` 同口径（30 分钟）。
    /// 这里刻意不用 180 秒——那是会话级窗口，用它会让小组件刚加上三分钟就空白。
    public static let snapshotMaxAgeSeconds = 30 * 60.0

    /// 取一次数据。`force` 为 true 时（刷新按钮）跳过缓存直接打接口。
    public static func load(at date: Date = Date(), force: Bool = false) async -> WidgetDataSourceResult {
        // **必须核对 active owner**：凭据是「某账号某车」的，而 active-owner.json 才是
        // 「主页当前车辆」。两者不一致（换了账号/换了车、宿主还没重写凭据）时
        // 绝不能用旧凭据继续拉——那正是报告点名的「残留 vehicleID 显示别的车」。
        let activeOwner = try? SystemSnapshotStore.currentOwner()
        let activeOwnerID = activeOwner?.ownerIdentifierString
        // 不用 `flatMap`：闭包里 `return nil` 与返回 `WidgetCredential` 混在一起时
        // 泛型参数推不出来（CI 实测 "generic parameter 'U' could not be inferred"）。
        let stored = WidgetCredentialStore.read(at: date)
        let credential: WidgetCredential? = {
            guard let stored = stored, let activeOwnerID = activeOwnerID,
                  stored.ownerID == activeOwnerID else { return nil }
            return stored
        }()
        var liveReason = "no_credential"
        if let credential = credential {
            if !force, let cached = WidgetFetchCache.read(ownerID: credential.ownerID, at: date,
                                                          maxAgeSeconds: cacheMaxAgeSeconds) {
                return WidgetDataSourceResult(snapshot: cached, origin: .cache, reason: "")
            }
            let result = await WidgetVehicleClient.fetch(credential, at: date)
            let completedAt = Date()
            // success / failure 都会继续读写数据，必须在分流前复核完整授权。
            // 只比 owner 会漏掉同车换 token、换密钥和撤权；Equatable 也包含 updatedAt。
            guard let currentOwner = try? SystemSnapshotStore.currentOwner(),
                  currentOwner == activeOwner,
                  currentOwner.ownerIdentifierString == credential.ownerID,
                  WidgetCredentialStore.read(at: completedAt) == credential else {
                return currentSnapshot(at: completedAt, reason: "stale_credential")
            }
            switch result {
            case .success(let vehicle):
                // 车名、充电态或账号统计不等于核心测量成功，空 live 不能盖掉好缓存。
                if !vehicle.hasCoreMeasurements {
                    liveReason = "no_data"
                } else if let snapshot = makeSnapshot(vehicle, credential: credential, at: completedAt) {
                    WidgetFetchCache.write(snapshot)
                    return WidgetDataSourceResult(snapshot: snapshot, origin: .live, reason: "")
                } else {
                    liveReason = "snapshot_invalid"
                }
            case .failure(let error):
                liveReason = error.code
            }
            // 只有 await 后授权仍完整匹配，才允许失败/空结果回退到该凭据的缓存。
            if let cached = WidgetFetchCache.read(ownerID: credential.ownerID, at: completedAt,
                                                  maxAgeSeconds: cacheMaxAgeSeconds) {
                return WidgetDataSourceResult(snapshot: cached, origin: .cache, reason: liveReason)
            }
            return currentSnapshot(at: completedAt, reason: liveReason)
        }
        return currentSnapshot(at: date, reason: liveReason)
    }

    private static func currentSnapshot(at date: Date, reason: String) -> WidgetDataSourceResult {
        // 兜底只读当前 active owner 的宿主快照，绝不再用在途请求捕获的 owner。
        if let snapshot = try? SystemSnapshotStore.readCurrent(now: date),
           isUsable(snapshot, at: date) {
            return WidgetDataSourceResult(snapshot: snapshot, origin: .snapshot, reason: reason)
        }
        return WidgetDataSourceResult(snapshot: nil, origin: .none, reason: reason)
    }

    /// 只做时间与归属检查：快照本身已由 store 校验过结构，这里补一条「多久内的还能展示」。
    private static func isUsable(_ snapshot: SystemSnapshot, at date: Date) -> Bool {
        guard let vehicle = snapshot.vehicle else { return false }
        let age = date.timeIntervalSince1970 - Double(vehicle.updatedAt) / 1000
        return age >= -SystemSnapshotFreshness.futureToleranceSeconds && age < snapshotMaxAgeSeconds
    }

    /// 把接口结果拼成共享 schema 的快照。构造不出合规数据就返回 nil（调用方退回缓存/快照）。
    ///
    /// 时间全部用**响应到达时刻**（`sampledAt` / `statsUpdatedAt`），不用服务端的
    /// `refreshTime`：那个是车机上报时间，可能比本地时钟旧几分钟，会让卡片一加上就「可能已过期」。
    ///
    /// **必须自己过一遍 `validated()`**：这份快照会进缓存、被扩展当权威数据渲染，
    /// 一旦违反 schema（时间倒挂、owner 非法、数值越界）就该当场失败，
    /// 而不是等渲染时显示成一片「--」还查不出原因。
    private static func makeSnapshot(_ vehicle: WidgetFetchedVehicle,
                                     credential: WidgetCredential, at date: Date) -> SystemSnapshot? {
        // owner 必须能从凭据解析出来；解析不出说明凭据本身坏了，直接失败。
        guard let owner = SystemSnapshotStore.ownerIdentifier(credential.ownerID) else { return nil }
        let suffix = credential.vin.utf8.count > 6 ? String(credential.vin.suffix(4)) : nil
        let statsAt = vehicle.statsUpdatedAt
        let value = SystemVehicleSnapshot(
            name: vehicle.name, vinDisplaySuffix: suffix,
            socPercent: vehicle.socPercent, socUpdatedAt: vehicle.socPercent == nil ? nil : vehicle.sampledAt,
            charging: vehicle.charging, chargingUpdatedAt: vehicle.charging == nil ? nil : vehicle.sampledAt,
            chargeProgressPercent: vehicle.chargeProgressPercent,
            chargeProgressUpdatedAt: vehicle.chargeProgressPercent == nil ? nil : vehicle.sampledAt,
            updatedAt: max(vehicle.sampledAt, statsAt ?? 0),
            voltage: vehicle.voltage, current: vehicle.current, power: vehicle.power,
            lockState: vehicle.lockState, seatState: vehicle.seatState, online: vehicle.online,
            todayMileKm: vehicle.todayMileKm, lastMileKm: vehicle.lastMileKm,
            lastRideMinutes: vehicle.lastRideMinutes, totalMileKm: vehicle.totalMileKm,
            rangeKm: vehicle.rangeKm, integral: vehicle.integral, unread: vehicle.unread,
            tireFrontBar: vehicle.tireFrontBar, tireRearBar: vehicle.tireRearBar,
            tireFrontTemp: vehicle.tireFrontTemp, tireRearTemp: vehicle.tireRearTemp,
            statsUpdatedAt: statsAt)
        // 有效期给足 15 分钟（schema 上限）：扩展自己拉的条目靠 capturedAt 判新旧，
        // expiresAt 只是让 `isStale` 在绘制时有个一致的参考。
        let captured = max(vehicle.sampledAt, statsAt ?? 0)
        let snapshot = SystemSnapshot(owner: owner, capturedAt: captured,
                                      expiresAt: captured + SystemSnapshot.maxLifetimeMs,
                                      vehicle: value)
        return (try? snapshot.validated(expectedOwner: owner, now: date)) == nil ? nil : snapshot
    }
}
