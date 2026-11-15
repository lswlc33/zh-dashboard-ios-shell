import Foundation
import SwiftUI
import WidgetKit
import AppIntents
import ZeehoSystemShared

// 小组件三档布局：systemSmall ← Android 2×2、systemMedium ← 4×2、systemLarge ← 4×4。
// 尺寸、字号、间距、色值全部按 Android 规格书 1:1 搬运（见 WidgetStyle.swift）。
// 所有状态分支严格对齐 BaseWidget：未知就整块收起，绝不补 0 或拿旧值顶替。

struct ZeehoVehicleEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSnapshot?
    let requiresRefresh: Bool
    var showName = true
    var showTime = true
    /// 深浅色：-1 跟随系统、0 浅色、1 深色（与 Android widget_dark 同语义）。
    var darkMode: Int = -1
    /// 4×4 六格 / 4×2 两格的统计指标；空数组表示用该档默认顺序。
    var stats: [WidgetStatField] = []
    /// 原生编辑面板里「隐藏统计」开关；true 时 4×4/4×2 的统计块整块不占位。
    var statsHidden = false
    /// 这一帧的数据来源（诊断用，也决定「打开面板同步」那句提示要不要出现）。
    var origin: WidgetDataSourceResult.Origin = .snapshot

    var presentation: WidgetVehiclePresentation {
        // 桌面小组件过期后保留最后已知电量/充电状态，只把时间标注成过期，
        // 与 Android 小组件「更新时间 + 可能已过期」口径一致。
        var value = WidgetVehiclePresentation(snapshot: snapshot, date: date, requiresRefresh: requiresRefresh)
        value.keepsLastKnown = true
        value.freshWindow = WidgetFreshness.maxAgeSeconds
        return value
    }

    /// 解析实际生效的深浅色。
    func isDark(_ environment: ColorScheme) -> Bool {
        switch darkMode {
        case 0: return false
        case 1: return true
        default: return environment == .dark
        }
    }

    /// 该档位实际使用的统计指标（空则默认）。
    func statFields(for family: WidgetFamily) -> [WidgetStatField] {
        let defaults = family == .systemLarge ? WidgetStatField.defaultLarge
            : family == .systemMedium ? WidgetStatField.defaultMedium : []
        guard !defaults.isEmpty else { return [] }
        let resolved = stats.filter { WidgetStatField.selectable.contains($0) }
        var result: [WidgetStatField] = []
        for field in resolved where !result.contains(field) { result.append(field) }
        for field in defaults where result.count < defaults.count && !result.contains(field) { result.append(field) }
        return Array(result.prefix(defaults.count))
    }
}

// MARK: - 车况读取
//
// 数据来源优先级见 Shared/WidgetDataSource：「扩展自己拉 → 自己的缓存 → 宿主快照」。
// 前两条对应官方 `ZHWidgetExtension` 的做法（扩展自带网络层，不依赖宿主存活），
// 第三条保留原有兜底，未授权后台凭据/弱网时行为不变。

/// `getTimeline` 的一次性闸门：网络结果与超时兜底**先到先赢**，`completion` 只调一次。
///
/// 为什么必须有：WidgetKit 的时间预算只有几秒，而一次联网最坏 18 秒。
/// 直接 `await` 会让系统在预算到点时掐掉扩展，`completion` 永不调用 ——
/// 表现就是「小组件一直显示旧数据 / 一直占位」，而且系统不会立刻再给机会。
/// 用闸门保证：预算内一定交出 timeline（哪怕是快照兜底），网络结果只用于填缓存。
private final class TimelineGate {
    private let lock = NSLock()
    private var completion: ((Timeline<ZeehoVehicleEntry>) -> Void)?
    private var fallback: DispatchWorkItem?

    init(completion: @escaping (Timeline<ZeehoVehicleEntry>) -> Void) {
        self.completion = completion
    }

    /// 正常完成（网络结果 / 缓存 / 快照）：取消超时兜底并交结果。
    func finish(_ timeline: Timeline<ZeehoVehicleEntry>) {
        lock.lock()
        let callback = completion
        completion = nil
        let fallback = self.fallback
        self.fallback = nil
        lock.unlock()
        fallback?.cancel()
        callback?(timeline)
    }

    /// 超时兜底：到点还没 finish 就先交一份「只读本地」的 timeline。
    func scheduleFallback(seconds: Double,
                          build: @escaping () -> Timeline<ZeehoVehicleEntry>) {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let callback = self.completion
            self.completion = nil
            self.fallback = nil
            self.lock.unlock()
            guard let callback = callback else { return }
            callback(build())
        }
        lock.lock()
        fallback = item
        let armed = completion != nil
        lock.unlock()
        // 已经被网络结果抢先完成时不再排队。
        guard armed else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.5, seconds), execute: item)
    }
}

struct ZeehoVehicleProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        // 占位和图库都不能伪造一辆车或 100% 电量。
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ZeehoVehicleEntry) -> Void) {
        // 图库预览不联网：只读已有快照/缓存，避免添加小组件时卡住预览面板。
        completion(ZeehoWidgetReader.read(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZeehoVehicleEntry>) -> Void) {
        // WidgetKit 给的时间预算只有几秒级；网络最坏要 18 秒（见 WidgetVehicleClient），
        // 直接 await 会被系统掐断，表现是「小组件永远停在旧数据 / 占位态」。
        // 所以这里用一次性闸门：**先到先赢**，超时就交快照兜底的 timeline，
        // 之后网络回来也只是把结果写进缓存，下次刷新自然用上。
        let gate = TimelineGate(completion: completion)
        Task {
            let result = await WidgetDataSource.load(at: Date())
            gate.finish(Self.timeline(entry: ZeehoWidgetReader.entry(result, at: Date()), now: Date()))
        }
        // 保守取 3.5 秒：与系统对 App Extension 的常见预算留出余量。
        gate.scheduleFallback(seconds: 3.5) {
            let now = Date()
            // 多语句闭包必须显式 return（单表达式闭包才允许省略）。
            return Self.timeline(entry: ZeehoWidgetReader.read(at: now), now: now)
        }
    }

    static func timeline(entry: ZeehoVehicleEntry, now: Date) -> Timeline<ZeehoVehicleEntry> {
        let refreshAfter = now.addingTimeInterval(refreshInterval)
        var entries = [entry]
        if let snapshot = entry.snapshot, let vehicle = snapshot.vehicle,
           !entry.presentation.isStale {
            // 未来 entry 只把数值标成「可能已过期」，不再抹掉电量/充电状态：
            // 过期后保留最后同步值 + 更新时间，和 Android 小组件同一口径。
            // 期限按小组件的 30 分钟窗口算，不能用 180 秒的会话级 expiresAt——
            // 那会让小组件刚加上 3 分钟就显示「可能已过期」。
            let deadline = Date(timeIntervalSince1970: Double(vehicle.updatedAt) / 1000)
                .addingTimeInterval(WidgetFreshness.maxAgeSeconds)
            if deadline > now && deadline <= refreshAfter {
                entries.append(ZeehoVehicleEntry(date: deadline, snapshot: snapshot, requiresRefresh: true,
                    showName: entry.showName, showTime: entry.showTime, darkMode: entry.darkMode,
                    stats: entry.stats, statsHidden: entry.statsHidden, origin: entry.origin))
            }
        }
        // 这是刷新请求，不是系统保证；不调用 WidgetCenter 反复催更。
        return Timeline(entries: entries, policy: .after(refreshAfter))
    }
}

/// 共享层的读取入口：StaticConfiguration 与 AppIntentConfiguration 共用。
enum ZeehoWidgetReader {
    /// 同步读（只用于图库预览）：只走快照/缓存，不联网。
    static func read(at date: Date, vehicleID: String? = nil, showName: Bool? = nil,
                     showTime: Bool? = nil) -> ZeehoVehicleEntry {
        makeEntry(snapshot: readSnapshot(at: date, vehicleID: vehicleID),
                  origin: .snapshot, at: date, showName: showName, showTime: showTime)
    }

    /// 把取数结果组装成 entry（Provider 用）。
    static func entry(_ result: WidgetDataSourceResult, at date: Date,
                      showName: Bool? = nil, showTime: Bool? = nil) -> ZeehoVehicleEntry {
        makeEntry(snapshot: result.snapshot, origin: result.origin, at: date,
                  showName: showName, showTime: showTime)
    }

    private static func makeEntry(snapshot: SystemSnapshot?, origin: WidgetDataSourceResult.Origin,
                                 at date: Date, showName: Bool?, showTime: Bool?) -> ZeehoVehicleEntry {
        // 显示开关只是装饰：配置文件坏了也必须照样显示车况，不能连带吞掉快照。
        let settings = (try? SystemSnapshotStore.currentOwner())
            .flatMap { try? SystemSnapshotStore.widgetSettings(expectedOwner: $0) }
        return ZeehoVehicleEntry(date: date, snapshot: snapshot, requiresRefresh: false,
            showName: showName ?? settings?.showName ?? true,
            showTime: showTime ?? settings?.showTime ?? true,
            darkMode: settings?.darkMode ?? -1,
            stats: settings?.stats ?? [], statsHidden: false, origin: origin)
    }

    private static func readSnapshot(at date: Date, vehicleID: String?) -> SystemSnapshot? {
        guard SystemSnapshotStore.isAvailable() else { return nil }
        do {
            // 指定了具体车辆就按匿名 id 精确定位；缺快照如实为空，绝不回退当前车。
            if let vehicleID = vehicleID, !vehicleID.isEmpty {
                return try SystemSnapshotStore.readVehicle(identifier: vehicleID, now: date)
            }
            // iOS 端默认只显示「主页当前选中车辆」：不读 widget-settings 里的旧选车记录。
            // 主 App 切换车辆时会把 active-owner.json 一起换掉，这里自然跟着变。
            return try SystemSnapshotStore.readCurrent(now: date)
        } catch {
            // 未声明/未获准的组、缺文件、坏 JSON、版本和 owner 不符统一 fail closed。
            return nil
        }
    }
}

// MARK: - 共用小组件元件

/// 锁车/坐垫胶囊（Android widget_pill：全圆角、左右 padding 6dp）。
private struct StatePill: View {
    let text: String
    let colors: WidgetPalette.Colors
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundColor(colors.text)
            .lineLimit(1)
            .padding(.horizontal, WidgetMetrics.pillPadH)
            .frame(maxHeight: .infinity)
            .background(Capsule().fill(colors.pillBg))
    }
}

/// 电量进度条（Android ProgressBar：轨道 line、填充 accent、圆角 20dp）。
private struct SOCProgress: View {
    let percent: Double?
    let height: CGFloat
    let colors: WidgetPalette.Colors

    var body: some View {
        // 电量未知时整条消失（Android w_progress GONE），不是画一条 0% 的空轨。
        if let percent = percent {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(colors.line)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(colors.accent)
                        .frame(width: max(0, min(1, percent / 100)) * proxy.size.width)
                }
            }
            .frame(height: height)
        }
    }
}

/// 刷新按钮（Android w_refresh：accent 文字、widget_btn 底、14dp 圆角）。
///
/// **iOS 17+ 才是真按钮**：`Button(intent:)` 让点击在扩展进程里真的发请求，
/// 系统随后重建时间线。之前这里只是个 `Text` —— 长得像按钮但点不动
/// （`ZeehoWidgetRefreshIntent` 全仓零引用，属于死控件）。
///
/// **iOS 15.4~16.x 降级为纯装饰**：那两代没有 `Button(intent:)`，壳也没有注册
/// 自定义 URL scheme（`Link` 无处可跳）。这里刻意不画假按钮、也不假装能点：
/// 低系统的刷新只能靠系统自己排时间线，用户长按进 App 同步。
private struct RefreshPill: View {
    let text: String
    let width: CGFloat
    let fontSize: CGFloat
    let colors: WidgetPalette.Colors

    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: ZeehoWidgetRefreshIntent()) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundColor(colors.accent)
            .lineLimit(1)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: WidgetMetrics.refreshCorner, style: .continuous)
                .fill(colors.refreshBg))
    }
}

// MARK: - 主视图

struct ZeehoVehicleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: ZeehoVehicleEntry

    private var presentation: WidgetVehiclePresentation { entry.presentation }
    private var colors: WidgetPalette.Colors { WidgetPalette.colors(dark: entry.isDark(colorScheme)) }

    /// 内容内边距（Android dp 1:1）在 iOS 17 之后要扣掉系统自加的那一层。
    ///
    /// WidgetKit 从 iOS 17 起会先给 widget 内容套一层默认内容边距（iPhone 上 16pt），
    /// 我们这套布局又按 Android 规格自带 14/12dp 内边距，两层叠起来就是 30dp —— 用户看到的
    /// 「边距大到异常、内容挤在中间一小块」正是这个。iOS 17+ 因此不再叠加自己那一层，
    /// 交给系统边距兜住；老系统没有系统边距，仍按 Android 规格加。
    private func contentPad(_ android: CGFloat) -> CGFloat {
        if #available(iOS 17.0, *) { return 0 }
        return android
    }

    var body: some View {
        Group {
            if presentation.vehicle == nil {
                unavailable
            } else {
                switch family {
                case .systemMedium: medium
                case .systemLarge: large
                default: small
                }
            }
        }
        .modifier(WidgetSurface(colors: colors))
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(WidgetStrings.title, systemImage: "car.fill")
                .font(.caption)
                .foregroundColor(colors.muted)
            Text(WidgetStrings.unavailable)
                .font(.headline)
                .foregroundColor(colors.text)
            Text(family == .systemSmall ? WidgetStrings.unavailableShort : WidgetStrings.unavailableHint)
                .font(.caption)
                .foregroundColor(colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(contentPad(WidgetMetrics.padSmall))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: systemSmall ← Android 2×2（140×140，pad 14）
    //
    // header 14 / hero 弹性 / charge 16 / controls 24 + marginTop 4

    private var small: some View {
        let v = presentation.vehicle
        let now = entry.date
        return VStack(alignment: .leading, spacing: 0) {
            // header：车名（muted 9sp）+ 更新时间（8sp）
            HStack(spacing: 0) {
                if entry.showName, let name = v?.name, !name.isEmpty {
                    Text(name)
                        .font(.system(size: WidgetFont.s2Title))
                        .foregroundColor(colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if entry.showTime {
                    Text(WidgetStatusText.updated(v?.updatedAt, stale: presentation.isStale, now: now))
                        .font(.system(size: WidgetFont.s2Updated))
                        .foregroundColor(colors.muted)
                        .lineLimit(1)
                }
            }
            .frame(height: 14)

            // hero：电量 34sp + %/电压尾巴 + 进度条
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(WidgetStatusText.soc(v, date: now))
                        .font(.system(size: WidgetFont.s2Soc, weight: .medium))
                        .foregroundColor(colors.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("%")
                        .font(.system(size: WidgetFont.s2Unit))
                        .foregroundColor(colors.muted)
                        .padding(.leading, 2)
                        .padding(.bottom, 4)
                    if let tail = WidgetStatusText.voltageTail(v, date: now) {
                        Text(tail)
                            .font(.system(size: WidgetFont.s2Voltage))
                            .foregroundColor(colors.muted)
                            .padding(.leading, 0)
                            .padding(.bottom, 5)
                            .lineLimit(1)
                    }
                }
                SOCProgress(percent: v?.visibleSOCPercent(at: now), height: WidgetMetrics.progressHeightSmall, colors: colors)
                    .padding(.top, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // charge 行：状态文案 11sp bold
            chargeLine(fontSize: WidgetFont.s2Charge)
                .frame(height: 16)

            // controls：锁车 / 坐垫胶囊（10sp，高 24）
            HStack(spacing: 0) {
                if let lock = WidgetStatusText.lockPill(vehicle: v, date: now) {
                    StatePill(text: lock, colors: colors, fontSize: WidgetFont.s2Pill)
                }
                if let lock = WidgetStatusText.lockPill(vehicle: v, date: now),
                   let seat = WidgetStatusText.seatPill(vehicle: v, date: now) {
                    Spacer().frame(width: 4)
                    StatePill(text: seat, colors: colors, fontSize: WidgetFont.s2Pill)
                } else if let seat = WidgetStatusText.seatPill(vehicle: v, date: now) {
                    StatePill(text: seat, colors: colors, fontSize: WidgetFont.s2Pill)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.top, 4)
        }
        .padding(contentPad(WidgetMetrics.padSmall))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: systemMedium ← Android 4×2（280×175，pad 12）
    //
    // header 18 / hero 弹性（三栏 1:1:1）/ controls 38 + marginTop 4

    private var medium: some View {
        let v = presentation.vehicle
        let now = entry.date
        let fields = entry.statFields(for: .systemMedium)
        return VStack(alignment: .leading, spacing: 0) {
            // header 一行：标题 10sp bold / 胶囊 / 弹簧 / 时间 / 刷新
            HStack(spacing: 0) {
                if entry.showName {
                    Text(v?.name?.isEmpty == false ? v!.name! : WidgetStrings.title)
                        .font(.system(size: WidgetFont.mTitle, weight: .bold))
                        .foregroundColor(colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(3)
                }
                if let lock = WidgetStatusText.lockPill(vehicle: v, date: now) {
                    StatePill(text: lock, colors: colors, fontSize: WidgetFont.mPill)
                        .padding(.leading, 6)
                }
                if let seat = WidgetStatusText.seatPill(vehicle: v, date: now) {
                    StatePill(text: seat, colors: colors, fontSize: WidgetFont.mPill)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 4)
                if entry.showTime {
                    Text(WidgetStatusText.updated(v?.updatedAt, stale: presentation.isStale, now: now))
                        .font(.system(size: WidgetFont.mUpdated))
                        .foregroundColor(colors.muted)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                RefreshPill(text: WidgetStrings.refreshAction, width: WidgetMetrics.refreshWidthMedium,
                            fontSize: WidgetFont.mRefresh, colors: colors)
                    .padding(.leading, 6)
            }
            .frame(height: 18)

            // hero 三栏等分：能量 / 中间统计两格 / 车模
            HStack(spacing: 0) {
                // 栏 1：电量 30sp + % + 状态行（含电压）+ 进度条
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(WidgetStatusText.soc(v, date: now))
                            .font(.system(size: WidgetFont.mSoc, weight: .medium))
                            .foregroundColor(colors.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("%")
                            .font(.system(size: WidgetFont.mUnit))
                            .foregroundColor(colors.muted)
                            .padding(.leading, 2)
                            .padding(.bottom, 4)
                    }
                    // 4×2 的电压并入状态行（Android：w_voltage GONE，拼进 w_charge）
                    chargeLine(fontSize: WidgetFont.mCharge, appendVoltage: WidgetStatusText.voltageTail(v, date: now))
                    SOCProgress(percent: v?.visibleSOCPercent(at: now), height: WidgetMetrics.progressHeightSmall, colors: colors)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                // 栏 2：两格统计（上行/下行，居中）；隐藏时不占位，电量按 Android
                // w_stats GONE 的口径自动吃满剩余宽度。
                if !entry.statsHidden {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let first = fields.first {
                            statCell(first, vehicle: v, valueFont: WidgetFont.mMidValue,
                                     labelFont: WidgetFont.mMidLabel, color: colors, now: now)
                        }
                        if fields.count > 1 {
                            statCell(fields[1], vehicle: v, valueFont: WidgetFont.mMidValue,
                                     labelFont: WidgetFont.mMidLabel, color: colors, now: now)
                                .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 8)
                }

                // 栏 3：车模（fitCenter，占满栏高）；缺图时整栏不占位，电量与统计按 Android
                // w_car_box GONE 的口径自动吃满剩余宽度。
                vehicleArt(ownerID: presentation.ownerID, leading: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 2)

            // controls：4 个车控按钮（38dp）
            controlRow(height: WidgetMetrics.buttonHeightMedium, fontSize: WidgetFont.mButton)
                .padding(.top, 4)
        }
        .padding(contentPad(WidgetMetrics.padMedium))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: systemLarge ← Android 4×4（280×280，pad 14）
    //
    // header 18 / status 18 / hero 弹性（40:60）/ stats wrap(min72) / controls 48

    private var large: some View {
        let v = presentation.vehicle
        let now = entry.date
        let fields = entry.statFields(for: .systemLarge)
        return VStack(alignment: .leading, spacing: 0) {
            // header：标题 11sp bold + 时间 + 刷新
            HStack(spacing: 0) {
                if entry.showName {
                    Text(v?.name?.isEmpty == false ? v!.name! : WidgetStrings.title)
                        .font(.system(size: WidgetFont.lTitle, weight: .bold))
                        .foregroundColor(colors.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if entry.showTime {
                    Text(WidgetStatusText.updated(v?.updatedAt, stale: presentation.isStale, now: now))
                        .font(.system(size: WidgetFont.lUpdated))
                        .foregroundColor(colors.muted)
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                RefreshPill(text: WidgetStrings.refreshAction, width: WidgetMetrics.refreshWidthLarge,
                            fontSize: WidgetFont.lRefresh, colors: colors)
                    .padding(.leading, 6)
            }
            .frame(height: 18)

            // status 行：锁车 / 坐垫胶囊 + 弹簧 + 在线点 + 在线文案
            HStack(spacing: 0) {
                if let lock = WidgetStatusText.lockPill(vehicle: v, date: now) {
                    StatePill(text: lock, colors: colors, fontSize: WidgetFont.lPill)
                }
                if let seat = WidgetStatusText.seatPill(vehicle: v, date: now) {
                    StatePill(text: seat, colors: colors, fontSize: WidgetFont.lPill)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
                if WidgetStatusText.outageDot(vehicle: v, date: now) {
                    Circle()
                        .fill(colors.dot)
                        .frame(width: 4, height: 4)
                        .padding(.trailing, 4)
                }
                Text(WidgetStatusText.onlineText(vehicle: v, date: now))
                    .font(.system(size: WidgetFont.lPill))
                    .foregroundColor(colors.muted)
            }
            .frame(height: 18)
            .padding(.top, 2)

            // hero：电量 40% + 车模 60%
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(WidgetStatusText.soc(v, date: now))
                            .font(.system(size: WidgetFont.lSoc, weight: .medium))
                            .foregroundColor(colors.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("%")
                            .font(.system(size: WidgetFont.lUnit))
                            .foregroundColor(colors.muted)
                            .padding(.leading, 2)
                            .padding(.bottom, 5)
                    }
                    chargeLine(fontSize: WidgetFont.lCharge)
                        .padding(.top, 2)
                    SOCProgress(percent: v?.visibleSOCPercent(at: now), height: WidgetMetrics.progressHeightLarge, colors: colors)
                        .padding(.top, 4)
                    // 4×4 电压独立一行
                    if let tail = WidgetStatusText.voltageTail(v, date: now) {
                        Text(tail)
                            .font(.system(size: WidgetFont.lVoltage))
                            .foregroundColor(colors.muted)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(40)

                vehicleArt(ownerID: presentation.ownerID, leading: 8)
                    .layoutPriority(60)
            }
            .frame(minHeight: 88, maxHeight: .infinity)
            .padding(.top, 2)

            // stats：3 列 × 2 行（列优先：0/3、1/4、2/5）
            if !entry.statsHidden {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<3, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 0) {
                            let top = column
                            let bottom = column + 3
                            if top < fields.count {
                                statCell(fields[top], vehicle: v, valueFont: WidgetFont.lStatValue,
                                         labelFont: WidgetFont.lStatLabel, unitFont: WidgetFont.lStatUnit,
                                         color: colors, now: now, alignedLeading: true)
                            }
                            if bottom < fields.count {
                                statCell(fields[bottom], vehicle: v, valueFont: WidgetFont.lStatValue,
                                         labelFont: WidgetFont.lStatLabel, unitFont: WidgetFont.lStatUnit,
                                         color: colors, now: now, alignedLeading: true)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, column == 0 ? 0 : 6)
                    }
                }
                .frame(minHeight: 72, alignment: .top)
                .padding(.top, 2)
            }

            // controls：4 个车控按钮（48dp）
            controlRow(height: WidgetMetrics.buttonHeightLarge, fontSize: WidgetFont.lButton)
                .padding(.top, 2)
        }
        .padding(contentPad(WidgetMetrics.padSmall))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 子元件

    /// 状态行：颜色按语义（离线 warn / 充电 accent / 其余 muted）。
    private func chargeLine(fontSize: CGFloat, appendVoltage: String? = nil) -> some View {
        let line = WidgetStatusText.chargeLine(vehicle: presentation.vehicle, hasData: presentation.hasData, date: entry.date)
        let text = appendVoltage.map { "\(line.text) · \($0)" } ?? line.text
        let color: Color = {
            switch line.tone {
            case .warn: return colors.warn
            case .accent: return colors.accent
            case .normal: return colors.muted
            }
        }()
        return Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// 单个统计格：label（muted）+ value（text）+ unit（muted）。
    private func statCell(_ field: WidgetStatField, vehicle: SystemVehicleSnapshot?,
                          valueFont: CGFloat, labelFont: CGFloat,
                          unitFont: CGFloat? = nil, color: WidgetPalette.Colors,
                          now: Date, alignedLeading: Bool = false) -> some View {
        let value = WidgetStatValue.resolve(field, vehicle: vehicle, date: now)
        return VStack(alignment: alignedLeading ? .leading : .center, spacing: 0) {
            Text(value.label)
                .font(.system(size: labelFont))
                .foregroundColor(color.muted)
                .lineLimit(1)
                .frame(minHeight: 14, alignment: alignedLeading ? .leading : .center)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value.value)
                    .font(.system(size: valueFont, weight: .medium))
                    .foregroundColor(color.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unitFont = unitFont, !value.unit.isEmpty {
                    Text(value.unit)
                        .font(.system(size: unitFont))
                        .foregroundColor(color.muted)
                        .padding(.leading, 2)
                        .padding(.bottom, 1)
                } else if !value.unit.isEmpty {
                    // 4×2 的中间列把单位拼进数值串（Android 同款）
                    Text(" \(value.unit)")
                        .font(.system(size: valueFont * 0.77, weight: .medium))
                        .foregroundColor(color.muted)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignedLeading ? .leading : .center)
    }

    /// 车模：读 App Group 里按匿名 owner 分文件的共享素材（由主 App 在快照落盘后按 artUrl 下载）。
    ///
    /// 缺图时返回 `EmptyView` 而不是 `Color.clear`：`Color.clear` 仍会占住
    /// `.frame(maxWidth:.infinity)` 分到的整栏宽度，用户看到的就是「车没显示、右边空了一大块」。
    /// Android 那边 w_car_box 缺图是 GONE（布局里直接不占位），这里对齐同一口径。
    @ViewBuilder private func vehicleArt(ownerID: String, leading: CGFloat) -> some View {
        if let image = ZeehoWidgetArt.vehicleImage(ownerID: ownerID) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, leading)
        }
    }

    /// 车控按钮行：解锁 / 锁车 / 鸣笛 / 坐垫（等分）。
    @ViewBuilder
    private func controlRow(height: CGFloat, fontSize: CGFloat) -> some View {
        // 交互按钮是 iOS 17+（Button(intent:)）；低系统整行不出现，
        // 不给不可点的假按钮——Android 上这行是真能车的，画个假的更糟。
        if #available(iOS 17.0, *) {
            HStack(spacing: 0) {
                ForEach(Array(ZeehoWidgetCommand.allCases.enumerated()), id: \.element) { index, command in
                    ZeehoWidgetCommandButton(command: command, fontSize: fontSize, colors: colors,
                                             ownerID: presentation.ownerID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, index == 0 ? 0 : WidgetMetrics.buttonGap)
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - 小组件定义

/// 老系统（iOS 15.4~16.x）用的静态配置版：没有编辑面板，数据来源仍是
/// 「自己拉 → 缓存 → 宿主快照」（`WidgetDataSource`），只是不能按实例改显示项。
struct ZeehoVehicleWidget: Widget {
    let kind = ZeehoWidgetKind.vehicle

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZeehoVehicleProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.displayName)
        .description(WidgetStrings.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 原车辆小组件：**必须保持 StaticConfiguration**。
///
/// ## 为什么不能把它换成 AppIntentConfiguration（1.1.19 的真实事故）
///
/// WidgetKit 把已放置实例的配置**按 intent 类型名**存档。1.1.19 把同一 kind
/// (`ZeehoVehicleWidget`) 从 `StaticConfiguration` 换成了 `AppIntentConfiguration`，
/// 存量实例持有的旧配置类型不存在了 → WidgetKit **再也不会为它产出 timeline**
/// → 桌面上永远停在占位骨架屏，用户只能删掉重加。
/// （Stack Overflow #64075386、callstackincubator/voltra#272、tmeng53/wildcard#822
///  三份独立实测；Apple 没有文档化这条行为。）
///
/// 结论：**kind 一旦对外发布，它的配置类型就不能改**。要加原生编辑只能开新 kind。
struct ZeehoVehicleWidget: Widget {
    let kind = ZeehoWidgetKind.vehicle

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZeehoVehicleProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.displayName)
        .description(WidgetStrings.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// iOS 17+ 支持原生编辑的版本（长按 →「编辑小组件」），**使用独立 kind**。
///
/// 必须是新 kind，不能复用 `ZeehoVehicleWidget`：理由见上面 `ZeehoVehicleWidget` 的注释
/// —— 复用会让 1.1.18 及更早的用户实例全部失效。代价是老实例不会自动获得编辑能力，
/// 需要用户在桌面重新添加这一个小组件（图库里会看到两个条目）。
@available(iOS 17.0, *)
struct ZeehoConfigurableVehicleWidget: Widget {
    let kind = ZeehoWidgetKind.configurable

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ZeehoVehicleWidgetConfiguration.self,
                               provider: ZeehoVehicleConfigProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.configurableDisplayName)
        .description(WidgetStrings.configurableDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// 为什么不用 `if #available` 写在 `WidgetBundle.body` 里：
// `Widget` 与 `WidgetBundle` 的 body 都**没有** result builder，苹果也没有提供
// `WidgetConfigurationBuilder`（SDK 里查无此类型）。带 else 的 if #available 会直接
// 编译失败（"closure containing control flow statement cannot be used with result builder"）。
// 所以用 `static func main()` 把分派提到 builder 之上。`WidgetBundle.main()` 是
// WidgetKit 里真实存在的 `@MainActor public static func main()`，可以这样调用
// （Chromium / Home Assistant 都这么做，见「小组件自取数」的记忆条目）。
// iOS 17+ 的 bundle 同时注册两个 kind：原 kind 保持静态配置，新 kind 提供编辑。
@main
struct ZeehoWidgets {
    static func main() {
        if #available(iOS 17.0, *) {
            ZeehoModernWidgets.main()
        } else {
            ZeehoLegacyWidgets.main()
        }
    }
}

/// iOS 17+：原静态小组件（保证老实例继续工作）+ 新的可编辑小组件 + Live Activity。
@available(iOS 17.0, *)
struct ZeehoModernWidgets: WidgetBundle {
    var body: some Widget {
        ZeehoVehicleWidget()
        ZeehoConfigurableVehicleWidget()
        if #available(iOS 16.1, *) {
            ZeehoLiveActivityWidget()
        }
    }
}

/// iOS 15.4~16.x：静态配置的车辆小组件 + Live Activity。
struct ZeehoLegacyWidgets: WidgetBundle {
    var body: some Widget {
        ZeehoVehicleWidget()
        if #available(iOS 16.1, *) {
            ZeehoLiveActivityWidget()
        }
    }
}
