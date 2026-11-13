import AppIntents
import Foundation
import WidgetKit
import ZeehoSystemShared

// iOS 17 的真正 AppIntentConfiguration；没有手写 INIntent 假类或网页伪造实例 id。
// 15.4–16.x 沿用 StaticConfiguration，状态明确 perInstanceVehicleSelection=false。
@available(iOS 17.0, *)
struct ZeehoWidgetVehicleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "车辆")
    static var defaultQuery = ZeehoWidgetVehicleQuery()
    let id: String
    let name: String
    let suffix: String?
    var displayRepresentation: DisplayRepresentation {
        if let suffix = suffix { return DisplayRepresentation(title: "\(name)", subtitle: "尾号 \(suffix)") }
        return DisplayRepresentation(title: "\(name)")
    }
    init(_ value: SystemWidgetVehicle) {
        id = value.id; name = value.name ?? WidgetStrings.vehicle; suffix = value.suffix
    }
}

@available(iOS 17.0, *)
struct ZeehoWidgetVehicleQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ZeehoWidgetVehicleEntity] {
        guard identifiers.count <= SystemSnapshotStore.maxVehicles else { return [] }
        let accepted = Set(identifiers)
        return try choices().filter { accepted.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ZeehoWidgetVehicleEntity] { try choices() }
    private func choices() throws -> [ZeehoWidgetVehicleEntity] {
        guard SystemSnapshotStore.isAvailable() else { return [] }
        return try SystemSnapshotStore.vehicles().map(ZeehoWidgetVehicleEntity.init)
    }
}

@available(iOS 17.0, *)
struct ZeehoVehicleConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "车辆状态"
    static var description = IntentDescription("每个小组件可选择一辆已在 App 同步的车辆；不会查询云端或定位。")
    @Parameter(title: "车辆（未选时使用 App 默认）") var vehicle: ZeehoWidgetVehicleEntity?
    @Parameter(title: "显示车辆名称", default: true) var showName: Bool
    @Parameter(title: "显示更新时间", default: true) var showTime: Bool
}

@available(iOS 17.0, *)
struct ZeehoConfiguredVehicleWidget: Widget {
    let kind = "ZeehoVehicleWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ZeehoVehicleConfigurationIntent.self,
                               provider: ZeehoConfiguredVehicleProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.displayName)
        .description(WidgetStrings.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@available(iOS 17.0, *)
struct ZeehoConfiguredVehicleProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }
    func snapshot(for configuration: ZeehoVehicleConfigurationIntent, in context: Context) async -> ZeehoVehicleEntry {
        ZeehoVehicleProvider.read(at: Date(), vehicleID: configuration.vehicle?.id,
            showName: configuration.showName, showTime: configuration.showTime)
    }
    func timeline(for configuration: ZeehoVehicleConfigurationIntent, in context: Context) async -> Timeline<ZeehoVehicleEntry> {
        let now = Date()
        let entry = ZeehoVehicleProvider.read(at: now, vehicleID: configuration.vehicle?.id,
            showName: configuration.showName, showTime: configuration.showTime)
        return ZeehoVehicleProvider.timeline(entry: entry, now: now)
    }
}
