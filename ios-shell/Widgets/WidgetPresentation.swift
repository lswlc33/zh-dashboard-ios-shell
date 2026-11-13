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
    static let unavailableShort = "打开 App 主页同步"
    static let unavailableHint = "打开 App 进入主页即可同步当前车辆；系统决定小组件的刷新时间。"
    static let unknown = "未知"
    static let missing = "—"
    static let soc = "电量"
    static let charging = "充电中"
    static let notCharging = "未充电"
    static let chargingState = "充电状态"
    static let chargeProgress = "充电进度"
    static let stale = "数据已过期"
    static let mayBeStale = "可能已过期"
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

// 桌面小组件的「可能已过期」时间窗。
//
// 共享层的新鲜窗口是 180 秒（Live Activity 需要），但 WidgetKit 的刷新由系统
// 预算决定，通常十几分钟才一次；沿用 180 秒会让桌面小组件永远挂着过期标记。
// 这里对齐 Android 小组件的 30 分钟口径（BaseWidget.updated()）。
enum WidgetFreshness {
    static let maxAgeSeconds: Double = 30 * 60
}

// 这是对共享 schema 的展示包装，不复制 wire 字段或另设一套 TTL。
struct WidgetVehiclePresentation {
    let snapshot: SystemSnapshot?
    let date: Date
    var requiresRefresh = false
    // 桌面小组件保留最后已知值（过期只标注时间，和 Android 小组件一致）；
    // Live Activity 不打开这个开关：锁屏上的数值会被当成实时读数。
    var keepsLastKnown = false
    // 判过期用的时间窗；桌面小组件传 WidgetFreshness.maxAgeSeconds，其余保持 180 秒。
    var freshWindow: Double = SystemSnapshotFreshness.vehicleMaxAgeSeconds

    var vehicle: SystemVehicleSnapshot? { snapshot?.vehicle }
    var name: String { vehicle?.name ?? WidgetStrings.vehicle }
    /// 数值本身是否已过 freshWindow 新鲜窗口。
    var isStale: Bool {
        guard let snapshot = snapshot else { return false }
        if requiresRefresh { return true }
        guard let vehicle = vehicle else { return snapshot.isStale(at: date) }
        if freshWindow > SystemSnapshotFreshness.vehicleMaxAgeSeconds {
            // 宽窗口模式（桌面小组件）：只看最后同步时间，不看 expiresAt
            // （expiresAt 是 180 秒的会话级期限，用它判断会让小组件长期显示过期）。
            let age = date.timeIntervalSince1970 - Double(vehicle.updatedAt) / 1000
            return age > freshWindow || age < -SystemSnapshotFreshness.futureToleranceSeconds
        }
        if snapshot.isStale(at: date) { return true }
        return (vehicle.socPercent != nil && vehicle.visibleSOCPercent(at: date) == nil)
            || (vehicle.charging != nil && vehicle.visibleCharging(at: date) == nil)
            || (vehicle.chargeProgressPercent != nil && vehicle.visibleChargeProgress(at: date) == nil)
    }
    // keepsLastKnown 时直接给原始值：过期了也显示「上次同步到的电量 + 更新时间」，
    // 而不是把整块数据抹成「—」（那正是小组件长期空白的原因）。
    var soc: Double? { keepsLastKnown ? vehicle?.socPercent : (isStale ? nil : vehicle?.visibleSOCPercent(at: date)) }
    var charging: Bool? { keepsLastKnown ? vehicle?.charging : (isStale ? nil : vehicle?.visibleCharging(at: date)) }
    var chargeProgress: Double? {
        guard charging == true else { return nil }
        return keepsLastKnown ? vehicle?.chargeProgressPercent : vehicle?.visibleChargeProgress(at: date)
    }
    var updatedAt: Int64? { vehicle?.updatedAt }
}

struct WidgetUpdatedAt: View {
    let timestamp: Int64?
    let stale: Bool
    // 桌面小组件保留最后已知值时用 true：同一行写「时间 · 可能已过期」，
    // 与 Android 小组件的 widget_updated_stale 一致，不再单独占一行红字。
    var keepsLastKnown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if stale && !keepsLastKnown {
                Label(WidgetStrings.stale, systemImage: "exclamationmark.circle")
                    .font(.caption2)
            }
            if let timestamp = timestamp {
                let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
                Text(line(date))
                    .font(.caption2)
                    .lineLimit(2)
            } else {
                Text("\(WidgetStrings.lastUpdated) \(WidgetStrings.missing)")
                    .font(.caption2)
            }
        }
        .foregroundColor(.secondary)
    }

    private func line(_ date: Date) -> String {
        let stamp = "\(WidgetStrings.lastUpdated) \(date.formatted(date: .numeric, time: .shortened))"
        return stale && keepsLastKnown ? "\(stamp) · \(WidgetStrings.mayBeStale)" : stamp
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
