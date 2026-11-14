import Foundation

// 统计槽位指标：与 Android WidgetStats 同一套稳定 id（持久化契约，改名会让老配置失效）。
// 放在 Shared 而不是 Widgets：SystemWidgetSettings 要按它做校验，而 Shared 模块
// 不包含 Widgets 目录；同时 Host 与扩展都必须能读到同一份顺序定义。
// MARK: - 统计槽位
//
// 与 Android WidgetStats 同一套稳定 id（持久化契约，改名会让老配置失效）。
// 这里只列小组件展示需要的子集；retired 的 lock/seat/online/updated 不进槽位
// （它们在布局里是固定位置的状态元素，与 Android 一致）。
public enum WidgetStatField: String, CaseIterable, Codable, Sendable {
    case today, last, duration, total
    case soc, range, voltage, current, power
    case chargeState, fullAt, charged
    case tireFront, tireRear, tirePair, tireTempFront, tireTempRear
    case integral, unread

    public var title: String {
        switch self {
        case .today: return "今日骑行"
        case .last: return "上一次骑行"
        case .duration: return "骑行时长"
        case .total: return "总里程"
        case .soc: return "电量"
        case .range: return "仪表续航"
        case .voltage: return "电压"
        case .current: return "电流"
        case .power: return "功率"
        case .chargeState: return "充电状态"
        case .fullAt: return "充满时间"
        case .charged: return "已充时长"
        case .tireFront: return "前轮胎压"
        case .tireRear: return "后轮胎压"
        case .tirePair: return "胎压"
        case .tireTempFront: return "前胎温度"
        case .tireTempRear: return "后胎温度"
        case .integral: return "积分"
        case .unread: return "未读消息"
        }
    }

    /// 该指标所属分组（用于编辑界面分组展示，与 Android STAT_GROUPS 一致）。
    public var group: String {
        switch self {
        case .today, .last, .duration, .total: return "骑行"
        case .soc, .range, .voltage, .current, .power, .chargeState, .fullAt, .charged: return "电池与充电"
        case .tireFront, .tireRear, .tirePair, .tireTempFront, .tireTempRear: return "胎压与温度"
        case .integral, .unread: return "账号"
        }
    }

    /// 4×4 六格默认顺序（与 Android WidgetStats.defaults 逐格一致，老用户升级不变）。
    public static let defaultLarge: [WidgetStatField] = [.today, .last, .duration, .tireFront, .tireRear, .integral]
    /// 4×2 两格默认（沿用旧中间列两行）。
    public static let defaultMedium: [WidgetStatField] = [.today, .tirePair]

    public static var selectable: [WidgetStatField] {
        [.today, .last, .duration, .total, .soc, .range, .voltage, .current, .power, .chargeState,
         .fullAt, .charged, .tireFront, .tireRear, .tirePair, .tireTempFront, .tireTempRear, .integral, .unread]
    }
}
