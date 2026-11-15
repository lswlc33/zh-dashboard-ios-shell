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
        let activeOwner = (try? SystemSnapshotStore.currentOwner())?.ownerIdentifierString
        // 不用 `flatMap`：闭包里 `return nil` 与返回 `WidgetCredential` 混在一起时
        // 泛型参数推不出来（CI 实测 "generic parameter 'U' could not be inferred"）。
        let stored = WidgetCredentialStore.read(at: date)
        let credential: WidgetCredential? = {
            guard let stored = stored, let activeOwner = activeOwner,
                  stored.ownerID == activeOwner else { return nil }
            return stored
        }()
        var liveReason = "no_credential"
        if let credential = credential {
            if !force, let cached = WidgetFetchCache.read(ownerID: credential.ownerID, at: date,
                                                          maxAgeSeconds: cacheMaxAgeSeconds) {
                return WidgetDataSourceResult(snapshot: cached, origin: .cache, reason: "")
            }
            switch await WidgetVehicleClient.fetch(credential, at: date) {
            case .success(let vehicle):
                let snapshot = makeSnapshot(vehicle, credential: credential, at: date)
                WidgetFetchCache.write(snapshot)
                return WidgetDataSourceResult(snapshot: snapshot, origin: .live, reason: "")
            case .failure(let error):
                liveReason = error.code
                // 接口挂了但缓存还在：先用缓存，别退回更旧的宿主快照。
                if let cached = WidgetFetchCache.read(ownerID: credential.ownerID, at: date,
                                                      maxAgeSeconds: cacheMaxAgeSeconds) {
                    return WidgetDataSourceResult(snapshot: cached, origin: .cache, reason: error.code)
                }
            }
        }
        // 兜底：主 App 前台快照（原有行为，未授权用户/弱网都走这里）。
        if let snapshot = try? SystemSnapshotStore.readCurrent(now: date),
           isUsable(snapshot, at: date) {
            return WidgetDataSourceResult(snapshot: snapshot, origin: .snapshot, reason: liveReason)
        }
        return WidgetDataSourceResult(snapshot: nil, origin: .none, reason: liveReason)
    }

    /// 只做时间与归属检查：快照本身已由 store 校验过结构，这里补一条「多久内的还能展示」。
    private static func isUsable(_ snapshot: SystemSnapshot, at date: Date) -> Bool {
        guard let vehicle = snapshot.vehicle else { return false }
        let age = date.timeIntervalSince1970 - Double(vehicle.updatedAt) / 1000
        return age >= -SystemSnapshotFreshness.futureToleranceSeconds && age < snapshotMaxAgeSeconds
    }

    /// 把接口结果拼成共享 schema 的快照。
    ///
    /// 时间全部用**响应到达时刻**（`sampledAt` / `statsUpdatedAt`），不用服务端的
    /// `refreshTime`：那个是车机上报时间，可能比本地时钟旧几分钟，会让卡片一加上就「可能已过期」。
    private static func makeSnapshot(_ vehicle: WidgetFetchedVehicle,
                                     credential: WidgetCredential, at date: Date) -> SystemSnapshot {
        let owner = SystemSnapshotStore.ownerIdentifier(credential.ownerID)
            ?? SystemSnapshotOwner(scopeID: "unknown", accountVINHash: String(repeating: "0", count: 64))
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
        return SystemSnapshot(owner: owner, capturedAt: captured,
                              expiresAt: captured + SystemSnapshot.maxLifetimeMs,
                              vehicle: value)
    }
}
