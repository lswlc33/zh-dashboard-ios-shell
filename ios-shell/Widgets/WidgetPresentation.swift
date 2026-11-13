import Foundation
import SwiftUI
import UIKit
import WidgetKit
import ZeehoSystemShared

// Extension 文案独立集中；不把主 App 的权限、凭据或网页桥一起链接进小组件。
enum WidgetStrings {
    static let title = "几何面板"
    static let vehicle = "车辆"
    static let displayName = "车辆状态"
    static let description = "显示 App 最近同步的电量与充电状态；系统决定刷新时间。"
    static let unavailable = "车况暂无数据"
    static let unavailableHint = "请打开 App 同步车辆；共享数据不可用时不显示示例车辆。"
    static let unknown = "未知"
    static let missing = "—"
    static let soc = "电量"
    static let charging = "充电中"
    static let notCharging = "未充电"
    static let chargingState = "充电状态"
    static let chargeProgress = "充电进度"
    static let stale = "数据已过期"
    static let lastUpdated = "最后更新"
    static let snapshotOnly = "仅显示 App 最近同步的数据"
    static let refreshHint = "不会在小组件中查询车辆或获取位置。"
    static let ride = "骑行记录"
    static let rideWaiting = "等待记录"
    static let rideRecording = "记录中"
    static let ridePaused = "已暂停"
    static let rideInterrupted = "记录中断"
    static let rideEnded = "已结束"
    static let speed = "速度"
    static let speedUnit = "km/h"
    static let elapsed = "已记录时长"
    static let activityUnavailable = "暂无数据"
    static let nativeGauge = "原生仪表"
}

enum WidgetValueText {
    static func percent(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return WidgetStrings.missing }
        return String(format: "%.0f%%", value)
    }

    static func speed(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return WidgetStrings.missing }
        return String(format: "%.0f", value)
    }

    static func elapsed(_ seconds: Double?) -> String {
        // 只格式化原生实际记录的时长；不能拿现在减 startedAt 补出未收到的进度。
        guard let seconds = seconds, seconds.isFinite, seconds >= 0, seconds <= 31_536_000 else {
            return WidgetStrings.missing
        }
        let total = Int(seconds.rounded(.down))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func charging(_ value: Bool?) -> String {
        guard let value = value else { return WidgetStrings.unknown }
        return value ? WidgetStrings.charging : WidgetStrings.notCharging
    }

    static func chargingSymbol(_ value: Bool?) -> String {
        guard let value = value else { return "questionmark.circle" }
        return value ? "bolt.fill" : "powerplug"
    }

    static func batterySymbol(soc: Double?, charging: Bool?) -> String {
        if charging == true { return "bolt.fill" }
        guard let soc = soc else { return "questionmark.circle" }
        switch soc {
        case ..<12.5: return "battery.0"
        case ..<37.5: return "battery.25"
        case ..<62.5: return "battery.50"
        case ..<87.5: return "battery.75"
        default: return "battery.100"
        }
    }
}

// 这是对共享 schema 的展示包装，不复制 wire 字段或另设一套 TTL。
struct WidgetVehiclePresentation {
    let snapshot: SystemSnapshot?
    let date: Date
    var requiresRefresh = false

    var vehicle: SystemVehicleSnapshot? { snapshot?.vehicle }
    var name: String { vehicle?.name ?? WidgetStrings.vehicle }
    var isStale: Bool {
        guard let snapshot = snapshot else { return false }
        if requiresRefresh || snapshot.isStale(at: date) { return true }
        guard let vehicle = vehicle else { return false }
        return (vehicle.socPercent != nil && vehicle.visibleSOCPercent(at: date) == nil)
            || (vehicle.charging != nil && vehicle.visibleCharging(at: date) == nil)
            || (vehicle.chargeProgressPercent != nil && vehicle.visibleChargeProgress(at: date) == nil)
    }
    var soc: Double? { isStale ? nil : vehicle?.visibleSOCPercent(at: date) }
    var charging: Bool? { isStale ? nil : vehicle?.visibleCharging(at: date) }
    var chargeProgress: Double? {
        charging == true && !isStale ? vehicle?.visibleChargeProgress(at: date) : nil
    }
    var updatedAt: Int64? { vehicle?.updatedAt }
}

struct WidgetUpdatedAt: View {
    let timestamp: Int64?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if stale {
                Label(WidgetStrings.stale, systemImage: "exclamationmark.circle")
                    .font(.caption2)
            }
            if let timestamp = timestamp {
                let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
                Text("\(WidgetStrings.lastUpdated) \(date.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .lineLimit(2)
            } else {
                Text("\(WidgetStrings.lastUpdated) \(WidgetStrings.missing)")
                    .font(.caption2)
            }
        }
        .foregroundColor(.secondary)
    }
}

struct WidgetSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            // 使用 WidgetKit 的系统背景约定，允许系统决定背景及边距的展示。
            content.containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        } else {
            content.padding(16).background(Color(uiColor: .systemBackground))
        }
    }
}
