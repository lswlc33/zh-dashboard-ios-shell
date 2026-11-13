import Foundation
import SwiftUI
import WidgetKit
import ZeehoSystemShared

struct ZeehoVehicleEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSnapshot?
    let requiresRefresh: Bool
    var showName = true
    var showTime = true

    var presentation: WidgetVehiclePresentation {
        // 桌面小组件过期后保留最后已知电量/充电状态，只把时间标注成过期，
        // 与 Android 小组件「更新时间 + 可能已过期」口径一致。
        var value = WidgetVehiclePresentation(snapshot: snapshot, date: date, requiresRefresh: requiresRefresh)
        value.keepsLastKnown = true
        value.freshWindow = WidgetFreshness.maxAgeSeconds
        return value
    }
}

struct ZeehoVehicleProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        // 占位和图库都不能伪造一辆车或 100% 电量。
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ZeehoVehicleEntry) -> Void) {
        completion(Self.read(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZeehoVehicleEntry>) -> Void) {
        let now = Date()
        completion(Self.timeline(entry: Self.read(at: now), now: now))
    }

    static func timeline(entry: ZeehoVehicleEntry, now: Date) -> Timeline<ZeehoVehicleEntry> {
        let refreshAfter = now.addingTimeInterval(refreshInterval)
        var entries = [entry]
        if let snapshot = entry.snapshot, let vehicle = snapshot.vehicle,
           !entry.presentation.isStale {
            // 未来 entry 只把数值标成「可能已过期」，不再抹掉电量/充电状态：
            // 过期后保留最后同步值 + 更新时间，和 Android 小组件同一口径。
            // 期限按小组件的 30 分钟窗口算，不能用 180 秒的会话级 expiresAt——
            // 那会让小组件刚加上 3 分钟就显示「可能已过期」。
            let deadline = Date(timeIntervalSince1970: Double(vehicle.updatedAt) / 1000)
                .addingTimeInterval(WidgetFreshness.maxAgeSeconds)
            if deadline > now && deadline <= refreshAfter {
                entries.append(ZeehoVehicleEntry(date: deadline, snapshot: snapshot, requiresRefresh: true,
                    showName: entry.showName, showTime: entry.showTime))
            }
        }
        // 这是刷新请求，不是系统保证；不调用 WidgetCenter 反复催更。
        return Timeline(entries: entries, policy: .after(refreshAfter))
    }

    static func read(at date: Date, vehicleID: String? = nil, showName: Bool? = nil,
                     showTime: Bool? = nil) -> ZeehoVehicleEntry {
        guard SystemSnapshotStore.isAvailable() else {
            return ZeehoVehicleEntry(date: date, snapshot: nil, requiresRefresh: false)
        }
        do {
            // iOS 端只显示「主页当前选中车辆」：不读 widget-settings 里的旧选车记录，
            // 也不提供按实例切换车辆（那是 Android 的 4×2/4×4 多实例模型）。
            // 主 App 切换车辆时会把 active-owner.json 一起换掉，这里自然跟着变。
            let snapshot = try SystemSnapshotStore.readCurrent(now: date)
            // 显示开关只是装饰：配置文件坏了也必须照样显示车况，不能连带吞掉快照。
            let settings = (try? SystemSnapshotStore.currentOwner())
                .flatMap { try? SystemSnapshotStore.widgetSettings(expectedOwner: $0) }
            return ZeehoVehicleEntry(date: date, snapshot: snapshot, requiresRefresh: false,
                showName: showName ?? settings?.showName ?? true, showTime: showTime ?? settings?.showTime ?? true)
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
        VStack(alignment: .leading, spacing: 8) {
            Label(WidgetStrings.title, systemImage: "car.fill")
                .font(.caption)
            Text(WidgetStrings.unavailable)
                .font(.headline)
            Text(family == .systemSmall ? WidgetStrings.unavailableShort : WidgetStrings.unavailableHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        Label(entry.showName ? presentation.name : WidgetStrings.vehicle, systemImage: "car.fill")
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

    /// 时间行：桌面小组件保留最后已知值，所以过期只标注「可能已过期」而不是抹掉数值。
    private var updatedLine: some View {
        WidgetUpdatedAt(timestamp: presentation.updatedAt, stale: presentation.isStale, keepsLastKnown: true)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading
            battery
            charging
            Spacer(minLength: 0)
            if entry.showTime { updatedLine }
            else if presentation.isStale { Text(WidgetStrings.mayBeStale).font(.caption2).foregroundColor(.secondary) }
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
            if entry.showTime { updatedLine }
            else if presentation.isStale { Text(WidgetStrings.mayBeStale).font(.caption2).foregroundColor(.secondary) }
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
            if entry.showTime { updatedLine }
            else if presentation.isStale { Text(WidgetStrings.mayBeStale).font(.caption2).foregroundColor(.secondary) }
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
    // 目标系统已是 iOS 27，不再保留 iOS 17 的 AppIntentConfiguration 分支：
    // 那套需要 AppIntents metadata 提取，而手写 swiftc 流程产不出 const-values。
    // 统一用 StaticConfiguration，组件按 SystemWidgetSettings 的默认车辆显示；
    // Live Activity 仍从 iOS 16.1 起条件注册。
    var body: some Widget {
        ZeehoVehicleWidget()
        if #available(iOS 16.1, *) {
            ZeehoLiveActivityWidget()
        }
    }
}
