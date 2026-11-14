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

struct ZeehoVehicleProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ZeehoVehicleEntry {
        // 占位和图库都不能伪造一辆车或 100% 电量。
        ZeehoVehicleEntry(date: Date(), snapshot: nil, requiresRefresh: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ZeehoVehicleEntry) -> Void) {
        completion(ZeehoWidgetReader.read(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZeehoVehicleEntry>) -> Void) {
        let now = Date()
        completion(Self.timeline(entry: ZeehoWidgetReader.read(at: now), now: now))
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
                    stats: entry.stats))
            }
        }
        // 这是刷新请求，不是系统保证；不调用 WidgetCenter 反复催更。
        return Timeline(entries: entries, policy: .after(refreshAfter))
    }
}

/// 共享层的读取入口：StaticConfiguration 与 AppIntentConfiguration 共用。
enum ZeehoWidgetReader {
    static func read(at date: Date, vehicleID: String? = nil, showName: Bool? = nil,
                     showTime: Bool? = nil) -> ZeehoVehicleEntry {
        guard SystemSnapshotStore.isAvailable() else {
            return ZeehoVehicleEntry(date: date, snapshot: nil, requiresRefresh: false)
        }
        do {
            // 指定了具体车辆就按匿名 id 精确定位；缺快照如实为空，绝不回退当前车。
            let snapshot: SystemSnapshot?
            if let vehicleID = vehicleID, !vehicleID.isEmpty {
                snapshot = try SystemSnapshotStore.readVehicle(identifier: vehicleID, now: date)
            } else {
                // iOS 端默认只显示「主页当前选中车辆」：不读 widget-settings 里的旧选车记录。
                // 主 App 切换车辆时会把 active-owner.json 一起换掉，这里自然跟着变。
                snapshot = try SystemSnapshotStore.readCurrent(now: date)
            }
            // 显示开关只是装饰：配置文件坏了也必须照样显示车况，不能连带吞掉快照。
            let settings = (try? SystemSnapshotStore.currentOwner())
                .flatMap { try? SystemSnapshotStore.widgetSettings(expectedOwner: $0) }
            return ZeehoVehicleEntry(date: date, snapshot: snapshot, requiresRefresh: false,
                showName: showName ?? settings?.showName ?? true,
                showTime: showTime ?? settings?.showTime ?? true,
                darkMode: settings?.darkMode ?? -1,
                stats: settings?.stats ?? [])
        } catch {
            // 未声明/未获准的组、缺文件、坏 JSON、版本和 owner 不符统一 fail closed。
            return ZeehoVehicleEntry(date: date, snapshot: nil, requiresRefresh: false)
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
private struct RefreshPill: View {
    let text: String
    let width: CGFloat
    let fontSize: CGFloat
    let colors: WidgetPalette.Colors

    var body: some View {
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
        .padding(WidgetMetrics.padSmall)
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

                // 栏 2：两格统计（上行/下行，居中）
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

                // 栏 3：车模（fitCenter，占满栏高）
                vehicleArt
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 2)

            // controls：4 个车控按钮（38dp）
            controlRow(height: WidgetMetrics.buttonHeightMedium, fontSize: WidgetFont.mButton)
                .padding(.top, 4)
        }
        .padding(WidgetMetrics.padMedium)
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

                vehicleArt
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 8)
                    .layoutPriority(60)
            }
            .frame(minHeight: 88, maxHeight: .infinity)
            .padding(.top, 2)

            // stats：3 列 × 2 行（列优先：0/3、1/4、2/5）
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

            // controls：4 个车控按钮（48dp）
            controlRow(height: WidgetMetrics.buttonHeightLarge, fontSize: WidgetFont.lButton)
                .padding(.top, 2)
        }
        .padding(WidgetMetrics.padSmall)
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

    /// 车模：读 App Group 里的共享素材；缺图时不占位（Android w_car_box GONE）。
    @ViewBuilder private var vehicleArt: some View {
        if let image = ZeehoWidgetArt.vehicleImage() {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
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

struct ZeehoVehicleWidget: Widget {
    let kind = "ZeehoVehicleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZeehoVehicleProvider()) { entry in
            ZeehoVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetStrings.displayName)
        .description(WidgetStrings.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ZeehoWidgets: WidgetBundle {
    // 目标系统已是 iOS 27，不再保留 iOS 17 的 AppIntentConfiguration 分支：
    // 那套需要 AppIntents metadata 提取，而手写 swiftc 流程产不出 const-values。
    // 统一用 StaticConfiguration，组件按 SystemWidgetSettings 的默认车辆显示；
    // Live Activity 仍从 iOS 16.1 起条件注册。
    var body: some Widget {
        ZeehoVehicleWidget()
        if #available(iOS 16.1, *) {
            ZeehoLiveActivityWidget()
        }
    }
}
