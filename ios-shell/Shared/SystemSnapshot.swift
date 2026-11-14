import Foundation

// 主 App 与 extension 只交换这一份白名单；所有时间是数据/状态事件的 Unix 毫秒，不能在读取时改成现在。
public struct SystemSnapshotError: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

public struct SystemSnapshotOwner: Codable, Equatable, Hashable, Sendable {
    public let scopeID: String
    public let accountVINHash: String
    // 仅用于同账号多车目录的匿名隔离；旧 v1 owner 没有此字段，仍只能按单车读取。
    public let accountHash: String?
    public init(scopeID: String, accountVINHash: String, accountHash: String? = nil) {
        self.scopeID = scopeID; self.accountVINHash = accountVINHash; self.accountHash = accountHash
    }
    public func sharesAccount(with other: SystemSnapshotOwner) -> Bool {
        if let account = accountHash, let otherAccount = other.accountHash { return account == otherAccount }
        return accountVINHash == other.accountVINHash
    }
    /// AppIntent 实体/配置用的匿名 id（与 SystemWidgetVehicle.id 同一拼法）。
    /// 只暴露两个 hash，不含 VIN 与账号名。
    public var ownerIdentifierString: String { accountVINHash + "." + scopeID }
    public var isValid: Bool {
        !scopeID.isEmpty && scopeID.utf8.count <= 96
            && scopeID.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value)
                    || (97...122).contains($0.value) || [45, 95].contains($0.value)
            }
            && accountVINHash.utf8.count == 64
            && accountVINHash.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
            && (accountHash.map { $0.utf8.count == 64 && $0.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            } } ?? true)
    }
}

public enum SystemSnapshotFreshness {
    public static let vehicleMaxAgeSeconds: Double = 180
    public static let rideSpeedMaxAgeSeconds: Double = 10
    // 统计类（里程/胎压/积分/电压电流功率）变化慢，与桌面小组件 30 分钟窗口对齐；
    // 用 180 秒判会让这些整块恒为空。
    public static let widgetStatsMaxAgeSeconds: Double = 30 * 60
    public static let futureToleranceSeconds: Double = 30
    public static func isFresh(_ timestamp: Int64?, at date: Date = Date(), maxAgeSeconds: Double) -> Bool {
        guard let timestamp = timestamp else { return false }
        let age = date.timeIntervalSince1970 - Double(timestamp) / 1000
        return age >= -futureToleranceSeconds && age < maxAgeSeconds
    }
}

public struct SystemVehicleSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String?
    public let vinDisplaySuffix: String?
    public let socPercent: Double?
    public let socUpdatedAt: Int64?
    public let charging: Bool?
    public let chargingUpdatedAt: Int64?
    public let chargeProgressPercent: Double?
    public let chargeProgressUpdatedAt: Int64?
    public let updatedAt: Int64
    // ---- 与 Android 小组件 1:1 对齐所需的展示字段 ----
    // 全部是可缺席的匿名标量：缺测就是 nil，绝不补 0 或拿旧值顶替。
    // 只用于桌面/锁屏展示，不参与身份、凭据或位置。
    public let voltage: Double?          // V，0.1 精度
    public let current: Double?          // A
    public let power: Double?            // W（负值为回充）
    public let lockState: Int?           // 1=已锁 0=未锁 nil=未知
    public let seatState: Int?           // 1=已锁 0=未锁 nil=未知
    public let online: Int?              // 1=在线 0=离线 nil=未知
    public let todayMileKm: Double?      // 今日骑行
    public let lastMileKm: Double?       // 上次骑行
    public let lastRideMinutes: Double?  // 上次骑行时长
    public let totalMileKm: Double?      // 总里程
    public let rangeKm: Double?          // 仪表续航（官方未校准）
    public let integral: Double?         // 积分
    public let unread: Int?              // 未读消息
    public let tireFrontBar: Double?     // 前轮胎压
    public let tireRearBar: Double?      // 后轮胎压
    public let tireFrontTemp: Double?    // 前胎温度
    public let tireRearTemp: Double?     // 后胎温度
    public let statsUpdatedAt: Int64?    // 上述统计字段的统一采样时间

    public init(name: String? = nil, vinDisplaySuffix: String? = nil, socPercent: Double? = nil,
                socUpdatedAt: Int64? = nil, charging: Bool? = nil, chargingUpdatedAt: Int64? = nil,
                chargeProgressPercent: Double? = nil, chargeProgressUpdatedAt: Int64? = nil, updatedAt: Int64,
                voltage: Double? = nil, current: Double? = nil, power: Double? = nil,
                lockState: Int? = nil, seatState: Int? = nil, online: Int? = nil,
                todayMileKm: Double? = nil, lastMileKm: Double? = nil, lastRideMinutes: Double? = nil,
                totalMileKm: Double? = nil, rangeKm: Double? = nil, integral: Double? = nil, unread: Int? = nil,
                tireFrontBar: Double? = nil, tireRearBar: Double? = nil,
                tireFrontTemp: Double? = nil, tireRearTemp: Double? = nil, statsUpdatedAt: Int64? = nil) {
        self.name = name; self.vinDisplaySuffix = vinDisplaySuffix; self.socPercent = socPercent
        self.socUpdatedAt = socUpdatedAt; self.charging = charging; self.chargingUpdatedAt = chargingUpdatedAt
        self.chargeProgressPercent = chargeProgressPercent; self.chargeProgressUpdatedAt = chargeProgressUpdatedAt
        self.updatedAt = updatedAt
        self.voltage = voltage; self.current = current; self.power = power
        self.lockState = lockState; self.seatState = seatState; self.online = online
        self.todayMileKm = todayMileKm; self.lastMileKm = lastMileKm; self.lastRideMinutes = lastRideMinutes
        self.totalMileKm = totalMileKm; self.rangeKm = rangeKm; self.integral = integral; self.unread = unread
        self.tireFrontBar = tireFrontBar; self.tireRearBar = tireRearBar
        self.tireFrontTemp = tireFrontTemp; self.tireRearTemp = tireRearTemp
        self.statsUpdatedAt = statsUpdatedAt
    }
    // 云端时间是接口同步时间，不宣称是传感器时间；缺时间或超过 180 秒一律显示未知。
    public func visibleSOCPercent(at date: Date = Date()) -> Double? {
        SystemSnapshotFreshness.isFresh(socUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? socPercent : nil
    }
    public func visibleCharging(at date: Date = Date()) -> Bool? {
        SystemSnapshotFreshness.isFresh(chargingUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? charging : nil
    }
    public func visibleChargeProgress(at date: Date = Date()) -> Double? {
        SystemSnapshotFreshness.isFresh(chargeProgressUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? chargeProgressPercent : nil
    }
    /// 统计类字段（里程/胎压/积分等）变化慢，用与桌面小组件一致的 30 分钟窗口；
    /// 缺测就是 nil，不参与「未知」以外的任何推断。
    public var hasStatistics: Bool {
        statsUpdatedAt != nil && (voltage != nil || tireFrontBar != nil || tireRearBar != nil
            || todayMileKm != nil || lastMileKm != nil || totalMileKm != nil
            || rangeKm != nil || integral != nil || unread != nil
            || current != nil || power != nil || lastRideMinutes != nil)
    }
    /// 前后胎压都没有时（无胎压车型），展示层让位给总里程 —— 与 Android 判据完全一致：
    /// 只有「两个传感器都没上报」才让位，只缺一侧仍显示「—」。
    public var hasTirePressure: Bool { tireFrontBar != nil || tireRearBar != nil }
    // 状态类字段（锁车/坐垫/在线）用与车况标量相同的 180 秒窗口：
    // 它们是「当前状态」，过期后就不该再宣称已锁车/在线。
    /// 锁车状态：1 = 已锁、0 = 未锁、nil = 未知。
    public func visibleLockState(at date: Date = Date()) -> Int? {
        SystemSnapshotFreshness.isFresh(statsUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? lockState : nil
    }
    public func visibleSeatState(at date: Date = Date()) -> Int? {
        SystemSnapshotFreshness.isFresh(statsUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? seatState : nil
    }
    public func visibleOnlineState(at date: Date = Date()) -> Int? {
        SystemSnapshotFreshness.isFresh(statsUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.vehicleMaxAgeSeconds)
            ? online : nil
    }
    /// 统计类字段的可见性：里程/胎压/积分等用 30 分钟宽窗口。
    public func visibleStatistics(at date: Date = Date()) -> Bool {
        SystemSnapshotFreshness.isFresh(statsUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.widgetStatsMaxAgeSeconds)
    }
    public func visibleTires(at date: Date = Date()) -> Bool {
        SystemSnapshotFreshness.isFresh(statsUpdatedAt, at: date, maxAgeSeconds: SystemSnapshotFreshness.widgetStatsMaxAgeSeconds)
    }
    public func visibleVoltage(at date: Date = Date()) -> Double? {
        visibleStatistics(at: date) ? voltage : nil
    }
    public func visibleCurrent(at date: Date = Date()) -> Double? {
        visibleStatistics(at: date) ? current : nil
    }
    public func visiblePower(at date: Date = Date()) -> Double? {
        visibleStatistics(at: date) ? power : nil
    }
    public func visibleTotalMile(at date: Date = Date()) -> Double? {
        visibleStatistics(at: date) ? totalMileKm : nil
    }
    public func visibleRange(at date: Date = Date()) -> Double? {
        visibleStatistics(at: date) ? rangeKm : nil
    }
}

public enum SystemRideState: String, Codable, Hashable, Sendable {
    case waiting, recording, paused, interrupted, ended
}

public struct SystemRideSnapshot: Codable, Equatable, Hashable, Sendable {
    public let state: SystemRideState
    public let startedAt: Int64
    public let updatedAt: Int64
    public let speedKph: Double?
    public let speedUpdatedAt: Int64?
    public let lastLocationAt: Int64?
    public let lastSignalAt: Int64?
    public let locationAgeSeconds: Double?
    public let elapsedSeconds: Double?
    public let gapCount: Int?
    public init(state: SystemRideState, startedAt: Int64, updatedAt: Int64, speedKph: Double? = nil,
                speedUpdatedAt: Int64? = nil, lastLocationAt: Int64? = nil, lastSignalAt: Int64? = nil,
                locationAgeSeconds: Double? = nil, elapsedSeconds: Double? = nil, gapCount: Int? = nil) {
        self.state = state; self.startedAt = startedAt; self.updatedAt = updatedAt; self.speedKph = speedKph
        self.speedUpdatedAt = speedUpdatedAt; self.lastLocationAt = lastLocationAt; self.lastSignalAt = lastSignalAt
        self.locationAgeSeconds = locationAgeSeconds; self.elapsedSeconds = elapsedSeconds; self.gapCount = gapCount
    }
    // Widget/实时活动不会采样 GPS；过期速度必须留空，不能让最后一次车速永远显示为实时速度。
    public func visibleSpeedKph(at date: Date = Date()) -> Double? {
        guard state == .recording, let speed = speedKph, let at = speedUpdatedAt else { return nil }
        return SystemSnapshotFreshness.isFresh(at, at: date,
                    maxAgeSeconds: SystemSnapshotFreshness.rideSpeedMaxAgeSeconds) ? speed : nil
    }
}

// 只由已接受的原生 BLE/GPS 样本构造；不代表已录制行程，不携带位置坐标。
public enum SystemGaugeSource: String, Codable, Hashable, Sendable { case ble, gps }
public struct SystemGaugeSnapshot: Codable, Equatable, Hashable, Sendable {
    public let source: SystemGaugeSource
    public let speedKph: Double
    public let updatedAt: Int64
    public init(source: SystemGaugeSource, speedKph: Double, updatedAt: Int64) {
        self.source = source; self.speedKph = speedKph; self.updatedAt = updatedAt
    }
    public func visibleSpeedKph(at date: Date = Date()) -> Double? {
        SystemSnapshotFreshness.isFresh(updatedAt, at: date,
            maxAgeSeconds: SystemSnapshotFreshness.rideSpeedMaxAgeSeconds) ? speedKph : nil
    }
}

public struct SystemSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maxLifetimeMs: Int64 = 15 * 60 * 1000
    public let version: Int
    public let owner: SystemSnapshotOwner
    public let capturedAt: Int64
    public let expiresAt: Int64
    public let vehicle: SystemVehicleSnapshot?
    public let ride: SystemRideSnapshot?
    public let gauge: SystemGaugeSnapshot?
    public init(version: Int = SystemSnapshot.currentVersion, owner: SystemSnapshotOwner, capturedAt: Int64,
                expiresAt: Int64, vehicle: SystemVehicleSnapshot? = nil, ride: SystemRideSnapshot? = nil,
                gauge: SystemGaugeSnapshot? = nil) {
        self.version = version; self.owner = owner; self.capturedAt = capturedAt; self.expiresAt = expiresAt
        self.vehicle = vehicle; self.ride = ride; self.gauge = gauge
    }
    public func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince1970 * 1000 >= Double(expiresAt)
    }
    public func validated(expectedOwner: SystemSnapshotOwner, now: Date = Date()) throws -> SystemSnapshot {
        guard version == Self.currentVersion else { throw SystemSnapshotError("snapshot_version_unsupported") }
        guard owner.isValid, owner == expectedOwner else { throw SystemSnapshotError("snapshot_owner_mismatch") }
        let latest = now.timeIntervalSince1970 * 1000 + 30_000
        func timestamp(_ value: Int64) -> Bool { value >= 946_684_800_000 && Double(value) <= latest }
        func sampleTime(_ value: Int64?) -> Bool {
            value.map { timestamp($0) && $0 <= capturedAt } ?? true
        }
        func number(_ value: Double?, range: ClosedRange<Double>) -> Bool {
            value.map { $0.isFinite && range.contains($0) } ?? true
        }
        guard timestamp(capturedAt), expiresAt > capturedAt,
              expiresAt - capturedAt <= Self.maxLifetimeMs, vehicle != nil || ride != nil || gauge != nil else {
            throw SystemSnapshotError("invalid_snapshot_time")
        }
        if let value = vehicle {
            let safeName = value.name.map {
                !$0.isEmpty && $0.count <= 40 && $0.utf8.count <= 160
                    && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            } ?? true
            let safeSuffix = value.vinDisplaySuffix.map {
                (4...6).contains($0.utf8.count) && $0.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
                }
            } ?? true
            guard safeName, safeSuffix, sampleTime(value.updatedAt), value.updatedAt <= capturedAt,
                  number(value.socPercent, range: 0...100), number(value.chargeProgressPercent, range: 0...100),
                  sampleTime(value.socUpdatedAt), sampleTime(value.chargingUpdatedAt), sampleTime(value.chargeProgressUpdatedAt),
                  value.socUpdatedAt.map({ $0 <= value.updatedAt }) ?? true,
                  value.chargingUpdatedAt.map({ $0 <= value.updatedAt }) ?? true,
                  value.chargeProgressUpdatedAt.map({ $0 <= value.updatedAt }) ?? true,
                  (value.socPercent == nil) == (value.socUpdatedAt == nil),
                  (value.charging == nil) == (value.chargingUpdatedAt == nil),
                  (value.chargeProgressPercent == nil) == (value.chargeProgressUpdatedAt == nil) else {
                throw SystemSnapshotError("invalid_vehicle_snapshot")
            }
            // 展示类统计字段：只做范围与符号校验，缺测合法。
            // 单位统一为展示单位（V/A/W/bar/km/分），负功率表示回充，其余不允许负值。
            guard number(value.voltage, range: 0...200), number(value.current, range: -500...500),
                  number(value.power, range: -30_000...30_000),
                  number(value.todayMileKm, range: 0...10_000), number(value.lastMileKm, range: 0...10_000),
                  number(value.lastRideMinutes, range: 0...10_000), number(value.totalMileKm, range: 0...2_000_000),
                  number(value.rangeKm, range: 0...2_000), number(value.integral, range: 0...100_000_000),
                  number(value.tireFrontBar, range: 0...20), number(value.tireRearBar, range: 0...20),
                  number(value.tireFrontTemp, range: -60...200), number(value.tireRearTemp, range: -60...200),
                  value.lockState.map({ [0, 1].contains($0) }) ?? true,
                  value.seatState.map({ [0, 1].contains($0) }) ?? true,
                  value.online.map({ [0, 1].contains($0) }) ?? true,
                  value.unread.map({ (0...100_000).contains($0) }) ?? true,
                  sampleTime(value.statsUpdatedAt),
                  value.statsUpdatedAt.map({ $0 <= capturedAt }) ?? true else {
                throw SystemSnapshotError("invalid_vehicle_snapshot")
            }
        }
        if let value = ride {
            guard sampleTime(value.startedAt), sampleTime(value.updatedAt), value.updatedAt >= value.startedAt,
                  sampleTime(value.speedUpdatedAt), sampleTime(value.lastLocationAt), sampleTime(value.lastSignalAt),
                  [value.speedUpdatedAt, value.lastLocationAt, value.lastSignalAt].allSatisfy({
                      $0.map { $0 >= value.startedAt && $0 <= value.updatedAt } ?? true
                  }), number(value.speedKph, range: 0...400),
                  number(value.locationAgeSeconds, range: 0...31_536_000),
                  number(value.elapsedSeconds, range: 0...31_536_000),
                  value.gapCount.map({ (0...1024).contains($0) }) ?? true,
                  value.speedKph == nil || value.speedUpdatedAt != nil,
                  value.locationAgeSeconds == nil || value.lastLocationAt != nil,
                  value.state == .recording || value.speedKph == nil else {
                throw SystemSnapshotError("invalid_ride_snapshot")
            }
        }
        if let value = gauge {
            guard sampleTime(value.updatedAt), number(value.speedKph, range: 0...400) else {
                throw SystemSnapshotError("invalid_gauge_snapshot")
            }
        }
        return self
    }
}
