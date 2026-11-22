import ActivityKit
import Foundation
import SwiftUI
import WidgetKit
import ZeehoSystemShared

@available(iOS 16.1, *)
private struct LiveActivityPresentation {
    let context: ActivityViewContext<ZeehoActivityAttributes>
    let date: Date

    var snapshot: SystemSnapshot? {
        // Activity payload 也验证真实 shared graph 与匿名 owner；不可展示失配的另一辆车。
        try? context.state.snapshot.validated(expectedOwner: context.attributes.owner, now: date)
    }
    var kind: ZeehoActivityKind { context.attributes.kind }
    var systemIsStale: Bool {
        if #available(iOS 16.2, *) { return context.isStale }
        return false
    }
    var vehicle: WidgetVehiclePresentation {
        // 锁屏/灵动岛只展示最后一次同步到的值：界面已经写了「最后更新」时间，
        // 用户能自己判断新旧；把电量/充电状态抹成「—」反而丢掉了有用信息。
        // 时间窗与桌面小组件对齐 30 分钟口径（WidgetFreshness.maxAgeSeconds）。
        var value = WidgetVehiclePresentation(snapshot: snapshot, date: date, requiresRefresh: systemIsStale)
        value.keepsLastKnown = true
        value.freshWindow = WidgetFreshness.maxAgeSeconds
        return value
    }
    var ride: SystemRideSnapshot? { snapshot?.ride }
    var isGauge: Bool { kind == .gauge }
    var speedDisplay: Bool { kind == .ride || isGauge }
    var available: Bool { isGauge ? snapshot?.gauge != nil : kind == .ride ? ride != nil : snapshot?.vehicle != nil }
    var isStale: Bool {
        guard let snapshot = snapshot else { return false }
        if systemIsStale || snapshot.isStale(at: date) { return true }
        if isGauge { return snapshot.gauge?.visibleSpeedKph(at: date) == nil }
        if kind == .ride, let ride = ride {
            let stateFresh = SystemSnapshotFreshness.isFresh(ride.updatedAt, at: date,
                maxAgeSeconds: SystemSnapshotFreshness.rideSpeedMaxAgeSeconds)
            return !stateFresh || (ride.speedKph != nil && ride.visibleSpeedKph(at: date) == nil)
        }
        return vehicle.isStale
    }
    var name: String { snapshot?.vehicle?.name ?? WidgetStrings.vehicle }
    var updatedAt: Int64? { isGauge ? snapshot?.gauge?.updatedAt : kind == .ride ? ride?.updatedAt : snapshot?.vehicle?.updatedAt }
    // 车速/时长同样给最后已知的原始值：过期只由下面的「最后更新」时间体现，
    // 不再用 visibleSpeedKph 的 10 秒窗口把锁屏读数抹成「—」。
    var speed: Double? {
        isGauge ? snapshot?.gauge?.speedKph : ride?.speedKph
    }
    var elapsedText: String { WidgetValueText.elapsed(ride?.elapsedSeconds) }
    /// 充电段起点（ContentState.chargeStartedAt）：视图用系统计时器
    /// （Text(timerInterval:)）让「已充电」时长在锁屏/灵动岛自动走表，
    /// 不依赖 App 进程存活；未充电或字段缺失（旧版本写入的活动）时不显示。
    var chargeStarted: Date? {
        guard kind == .charging, vehicle.charging == true, let ms = context.state.chargeStartedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
    var primaryText: String {
        speedDisplay ? WidgetValueText.speed(speed) : WidgetValueText.percent(vehicle.soc)
    }
    var primaryLabel: String { speedDisplay ? WidgetStrings.speed : WidgetStrings.soc }
    var icon: String {
        guard available else { return "questionmark.circle" }
        // 过期不再换感叹号：图标只表达业务形态，时间新旧交给「最后更新」那一行。
        if isGauge { return "speedometer" }
        if kind == .ride {
            switch ride?.state {
            case .recording?: return "bicycle"
            case .paused?: return "pause.fill"
            case .interrupted?: return "exclamationmark.circle"
            case .ended?: return "checkmark.circle"
            default: return "clock"
            }
        }
        return WidgetValueText.batterySymbol(soc: vehicle.soc, charging: vehicle.charging)
    }
    var status: String {
        guard available else { return WidgetStrings.activityUnavailable }
        // 状态文案始终是真实业务状态；过期由「最后更新」行体现，不换成「数据已过期」。
        if isGauge { return WidgetStrings.nativeGauge }
        if kind == .ride {
            switch ride?.state {
            case .waiting?: return WidgetStrings.rideWaiting
            case .recording?: return WidgetStrings.rideRecording
            case .paused?: return WidgetStrings.ridePaused
            case .interrupted?: return WidgetStrings.rideInterrupted
            case .ended?: return WidgetStrings.rideEnded
            default: return WidgetStrings.unknown
            }
        }
        return WidgetValueText.charging(vehicle.charging)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityBanner: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>
    private var presentation: LiveActivityPresentation {
        LiveActivityPresentation(context: context, date: Date())
    }

    var body: some View {
        let presentation = self.presentation
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(presentation.name, systemImage: presentation.icon)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(presentation.status).font(.caption).lineLimit(1)
            }
            if presentation.speedDisplay {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WidgetStrings.speed).font(.caption).foregroundColor(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(presentation.primaryText).font(.title2.monospacedDigit())
                            Text(WidgetStrings.speedUnit).font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    if !presentation.isGauge {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(WidgetStrings.elapsed).font(.caption).foregroundColor(.secondary)
                            Text(presentation.elapsedText).font(.title2.monospacedDigit())
                        }
                    }
                }
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WidgetStrings.soc).font(.caption).foregroundColor(.secondary)
                        Text(presentation.primaryText).font(.title2.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                    Label(WidgetValueText.charging(presentation.vehicle.charging),
                          systemImage: WidgetValueText.chargingSymbol(presentation.vehicle.charging))
                        .font(.subheadline)
                }
                if let started = presentation.chargeStarted {
                    // 系统计时器自动走表：App 挂起时「已充电」仍逐秒推进，无需后台执行权。
                    HStack(spacing: 6) {
                        Text(WidgetStrings.chargeElapsed).font(.caption).foregroundColor(.secondary)
                        Text(timerInterval: started...started.addingTimeInterval(86_400), countsDown: false)
                            .font(.caption.monospacedDigit())
                    }
                }
                if let progress = presentation.vehicle.chargeProgress {
                    HStack(spacing: 8) {
                        Text(WidgetStrings.chargeProgress).font(.caption)
                        ProgressView(value: progress, total: 100)
                        Text(WidgetValueText.percent(progress)).font(.caption.monospacedDigit())
                    }
                }
            }
            // annotatesStale: false —— 实时活动不出现「数据已过期/可能已过期」，
            // 只保留「最后更新 <时间>」这一行。
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale,
                            annotatesStale: false)
        }
        .padding(16)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityExpandedLeading: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        VStack(alignment: .leading, spacing: 4) {
            Label(presentation.name, systemImage: presentation.icon)
                .font(.caption)
                .lineLimit(1)
            Text(presentation.status).font(.caption2).lineLimit(2)
        }
    }
}

@available(iOS 16.1, *)
private struct LiveActivityExpandedTrailing: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        VStack(alignment: .trailing, spacing: 3) {
            Text(presentation.primaryLabel).font(.caption2)
            Text(presentation.primaryText).font(.title2.monospacedDigit()).lineLimit(1)
            if presentation.speedDisplay {
                Text(WidgetStrings.speedUnit).font(.caption2)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct LiveActivityExpandedBottom: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        VStack(alignment: .leading, spacing: 6) {
            if presentation.kind == .ride {
                HStack {
                    Text(WidgetStrings.elapsed).font(.caption)
                    Spacer(minLength: 0)
                    Text(presentation.elapsedText).font(.headline.monospacedDigit())
                }
            } else if let progress = presentation.vehicle.chargeProgress {
                HStack {
                    Text(WidgetStrings.chargeProgress).font(.caption)
                    ProgressView(value: progress, total: 100)
                    Text(WidgetValueText.percent(progress)).font(.caption.monospacedDigit())
                }
            }
            if let started = presentation.chargeStarted {
                HStack {
                    Text(WidgetStrings.chargeElapsed).font(.caption)
                    Spacer(minLength: 0)
                    Text(timerInterval: started...started.addingTimeInterval(86_400), countsDown: false)
                        .font(.headline.monospacedDigit())
                }
            }
            // annotatesStale: false —— 实时活动不出现「数据已过期/可能已过期」，
            // 只保留「最后更新 <时间>」这一行。
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale,
                            annotatesStale: false)
        }
    }
}

@available(iOS 16.1, *)
private struct LiveActivityCompactLeading: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        Image(systemName: presentation.icon)
            .accessibilityLabel(presentation.status)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityCompactTrailing: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        Text(presentation.primaryText)
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("\(presentation.primaryLabel) \(presentation.primaryText)")
    }
}

@available(iOS 16.1, *)
private struct LiveActivityMinimal: View {
    let context: ActivityViewContext<ZeehoActivityAttributes>

    var body: some View {
        let presentation = LiveActivityPresentation(context: context, date: Date())
        Image(systemName: presentation.icon)
            .accessibilityLabel("\(presentation.status) \(presentation.primaryText)")
    }
}

@available(iOS 16.1, *)
struct ZeehoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZeehoActivityAttributes.self) { context in
            // 锁屏/横幅都是系统 Live Activity，不用另一种 ExtensionKit target。
            LiveActivityBanner(context: context)
        } dynamicIsland: { context in
            // 仅支持 Dynamic Island 的设备由系统展示这些标准区域；其他设备仍有锁屏布局。
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityExpandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityExpandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityExpandedBottom(context: context)
                }
            } compactLeading: {
                LiveActivityCompactLeading(context: context)
            } compactTrailing: {
                LiveActivityCompactTrailing(context: context)
            } minimal: {
                LiveActivityMinimal(context: context)
            }
        }
    }
}
