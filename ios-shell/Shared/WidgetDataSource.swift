import Foundation

// 小组件的取数策略：「自己拉 + 快照兜底」。
//
// 顺序（每一步失败都往下退，绝不因为上层失败就把卡片清空）：
//   1. 有可用凭据 → 扩展自己调接口（官方 `ZHWidgetExtension` 同款做法）；
//   2. 命中缓存或接口失败 → 合法同完整 owner 的缓存/宿主快照按核心车况采样时间择新；
//   3. 没凭据/缓存不可用 → 读主 App 写的前台快照。
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
    /// 主路径自取缓存的窗口，与小组件 5 分钟刷新档对齐：
    /// 否则 getTimeline 醒来时缓存还年轻，直接命中旧值、整轮都不联网，
    /// 刷新节奏调得再短也读不到新数据。
    public static let fetchCacheSeconds: TimeInterval = 5 * 60
    /// 失败回退与图库预览（loadLocal）沿用 30 分钟口径：
    /// 接口失败时宁可展示 30 分钟内的旧缓存，也不显示占位。
    public static let cacheMaxAgeSeconds = SystemSnapshotFreshness.widgetStatsMaxAgeSeconds

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
                                                          maxAgeSeconds: fetchCacheSeconds) {
                // 车辆切换可能与文件读取并发；命中缓存后也必须复核完整身份，
                // 与网络返回和 loadLocal 的分支保持同一条 fail-closed 规则。
                guard let currentOwner = try? SystemSnapshotStore.currentOwner(),
                      currentOwner == activeOwner,
                      currentOwner.ownerIdentifierString == credential.ownerID,
                      WidgetCredentialStore.read(at: date) == credential else {
                    return currentSnapshot(at: date, reason: "stale_credential")
                }
                return preferredLocal(cached, owner: currentOwner, credential: credential,
                                      at: date, reason: "")
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
                } else if let snapshot = makeSnapshot(vehicle, credential: credential, owner: currentOwner,
                                                      at: completedAt) {
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
                return preferredLocal(cached, owner: currentOwner, credential: credential,
                                      at: completedAt, reason: liveReason)
            }
            return currentSnapshot(at: completedAt, reason: liveReason)
        }
        return currentSnapshot(at: date, reason: liveReason)
    }

    /// 图库预览和时间线超时只读本地；不能再次 await 联网而失去兜底意义。
    public static func loadLocal(at date: Date = Date()) -> WidgetDataSourceResult {
        let active = try? SystemSnapshotStore.currentOwner()
        let credential = WidgetCredentialStore.read(at: date)
        if let active = active, let credential = credential,
           credential.ownerID == active.ownerIdentifierString,
           let cached = WidgetFetchCache.read(ownerID: credential.ownerID, at: date,
                                               maxAgeSeconds: cacheMaxAgeSeconds),
           (try? SystemSnapshotStore.currentOwner()) == active,
           WidgetCredentialStore.read(at: date) == credential {
            return preferredLocal(cached, owner: active, credential: credential, at: date, reason: "")
        }
        return currentSnapshot(at: date, reason: "local_fallback")
    }

    /// 三条本地路径共用整份择新：不拼接字段，避免账号/车辆或不同采样批次混用。
    private static func preferredLocal(_ cached: SystemSnapshot, owner: SystemSnapshotOwner,
                                       credential: WidgetCredential, at date: Date,
                                       reason: String) -> WidgetDataSourceResult {
        let host = currentSnapshot(at: date, reason: reason)
        // 读宿主快照也可能遇到换车/撤权；在交付缓存前再次核对完整 owner 和完整凭据。
        guard (try? SystemSnapshotStore.currentOwner()) == owner,
              host.snapshot.map({ $0.owner == owner }) ?? true,
              owner.ownerIdentifierString == credential.ownerID,
              WidgetCredentialStore.read(at: date) == credential else {
            return currentSnapshot(at: date, reason: "stale_credential")
        }
        // cache store 只按短 id/年龄过滤；此处补齐 schema 与 accountHash 的完整归属校验。
        guard (try? cached.validated(expectedOwner: owner, now: date)) != nil else { return host }
        if let snapshot = host.snapshot, snapshot.owner == owner,
           let hostTime = coreSampleTime(snapshot),
           hostTime > (coreSampleTime(cached) ?? 0) {
            return host
        }
        return WidgetDataSourceResult(snapshot: SystemSnapshotStore.applyingDualDisplay(cached), origin: .cache, reason: reason)
    }

    private static func coreSampleTime(_ snapshot: SystemSnapshot) -> Int64? {
        guard let vehicle = snapshot.vehicle else { return nil }
        // capturedAt / updatedAt 会随骑行、gauge 或统计推进；只能比较有值字段自己的车况时间。
        // 统计字段没有独立的核心采样时间，不能用 statsUpdatedAt 给旧电量续鲜。
        return [vehicle.socPercent == nil ? nil : vehicle.socUpdatedAt,
                vehicle.charging == nil ? nil : vehicle.chargingUpdatedAt,
                vehicle.chargeProgressPercent == nil ? nil : vehicle.chargeProgressUpdatedAt]
            .compactMap { $0 }.max()
    }

    private static func currentSnapshot(at date: Date, reason: String) -> WidgetDataSourceResult {
        // 保留合法的最后车况，过期由展示层标注；读取不能把真实采样时间改成现在。
        do {
            if let snapshot = try SystemSnapshotStore.readCurrent(now: date), snapshot.vehicle != nil {
                return WidgetDataSourceResult(snapshot: SystemSnapshotStore.applyingDualDisplay(snapshot), origin: .snapshot, reason: reason)
            }
        } catch {
            let code = (error as? SystemSnapshotError)?.code ?? "snapshot_read_failed"
            return WidgetDataSourceResult(snapshot: nil, origin: .none, reason: code)
        }
        return WidgetDataSourceResult(snapshot: nil, origin: .none, reason: reason)
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
                                     credential: WidgetCredential, owner: SystemSnapshotOwner,
                                     at date: Date) -> SystemSnapshot? {
        // 沿用刚复核的完整 owner（含 accountHash），不能从短 id 重建并丢掉账号归属。
        guard owner.isValid, owner.ownerIdentifierString == credential.ownerID else { return nil }
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
            statsUpdatedAt: statsAt,
            dualDisplay: SystemSnapshotStore.dualDisplay(expectedOwner: owner))
        // 有效期给足 15 分钟（schema 上限）：扩展自己拉的条目靠 capturedAt 判新旧，
        // expiresAt 只是让 `isStale` 在绘制时有个一致的参考。
        let captured = max(vehicle.sampledAt, statsAt ?? 0)
        let snapshot = SystemSnapshot(owner: owner, capturedAt: captured,
                                      expiresAt: captured + SystemSnapshot.maxLifetimeMs,
                                      vehicle: value)
        return (try? snapshot.validated(expectedOwner: owner, now: date)) == nil ? nil : snapshot
    }
}
