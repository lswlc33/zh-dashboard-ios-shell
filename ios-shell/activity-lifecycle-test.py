"""编译生产实时活动策略并核对各入口生命周期接线：python -I activity-lifecycle-test.py。

真实编译 Shared/SystemSnapshot.swift + Shared/SystemActivityPolicy.swift（提取生产 ZeehoActivityKind），
用合成快照驱动时间口径、回收判据、ride/gauge 展示与充电计时；另用进程内闸门验证同 id 串行。
其余入口（manager/冷后台/凭据轮询/UI/构建接线）用生产源码断言，防止只在测试里成立。
macOS 必须有 swiftc；其他平台缺工具链明确 SKIP，--require-swift 可禁止跳过。
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


SWIFT_TESTS = r'''
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

// 同 id 重入计数：任何时刻只允许 1 个持有者。
private final class Occupancy: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var peak = 0
    private var total = 0

    func enter() {
        lock.lock()
        inside += 1
        peak = max(peak, inside)
        total += 1
        lock.unlock()
    }

    func leave() {
        lock.lock()
        inside -= 1
        lock.unlock()
    }

    func snapshot() -> (peak: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (peak, total)
    }
}

@main
private enum ActivityLifecycleTests {
    private static let baseMs: Int64 = 1_800_000_000_000
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let owner = SystemSnapshotOwner(scopeID: "fixtureOwner",
                                                   accountVINHash: String(repeating: "a", count: 64))
    private static let otherOwner = SystemSnapshotOwner(scopeID: "otherOwner",
                                                        accountVINHash: String(repeating: "b", count: 64))

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func at(_ secondsAgo: Int64) -> Int64 { baseMs - secondsAgo * 1000 }

    private static func snapshot(vehicle: SystemVehicleSnapshot? = nil, ride: SystemRideSnapshot? = nil,
                                 gauge: SystemGaugeSnapshot? = nil, capturedAt: Int64? = nil,
                                 expiresAt: Int64? = nil, snapshotOwner: SystemSnapshotOwner? = nil) -> SystemSnapshot {
        let captured = capturedAt ?? baseMs
        return SystemSnapshot(owner: snapshotOwner ?? owner, capturedAt: captured,
            expiresAt: expiresAt ?? captured + 180_000, vehicle: vehicle, ride: ride, gauge: gauge)
    }

    private static func vehicle(soc: Double? = nil, socAt: Int64? = nil, charging: Bool? = nil,
                               chargingAt: Int64? = nil, progress: Double? = nil, progressAt: Int64? = nil,
                               updatedAt: Int64? = nil, statsAt: Int64? = nil) -> SystemVehicleSnapshot {
        SystemVehicleSnapshot(socPercent: soc, socUpdatedAt: socAt, charging: charging,
            chargingUpdatedAt: chargingAt, chargeProgressPercent: progress,
            chargeProgressUpdatedAt: progressAt, updatedAt: updatedAt ?? baseMs, statsUpdatedAt: statsAt)
    }

    private static func ride(state: SystemRideState, startedAt: Int64, updatedAt: Int64,
                             speed: Double? = nil, speedAt: Int64? = nil) -> SystemRideSnapshot {
        SystemRideSnapshot(state: state, startedAt: startedAt, updatedAt: updatedAt, speedKph: speed,
            speedUpdatedAt: speedAt, gapCount: 0)
    }

    // MARK: - 时间口径

    private static func vehicleSourceIgnoresWrapperAndStats() throws {
        let core = at(44 * 60)
        let value = snapshot(vehicle: vehicle(soc: 55, socAt: core, charging: true, chargingAt: core,
                                             updatedAt: baseMs, statsAt: baseMs))
        for kind in [ZeehoActivityKind.vehicle, ZeehoActivityKind.charging] {
            try check(SystemActivityPolicy.latestSourceAt(value, kind: kind, at: baseDate) == core,
                      "\(kind.rawValue): 包装时间/统计时间续命了旧核心字段")
        }
        try check(SystemActivityPolicy.widgetSourceAt(value, at: baseDate) == core,
                  "小组件来源使用了包装时间")
        let recent = snapshot(vehicle: vehicle(soc: 55, socAt: at(9), updatedAt: baseMs, statsAt: baseMs))
        try check(SystemActivityPolicy.latestSourceAt(recent, kind: .vehicle, at: baseDate) == at(9),
                  "较新的核心字段没有被采用")
    }

    private static func chargingProgressOnlyCountsWhileCharging() throws {
        let socAt = at(1_000)
        let chargingAt = at(500)
        let progressAt = at(20)
        let on = snapshot(vehicle: vehicle(soc: 40, socAt: socAt, charging: true, chargingAt: chargingAt,
                                           progress: 30, progressAt: progressAt))
        try check(SystemActivityPolicy.latestSourceAt(on, kind: .charging, at: baseDate) == progressAt,
                  "充电中未把最新进度计入来源")
        let off = snapshot(vehicle: vehicle(soc: 40, socAt: socAt, charging: false, chargingAt: chargingAt,
                                            progress: 30, progressAt: baseMs - 100))
        try check(SystemActivityPolicy.latestSourceAt(off, kind: .charging, at: baseDate) == chargingAt,
                  "未充电时仍用充电进度续命")
    }

    private static func unusableTimesAreIgnored() throws {
        let future = snapshot(vehicle: vehicle(soc: 40, socAt: baseMs + 60_000))
        try check(SystemActivityPolicy.latestSourceAt(future, kind: .vehicle, at: baseDate) == nil,
                  "未来时间被当作核心来源")
        let beyondWrapper = snapshot(vehicle: vehicle(soc: 40, socAt: baseMs + 1_000))
        try check(SystemActivityPolicy.latestSourceAt(beyondWrapper, kind: .vehicle, at: baseDate) == nil,
                  "晚于 capturedAt 的时间被当作核心来源")
        let epoch = snapshot(vehicle: vehicle(soc: 40, socAt: 0))
        try check(SystemActivityPolicy.latestSourceAt(epoch, kind: .vehicle, at: baseDate) == nil,
                  "零值时标被当作核心来源")
        let filled = snapshot(vehicle: vehicle(soc: 40, socAt: baseMs + 60_000, charging: false,
                                               chargingAt: at(7)))
        try check(SystemActivityPolicy.latestSourceAt(filled, kind: .vehicle, at: baseDate) == at(7),
                  "一个字段不可用时没有退到同 kind 的其他核心字段")
    }

    private static func idleUsesOnlyKindRelevantSources() throws {
        let staleProgress = snapshot(vehicle: vehicle(soc: 42, socAt: at(60), charging: true,
                                                     chargingAt: at(60), progress: 20, progressAt: at(31 * 60)))
        try check(!SystemActivityPolicy.isIdle(staleProgress, kind: .charging, at: baseDate),
                  "旧充电进度把刚确认的充电态判成停更")
        let oldSOC = snapshot(vehicle: vehicle(soc: 42, socAt: at(30 * 60), charging: true,
                                              chargingAt: at(40 * 60)))
        try check(SystemActivityPolicy.isIdle(oldSOC, kind: .charging, at: baseDate),
                  "超过 30 分钟的核心来源没有判停更")
        try check(!SystemActivityPolicy.isIdle(oldSOC, kind: .charging, at: baseDate,
                                               graceSeconds: 30 * 60 + 1),
                  "停更边界被算错")
        try check(!SystemActivityPolicy.isIdle(oldSOC, kind: .charging, at: baseDate, graceSeconds: -1),
                  "非法宽限期不能回收")
        try check(!SystemActivityPolicy.isIdle(oldSOC, kind: .charging, at: baseDate,
                                               graceSeconds: .infinity),
                  "无限宽限期不能回收")
    }

    private static func statsOnlyNeverRefreshesAnActivity() throws {
        let stats = snapshot(vehicle: vehicle(updatedAt: baseMs, statsAt: at(60)))
        try check(SystemActivityPolicy.latestSourceAt(stats, kind: .vehicle, at: baseDate) == nil,
                  "纯统计快照被当作核心来源")
        try check(!SystemActivityPolicy.isIdle(stats, kind: .vehicle, at: baseDate),
                  "没有核心来源就判停更，会结束无法证实的活动")
        try check(SystemActivityPolicy.widgetSourceAt(stats, at: baseDate) == at(60),
                  "纯统计快照没有退到统计来源")
        let mixed = snapshot(vehicle: vehicle(soc: 40, socAt: at(44 * 60), updatedAt: baseMs, statsAt: at(60)))
        try check(SystemActivityPolicy.widgetSourceAt(mixed, at: baseDate) == at(44 * 60),
                  "有核心字段时仍用了更晚的统计来源")
    }

    private static func rideTimelineUsesRideSources() throws {
        let paused = snapshot(ride: ride(state: .paused, startedAt: at(60 * 60), updatedAt: at(40 * 60),
                                        speed: 30, speedAt: at(40 * 60)))
        try check(SystemActivityPolicy.latestSourceAt(paused, kind: .ride, at: baseDate) == at(40 * 60),
                  "暂停行程把旧速度算成来源")
        try check(SystemActivityPolicy.isIdle(paused, kind: .ride, at: baseDate),
                  "停更 40 分钟的行程没有判停更")
        let recording = snapshot(ride: ride(state: .recording, startedAt: at(20 * 60), updatedAt: at(60),
                                           speed: 12, speedAt: at(3)))
        try check(SystemActivityPolicy.latestSourceAt(recording, kind: .ride, at: baseDate) == at(3),
                  "录制中最新速度没有成为来源")
        let inverted = snapshot(ride: ride(state: .recording, startedAt: baseMs, updatedAt: at(60)))
        try check(SystemActivityPolicy.latestSourceAt(inverted, kind: .ride, at: baseDate) == nil,
                  "开始时间晚于更新时间的数据被采信")
    }

    // MARK: - 展示语义

    private static func presentationDoesNotResurrectPausedRide() throws {
        let current = snapshot(ride: ride(state: .paused, startedAt: at(60 * 60), updatedAt: at(40 * 60)))
        let previous = snapshot(ride: ride(state: .recording, startedAt: at(60 * 60), updatedAt: at(59 * 60),
                                          speed: 30, speedAt: at(59 * 60)))
        let shown = SystemActivityPolicy.presentation(current, previous: previous, kind: .ride, at: baseDate)
        try check(shown.ride?.state == .paused, "暂停后展示把状态改回录制")
        try check(shown.ride?.speedKph == nil, "暂停后展示复活了上次车速")
        try check(shown.ride?.updatedAt == at(40 * 60), "暂停后展示改写了行程时间")
        try check(shown.gauge == nil, "上一帧 gauge 被无依据地并入")
    }

    private static func recordingRideMergesFreshGaugeOnly() throws {
        let gauge = SystemGaugeSnapshot(source: .ble, speedKph: 25, updatedAt: at(2))
        let current = snapshot(ride: ride(state: .recording, startedAt: at(10 * 60), updatedAt: at(5)),
                               gauge: gauge)
        let shown = SystemActivityPolicy.presentation(current, previous: nil, kind: .ride, at: baseDate)
        try check(shown.ride?.speedKph == 25, "录制中未并入最新 gauge 速度")
        try check(shown.ride?.speedUpdatedAt == at(2), "并入速度丢失了原采样时间")
        try check(shown.ride?.state == .recording && shown.ride?.startedAt == at(10 * 60),
                  "并入速度改写了状态或开始时间")
        try check(shown.gauge == gauge, "gauge 未随同展示")

        let staleGauge = SystemGaugeSnapshot(source: .ble, speedKph: 25, updatedAt: at(120))
        let staleCurrent = snapshot(ride: ride(state: .recording, startedAt: at(10 * 60), updatedAt: at(30)),
                                    gauge: staleGauge)
        let stalePrevious = snapshot(ride: ride(state: .recording, startedAt: at(10 * 60),
                                                updatedAt: at(60), speed: 18, speedAt: at(60)))
        let staleShown = SystemActivityPolicy.presentation(staleCurrent, previous: stalePrevious,
                                                           kind: .ride, at: baseDate)
        try check(staleShown.ride?.speedKph == 18, "过期 gauge 被当成实时速度")
        try check(staleShown.ride?.speedUpdatedAt == at(60), "回退速度丢失了原采样时间")
    }

    private static func presentationNeverBorrowsAnotherOwner() throws {
        let current = snapshot(ride: ride(state: .recording, startedAt: at(10 * 60), updatedAt: at(60)))
        let foreign = snapshot(gauge: SystemGaugeSnapshot(source: .gps, speedKph: 9, updatedAt: at(5)),
                               snapshotOwner: otherOwner)
        let shown = SystemActivityPolicy.presentation(current, previous: foreign, kind: .ride, at: baseDate)
        try check(shown.gauge == nil, "不同 owner 的 gauge 被并入")
        try check(shown.ride?.speedKph == nil, "不同 owner 的旧速度被并入")

        let car = snapshot(vehicle: vehicle(soc: 50, socAt: at(30), charging: false, chargingAt: at(30)))
        let carShown = SystemActivityPolicy.presentation(car, previous: nil, kind: .vehicle, at: baseDate)
        try check(carShown.vehicle == car.vehicle, "车况展示改写了原始字段")
        try check(carShown.capturedAt == car.capturedAt && carShown.expiresAt == car.expiresAt,
                  "车况展示改写了快照包围时间")
    }

    private static func chargeClockFreezesAtLastConfirmation() throws {
        let confirmed = at(60)
        let on = snapshot(vehicle: vehicle(soc: 40, socAt: confirmed, charging: true, chargingAt: confirmed))
        try check(SystemActivityPolicy.chargeStartedAt(kind: .charging, snapshot: on, previous: nil)
                  == Double(confirmed), "首次充电开始时间不是确认时间")
        try check(SystemActivityPolicy.chargeStartedAt(kind: .charging, snapshot: on,
                                                       previous: Double(at(30 * 60))) == Double(at(30 * 60)),
                  "已记录的更早开始时间被覆盖")
        try check(SystemActivityPolicy.chargeStartedAt(kind: .charging, snapshot: on,
                                                       previous: Double(baseMs)) == Double(confirmed),
                  "晚于本次确认的旧开始时间被采信")
        try check(SystemActivityPolicy.chargeStartedAt(kind: .vehicle, snapshot: on, previous: nil) == nil,
                  "非充电活动带上了充电开始时间")
        let off = snapshot(vehicle: vehicle(soc: 40, socAt: confirmed, charging: false, chargingAt: confirmed))
        try check(SystemActivityPolicy.chargeStartedAt(kind: .charging, snapshot: off, previous: nil) == nil,
                  "非充电态仍带充电开始时间")
        try check(SystemActivityPolicy.confirmedChargeElapsed(snapshot: on, startedAt: Double(at(30 * 60)))
                  == 29 * 60, "充电时长没有固定到最后一次确认")
        try check(SystemActivityPolicy.confirmedChargeElapsed(snapshot: off, startedAt: Double(at(30 * 60)))
                  == nil, "非充电态仍显示充电时长")
        try check(SystemActivityPolicy.confirmedChargeElapsed(snapshot: on, startedAt: Double(baseMs)) == nil,
                  "开始时间晚于确认时间仍算时长")
    }

    private static func staleDateUsesEarliestFieldDeadline() throws {
        let expires = baseMs + 180_000
        let car = snapshot(vehicle: vehicle(soc: 40, socAt: at(170)), expiresAt: expires)
        try check(SystemActivityPolicy.staleDate(car, kind: .vehicle) == Date(timeIntervalSince1970: 1_800_000_010),
                  "车况失鲜时间不是最早字段截止")
        let freshCar = snapshot(vehicle: vehicle(soc: 40, socAt: baseMs), expiresAt: expires)
        try check(SystemActivityPolicy.staleDate(freshCar, kind: .vehicle)
                  == Date(timeIntervalSince1970: 1_800_000_180), "车况失鲜时间超出快照有效期")
        let rideValue = snapshot(ride: ride(state: .recording, startedAt: at(30 * 60), updatedAt: at(20),
                                           speed: 11, speedAt: at(1_000)), expiresAt: expires)
        try check(SystemActivityPolicy.staleDate(rideValue, kind: .ride)
                  == Date(timeIntervalSince1970: 1_799_999_981), "行程失鲜时间没有取最早字段")
        let gauge = snapshot(gauge: SystemGaugeSnapshot(source: .ble, speedKph: 20, updatedAt: at(4)),
                            expiresAt: expires)
        try check(SystemActivityPolicy.staleDate(gauge, kind: .gauge)
                  == Date(timeIntervalSince1970: 1_799_999_996), "仪表失鲜时间没有用 10 秒窗口")
        let tight = snapshot(vehicle: vehicle(soc: 40, socAt: baseMs), expiresAt: baseMs + 5_000)
        try check(SystemActivityPolicy.staleDate(tight, kind: .vehicle)
                  == Date(timeIntervalSince1970: 1_800_000_005), "快照过期更早时没有采用它")
    }

    // MARK: - 闸门

    private static func gateSerializesSameID() async throws {
        let gate = SystemActivityOperationGate()
        try check(await waitFor("同 id 首次加锁", { await gate.acquire("charging") }),
                  "首次加锁超过 2 秒")
        let occupancy = Occupancy()
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<6 {
            Task {
                await gate.acquire("charging")
                occupancy.enter()
                try? await Task.sleep(nanoseconds: 20_000_000)
                occupancy.leave()
                await gate.release("charging")
                finished.signal()
            }
        }
        // 主线程持闸时任何等待者都不能进入 update/end 临界区。
        try? await Task.sleep(nanoseconds: 120_000_000)
        try check(occupancy.snapshot().total == 0, "等待者在闸门被占用时进入了临界区")
        await gate.release("charging")
        for index in 0..<6 {
            try check(finished.wait(timeout: .now() + 5) == .success,
                      "第 \(index) 个等待者没有被放行")
        }
        let result = occupancy.snapshot()
        try check(result.total == 6, "闸门丢失等待者：\(result.total)")
        try check(result.peak == 1, "同 id 允许了 \(result.peak) 个并发持有者")
    }

    private static func gateKeepsIDsIndependent() async throws {
        let gate = SystemActivityOperationGate()
        try check(await waitFor("占用 charger", { await gate.acquire("charger") }), "charger 加锁失败")
        try check(await waitFor("占用 rider", { await gate.acquire("rider") }), "不同 id 被互相阻塞")
        try check(await waitFor("释放后重新加锁", {
            await gate.release("rider")
            await gate.release("charger")
            await gate.acquire("rider")
            await gate.release("rider")
        }), "全部释放后 id 没有恢复可用")
        try check(await waitFor("重复释放", {
            await gate.release("rider")
            await gate.acquire("rider")
            await gate.release("rider")
        }), "空队列上重复释放破坏了 id")
    }

    /// 只用于防止测试自身挂死；被测逻辑卡住时必须失败而不是静默超时。
    private static func waitFor(_ label: String, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let done = DispatchSemaphore(value: 0)
        let task = Task { await work(); done.signal() }
        let ok = done.wait(timeout: .now() + 2) == .success
        if !ok { task.cancel() }
        if !ok { print("TIMEOUT: " + label) }
        return ok
    }

    static func main() async throws {
        let tests: [(String, () async throws -> Void)] = [
            ("vehicle source ignores wrapper and stats", vehicleSourceIgnoresWrapperAndStats),
            ("charging progress only counts while charging", chargingProgressOnlyCountsWhileCharging),
            ("unusable timestamps are ignored", unusableTimesAreIgnored),
            ("idle uses only kind relevant sources", idleUsesOnlyKindRelevantSources),
            ("stats-only never refreshes an activity", statsOnlyNeverRefreshesAnActivity),
            ("ride timeline uses ride sources", rideTimelineUsesRideSources),
            ("presentation never resurrects paused ride", presentationDoesNotResurrectPausedRide),
            ("recording ride merges fresh gauge only", recordingRideMergesFreshGaugeOnly),
            ("presentation never borrows another owner", presentationNeverBorrowsAnotherOwner),
            ("charge clock freezes at last confirmation", chargeClockFreezesAtLastConfirmation),
            ("stale date uses earliest field deadline", staleDateUsesEarliestFieldDeadline),
            ("gate serializes the same id", gateSerializesSameID),
            ("gate keeps ids independent", gateKeepsIDsIndependent),
        ]
        for (name, test) in tests {
            do {
                try await test()
            } catch let failure as TestFailure {
                throw TestFailure(description: "FAIL: \(name): \(failure.description)")
            } catch {
                throw TestFailure(description: "FAIL: \(name): \(error)")
            }
        }
        print("PASS: \(tests.count) production Swift activity lifecycle fixtures")
    }
}
'''


def extract_type(source, name):
    # 顶层类型以顶格右括号结束；只取类型本身，不改写生产实现。
    pattern = (rf'(?ms)^(?:(?:public|private|fileprivate|internal|final)\s+)*'
               rf'(?:enum|struct)\s+{re.escape(name)}\b[^\n]*\{{.*?^\}}[ \t]*$')
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError('expected one production type: ' + name)
    return matches[0]


def slice_between(text, start_marker, end_marker, label):
    start = text.find(start_marker)
    if start < 0:
        raise ValueError('missing production marker: ' + label)
    end = text.find(end_marker, start)
    if end < 0:
        raise ValueError('missing production marker after ' + label + ': ' + end_marker)
    return text[start:end]


def require(text, needle, label):
    if needle not in text:
        raise ValueError('missing expected production behaviour: ' + label)
    return text.index(needle)


def ordered(text, first, second, label):
    if require(text, first, label + ' (first)') >= require(text, second, label + ' (second)'):
        raise ValueError('production order changed: ' + label)


def check_surfaces(root):
    surfaces = (root / 'SystemSurfaces.swift').read_text(encoding='utf-8-sig')
    if 'refreshWidgetCredential' in surfaces:
        raise ValueError('old keychain-reseeding widget refresh is still scheduled')
    manager_scope = slice_between(surfaces, '    func setScope(_ next: SystemSnapshotOwner?, generation ticket: UInt64) async {',
                                 '    func clearScope(generation ticket: UInt64) async -> Int {',
                                 'manager.setScope')
    ordered(manager_scope, 'await gate.acquire(activity.id)', 'finishWhileHoldingGate(activity)',
            'setScope must end foreign owner activities only inside the gate')
    require(manager_scope, 'guard ticket == generation, owner == next else',
            'setScope must revalidate scope after queueing for the gate')
    manager_clear = slice_between(surfaces, '    func clearScope(generation ticket: UInt64) async -> Int {',
                                  '    fileprivate static func isLive(_ state: ActivityState) -> Bool {',
                                  'manager.clearScope')
    ordered(manager_clear, 'await gate.acquire(activity.id)', 'finishWhileHoldingGate(activity)',
            'clearScope must end only inside the gate')
    require(manager_clear, 'guard ticket == generation, owner == nil else',
            'clearScope must revalidate the revocation after queueing')
    manager_update = slice_between(surfaces, '    func update(_ snapshot: SystemSnapshot, id: String?, generation ticket: UInt64,',
                                   '    private func updateWhileHoldingGate(', 'manager.update')
    ordered(manager_update, 'await gate.acquire(activity.id)', 'updateWhileHoldingGate',
            'update must enter the shared gate before touching an activity')
    guarded = slice_between(surfaces, '    private func updateWhileHoldingGate(', '    func end(owner expected: SystemSnapshotOwner',
                            'manager.updateWhileHoldingGate')
    ordered(guarded, 'guard lease.valid, context?.canDeliver != false, ticket == generation, owner == snapshot.owner else',
            'let value = SystemActivityPolicy.presentation', 'update must revalidate the ticket under the gate')
    ordered(guarded, 'let oldTime = SystemActivityPolicy.latestSourceAt(previous.snapshot, kind: kind)',
            'let edgeChanged', 'update must reject going back in time before throttling')
    ordered(guarded, 'await activity.update(', 'if owner != snapshot.owner { await Self.finishWhileHoldingGate(activity) }',
            'update must revalidate context and owner after the awaited ActivityKit update')
    ordered(guarded, 'if owner != snapshot.owner { await Self.finishWhileHoldingGate(activity) }',
            'lastUpdates.removeValue(forKey: activity.id)',
            'a cancelled update must clear its throttle entry before throwing')
    manager_end = slice_between(surfaces, '    func end(owner expected: SystemSnapshotOwner, id: String? = nil, kind: ZeehoActivityKind? = nil,',
                                '    fileprivate static func chargeStartedAt(', 'manager.end')
    ordered(manager_end, 'await gate.acquire(activity.id)', 'finishWhileHoldingGate(activity)',
            'end must run inside the same gate')
    reap = slice_between(surfaces, '    static func reapIdleActivities(graceSeconds: TimeInterval = 30 * 60) {',
                         'final class IOSSystemSurfacesService', 'manager.reapIdleActivities')
    ordered(reap, 'await gate.acquire(activity.id)', 'let state = content(activity)',
            'reap must read the snapshot only after acquiring the gate')
    ordered(reap, 'let state = content(activity)', 'SystemActivityPolicy.isIdle(',
            'reap must judge idleness on the gate-protected snapshot')
    ordered(reap, 'SystemActivityPolicy.isIdle(', 'finishWhileHoldingGate(activity)',
            'reap must end only after the idle judgement')
    static_reap = slice_between(surfaces, '    static func reapIdleActivities(graceSeconds: TimeInterval = 30 * 60) {',
                                '    @discardableResult private func reloadWidgets(',
                                'service.reapIdleActivities')
    require(static_reap, 'IOSLiveActivityManager.reapIdleActivities(graceSeconds: graceSeconds)',
            'service reap must delegate to the gated manager path')
    cold = slice_between(surfaces, '    private static func updateRunningActivities(sample: IOSBackgroundClient.VehicleSample,',
                         '    // 凭据撤销只取消充电调度，绝不停止独立的骑行/GPS/BLE 会话。',
                         'cold background update')
    ordered(cold, 'guard activeInstance == nil, context.canDeliver, credential.canSampleVehicle,',
            'let previous = IOSLiveActivityManager.content(activity)',
            'cold background must revalidate the credentials under the gate')
    ordered(cold, 'let previous = IOSLiveActivityManager.content(activity)',
            'if activity.attributes.kind == .charging, sample.charging == false {',
            'cold background must end only an exact charging stop')
    require(cold, 'await IOSLiveActivityManager.finishWhileHoldingGate(activity)',
            'cold background stop must keep the gate while ending')
    require(cold, 'let merged = Self.mergedBackgroundVehicle(vehicle, sample: sample)',
            'cold background must still merge vehicle data for the same sample')
    require(cold, 'guard (try? value.validated(expectedOwner: activity.attributes.owner)) != nil',
            'cold background merge must be validated before display')
    poll = slice_between(surfaces, '    private static func chargingCredentialMatches(_ scope: IOSRideScope) -> Bool {',
                         '    private func startActivity(', 'charging poll admission')
    require(poll, 'credential.canSampleVehicle && credential.ownerHash == scope.ownerHash',
            'charging poll must require a usable background credential for the same owner')
    if poll.count('Self.chargingCredentialMatches(captured)') != 3:
        raise ValueError('charging poll must revalidate the credential on start, each loop and the run callback')
    cleared = slice_between(surfaces, '    static func backgroundCredentialCleared() {',
                            '    private static func chargingKey(', 'backgroundCredentialCleared')
    for needle, label in [
        ('service.chargingStartLease.cancel()', 'credential clear must cancel a pending charging start'),
        ('service.stopChargingPoll()', 'credential clear must stop the charging poll'),
        ('IOSContinuedCharging.shared.stop(ownerID: owner.ownerIdentifierString, success: false)',
         'credential clear must stop continued charging processing'),
    ]:
        require(cleared, needle, label)
    for forbidden in ('stopRide', 'nativeRide', 'stopGauge'):
        if forbidden in cleared:
            raise ValueError('credential clear must not stop the independent ride session: ' + forbidden)
    if surfaces.count('await gate.acquire(activity.id)') != 6:
        raise ValueError('an ActivityKit entry point bypasses the shared per-id gate')
    return surfaces


def check_dashboard(root):
    dashboard = (root / 'Dashboard.swift').read_text(encoding='utf-8-sig')
    active = slice_between(dashboard, 'func applicationDidBecomeActive(_ application: UIApplication) {',
                           '\n}\n', 'applicationDidBecomeActive')
    ordered(active, 'func applicationDidBecomeActive', 'IOSSystemSurfacesService.reapIdleActivities()',
            'foreground must reap idle activities on resume')
    if 'DispatchQueue.global' in active:
        raise ValueError('foreground reap must be registered on the main thread, not a global queue')
    return dashboard


def check_presentation(root):
    presentation = (root / 'Widgets' / 'WidgetPresentation.swift').read_text(encoding='utf-8-sig')
    require(presentation, 'SystemActivityPolicy.widgetSourceAt', 'widget freshness must use the core source time')
    require(presentation, 'var relativeAge = false', 'stale label must support a dynamic relative age')
    live = (root / 'Widgets' / 'LiveActivityWidget.swift').read_text(encoding='utf-8-sig')
    if 'timerInterval:' in live:
        raise ValueError('charge duration must not keep ticking past the last confirmed sample')
    require(live, 'SystemActivityPolicy.confirmedChargeElapsed', 'charge duration must freeze at the last confirmation')
    if live.count('annotatesStale: true, relativeAge: true') != 2:
        raise ValueError('banner and expanded layouts must both annotate a dynamic stale age')
    if live.count('WidgetSyncAge(timestamp: presentation.updatedAt') < 3:
        raise ValueError('compact and minimal layouts must show the last sync age')
    return live


def check_wiring(root):
    build = (root / 'build.sh').read_text(encoding='utf-8-sig')
    require(build, 'activity-lifecycle-test.py" --require-swift',
            'Apple builds must execute the activity lifecycle regressions')
    support = (root / 'build-support.py').read_text(encoding='utf-8-sig')
    require(support, "'ios-shell/activity-lifecycle-test.py'",
            'the new regression script must be a pinned build input')
    contract = (root / 'test.py').read_text(encoding='utf-8-sig')
    if 'refreshWidgetCredential' in contract:
        raise ValueError('test.py still pins the removed keychain-reseeding path')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', help='swiftc executable path or command name')
    parser.add_argument('--require-swift', action='store_true',
                        help='fail instead of SKIP if swiftc is missing (always required on macOS)')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent

    check_surfaces(root)
    check_dashboard(root)
    check_presentation(root)
    check_wiring(root)

    snapshot_source = root / 'Shared' / 'SystemSnapshot.swift'
    policy_source = root / 'Shared' / 'SystemActivityPolicy.swift'
    for path in (snapshot_source, policy_source):
        if not path.is_file():
            raise ValueError('missing production Swift source: ' + str(path))
    kind = extract_type((root / 'Shared' / 'ZeehoActivityAttributes.swift').read_text(encoding='utf-8-sig'),
                        'ZeehoActivityKind')

    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None:
        message = 'swiftc not found; production Swift activity fixtures were NOT executed'
        if args.swiftc or args.require_swift or sys.platform == 'darwin':
            print('FAIL: ' + message, file=sys.stderr)
            return 1
        print('SKIP: ' + message)
        print('OK: activity lifecycle source contracts and build wiring hold')
        return 0

    print('Testing production Shared/SystemActivityPolicy.swift and gated call sites', flush=True)
    with tempfile.TemporaryDirectory(prefix='zeeho-activity-lifecycle-') as directory:
        work = pathlib.Path(directory)
        kind_file = work / 'ZeehoActivityKind.swift'
        tests_file = work / 'ActivityLifecycleTests.swift'
        executable = work / ('activity-lifecycle-test.exe' if sys.platform == 'win32'
                             else 'activity-lifecycle-test')
        kind_file.write_text('import Foundation\n\n' + kind + '\n', encoding='utf-8')
        tests_file.write_text(SWIFT_TESTS, encoding='utf-8')
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library',
                        str(snapshot_source), str(policy_source), str(kind_file), str(tests_file),
                        '-o', str(executable)], cwd=work, check=True, timeout=90)
        subprocess.run([str(executable)], cwd=work, check=True, timeout=30)
    print('OK: activity lifecycle source contracts and build wiring hold')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
