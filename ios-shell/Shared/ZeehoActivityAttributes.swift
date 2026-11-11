import Foundation

public enum ZeehoActivityKind: String, Codable, Hashable, Sendable {
    case vehicle, charging, ride
}

#if os(iOS)
import ActivityKit

// 类型只由主 App/Widget 的 Apple target 编译；基础快照和存储不链接 KMP，也不要求 UIKit/SwiftUI。
@available(iOS 16.1, *)
public struct ZeehoActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public let snapshot: SystemSnapshot
        public init(snapshot: SystemSnapshot) { self.snapshot = snapshot }
    }
    public let owner: SystemSnapshotOwner
    public let kind: ZeehoActivityKind
    public init(owner: SystemSnapshotOwner, kind: ZeehoActivityKind) {
        self.owner = owner; self.kind = kind
    }
}
#endif
