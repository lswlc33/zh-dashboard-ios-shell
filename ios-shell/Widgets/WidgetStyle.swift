import Foundation
import SwiftUI
import ZeehoSystemShared

// 桌面小组件的配色与排版 token。
//
// 色值直接抄 Android `WidgetTheme.color(dark, role)` 与 res/drawable/widget_*.xml，
// 目标是 iOS 与 Android 视觉 1:1（用户口径：安卓什么样，iOS 就要什么样）。
// 深浅色按实例偏好（dark = -1 跟随系统 / 0 浅色 / 1 深色）选一套，不依赖 values-night。
enum WidgetPalette {
    // MARK: - 语义色（WidgetTheme.color）
    struct Colors {
        let bg: Color            // 卡片底
        let text: Color          // 主文字
        let muted: Color         // 次文字
        let chipBg: Color        // 刷新按钮底 / 进度轨道底
        let line: Color          // 进度轨道
        let accent: Color        // 电量填充 / 充电中 / 刷新文字
        let good: Color          // 已充满
        let warn: Color          // 离线
        // drawable 实色
        let pillBg: Color        // 锁车/坐垫胶囊
        let btnPrimaryBg: Color  // 解锁主按钮底
        let btnPrimaryText: Color// 解锁主按钮文字（不是通用 text）
        let btnSoftBg: Color     // 锁车/鸣笛/坐垫按钮底
        let dot: Color           // 在线圆点
        let refreshBg: Color     // 刷新按钮底
    }

    static func colors(dark: Bool) -> Colors {
        dark
            ? Colors(bg: hex(0x101318), text: hex(0xF5F6F8), muted: hex(0x9AA0A6),
                     chipBg: hex(0x1B2028), line: hex(0x262C36), accent: hex(0x7FB0FF),
                     good: hex(0x8CE99A), warn: hex(0xFFB4A2),
                     pillBg: hex(0x30363B), btnPrimaryBg: hex(0xDBE4EA),
                     btnPrimaryText: hex(0x222C34), btnSoftBg: hex(0x30363B),
                     dot: hex(0x6FBF9A), refreshBg: hex(0x1B2028))
            : Colors(bg: hex(0xF7F9FD), text: hex(0x131720), muted: hex(0x5F6B7A),
                     chipBg: hex(0xFFFFFF), line: hex(0xE2E8F2), accent: hex(0x2F6FE0),
                     good: hex(0x0E8A5F), warn: hex(0xC2410C),
                     pillBg: hex(0xEDF0F3), btnPrimaryBg: hex(0x23303C),
                     btnPrimaryText: hex(0xFFFFFF), btnSoftBg: hex(0xEDF0F3),
                     dot: hex(0x397B63), refreshBg: hex(0xFFFFFF))
    }

    /// 0xRRGGBB → Color（sRGB，不透明）。
    static func hex(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - 尺寸（Android dp，1:1 照抄）
//
// iOS 的 point 与 Android 的 dp 都是「与密度无关的逻辑单位」，直接按数值搬运即可。
// 各档画布来自 WidgetTheme：2×2=140、4×2=280×175、4×4=280。
enum WidgetMetrics {
    // 卡片
    static let cornerRadius: CGFloat = 24
    static let padSmall: CGFloat = 14      // 2×2 / 4×4
    static let padMedium: CGFloat = 12     // 4×2
    // 进度条
    static let progressHeightSmall: CGFloat = 6   // 2×2 / 4×2
    static let progressHeightLarge: CGFloat = 4   // 4×4
    // 胶囊
    static let pillPadH: CGFloat = 6
    // 按钮
    static let buttonCorner: CGFloat = 16
    static let buttonHeightMedium: CGFloat = 38   // 4×2
    static let buttonHeightLarge: CGFloat = 48    // 4×4
    static let buttonGap: CGFloat = 4
    // 刷新按钮
    static let refreshWidthMedium: CGFloat = 40
    static let refreshWidthLarge: CGFloat = 38
    static let refreshCorner: CGFloat = 14
}

// MARK: - 字号（Android sp）
//
// 逐档照抄 BaseWidget.textSp / 各布局 XML。Android sp 与 iOS pt 同为逻辑单位。
enum WidgetFont {
    // 2×2
    static let s2Title: CGFloat = 9
    static let s2Updated: CGFloat = 8
    static let s2Soc: CGFloat = 34
    static let s2Unit: CGFloat = 12
    static let s2Voltage: CGFloat = 10
    static let s2Charge: CGFloat = 11
    static let s2Pill: CGFloat = 10
    // 4×2
    static let mTitle: CGFloat = 10
    static let mUpdated: CGFloat = 8
    static let mRefresh: CGFloat = 8
    static let mPill: CGFloat = 9
    static let mSoc: CGFloat = 30
    static let mUnit: CGFloat = 10
    static let mCharge: CGFloat = 9
    static let mMidLabel: CGFloat = 9
    static let mMidValue: CGFloat = 13
    static let mButton: CGFloat = 10
    // 4×4
    static let lTitle: CGFloat = 11
    static let lUpdated: CGFloat = 9
    static let lRefresh: CGFloat = 10
    static let lPill: CGFloat = 10
    static let lSoc: CGFloat = 40
    static let lUnit: CGFloat = 12
    static let lCharge: CGFloat = 10
    static let lVoltage: CGFloat = 10
    static let lStatLabel: CGFloat = 10
    static let lStatValue: CGFloat = 15
    static let lStatUnit: CGFloat = 10
    static let lButton: CGFloat = 11
}


// MARK: - 单个统计格的取值
//
// 数值口径与 Android 完全一致：里程 km（1 位小数）、胎压 bar（1 位）、时长分钟。
// 缺测返回 nil，展示层显示「—」而不是 0。
struct WidgetStatValue {
    let label: String
    let value: String
    let unit: String

    /// 按指标从快照取值；`tirePair` 在两颗传感器都缺时让位总里程（Android 9.7 同款规则）。
    static func resolve(_ field: WidgetStatField, vehicle: SystemVehicleSnapshot?,
                        date: Date = Date()) -> WidgetStatValue {
        guard let vehicle = vehicle else { return WidgetStatValue(label: field.title, value: "—", unit: "") }
        func km(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        func bar(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
        func num(_ value: Double?, _ decimals: Int = 0) -> String {
            value.map { String(format: "%.\(decimals)f", $0) } ?? "—"
        }
        let statsFresh = vehicle.visibleStatistics(at: date)
        switch field {
        case .today: return WidgetStatValue(label: field.title, value: statsFresh ? km(vehicle.todayMileKm) : "—", unit: "km")
        case .last: return WidgetStatValue(label: field.title, value: statsFresh ? km(vehicle.lastMileKm) : "—", unit: "km")
        case .duration: return WidgetStatValue(label: field.title, value: statsFresh ? num(vehicle.lastRideMinutes) : "—", unit: "分")
        case .total: return WidgetStatValue(label: field.title, value: statsFresh ? km(vehicle.totalMileKm) : "—", unit: "km")
        case .soc: return WidgetStatValue(label: field.title, value: num(vehicle.visibleSOCPercent(at: date)), unit: "%")
        case .range: return WidgetStatValue(label: field.title, value: statsFresh ? km(vehicle.rangeKm) : "—", unit: "km")
        case .voltage: return WidgetStatValue(label: field.title, value: num(vehicle.visibleVoltage(at: date), 1), unit: "V")
        case .current: return WidgetStatValue(label: field.title, value: num(vehicle.visibleCurrent(at: date), 1), unit: "A")
        case .power:
            let watts = vehicle.visiblePower(at: date)
            if let watts = watts, abs(watts) >= 1000 {
                return WidgetStatValue(label: field.title, value: String(format: "%.1f", watts / 1000), unit: "kW")
            }
            return WidgetStatValue(label: field.title, value: num(watts), unit: "W")
        case .chargeState:
            let text: String
            switch vehicle.visibleCharging(at: date) {
            case .some(true): text = "充电中"
            case .some(false): text = "未充电"
            case .none: text = "—"
            }
            return WidgetStatValue(label: field.title, value: text, unit: "")
        case .fullAt:
            // 充满时间是服务端 ETA，快照里没有独立字段；用充电进度估算会造数据，所以留空。
            return WidgetStatValue(label: field.title, value: "—", unit: "")
        case .charged: return WidgetStatValue(label: field.title, value: "—", unit: "分")
        case .tireFront:
            return WidgetStatValue(label: field.title, value: vehicle.visibleTires(at: date) ? bar(vehicle.tireFrontBar) : "—", unit: "bar")
        case .tireRear:
            return WidgetStatValue(label: field.title, value: vehicle.visibleTires(at: date) ? bar(vehicle.tireRearBar) : "—", unit: "bar")
        case .tirePair:
            // 两颗传感器都没上报 → 让位总里程（只有「都缺」才让位，缺一侧仍显示「—」，同 Android）。
            guard vehicle.hasTirePressure else {
                return WidgetStatValue(label: "总里程", value: statsFresh ? km(vehicle.totalMileKm) : "—", unit: "km")
            }
            let front = vehicle.visibleTires(at: date) ? bar(vehicle.tireFrontBar) : "—"
            let rear = vehicle.visibleTires(at: date) ? bar(vehicle.tireRearBar) : "—"
            return WidgetStatValue(label: field.title, value: "\(front) / \(rear)", unit: "")
        case .tireTempFront:
            return WidgetStatValue(label: field.title, value: vehicle.visibleTires(at: date) ? num(vehicle.tireFrontTemp) : "—", unit: "°C")
        case .tireTempRear:
            return WidgetStatValue(label: field.title, value: vehicle.visibleTires(at: date) ? num(vehicle.tireRearTemp) : "—", unit: "°C")
        case .integral: return WidgetStatValue(label: field.title, value: statsFresh ? num(vehicle.integral) : "—", unit: "分")
        case .unread: return WidgetStatValue(label: field.title, value: statsFresh ? num(vehicle.unread.map(Double.init)) : "—", unit: "条")
        }
    }
}

// MARK: - 状态文案（与 Android BaseWidget 9.1-9.4 完全同序）

enum WidgetStatusText {
    /// 充电/在线状态行的语义色标记（调用点映射到具体色）。
    enum LineTone { case normal, warn, accent }

    /// 充电/在线状态行。优先级：无数据 > 离线 > 充电态 > 锁车态 > 未知（同 Android 9.1）。
    static func chargeLine(vehicle: SystemVehicleSnapshot?, hasData: Bool,
                           date: Date = Date()) -> (text: String, tone: LineTone) {
        guard let vehicle = vehicle, hasData else { return ("打开面板同步", .normal) }
        if vehicle.visibleOnlineState(at: date) == 0 { return ("离线", .warn) }
        if let charging = vehicle.visibleCharging(at: date) {
            return charging ? ("充电中", .accent) : ("未充电", .normal)
        }
        switch vehicle.visibleLockState(at: date) {
        case .some(1): return ("已锁车", .normal)
        case .some(0): return ("未锁车", .normal)
        default: return ("状态未知", .normal)
        }
    }
    /// 锁车胶囊：只有明确的 1/0 才显示，未知整颗胶囊消失（同 Android 9.2）。
    static func lockPill(vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> String? {
        switch vehicle?.visibleLockState(at: date) {
        case .some(1): return "已锁车"
        case .some(0): return "未锁车"
        default: return nil
        }
    }
    /// 坐垫胶囊：同上（Android 9.3）。
    static func seatPill(vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> String? {
        switch vehicle?.visibleSeatState(at: date) {
        case .some(1): return "坐垫已锁"
        case .some(0): return "坐垫未锁"
        default: return nil
        }
    }
    /// 在线文案：只有明确的离线（0）才说离线；未知按在线（同 Android 9.4）。
    static func onlineText(vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> String {
        vehicle?.visibleOnlineState(at: date) == 0 ? "离线" : "在线"
    }
    static func outageDot(vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> Bool {
        vehicle?.visibleOnlineState(at: date) != 0
    }
    /// 电量数字：未知显示「--」（Android widget_soc_unknown）。
    static func soc(_ vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> String {
        guard let value = vehicle?.visibleSOCPercent(at: date) else { return "--" }
        return String(format: "%.0f", value)
    }
    /// 电压尾巴（2×2）：「82.8 V」。
    static func voltageTail(_ vehicle: SystemVehicleSnapshot?, date: Date = Date()) -> String? {
        guard let value = vehicle?.visibleVoltage(at: date), value > 0 else { return nil }
        return String(format: "%.1f V", value)
    }
    /// 更新时间：超过 30 分钟一律带上「可能已过期」（Android 7.9）。
    static func updated(_ timestamp: Int64?, stale: Bool, now: Date = Date()) -> String {
        guard let timestamp = timestamp else { return "更新 --" }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        let age = now.timeIntervalSince(date)
        formatter.dateFormat = age > 12 * 3600 ? "MM-dd HH:mm" : "HH:mm"
        let text = formatter.string(from: date)
        return stale ? "\(text) · 可能已过期" : "\(text) 更新"
    }
}
