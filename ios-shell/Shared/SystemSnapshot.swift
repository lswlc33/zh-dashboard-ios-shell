import Foundation

// 主 App 与 extension 只交换这一份白名单；所有时间是数据/状态事件的 Unix 毫秒，不能在读取时改成现在。
public struct SystemSnapshotError: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

public struct SystemSnapshotOwner: Codable, Equatable, Hashable, Sendable {
    public let scopeID: String
    public let accountVINHash: String
    public init(scopeID: String, accountVINHash: String) {
        self.scopeID = scopeID; self.accountVINHash = accountVINHash
    }
    public var isValid: Bool {
        !scopeID.isEmpty && scopeID.utf8.count <= 96
            && scopeID.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value)
                    || (97...122).contains($0.value) || [45, 95].contains($0.value)
            }
            && accountVINHash.utf8.count == 64
            && accountVINHash.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

public enum SystemSnapshotFreshness {
    public static let vehicleMaxAgeSeconds: Double = 180
    public static let rideSpeedMaxAgeSeconds: Double = 10
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
    public init(name: String? = nil, vinDisplaySuffix: String? = nil, socPercent: Double? = nil,
                socUpdatedAt: Int64? = nil, charging: Bool? = nil, chargingUpdatedAt: Int64? = nil,
                chargeProgressPercent: Double? = nil, chargeProgressUpdatedAt: Int64? = nil, updatedAt: Int64) {
        self.name = name; self.vinDisplaySuffix = vinDisplaySuffix; self.socPercent = socPercent
        self.socUpdatedAt = socUpdatedAt; self.charging = charging; self.chargingUpdatedAt = chargingUpdatedAt
        self.chargeProgressPercent = chargeProgressPercent; self.chargeProgressUpdatedAt = chargeProgressUpdatedAt
        self.updatedAt = updatedAt
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

public struct SystemSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maxLifetimeMs: Int64 = 15 * 60 * 1000
    public let version: Int
    public let owner: SystemSnapshotOwner
    public let capturedAt: Int64
    public let expiresAt: Int64
    public let vehicle: SystemVehicleSnapshot?
    public let ride: SystemRideSnapshot?
    public init(version: Int = SystemSnapshot.currentVersion, owner: SystemSnapshotOwner, capturedAt: Int64,
                expiresAt: Int64, vehicle: SystemVehicleSnapshot? = nil, ride: SystemRideSnapshot? = nil) {
        self.version = version; self.owner = owner; self.capturedAt = capturedAt; self.expiresAt = expiresAt
        self.vehicle = vehicle; self.ride = ride
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
              expiresAt - capturedAt <= Self.maxLifetimeMs, vehicle != nil || ride != nil else {
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
        return self
    }
}
