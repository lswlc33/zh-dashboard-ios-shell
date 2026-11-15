import Foundation
import SwiftUI
import WidgetKit
import AppIntents
import ZeehoSystemShared

// 小组件的原生编辑面板（iOS 17 起的长按 →「编辑小组件」）。
//
// ## 为什么用 AppIntentConfiguration
//
// iOS 让用户在桌面直接编辑小组件的唯一公开通道就是 `AppIntentConfiguration`：
// 它把 `WidgetConfigurationIntent` 的 `@Parameter` 渲染成系统原生编辑表单，
// 每项写进该实例自己的配置 archive，**不同实例可以各自不同**（Android 的
// widget-settings 是全局一份，做不到）。
//
// ## 和网页设置的关系
//
// 这里只提供「这个实例怎么显示」的开关；网页里的设置（showName/showTime/dark/stats）
// 仍然是**默认值**。配置留空 = 跟随 App 设置，所以老用户升级后观感不变。
//
// ## 硬约束
//
// · `@Parameter` 只放 AppEnum / Bool? / String 这类可归档类型，别放 `WidgetStatField`
//   这种裸 enum（它不是 AppEnum，索引里不会被识别）。
// · 参数顺序即编辑面板顺序，别为了「好看」调换——用户的既有配置按参数名归档，
//   顺序无关但语义不要改。
// · 本文件与 `WidgetCommands.swift` 一样必须进 `Metadata.appintents` 索引，
//   否则编辑面板是空的（且没有任何报错）。

/// 外观：跟随 App 设置 / 跟随系统 / 浅色 / 深色。
///
/// **必须单独有 `followApp`**：1.1.17 之前外观只由 App 内的「深浅色」设置控制。
/// 如果这里默认成 `.auto`，老实例升级成可编辑控件后会被无值配置强制改成「跟随系统」，
/// 用户在 App 里选的深色就被悄悄覆盖了 —— 属于升级回归。
@available(iOS 17.0, *)
enum ZeehoWidgetAppearance: String, AppEnum {
    case followApp, auto, light, dark

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "外观")
    static var caseDisplayRepresentations: [ZeehoWidgetAppearance: DisplayRepresentation] = [
        .followApp: DisplayRepresentation(title: "跟随 App 设置"),
        .auto: DisplayRepresentation(title: "跟随系统"),
        .light: DisplayRepresentation(title: "浅色"),
        .dark: DisplayRepresentation(title: "深色"),
    ]

    /// 映射回 Android 同语义的 darkMode 值；nil 表示「不改，用 App 设置」。
    var darkMode: Int? {
        switch self {
        case .followApp: return nil
        case .auto: return -1
        case .light: return 0
        case .dark: return 1
        }
    }
}

/// 统计区显示哪一组指标。比逐个槽位选更好用：iOS 的编辑面板是表单，六个下拉框没人愿意填。
@available(iOS 17.0, *)
enum ZeehoWidgetStatPreset: String, AppEnum {
    case followApp, ride, battery, tires, account, hidden

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "统计内容")
    static var caseDisplayRepresentations: [ZeehoWidgetStatPreset: DisplayRepresentation] = [
        .followApp: DisplayRepresentation(title: "跟随 App 设置"),
        .ride: DisplayRepresentation(title: "骑行数据"),
        .battery: DisplayRepresentation(title: "电池与充电"),
        .tires: DisplayRepresentation(title: "胎压与温度"),
        .account: DisplayRepresentation(title: "积分与消息"),
        .hidden: DisplayRepresentation(title: "不显示统计"),
    ]

    /// 空数组 = 用 App 设置（`SystemWidgetSettings.stats`）。
    var fields: [WidgetStatField] {
        switch self {
        case .followApp: return []
        case .ride: return [.today, .last, .duration, .total]
        case .battery: return [.soc, .range, .voltage, .current, .power, .chargeState]
        case .tires: return [.tireFront, .tireRear, .tireTempFront, .tireTempRear]
        case .account: return [.integral, .unread]
        case .hidden: return []
        }
    }
}

/// 小组件实例配置。所有参数都是可选的：留空即「跟随 App 设置」。
@available(iOS 17.0, *)
struct ZeehoVehicleWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "车辆状态小组件"
    static var description = IntentDescription("选择这个小部件显示哪些内容；留空则跟随 App 内的设置。")

    @Parameter(title: "显示车名")
    var showName: Bool?

    @Parameter(title: "显示更新时间")
    var showTime: Bool?

    @Parameter(title: "外观", default: .followApp)
    var appearance: ZeehoWidgetAppearance

    @Parameter(title: "统计内容", default: .followApp)
    var stats: ZeehoWidgetStatPreset

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$appearance)外观，统计显示\(\.$stats)") {
            \.$showName
            \.$showTime
        }
    }

    init() {
        appearance = .followApp
        stats = .followApp
    }
}

/// 把一份配置合并进 entry。留空的项保持 App 设置里的值。
@available(iOS 17.0, *)
extension ZeehoVehicleEntry {
    func applying(_ configuration: ZeehoVehicleWidgetConfiguration) -> ZeehoVehicleEntry {
        var value = self
        if let showName = configuration.showName { value.showName = showName }
        if let showTime = configuration.showTime { value.showTime = showTime }
        // nil = 「跟随 App 设置」：保留 entry 里已经从 widget-settings 读到的 darkMode。
        if let dark = configuration.appearance.darkMode { value.darkMode = dark }
        let preset = configuration.stats
        if preset == .hidden {
            value.stats = []
            value.statsHidden = true
        } else {
            let fields = preset.fields
            if !fields.isEmpty { value.stats = fields }
            value.statsHidden = false
        }
        return value
    }
}

/// 支持原生编辑的 provider。
///
/// 取数逻辑与 `ZeehoVehicleProvider` 完全一致（都走 `WidgetDataSource`），
/// 差别只有「多一个 configuration 参数」和异步签名。
@available(iOS 17.0, *)
struct ZeehoVehicleConfigProvider: AppIntentTimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }

    func snapshot(for configuration: ZeehoVehicleWidgetConfiguration, in context: Context) async -> ZeehoVehicleEntry {
        // 预览/图库只读本地，不联网：编辑面板里拖动参数时会反复取快照。
        ZeehoWidgetReader.read(at: Date()).applying(configuration)
    }

    func timeline(for configuration: ZeehoVehicleWidgetConfiguration, in context: Context) async -> Timeline<ZeehoVehicleEntry> {
        // 与 StaticConfiguration 那条一样要防超时：`WidgetDataSource.load` 最坏 18 秒，
        // 而 WidgetKit 的预算只有几秒。超时就交「只读本地」的 entry，
        // 网络结果迟到只会写进缓存，下次刷新自然用上。
        let now = Date()
        let result = await Self.loadWithDeadline(at: now, seconds: 3.5)
        let entry = ZeehoWidgetReader.entry(result, at: now).applying(configuration)
        return ZeehoVehicleProvider.timeline(entry: entry, now: now)
    }

    /// 带硬截止的取数：到点就返回本地快照，不等网络。
    ///
    /// 用 `ResultBox` 包一层而不是 `Optional`：`group.next()` 本身返回 Optional，
    /// 再套一层 `Optional` 会变成双层可选，`if let` 的语义容易写错（编译期看不出来）。
    private static func loadWithDeadline(at date: Date, seconds: Double) async -> WidgetDataSourceResult {
        await withTaskGroup(of: ResultBox.self) { group in
            group.addTask {
                ResultBox(value: await WidgetDataSource.load(at: date))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000))
                return ResultBox(value: nil)
            }
            defer { group.cancelAll() }
            // 只要**第一个完成**的：拿到真结果就用它，拿到 nil 就是超时。
            // 不能 while 轮询——超时分支先返回 nil 后再等 loadTask 等于没做超时。
            let first = await group.next()
            if let value = first?.value { return value }
            return WidgetDataSourceResult(snapshot: ZeehoWidgetReader.read(at: date).snapshot,
                                          origin: .snapshot, reason: "timeout")
        }
    }

    /// 只为了让任务组的结果类型单一（避免 Optional 套 Optional）。
    private struct ResultBox: Sendable {
        let value: WidgetDataSourceResult?
    }
}
