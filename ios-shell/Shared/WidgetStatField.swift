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

    /// 4×4 六格默认顺序。
    ///
    /// **默认槽位只放「一定拿得到」的量**：2026-11-15 真机确认「今日骑行 / 上一次骑行 /
    /// 骑行时长」在实际数据下常年是「—」（ride_home 要进过骑行页才拉，首页场景拿不到；
    /// 积分/未读同理依赖「我的」页）。默认项显示一片空白比少一项更糟，
    /// 所以默认改成总里程 / 胎压 / 电压 / 积分 / 续航 —— 它们都来自 vehicleHomePageV2
    /// 与 batteryInfo 这两个每次必拉的接口。
    /// 想看骑行数据的用户在 App 设置里自己选（那些项仍保留在 `selectable` 里）。
    ///
    /// 注：这不再与 Android `WidgetStats.defaults` 逐格一致——Android 那边骑行数据来自
    /// 长连接实时流，本来就拿得到；iOS 的数据通路不同，默认值跟着数据可得性走。
    public static let defaultLarge: [WidgetStatField] = [.total, .tireFront, .tireRear, .voltage, .integral, .range]
    /// 4×2 两格默认：总里程 + 胎压（同样避开长期缺测的骑行项）。
    public static let defaultMedium: [WidgetStatField] = [.total, .tirePair]

    public static var selectable: [WidgetStatField] {
        [.today, .last, .duration, .total, .soc, .range, .voltage, .current, .power, .chargeState,
         .fullAt, .charged, .tireFront, .tireRear, .tirePair, .tireTempFront, .tireTempRear, .integral, .unread]
    }
}
