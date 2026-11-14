import Foundation

// AppIntent 的实体 id 只有匿名 owner；不得把完整 VIN、token、账号名放入配置 archive。
public struct SystemWidgetVehicle: Equatable, Sendable {
    public let owner: SystemSnapshotOwner
    public let name: String?
    public let suffix: String?
    public var id: String { owner.accountVINHash + "." + owner.scopeID }
    public init(owner: SystemSnapshotOwner, name: String?, suffix: String?) {
        self.owner = owner; self.name = name; self.suffix = suffix
    }
}

public struct SystemWidgetSettings: Codable, Equatable, Sendable {
    public let accountHash: String
    public var vehicleID: String?
    public var showName: Bool
    public var showTime: Bool
    /// 深浅色：-1 跟随系统、0 浅色、1 深色（与 Android widget_dark 同语义）。
    public var darkMode: Int
    /// 统计槽位的指标顺序：4×4 六格、4×2 两格共用一份有序列表，
    /// 展示层按 family 截取（large 取 6、medium 取 2）。
    public var stats: [WidgetStatField]
    public init(accountHash: String, vehicleID: String? = nil, showName: Bool = true, showTime: Bool = true,
                darkMode: Int = -1, stats: [WidgetStatField] = []) {
        self.accountHash = accountHash; self.vehicleID = vehicleID
        self.showName = showName; self.showTime = showTime
        self.darkMode = darkMode; self.stats = stats
    }
    public func validated() throws -> SystemWidgetSettings {
        guard accountHash.count == 64, accountHash.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }), vehicleID.map({ SystemSnapshotStore.ownerIdentifier($0) != nil }) ?? true,
              [-1, 0, 1].contains(darkMode),
              stats.count <= 6,
              stats.allSatisfy({ WidgetStatField.selectable.contains($0) }),
              Set(stats).count == stats.count else {
            throw SystemSnapshotError("invalid_widget_settings")
        }
        return self
    }
}
