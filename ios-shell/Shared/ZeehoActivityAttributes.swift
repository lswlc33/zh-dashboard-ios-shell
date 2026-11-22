import Foundation

public enum ZeehoActivityKind: String, Codable, Hashable, Sendable {
    case vehicle, charging, ride, gauge
}

#if os(iOS)
import ActivityKit

// 类型只由主 App/Widget 的 Apple target 编译；基础快照和存储不链接 KMP，也不要求 UIKit/SwiftUI。
@available(iOS 16.1, *)
public struct ZeehoActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public let snapshot: SystemSnapshot
        /// 充电段的开始时刻（epoch ms）。视图用系统计时器（Text(timerInterval:)）
        /// 让「已充电」时长在锁屏/灵动岛上自动走表，不依赖 App 进程存活。
        /// optional 保证旧版本写入的活动内容 decode 时缺字段落 nil，向后兼容。
        public let chargeStartedAt: Double?
        public init(snapshot: SystemSnapshot, chargeStartedAt: Double? = nil) {
            self.snapshot = snapshot
            self.chargeStartedAt = chargeStartedAt
        }
    }
    public let owner: SystemSnapshotOwner
    public let kind: ZeehoActivityKind
    public init(owner: SystemSnapshotOwner, kind: ZeehoActivityKind) {
        self.owner = owner; self.kind = kind
    }
}
#endif
