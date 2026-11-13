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
    public init(accountHash: String, vehicleID: String? = nil, showName: Bool = true, showTime: Bool = true) {
        self.accountHash = accountHash; self.vehicleID = vehicleID; self.showName = showName; self.showTime = showTime
    }
    public func validated() throws -> SystemWidgetSettings {
        guard accountHash.count == 64, accountHash.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }), vehicleID.map({ SystemSnapshotStore.ownerIdentifier($0) != nil }) ?? true else {
            throw SystemSnapshotError("invalid_widget_settings")
        }
        return self
    }
}
