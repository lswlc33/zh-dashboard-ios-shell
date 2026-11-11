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
        WidgetVehiclePresentation(snapshot: snapshot, date: date, requiresRefresh: systemIsStale)
    }
    var ride: SystemRideSnapshot? { snapshot?.ride }
    var available: Bool { kind == .ride ? ride != nil : snapshot?.vehicle != nil }
    var isStale: Bool {
        guard let snapshot = snapshot else { return false }
        if systemIsStale || snapshot.isStale(at: date) { return true }
        if kind == .ride, let ride = ride {
            let stateFresh = SystemSnapshotFreshness.isFresh(ride.updatedAt, at: date,
                maxAgeSeconds: SystemSnapshotFreshness.rideSpeedMaxAgeSeconds)
            return !stateFresh || (ride.speedKph != nil && ride.visibleSpeedKph(at: date) == nil)
        }
        return vehicle.isStale
    }
    var name: String { snapshot?.vehicle?.name ?? WidgetStrings.vehicle }
    var updatedAt: Int64? { kind == .ride ? ride?.updatedAt : snapshot?.vehicle?.updatedAt }
    var speed: Double? { isStale ? nil : ride?.visibleSpeedKph(at: date) }
    var elapsedText: String { WidgetValueText.elapsed(isStale ? nil : ride?.elapsedSeconds) }
    var primaryText: String {
        kind == .ride ? WidgetValueText.speed(speed) : WidgetValueText.percent(vehicle.soc)
    }
    var primaryLabel: String { kind == .ride ? WidgetStrings.speed : WidgetStrings.soc }
    var icon: String {
        guard available else { return "questionmark.circle" }
        if isStale { return "exclamationmark.circle" }
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
        if isStale { return WidgetStrings.stale }
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
            if presentation.kind == .ride {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WidgetStrings.speed).font(.caption).foregroundColor(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(presentation.primaryText).font(.title2.monospacedDigit())
                            Text(WidgetStrings.speedUnit).font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(WidgetStrings.elapsed).font(.caption).foregroundColor(.secondary)
                        Text(presentation.elapsedText).font(.title2.monospacedDigit())
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
                if let progress = presentation.vehicle.chargeProgress {
                    HStack(spacing: 8) {
                        Text(WidgetStrings.chargeProgress).font(.caption)
                        ProgressView(value: progress, total: 100)
                        Text(WidgetValueText.percent(progress)).font(.caption.monospacedDigit())
                    }
                }
            }
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale)
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
            if presentation.kind == .ride {
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
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale)
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
