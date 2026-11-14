import Foundation
import SwiftUI
import WidgetKit
import AppIntents
import ZeehoSystemShared

// 小组件车控按钮：用 AppIntent 让按钮点击在扩展进程内执行，
// 通过 App Group 邮箱把命令投递给主 App（iOS 不允许扩展直接跑网络/BLE）。
//
// **硬约束**：iOS 只从各 bundle 的 `Metadata.appintents` 索引里找 intent，
// 缺了索引点按钮会静默无效（真机日志 `linkd Missing: <bundle>:<Type>`）。
// 本项目的构建是手写 swiftc，所以 build.sh 必须：
//   1) 编 appex 时加 `-emit-const-values-path` 与 `-const-gather-protocols-file`
//   2) 链接后对 **appex 和 app 各跑一次** `appintentsmetadataprocessor`
//   3) 再签名（保证索引进签名封条）
// 见 build.sh 的 appintents-metadata 段与 test.py 的对应断言。

/// 车控动作（与 Android CAR_CMDS 的四个按钮一一对应）。
enum ZeehoWidgetCommand: String, CaseIterable, Hashable, Sendable {
    case unlock, lock, horn, seat

    var title: String {
        switch self {
        case .unlock: return WidgetStrings.controlUnlock
        case .lock: return WidgetStrings.controlLock
        case .horn: return WidgetStrings.controlHorn
        case .seat: return WidgetStrings.controlSeat
        }
    }

    /// 是不是主按钮（解锁用 btnPrimary 配色，其余 soft）。
    var isPrimary: Bool { self == .unlock }
}

/// 小组件车控 intent。`ownerID` 让扩展知道该把命令投给哪个匿名 owner。
///
/// iOS 17 起才有交互式小组件按钮（`Button(intent:)`），所以整条链路
/// 都标 17.0；deployment target 仍是 15.4，低系统由调用点降级成无按钮布局。
@available(iOS 17.0, *)
struct ZeehoWidgetCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "车辆控制"
    static var description = IntentDescription("从桌面小组件执行车辆控制")
    // 按钮点击必须在前台执行；扩展进程被系统唤起时即为前台。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "动作")
    var action: String

    @Parameter(title: "车辆")
    var ownerID: String

    init() {
        action = ZeehoWidgetCommand.horn.rawValue
        ownerID = ""
    }

    init(command: ZeehoWidgetCommand, ownerID: String) {
        action = command.rawValue
        self.ownerID = ownerID
    }

    func perform() async throws -> some IntentResult {
        guard let command = ZeehoWidgetCommand(rawValue: action) else {
            return .result()
        }
        // 只接受当前 active owner，防止旧小组件向另一辆车投递命令。
        let owner = try? SystemSnapshotStore.currentOwner()
        _ = ZeehoWidgetCommandMailbox.post(command.rawValue, owner: owner)
        // 立刻请求刷新，让界面尽快反映「已受理」（不代表车已执行）。
        WidgetCenter.shared.reloadTimelines(ofKind: "ZeehoVehicleWidget")
        return .result()
    }
}

/// 小组件刷新 intent：点「刷新」时让扩展重新读一次共享快照。
@available(iOS 17.0, *)
struct ZeehoWidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新车况"
    static var description = IntentDescription("重新读取最近一次同步的车况")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "ZeehoVehicleWidget")
        return .result()
    }
}

// MARK: - 按钮视图

/// 车控按钮：用 `Button(intent:)` 触发上面的 intent。
/// 深浅色跟随卡片；解锁用主按钮配色（深底白字 / 浅底深字），其余 soft 底。
/// `Button(intent:)` 是 iOS 17.0+，低系统由调用点降级。
@available(iOS 17.0, *)
struct ZeehoWidgetCommandButton: View {
    let command: ZeehoWidgetCommand
    let fontSize: CGFloat
    let colors: WidgetPalette.Colors
    /// 当前快照对应的匿名 owner id；扩展按它核对，避免跨车投递。
    var ownerID: String = ""

    var body: some View {
        Button(intent: ZeehoWidgetCommandIntent(command: command, ownerID: ownerID)) {
            Text(command.title)
                .font(.system(size: fontSize))
                .foregroundColor(command.isPrimary ? colors.btnPrimaryText : colors.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: WidgetMetrics.buttonCorner, style: .continuous)
                    .fill(command.isPrimary ? colors.btnPrimaryBg : colors.btnSoftBg))
        }
        .buttonStyle(.plain)
    }
}

