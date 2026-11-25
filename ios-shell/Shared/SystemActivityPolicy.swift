import Foundation

// 所有 ActivityKit 入口共用进程内同一把 per-id 闸门。actor 在 await update/end 时会重入，
// 仅把 manager 写成 actor 或设置 updating 标记都不能阻止另一路 end/reap/冷后台交错。
public actor SystemActivityOperationGate {
    public static let shared = SystemActivityOperationGate()
    private var occupied: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func acquire(_ id: String) async {
        if occupied.insert(id).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    public func release(_ id: String) {
        guard var queue = waiters[id], !queue.isEmpty else {
            occupied.remove(id)
            return
        }
        let next = queue.removeFirst()
        if queue.isEmpty { waiters.removeValue(forKey: id) }
        else { waiters[id] = queue }
        // occupied 一直保留到队列清空，迟到的调用不能插队。
        next.resume()
    }
}

public enum SystemActivityPolicy {
    /// 活动真正收到的核心来源时间；统计、包装 capturedAt 和其他 kind 均不能续命。
    public static func latestSourceAt(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind,
                                      at date: Date = Date()) -> Int64? {
        func validTime(_ value: Int64?) -> Int64? {
            guard let value = value, value >= 946_684_800_000,
                  value <= snapshot.capturedAt,
                  Double(value) <= date.timeIntervalSince1970 * 1000 + 30_000 else { return nil }
            return value
        }
        func validNumber(_ value: Double?, range: ClosedRange<Double>) -> Bool {
            value.map { $0.isFinite && range.contains($0) } ?? false
        }
        var times: [Int64] = []
        switch kind {
        case .vehicle, .charging:
            guard let vehicle = snapshot.vehicle else { return nil }
            if validNumber(vehicle.socPercent, range: 0...100), let time = validTime(vehicle.socUpdatedAt) { times.append(time) }
            if vehicle.charging != nil, let time = validTime(vehicle.chargingUpdatedAt) { times.append(time) }
            if vehicle.charging == true, validNumber(vehicle.chargeProgressPercent, range: 0...100),
               let time = validTime(vehicle.chargeProgressUpdatedAt) { times.append(time) }
        case .ride:
            guard let ride = snapshot.ride else { return nil }
            if let time = validTime(ride.updatedAt), ride.startedAt <= time { times.append(time) }
            if ride.state == .recording, validNumber(ride.speedKph, range: 0...400),
               let time = validTime(ride.speedUpdatedAt), time >= ride.startedAt { times.append(time) }
        case .gauge:
            if let gauge = snapshot.gauge, validNumber(gauge.speedKph, range: 0...400),
               let time = validTime(gauge.updatedAt) { times.append(time) }
        }
        return times.max()
    }

    /// 有核心字段时只使用其真实来源；纯统计快照才允许退到统计来源时间。
    public static func widgetSourceAt(_ snapshot: SystemSnapshot, at date: Date = Date()) -> Int64? {
        if let core = latestSourceAt(snapshot, kind: .vehicle, at: date) { return core }
        guard let vehicle = snapshot.vehicle, vehicle.socPercent == nil, vehicle.charging == nil,
              vehicle.chargeProgressPercent == nil, let stats = vehicle.statsUpdatedAt,
              stats >= 946_684_800_000, stats <= snapshot.capturedAt,
              Double(stats) <= date.timeIntervalSince1970 * 1000 + 30_000 else { return nil }
        return stats
    }

    public static func isIdle(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind,
                              at date: Date = Date(), graceSeconds: TimeInterval = 30 * 60) -> Bool {
        guard graceSeconds.isFinite, graceSeconds >= 0,
              let source = latestSourceAt(snapshot, kind: kind, at: date) else { return false }
        return date.timeIntervalSince1970 - Double(source) / 1000 >= graceSeconds
    }

    // 只补速度及其原采样时间；状态、时长、缺口和定位/信号元数据全部属于 current。
    public static func presentation(_ value: SystemSnapshot, previous: SystemSnapshot?,
                                    kind: ZeehoActivityKind, at date: Date = Date()) -> SystemSnapshot {
        let sameOwner = previous?.owner == value.owner ? previous : nil
        let gauge = value.gauge ?? sameOwner?.gauge
        var ride = value.ride
        if kind == .ride, let current = ride, current.state == .recording {
            var speed = current.speedKph
            var speedAt = current.speedUpdatedAt
            var updatedAt = current.updatedAt
            if let gauge = value.gauge, gauge.visibleSpeedKph(at: date) != nil,
               gauge.updatedAt >= current.startedAt, gauge.updatedAt >= (speedAt ?? 0) {
                speed = gauge.speedKph; speedAt = gauge.updatedAt
                updatedAt = max(updatedAt, gauge.updatedAt)
            } else if speed == nil, let old = sameOwner?.ride, old.state == .recording,
                      old.startedAt == current.startedAt, let oldAt = old.speedUpdatedAt,
                      oldAt <= current.updatedAt {
                speed = old.speedKph; speedAt = old.speedUpdatedAt
            }
            ride = SystemRideSnapshot(state: current.state, startedAt: current.startedAt,
                updatedAt: updatedAt, speedKph: speed, speedUpdatedAt: speedAt,
                lastLocationAt: current.lastLocationAt, lastSignalAt: current.lastSignalAt,
                locationAgeSeconds: current.locationAgeSeconds,
                elapsedSeconds: current.elapsedSeconds, gapCount: current.gapCount)
        }
        return SystemSnapshot(version: value.version, owner: value.owner, capturedAt: value.capturedAt,
            expiresAt: value.expiresAt, vehicle: value.vehicle, ride: ride, gauge: gauge)
    }

    public static func chargeStartedAt(kind: ZeehoActivityKind, snapshot: SystemSnapshot,
                                       previous: Double?) -> Double? {
        guard kind == .charging, snapshot.vehicle?.charging == true,
              let confirmed = snapshot.vehicle?.chargingUpdatedAt else { return nil }
        if let previous = previous, previous.isFinite, previous >= 946_684_800_000,
           previous <= Double(confirmed) { return previous }
        return Double(confirmed)
    }

    /// 只承诺最后一次充电状态确认时的时长；失去更新后绝不继续当成实际充电计时。
    public static func confirmedChargeElapsed(snapshot: SystemSnapshot, startedAt: Double?) -> Double? {
        guard snapshot.vehicle?.charging == true, let startedAt = startedAt, startedAt.isFinite,
              let confirmed = snapshot.vehicle?.chargingUpdatedAt,
              startedAt >= 946_684_800_000, startedAt <= Double(confirmed) else { return nil }
        return (Double(confirmed) - startedAt) / 1000
    }

    /// 展示失鲜采用最早字段截止，与「多久没收到任何核心输入」的回收判据分开。
    public static func staleDate(_ snapshot: SystemSnapshot, kind: ZeehoActivityKind) -> Date {
        var deadlines = [snapshot.expiresAt]
        switch kind {
        case .gauge:
            if let gauge = snapshot.gauge { deadlines.append(gauge.updatedAt + 10_000) }
        case .ride:
            if let ride = snapshot.ride {
                deadlines.append(ride.updatedAt + 10_000)
                if ride.speedKph != nil, let time = ride.speedUpdatedAt { deadlines.append(time + 10_000) }
            }
        case .vehicle, .charging:
            if let vehicle = snapshot.vehicle {
                if vehicle.socPercent != nil, let time = vehicle.socUpdatedAt { deadlines.append(time + 180_000) }
                if vehicle.charging != nil, let time = vehicle.chargingUpdatedAt { deadlines.append(time + 180_000) }
                if vehicle.charging == true, vehicle.chargeProgressPercent != nil,
                   let time = vehicle.chargeProgressUpdatedAt { deadlines.append(time + 180_000) }
            }
        }
        return Date(timeIntervalSince1970: Double(deadlines.min() ?? snapshot.expiresAt) / 1000)
    }
}
