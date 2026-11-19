import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(FloatingMeterController.self) private var floatingMeter
    @Environment(\.scenePhase) private var scenePhase
    @State private var liveActivity = ChargeActivityController()
    @State private var widgets = WidgetPublisher()

    var body: some View {
        FreshRootExperience()
            // MiniWatts stays in Simplified Chinese regardless of the iPhone language.
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .background { ScreenAwakeHolder() }
            // Keep the PiP source layer alive for the floating meter.
            .background(alignment: .topLeading) {
                FloatingMeterStage(controller: floatingMeter)
                    .frame(width: 16, height: 9)
                    .opacity(0.02)
                    .allowsHitTesting(false)
            }
            .task {
                monitor.onTick = { [liveActivity, widgets, floatingMeter] snapshot in
                    let reading = ChargeReading(snapshot)
                    floatingMeter.render(snapshot: snapshot,
                                         thermalState: monitor.thermal.state,
                                         temperatureUnit: monitor.temperatureUnit)
                    liveActivity.sync(snapshot,
                                      selectedMetric: monitor.liveActivityMetric,
                                      temperatureUnit: monitor.temperatureUnit,
                                      enabled: monitor.showsLiveActivityWhileCharging,
                                      isForeground: UIApplication.shared.applicationState == .active)
                    widgets.publish(reading, lastSession: monitor.sessions.first)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    monitor.start()
                case .background:
                    if !floatingMeter.isRunning { monitor.pause() }
                    widgets.flush(ChargeReading(monitor.snapshot), lastSession: monitor.sessions.first)
                default:
                    break
                }
            }
    }
}


// MARK: - Fresh interface
//
// This is a separate presentation system, not a reskin of PageScaffold/Panel.
// It owns the navigation, spacing, hierarchy and components used by the app's
// active experience. The older feature views remain in the target for reference
// and for specialised detail screens, but are no longer the tab entry points.

private enum FreshTab: String, CaseIterable, Identifiable {
    case overview, battery, thermal, devices, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .battery: return "电池"
        case .thermal: return "温度"
        case .devices: return "设备"
        case .history: return "记录"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .battery: return "battery.100percent"
        case .thermal: return "thermometer.medium"
        case .devices: return "cable.connector"
        case .history: return "chart.xyaxis.line"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .battery: return "battery.100percent"
        case .thermal: return "thermometer.medium"
        case .devices: return "cable.connector"
        case .history: return "chart.xyaxis.line"
        }
    }
}

private enum FreshPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.08)
    static let accent = Color(red: 0.17, green: 0.39, blue: 0.91)
    static let green = Color(red: 0.10, green: 0.59, blue: 0.39)
    static let amber = Color(red: 0.83, green: 0.48, blue: 0.10)
    static let red = Color(red: 0.82, green: 0.22, blue: 0.20)
    static let violet = Color(red: 0.43, green: 0.34, blue: 0.79)
    static let hero = Color(red: 0.075, green: 0.105, blue: 0.16)
}

private struct FreshRootExperience: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var selectedTab: FreshTab = .overview
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .overview:
                    FreshOverviewPage(onSettings: { showingSettings = true })
                case .battery:
                    FreshBatteryPage(onSettings: { showingSettings = true })
                case .thermal:
                    FreshThermalPage(onSettings: { showingSettings = true })
                case .devices:
                    FreshDevicesPage(onSettings: { showingSettings = true })
                case .history:
                    FreshHistoryPage(onSettings: { showingSettings = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FreshTabBar(selection: $selectedTab)
        }
        .background(FreshPalette.canvas.ignoresSafeArea())
        .statusBarHidden(true)
        .sheet(isPresented: $showingSettings) {
            FreshSettingsPage()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .tint(FreshPalette.accent)
    }
}

private struct FreshTabBar: View {
    @Binding var selection: FreshTab
    @Namespace private var selectionGlass

    private var leadingTabs: [FreshTab] { Array(FreshTab.allCases.prefix(3)) }
    private var trailingTabs: [FreshTab] { Array(FreshTab.allCases.suffix(2)) }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 12)
            HStack(alignment: .center, spacing: 12) {
                tabGroup(leadingTabs)
                    .frame(width: availableWidth * 0.64)
                tabGroup(trailingTabs)
                    .frame(width: availableWidth * 0.36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 70)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, -12)
        .background {
            FreshPalette.canvas
                .opacity(0.72)
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: 10)
    }

    @ViewBuilder
    private func tabGroup(_ tabs: [FreshTab]) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(5)
        .background {
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                    }
            }
        }
    }

    private func tabButton(_ tab: FreshTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selection == tab ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 18, weight: selection == tab ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .frame(height: 25)
                Text(tab.title)
                    .font(.system(size: 11, weight: selection == tab ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selection == tab ? FreshPalette.accent : FreshPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 3)
            .background {
                if selection == tab {
                    if #available(iOS 26.0, *) {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .matchedGeometryEffect(id: "freshDockSelection", in: selectionGlass)
                    } else {
                        Capsule()
                            .fill(FreshPalette.accent.opacity(0.12))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

private struct FreshPage<Content: View>: View {
    let title: String
    let subtitle: String
    let onSettings: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .tracking(-0.7)
                            .foregroundStyle(FreshPalette.ink)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(FreshPalette.muted)
                    }
                    Spacer(minLength: 8)
                    Button(action: onSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FreshPalette.ink)
                            .frame(width: 44, height: 44)
                            .background(FreshPalette.card, in: Circle())
                            .overlay(Circle().stroke(FreshPalette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
                content()
            }
             .padding(.horizontal, 15)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(FreshPalette.canvas)
    }
}

private struct FreshCard<Content: View>: View {
    var dark = false
    var compact = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12, content: content)
            .padding(compact ? 11 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                dark ? FreshPalette.hero : FreshPalette.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(dark ? Color.white.opacity(0.08) : FreshPalette.line, lineWidth: 1)
            }
    }
}

private struct FreshSectionHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(FreshPalette.ink)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FreshPalette.muted)
            }
        }
        .padding(.top, 2)
    }
}

private struct FreshMetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var note: String? = nil
    var tint: Color = FreshPalette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FreshPalette.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.28), value: value)
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FreshPalette.muted)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(FreshPalette.muted)
                    .lineLimit(2)
            }
        }
         .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(12)
        .background(FreshPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(FreshPalette.line, lineWidth: 1)
        }
    }
}

private struct FreshProgressBar: View {
    let fraction: Double
    var tint: Color = FreshPalette.green
    var onDark = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(onDark ? Color.white.opacity(0.14) : FreshPalette.line)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct FreshStatusPill: View {
    let title: String
    var tint: Color = FreshPalette.green
    var symbol: String = "circle.fill"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct FreshOverviewPage: View {
    @Environment(PowerMonitor.self) private var monitor
    let onSettings: () -> Void

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var percent: Int? { monitor.displayedBatteryPercent }

    private var batteryTint: Color {
        guard let percent else { return FreshPalette.muted }
        return percent <= 20 ? FreshPalette.red : FreshPalette.green
    }

    var body: some View {
        FreshPage(title: "总览",
                  subtitle: "实时电源状态 · 每秒更新",
                  onSettings: onSettings) {
            hero
            FreshSectionHeading(title: "实时数据", detail: snapshot.externalConnected ? (snapshot.isCharging ? "充电中" : "已连接") : "电池供电")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FreshMetricTile(title: "充电器输入",
                                value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                                unit: "W",
                                note: snapshot.isWirelessInput ? "无线输入不可直接测量" : "手机接口实测",
                                tint: FreshPalette.accent)
                FreshMetricTile(title: "进入电芯",
                                value: monitor.displayedBatteryPower.map { Formatting.watts(abs($0)) } ?? "—",
                                unit: "W",
                                note: "进入电芯的功率",
                                tint: FreshPalette.green)
                FreshMetricTile(title: monitor.displayedBatteryVoltageIsEstimated ? "电芯电压 · 估算" : "电芯电压",
                                value: monitor.displayedBatteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "V",
                                tint: FreshPalette.accent)
                FreshMetricTile(title: "进入电流",
                                value: monitor.displayedBatteryCurrent.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "A",
                                note: "流入电芯的电流",
                                tint: FreshPalette.green)
            }

            FreshSectionHeading(title: "功率变化", detail: "最近 3 分钟")
            FreshCard {
                if monitor.live.isEmpty {
                    FreshEmptyState(title: "正在收集数据", subtitle: "保持应用前台运行，曲线会自动出现。")
                } else {
                    LivePowerChart(samples: monitor.live)
                        .frame(height: 132)
                }
                HStack(spacing: 14) {
                    FreshLegend(color: FreshPalette.accent, title: "接口输入")
                    FreshLegend(color: FreshPalette.green, title: "进入电芯")
                }
            }

            if !monitor.sensorsAvailable {
                FreshCard {
                    FreshEmptyState(title: "传感器暂不可用",
                                    subtitle: "当前没有读取到 HID 电源传感器。请在真实设备上运行 MiniWatts。")
                }
            }
        }
    }

    private var hero: some View {
        FreshCard(dark: true) {
            HStack {
                Text("BATTERY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.58))
                Spacer()
                FreshStatusPill(title: snapshot.externalConnected ? (snapshot.isCharging ? "充电中" : "已连接") : "电池供电",
                                tint: snapshot.externalConnected ? Color(red: 0.35, green: 0.86, blue: 0.62) : Color.white.opacity(0.78),
                                symbol: snapshot.externalConnected ? "bolt.fill" : "battery.50")
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(percent.map(String.init) ?? "—")
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .tracking(-2)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.32), value: percent)
                    .foregroundStyle(.white)
                Text("%")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Image(systemName: snapshot.isCharging ? "battery.100percent" : "battery.75percent")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.82))
            }
            FreshProgressBar(fraction: Double(percent ?? 0) / 100,
                             tint: percent.map { $0 <= 20 ? FreshPalette.red : Color(red: 0.30, green: 0.82, blue: 0.61) } ?? .white,
                             onDark: true)
            HStack {
                Text("系统电量")
                Spacer()
                Text("设备 \(monitor.deviceModelIdentifier)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.58))
        }
    }
}

private struct FreshBatteryPage: View {
    @Environment(PowerMonitor.self) private var monitor
    let onSettings: () -> Void

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var percent: Int { monitor.displayedBatteryPercent ?? 0 }

    var body: some View {
        FreshPage(title: "电池",
                  subtitle: "电芯读数与充电预测",
                  onSettings: onSettings) {
            FreshCard(dark: true) {
                HStack {
                    Text("系统电量")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Spacer()

                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(monitor.displayedBatteryPercent.map(String.init) ?? "—")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.32), value: monitor.displayedBatteryPercent)
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("状态栏电量")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text(monitor.snapshot.percent.map { "\($0)%" } ?? "暂不可用")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.28), value: monitor.snapshot.percent)
                            .foregroundStyle(.white)
                    }
                }
                FreshProgressBar(fraction: Double(percent) / 100,
                                 tint: percent <= 20 ? FreshPalette.red : Color(red: 0.30, green: 0.82, blue: 0.61),
                                 onDark: true)
            }

            FreshSectionHeading(title: "电芯数据", detail: "实时电芯读数")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FreshMetricTile(title: monitor.displayedBatteryVoltageIsEstimated ? "电芯电压 · 估算" : "电芯电压",
                                value: monitor.displayedBatteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "V",
                                note: monitor.displayedBatteryVoltageIsEstimated ? "SOC 曲线估算" : "传感器读数",
                                tint: FreshPalette.accent)
                FreshMetricTile(title: monitor.displayedBatteryCurrentIsEstimated ? "电芯电流 · 估算" : "电芯电流",
                                value: monitor.displayedBatteryCurrent.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "A",
                                note: monitor.displayedBatteryCurrentIsEstimated ? "非直接读数" : "传感器读数",
                                tint: FreshPalette.green)
                FreshMetricTile(title: monitor.displayedBatteryPowerIsEstimated ? "电芯功率 · 估算" : "电芯功率",
                                value: monitor.displayedBatteryPower.map { String(format: "%.2f", abs($0)) } ?? "—",
                                unit: "W",
                                tint: FreshPalette.green)
                FreshMetricTile(title: "电池容量",
                                value: String(format: "%.1f", monitor.batteryWattHours),
                                unit: "Wh",
                                note: "参与趋势换算",
                                tint: FreshPalette.violet)
            }

            FreshCard {
                FreshSectionHeading(title: "充入多少毫安", detail: snapshot.externalConnected ? "本次连接累计" : "连接充电器后开始统计")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    FreshMetricTile(title: "累计充入电荷",
                                    value: snapshot.externalConnected
                                        ? monitor.sessionTotals.displayedBatteryMilliAmpHours.map { String(format: "%.0f", $0) } ?? "—"
                                        : "—",
                                    unit: "mAh",
                                    note: monitor.sessionTotals.includesEstimatedBatteryCurrent ? "包含估算区间" : "电芯电流积分",
                                    tint: FreshPalette.green)
                    FreshMetricTile(title: "累计充入能量",
                                    value: snapshot.externalConnected
                                        ? monitor.sessionTotals.displayedBatteryWattHours.map { String(format: "%.2f", $0) } ?? "—"
                                        : "—",
                                    unit: "Wh",
                                    note: monitor.sessionTotals.includesEstimatedBatteryEnergy ? "包含估算区间" : "电芯功率积分",
                                    tint: FreshPalette.violet)
                }
                Text("统计本次连接期间进入电芯的累计电荷量与能量；传感器暂不可用时使用估算通道，并在上方注明。")
                    .font(.system(size: 11))
                    .foregroundStyle(FreshPalette.muted)
            }

            FreshCard {
                FreshSectionHeading(title: "充电预测")
                if snapshot.isCharging, percent < 100,
                   let fullSeconds = monitor.chargeSecondsRemaining(to: 100) {
                    HStack(spacing: 10) {
                        if percent < ChargeForecast.taperStart,
                           let eightySeconds = monitor.chargeSecondsRemaining(to: 80) {
                            FreshMetricTile(title: "预计到 80%",
                                            value: Formatting.duration(eightySeconds),
                                            tint: FreshPalette.green)
                        }
                        FreshMetricTile(title: "预计充满",
                                        value: Formatting.duration(fullSeconds),
                                        tint: FreshPalette.accent)
                    }
                    Text(monitor.chargeForecastIsCalibrated
                         ? "已根据近期真实电量变化动态校准；随着电量上升会持续修正。"
                         : "初始估算：先根据当前输入功率和电池能量给出时间，随后随电量变化自动校准。")
                        .font(.system(size: 11))
                        .foregroundStyle(FreshPalette.muted)
                } else {
                    FreshEmptyState(title: "等待充电数据",
                                    subtitle: "连接充电器并开始充电后，将立即显示初始剩余时间。")
                }
            }

            FreshCard {
                FreshSectionHeading(title: "健康度")
                FreshMetricTile(title: "手动设置的电池健康度",
                                value: String(format: "%.0f", monitor.displayedBatteryHealthPercent),
                                unit: "%",
                                note: "不会自动读取或覆盖",
                                tint: monitor.displayedBatteryHealthPercent < 80 ? FreshPalette.amber : FreshPalette.green)
            }

            FreshCard {
                FreshSectionHeading(title: "能量路径")
                FreshInfoRow(label: "接口输入",
                             value: snapshot.inputWatts.map { "\(Formatting.watts($0)) W" } ?? "—",
                             tint: FreshPalette.accent)
                FreshInfoRow(label: "进入电芯",
                             value: monitor.displayedBatteryPower.map { "\(Formatting.watts(max($0, 0))) W" } ?? "—",
                             tint: FreshPalette.green)
                FreshInfoRow(label: "系统负载与损耗",
                             value: monitor.displayedUnaccountedPowerWatts.map { "\(Formatting.watts($0)) W" } ?? "—",
                             tint: FreshPalette.amber)
                FreshInfoRow(label: "电芯能量占比",
                             value: monitor.displayedChargePathEfficiency.map { "\(Int($0.rounded()))%" } ?? "—",
                             tint: FreshPalette.violet)
            }
        }
    }
}

private struct FreshThermalPage: View {
    @Environment(PowerMonitor.self) private var monitor
    let onSettings: () -> Void

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var unit: TemperatureDisplayUnit { monitor.temperatureUnit }
    @State private var selectedTemperatureZone: ThermalZone = .battery
    private var displayedTemperatureZones: [ThermalZone] {
        [.battery, .charger, .soc, .storage, .radio, .display, .camera, .surface]
    }
    private func temperatureZoneTitle(_ zone: ThermalZone) -> String {
        switch zone {
        case .battery: return "电池"
        case .charger: return "充电芯片"
        case .soc: return "SoC 芯片"
        case .storage: return "存储"
        case .radio: return "射频模块"
        case .display: return "屏幕"
        case .camera: return "相机"
        case .surface: return "机身"
        case .wirelessCoil: return "无线线圈"
        case .other: return "其他"
        }
    }

    var body: some View {
        FreshPage(title: "温度",
                  subtitle: "设备热状态与传感器分布",
                  onSettings: onSettings) {
            FreshCard(dark: true) {
                HStack {
                    Text("SYSTEM THERMAL STATE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(Color.white.opacity(0.58))
                    Spacer()
                    FreshStatusPill(title: monitor.thermal.state.isThrottling ? "可能限频" : "正常范围",
                                    tint: monitor.thermal.state.isThrottling ? Color(red: 1.0, green: 0.50, blue: 0.42) : Color(red: 0.35, green: 0.86, blue: 0.62),
                                    symbol: monitor.thermal.state.symbol)
                }
                Text(monitor.thermal.state.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(monitor.thermal.state.chargingEffect)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                FreshProgressBar(fraction: monitor.thermal.state.severity,
                                 tint: monitor.thermal.state.isThrottling ? FreshPalette.red : FreshPalette.green,
                                 onDark: true)
                Text("持续时间：\(Formatting.duration(Date.now.timeIntervalSince(monitor.thermal.stateSince)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FreshMetricTile(title: "最高传感器",
                                value: snapshot.hottestSensor.map { unit.number($0.value) } ?? "—",
                                unit: unit.symbol,
                                note: snapshot.hottestSensor?.name,
                                tint: snapshot.hottestSensor.map { Color.mwTemperature($0.value) } ?? FreshPalette.ink)
                FreshMetricTile(title: "电池温度",
                                value: snapshot.batteryTemperature.map { unit.number($0) } ?? "—",
                                unit: unit.symbol,
                                tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? FreshPalette.ink)
                FreshMetricTile(title: "充电芯片",
                                value: snapshot.chargerTemperature.map { unit.number($0) } ?? "—",
                                unit: unit.symbol,
                                tint: snapshot.chargerTemperature.map { Color.mwTemperature($0) } ?? FreshPalette.ink)
                FreshMetricTile(title: "传感器数量",
                                value: "\(snapshot.temperatures.count)",
                                unit: "个",
                                tint: FreshPalette.accent)
            }

            FreshCard {
                FreshSectionHeading(title: "温度趋势", detail: "左右滑动切换部件")
                VStack(spacing: 8) {
                    TabView(selection: $selectedTemperatureZone) {
                        ForEach(displayedTemperatureZones, id: \.self) { zone in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(temperatureZoneTitle(zone))
                                        .font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    let zoneTemperature = snapshot.temperaturesByZone.first(where: { $0.zone == zone })?.representative
                                    Text(zoneTemperature.map { "\(unit.number($0))°" } ?? "—")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .animation(.snappy(duration: 0.28), value: zoneTemperature)
                                        .foregroundStyle(FreshPalette.green)
                                }
                                if monitor.live.contains(where: { $0.zoneTemperatures.contains(where: { $0.zone == zone }) }) {
                                    LiveTemperatureChart(samples: monitor.live, unit: unit, zone: zone)
                                        .frame(height: 130)
                                } else {
                                    FreshEmptyState(title: "等待\(temperatureZoneTitle(zone))温度样本",
                                                    subtitle: "该部件暂时没有可用读数。")
                                        .frame(height: 130)
                                }
                            }
                            .tag(zone)
                            .padding(.horizontal, 2)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 165)

                    HStack(spacing: 8) {
                        ForEach(displayedTemperatureZones, id: \.self) { zone in
                            Capsule()
                                .fill(selectedTemperatureZone == zone ? FreshPalette.accent : FreshPalette.muted.opacity(0.28))
                                .frame(width: selectedTemperatureZone == zone ? 18 : 6, height: 6)
                                .contentShape(Rectangle().size(width: 22, height: 18))
                                .onTapGesture { selectedTemperatureZone = zone }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            FreshCard {
                FreshSectionHeading(title: "传感器分区", detail: "\(snapshot.temperatures.count) 个有效读数")
                if snapshot.temperaturesByZone.isEmpty {
                    FreshEmptyState(title: "没有可用的温度读数",
                                    subtitle: "模拟器通常没有 iPhone PMU 温度传感器。")
                } else {
                    ForEach(snapshot.temperaturesByZone) { zone in
                        if let value = zone.representative {
                            HStack(spacing: 12) {
                                Image(systemName: zone.zone.symbol)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(FreshPalette.accent)
                                    .frame(width: 34, height: 34)
                                    .background(FreshPalette.canvas, in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(zone.zone.title)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("\(zone.readings.count) 个传感器")
                                        .font(.system(size: 10))
                                        .foregroundStyle(FreshPalette.muted)
                                }
                                Spacer()
                                Text("\(unit.number(value))°")
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.mwTemperature(value))
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }

            if !snapshot.temperatureWarnings.isEmpty {
                FreshCard {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(snapshot.temperatureWarnings, id: \.self) { warning in
                                Text(verbatim: warning)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(FreshPalette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("未纳入推算的读数（\(snapshot.temperatureWarnings.count)）", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
    }
}

private struct FreshDevicesPage: View {
    @Environment(PowerMonitor.self) private var monitor
    let onSettings: () -> Void

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var accessories: [ExternalBatteryDevice] {
        monitor.devices.filter { !$0.isInternal }
    }

    var body: some View {
        FreshPage(title: "设备",
                  subtitle: "充电器协商信息与外接设备电量",
                  onSettings: onSettings) {
            FreshCard(dark: true) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.externalConnected ? "CHARGER CONNECTED" : "NO CHARGER")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(Color.white.opacity(0.58))
                        Text(snapshot.externalConnected ? (snapshot.adapterName ?? (snapshot.isWirelessInput ? "无线充电器" : "已连接电源")) : "未连接充电器")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(snapshot.isWirelessInput ? "无线充电路径" : (snapshot.negotiatedProfile?.label ?? "等待充电协议信息"))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                    Spacer()
                    Image(systemName: snapshot.isWirelessInput ? "wave.3.right" : "powerplug.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.inputWatts.map(Formatting.watts) ?? "—")
                        .font(.system(size: 37, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("W 输入")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                    Spacer()
                    if let rated = snapshot.adapterRatedWatts {
                        Text("额定 \(String(format: "%.0f", rated)) W")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                }
            }

            FreshCard {
                FreshSectionHeading(title: "接口数据")
                FreshInfoRow(label: "输入电压",
                             value: snapshot.usbInputVoltage.map { String(format: "%.3f V", $0) } ?? "—",
                             tint: FreshPalette.accent)
                FreshInfoRow(label: "输入电流",
                             value: snapshot.usbInputCurrent.map { String(format: "%.3f A", $0) } ?? "—",
                             tint: FreshPalette.accent)
                FreshInfoRow(label: "输入功率",
                             value: snapshot.inputWatts.map { "\(Formatting.watts($0)) W" } ?? "—",
                             tint: FreshPalette.green)
                FreshInfoRow(label: "协商档位",
                             value: snapshot.negotiatedProfile?.label ?? "不可用",
                             tint: FreshPalette.violet)
                if let utilisation = snapshot.adapterUtilisation {
                    FreshInfoRow(label: "额定功率利用率",
                                 value: "\(Int((utilisation * 100).rounded()))%",
                                 tint: FreshPalette.amber)
                    FreshProgressBar(fraction: utilisation, tint: FreshPalette.accent)
                }
            }

            FreshCard {
                FreshSectionHeading(title: "协议档位", detail: "\(snapshot.adapterProfiles.count) 项")
                if snapshot.adapterProfiles.isEmpty {
                    FreshEmptyState(title: "没有报告协议档位",
                                    subtitle: "部分 USB-A 充电器或无线充电设备不会提供 USB-PD 档位列表。")
                } else {
                    ForEach(snapshot.adapterProfiles) { profile in
                        HStack {
                            Text("PDO \(profile.index + 1)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(FreshPalette.muted)
                            Spacer()
                            Text(profile.label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            if profile.index == snapshot.negotiatedProfile?.index {
                                FreshStatusPill(title: "当前", tint: FreshPalette.green, symbol: "checkmark")
                            }
                        }
                    }
                }
            }

            FreshCard {
                FreshSectionHeading(title: "本机")
                FreshInfoRow(label: "设备型号", value: monitor.deviceModelIdentifier)
                FreshInfoRow(label: "连接状态", value: snapshot.externalConnected ? (snapshot.isCharging ? "充电中" : "已连接") : "电池供电")
                FreshInfoRow(label: "电池电量", value: monitor.displayedBatteryPercent.map { "\($0)%" } ?? "—")
            }

            FreshCard {
                FreshSectionHeading(title: "外接设备", detail: "\(accessories.count) 台")
                if accessories.isEmpty {
                    FreshEmptyState(title: "暂未发现外接电池设备",
                                    subtitle: "当前 iOS 版本未向应用提供可读取的配件电量。")
                } else {
                    ForEach(accessories) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 19))
                                .foregroundStyle(FreshPalette.violet)
                                .frame(width: 44, height: 44)
                                .background(FreshPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if device.isCharging {
                                    Text("正在充电")
                                        .font(.system(size: 10))
                                        .foregroundStyle(FreshPalette.muted)
                                } else if let transport = device.transport {
                                    Text(transport.title)
                                        .font(.system(size: 10))
                                        .foregroundStyle(FreshPalette.muted)
                                } else {
                                    Text("已连接")
                                        .font(.system(size: 10))
                                        .foregroundStyle(FreshPalette.muted)
                                }
                            }
                            Spacer()
                            Text(device.percent.map { "\($0)%" } ?? "—")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

private struct FreshHistoryPage: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var confirmingDelete = false
    let onSettings: () -> Void

    var body: some View {
        FreshPage(title: "记录",
                  subtitle: "每次连接充电器时形成独立记录",
                  onSettings: onSettings) {
            if let current = monitor.currentSession {
                FreshCard(dark: true) {
                    HStack {
                        FreshStatusPill(title: "正在记录", tint: Color(red: 0.35, green: 0.86, blue: 0.62), symbol: "dot.radiowaves.left.and.right")
                        Spacer()
                        Text(Formatting.duration(current.duration))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    Text(current.adapterName ?? (current.isWireless ? "无线充电" : "当前充电"))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    HStack {
                        FreshHistoryValue(title: "已输入", value: monitor.sessionTotals.measuredInputWattHours.map { String(format: "%.2f Wh", $0) } ?? "—")
                        FreshHistoryValue(title: "进入电芯", value: monitor.sessionTotals.displayedBatteryWattHours.map { String(format: "%.2f Wh", $0) } ?? "—")
                        FreshHistoryValue(title: "电量增加", value: "+\(current.gainedPercent)%")
                    }
                }
            }

            FreshSectionHeading(title: "历史充电", detail: "\(monitor.sessions.count) 次")
            if monitor.sessions.isEmpty {
                FreshCard {
                    FreshEmptyState(title: "还没有已完成的充电记录",
                                    subtitle: "拔下充电器后，本次充电会自动保存到这里。")
                }
            } else {
                ForEach(monitor.sessions) { session in
                    FreshCard {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.adapterName ?? (session.isWireless ? "无线充电器" : "未知充电器"))
                                    .font(.system(size: 14, weight: .bold))
                                    .lineLimit(1)
                                Text("\(Formatting.timestamp(session.start)) · \(Formatting.duration(session.duration))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(FreshPalette.muted)
                            }
                            Spacer()
                            Text(session.totals.measuredInputWattHours.map { String(format: "%.2f Wh", $0) }
                                 ?? session.totals.displayedBatteryWattHours.map { String(format: "%.2f Wh", $0) }
                                 ?? "—")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(session.totals.measuredInputWattHours == nil ? FreshPalette.green : FreshPalette.accent)
                        }
                        FreshProgressBar(fraction: Double(session.endPercent) / 100,
                                         tint: FreshPalette.green)
                        HStack {
                            Text("\(session.startPercent)% → \(session.endPercent)%")
                            Spacer()
                            Text("+\(session.gainedPercent)%")
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(FreshPalette.muted)
                    }
                }

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text("清空全部记录")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .confirmationDialog("确定删除全部充电记录？",
                                    isPresented: $confirmingDelete,
                                    titleVisibility: .visible) {
                    Button("删除全部记录", role: .destructive) { monitor.deleteAllSessions() }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }
}

private struct FreshHistoryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.58))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FreshSettingsPage: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("运行方式") {
                    Toggle("充电时保持屏幕常亮",
                           isOn: Binding(get: { monitor.keepScreenAwakeWhileCharging },
                                         set: { monitor.keepScreenAwakeWhileCharging = $0 }))
                    Toggle("充电时显示实时活动",
                           isOn: Binding(get: { monitor.showsLiveActivityWhileCharging },
                                         set: { monitor.showsLiveActivityWhileCharging = $0 }))
                }

                Section("电池参数") {
                    HStack {
                        Text("电池健康度")
                        Spacer()
                        TextField("0–100", value: Binding(
                            get: { monitor.manualBatteryHealthPercent },
                            set: { monitor.manualBatteryHealthPercent = $0 }
                        ), format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        Text("%").foregroundStyle(.secondary)
                    }
                    Text("由你手动填写并保存。MiniWatts 不再自动提取健康度，也不会用系统数据覆盖这个数值。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("参与估算的电池能量") {
                        Text(String(format: "%.2f Wh", monitor.batteryWattHours))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }
                    LabeledContent("设备标识", value: monitor.deviceModelIdentifier)
                    LabeledContent("传感器状态", value: monitor.sensorsAvailable ? "已连接" : "不可用")
                }

                Section {
                    Text("切换到后台后，iOS 可能挂起普通应用的传感器轮询；MiniWatts 会在回到前台时立即重新枚举传感器并恢复采样。若需要后台持续刷新，可使用悬浮窗（画中画）功能。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct FreshInfoRow: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tint: Color = FreshPalette.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(FreshPalette.muted)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.28), value: value)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(FreshPalette.muted)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FreshLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FreshPalette.muted)
        }
    }
}

private struct FreshEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FreshPalette.ink)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(FreshPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }
}


/// A tab's page, built only while the tab is on screen.
///
/// A `TabView` keeps every tab that has been visited alive, and keeps updating it:
/// each page reads the monitor, so each one was re-evaluated on every tick, on
/// screen or not. With all five visited that was five pages rebuilt once a second,
/// and scrolling the one in front hitched at exactly that rhythm. The price is that
/// a tab comes back scrolled to the top.
///
/// The switch has to live inside the tab. Deciding it in `RootView` from the
/// selection does not work: a tab that is not showing never receives its parent's
/// update, so it kept the page it had and went on updating it.
private struct TabPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isOnScreen = true

    var body: some View {
        ZStack {
            if isOnScreen {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

/// Holds the screen on, but only while it is actually earning something: the app
/// is in front and the phone is plugged in. Keeping a battery instrument awake on
/// battery would be a poor joke.
///
/// A view of its own because deciding needs the snapshot, which changes every
/// second. Read in `RootView`'s body, it re-ran that body — and the tab view under
/// it — on every tick; here it re-runs an empty view.
private struct ScreenAwakeHolder: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onChange(of: shouldStayAwake, initial: true) { _, awake in
                UIApplication.shared.isIdleTimerDisabled = awake
            }
    }

    private var shouldStayAwake: Bool {
        monitor.keepScreenAwakeWhileCharging
            && monitor.snapshot.externalConnected
            && scenePhase == .active
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels —
/// two columns on a wide iPad, see `PanelScroll`.
///
/// The page's content and glow are closures, called by small views of their own
/// rather than here. Every page reads the monitor, and whatever a body reads
/// during evaluation re-runs that body when it changes: called here, a page's
/// reads made this scaffold re-run every tick, and with it the navigation stack,
/// the title, the toolbar and the scroll view. Now only `PageContent` and
/// `PageBackdrop` re-run, and the chrome stays as it is. For the same reason a
/// page must not read the monitor in its own body outside these closures.
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringResource
    var glow: () -> Color
    var toolbar: AnyView?
    var layout: PanelLayout
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         glow: @autoclosure @escaping () -> Color = .mwAccent,
         toolbar: AnyView? = nil,
         layout: PanelLayout = .panels,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.toolbar = toolbar
        self.layout = layout
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackdrop(glow: glow)
                PanelScroll(layout: layout, content: content)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.mwCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if let toolbar {
                    ToolbarItem(placement: .topBarTrailing) { toolbar }
                }
            }
        }
    }
}

/// The backdrop, with its glow read here for the same reason.
private struct PageBackdrop: View {
    let glow: () -> Color

    var body: some View {
        Backdrop(glow: glow())
    }
}

/// Used wherever a probe legitimately has nothing to report.
/// Shown where the input figure would be, when the input sensors answered but more
/// power is reaching the cell than they account for. See `PowerSnapshot.partialInputWatts`.
struct PartialInputNote: View {
    let sensedWatts: Double
    let cellWatts: Double

    var body: some View {
        EmptyNote(text: "The input sensors read \(Formatting.watts(sensedWatts)) W while \(Formatting.watts(cellWatts)) W is reaching the cell, so on this model they see only part of what comes in. That figure is not shown as the input, and nothing is worked out from it.",
                  systemImage: "exclamationmark.triangle")
    }
}

struct EmptyNote: View {
    let text: LocalizedStringResource
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
