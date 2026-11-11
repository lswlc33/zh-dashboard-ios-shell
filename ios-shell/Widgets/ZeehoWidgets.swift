import Foundation
import SwiftUI
import WidgetKit
import ZeehoSystemShared

struct ZeehoVehicleEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSnapshot?
    let requiresRefresh: Bool

    var presentation: WidgetVehiclePresentation {
        WidgetVehiclePresentation(snapshot: snapshot, date: date, requiresRefresh: requiresRefresh)
    }
}

struct ZeehoVehicleProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        // 占位和图库都不能伪造一辆车或 100% 电量。
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ZeehoVehicleEntry) -> Void) {
        completion(read(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZeehoVehicleEntry>) -> Void) {
        let now = Date()
        let entry = read(at: now)
        let refreshAfter = now.addingTimeInterval(Self.refreshInterval)
        var entries = [entry]
        if let snapshot = entry.snapshot, let vehicle = snapshot.vehicle,
           !entry.presentation.isStale {
            // 唯一未来 entry 只撤下过期数值，不预测电量/车速，也不改变原始数据时间。
            var deadlines = [Date(timeIntervalSince1970: Double(snapshot.expiresAt) / 1000)]
            let times = [vehicle.socUpdatedAt, vehicle.chargingUpdatedAt, vehicle.chargeProgressUpdatedAt]
            for timestamp in times.compactMap({ $0 }) {
                deadlines.append(Date(timeIntervalSince1970: Double(timestamp) / 1000)
                    .addingTimeInterval(SystemSnapshotFreshness.vehicleMaxAgeSeconds))
            }
            if let deadline = deadlines.filter({ $0 > now && $0 <= refreshAfter }).min() {
                entries.append(ZeehoVehicleEntry(date: deadline, snapshot: snapshot, requiresRefresh: true))
            }
        }
        // 这是刷新请求，不是系统保证；不调用 WidgetCenter 反复催更。
        completion(Timeline(entries: entries, policy: .after(refreshAfter)))
    }

    private func read(at date: Date) -> ZeehoVehicleEntry {
        guard SystemSnapshotStore.isAvailable() else {
            return ZeehoVehicleEntry(date: date, snapshot: nil, requiresRefresh: false)
        }
        do {
            let snapshot = try SystemSnapshotStore.readCurrent(now: date)
            return ZeehoVehicleEntry(date: date, snapshot: snapshot, requiresRefresh: false)
        } catch {
            // 未声明/未获准的组、缺文件、坏 JSON、版本和 owner 不符统一 fail closed。
            return ZeehoVehicleEntry(date: date, snapshot: nil, requiresRefresh: false)
        }
    }
}

struct ZeehoVehicleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ZeehoVehicleEntry

    private var presentation: WidgetVehiclePresentation { entry.presentation }

    var body: some View {
        Group {
            if presentation.vehicle == nil {
                unavailable
            } else {
                switch family {
                case .systemMedium: medium
                case .systemLarge: large
                default: small
                }
            }
        }
        .modifier(WidgetSurface())
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(WidgetStrings.title, systemImage: "car.fill")
                .font(.caption)
            Text(WidgetStrings.unavailable)
                .font(.headline)
            Text(WidgetStrings.missing)
                .font(.largeTitle.monospacedDigit())
            if family != .systemSmall {
                Text(WidgetStrings.unavailableHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            WidgetUpdatedAt(timestamp: nil, stale: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        Label(presentation.name, systemImage: "car.fill")
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(WidgetStrings.soc,
                  systemImage: WidgetValueText.batterySymbol(soc: presentation.soc, charging: presentation.charging))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(WidgetValueText.percent(presentation.soc))
                .font(.system(size: family == .systemSmall ? 32 : 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var charging: some View {
        Label(WidgetValueText.charging(presentation.charging),
              systemImage: WidgetValueText.chargingSymbol(presentation.charging))
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading
            battery
            charging
            Spacer(minLength: 0)
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
            HStack(alignment: .center, spacing: 20) {
                battery
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(WidgetStrings.chargingState).font(.caption).foregroundColor(.secondary)
                    charging
                }
            }
            Spacer(minLength: 0)
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            battery
            charging
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(WidgetStrings.chargeProgress).font(.caption).foregroundColor(.secondary)
                if let progress = presentation.chargeProgress {
                    ProgressView(value: progress, total: 100)
                    Text(WidgetValueText.percent(progress)).font(.subheadline.monospacedDigit())
                } else {
                    // ProgressView 无值会变成转圈；未知应显示空值而非假装在更新。
                    Text(WidgetStrings.missing).font(.subheadline)
                }
            }
            Spacer(minLength: 0)
            WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale)
            Text(WidgetStrings.snapshotOnly).font(.caption).foregroundColor(.secondary)
            Text(WidgetStrings.refreshHint).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ZeehoVehicleWidget: Widget {
    let kind = "ZeehoVehicleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZeehoVehicleProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.displayName)
        .description(WidgetStrings.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ZeehoWidgets: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        ZeehoVehicleWidget()
        if #available(iOS 16.1, *) {
            ZeehoLiveActivityWidget()
        }
    }
}
