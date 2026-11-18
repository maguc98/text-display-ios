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
                    FreshOverviewPage(onSettings: { showingSettings = true },
                                      onNavigate: { selectedTab = $0 })
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FreshTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: selection == tab ? .semibold : .regular))
                            .frame(height: 21)
                        Text(tab.title)
                            .font(.system(size: 10, weight: selection == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == tab ? FreshPalette.accent : FreshPalette.muted)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .padding(.top, 10)
                    .padding(.bottom, 7)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 9)
        .background {
            FreshPalette.card
                .overlay(alignment: .top) {
                    Rectangle().fill(FreshPalette.line).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct FreshPage<Content: View>: View {
    let title: String
    let subtitle: String
    let onSettings: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
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
                            .frame(width: 42, height: 42)
                            .background(FreshPalette.card, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                }
                content()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(FreshPalette.canvas)
    }
}

private struct FreshCard<Content: View>: View {
    var dark = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                dark ? FreshPalette.hero : FreshPalette.card,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
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
                    .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
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
                    .font(.system(size: 10))
                    .foregroundStyle(FreshPalette.muted)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 75, alignment: .leading)
        .padding(14)
        .background(FreshPalette.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
        .frame(height: 7)
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
    let onNavigate: (FreshTab) -> Void

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
                FreshMetricTile(title: monitor.displayedBatteryPowerIsEstimated ? "电芯功率 · 估算" : "电芯功率",
                                value: monitor.displayedBatteryPower.map { Formatting.watts(abs($0)) } ?? "—",
                                unit: "W",
                                note: monitor.displayedBatteryPowerIsEstimated ? "非直接传感器读数" : "电芯侧读数",
                                tint: FreshPalette.green)
                FreshMetricTile(title: monitor.displayedBatteryVoltageIsEstimated ? "电芯电压 · 估算" : "电芯电压",
                                value: monitor.displayedBatteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "V",
                                tint: FreshPalette.accent)
                FreshMetricTile(title: monitor.displayedBatteryCurrentIsEstimated ? "电芯电流 · 估算" : "电芯电流",
                                value: monitor.displayedBatteryCurrent.map { String(format: "%.2f", $0) } ?? "—",
                                unit: "A",
                                note: monitor.displayedBatteryCurrentIsEstimated ? "根据功率与电压推算" : "电芯侧读数",
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
                    FreshLegend(color: FreshPalette.amber, title: "估算值")
                }
            }

            FreshSectionHeading(title: "快捷入口")
            HStack(spacing: 10) {
                FreshQuickLink(title: "电池详情", symbol: "battery.100percent", tint: FreshPalette.green) {
                    onNavigate(.battery)
                }
                FreshQuickLink(title: "温度监测", symbol: "thermometer.medium", tint: FreshPalette.red) {
                    onNavigate(.thermal)
                }
            }
            HStack(spacing: 10) {
                FreshQuickLink(title: "充电设备", symbol: "cable.connector", tint: FreshPalette.accent) {
                    onNavigate(.devices)
                }
                FreshQuickLink(title: "充电记录", symbol: "chart.xyaxis.line", tint: FreshPalette.violet) {
                    onNavigate(.history)
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
                Text(monitor.virtualBattery.isEnabled ? "显示校准电量" : "系统电量")
                Spacer()
                if monitor.virtualBattery.isEnabled {
                    Text("原始 \(monitor.systemStatusBarBatteryPercent.map { "\($0)%" } ?? "—")")
                } else {
                    Text("设备 \(monitor.deviceModelIdentifier)")
                }
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
                  subtitle: "电量校准、电芯读数与充电预测",
                  onSettings: onSettings) {
            FreshCard(dark: true) {
                HStack {
                    Text("当前显示电量")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Spacer()
                    if monitor.virtualBattery.isEnabled {
                        FreshStatusPill(title: "校准已启用",
                                        tint: Color(red: 0.35, green: 0.86, blue: 0.62),
                                        symbol: "checkmark")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(monitor.displayedBatteryPercent.map(String.init) ?? "—")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("系统原始电量")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text(monitor.systemStatusBarBatteryPercent.map { "\($0)%" } ?? "暂不可用")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                FreshProgressBar(fraction: Double(percent) / 100,
                                 tint: percent <= 20 ? FreshPalette.red : Color(red: 0.30, green: 0.82, blue: 0.61),
                                 onDark: true)
            }

            FreshCard {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("手动电量校准")
                            .font(.system(size: 17, weight: .bold))
                        Text("只调整显示百分比，电压、电流和功率由系统测量或算法推算。")
                            .font(.system(size: 11))
                            .foregroundStyle(FreshPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(FreshPalette.accent)
                }

                if monitor.virtualBattery.isEnabled {
                    HStack(spacing: 14) {
                        Button {
                            monitor.adjustVirtualBatteryPercent(by: -1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(FreshPalette.canvas, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Slider(value: Binding(
                            get: { Double(monitor.virtualBattery.percent) },
                            set: { monitor.setVirtualBatteryPercentPreview(Int($0.rounded())) }
                        ), in: 0...100, step: 1, onEditingChanged: { editing in
                            if !editing { monitor.commitVirtualBatteryPercentChange() }
                        })
                        .tint(FreshPalette.accent)

                        Button {
                            monitor.adjustVirtualBatteryPercent(by: 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(FreshPalette.canvas, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack {
                        Text("校准偏移")
                        Spacer()
                        let offset = monitor.virtualBattery.systemPercentOffset
                        Text("\(offset > 0 ? "+" : "")\(offset)%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(FreshPalette.muted)

                    if let watts = monitor.virtualRateEstimateWatts {
                        FreshInfoRow(label: "电量趋势功率",
                                     value: "\(String(format: "%.2f", abs(watts))) W",
                                     detail: watts >= 0 ? "充入电芯" : "电池放电",
                                     tint: FreshPalette.green)
                    } else {
                        Text("正在收集连续电量变化记录。至少积累两次有效变化并经过足够观察时间后，才会显示趋势估算。")
                            .font(.system(size: 11))
                            .foregroundStyle(FreshPalette.muted)
                    }

                    Button(role: .destructive) {
                        monitor.disableVirtualBattery()
                    } label: {
                        Text("退出校准，恢复系统电量")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        monitor.enableVirtualBattery()
                    } label: {
                        Label("启用手动校准", systemImage: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FreshPalette.accent)
                }
            }

            FreshSectionHeading(title: "电芯数据", detail: "实测与估算明确区分")
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
                FreshSectionHeading(title: "充电预测")
                if snapshot.isCharging, let forecast = monitor.displayedChargeForecast, percent < 100 {
                    HStack(spacing: 10) {
                        if percent < ChargeForecast.taperStart {
                            FreshMetricTile(title: "预计到 80%",
                                            value: Formatting.duration(forecast.secondsRemaining(to: 80, from: percent, at: snapshot.date)),
                                            tint: FreshPalette.green)
                        }
                        FreshMetricTile(title: "预计充满",
                                        value: Formatting.duration(forecast.secondsRemaining(to: 100, from: percent, at: snapshot.date)),
                                        tint: FreshPalette.accent)
                    }
                    Text("根据近期电量变化速度推算；80% 以上会考虑充电电流逐渐下降，因此后段时间属于模型预测。")
                        .font(.system(size: 11))
                        .foregroundStyle(FreshPalette.muted)
                } else {
                    FreshEmptyState(title: "暂时没有可用预测",
                                    subtitle: "需要处于充电状态，并积累连续电量变化记录。")
                }
            }

            FreshCard {
                FreshSectionHeading(title: "能量路径")
                FreshInfoRow(label: "接口输入",
                             value: snapshot.inputWatts.map { "\(Formatting.watts($0)) W" } ?? "—",
                             tint: FreshPalette.accent)
                FreshInfoRow(label: "进入电芯",
                             value: monitor.displayedBatteryPower.map { "\(Formatting.watts(max($0, 0))) W" } ?? "—",
                             detail: monitor.displayedBatteryPowerIsEstimated ? "估算" : "传感器",
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
                FreshSectionHeading(title: "温度趋势", detail: "最近 3 分钟")
                if monitor.live.contains(where: { $0.hottestTemperature != nil }) {
                    LiveTemperatureChart(samples: monitor.live, unit: unit)
                        .frame(height: 130)
                } else {
                    FreshEmptyState(title: "正在等待温度样本", subtitle: "传感器读数出现后会绘制趋势。")
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
                                .frame(width: 38, height: 38)
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
                    LabeledContent("参与估算的电池能量") {
                        Text(String(format: "%.2f Wh", monitor.batteryWattHours))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }
                    LabeledContent("设备标识", value: monitor.deviceModelIdentifier)
                    LabeledContent("传感器状态", value: monitor.sensorsAvailable ? "已连接" : "不可用")
                }

                Section {
                    Text("MiniWatts 优先显示设备直接提供的传感器数据。估算值会单独标注，不会伪装成实测值。")
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
                .font(.system(size: 12))
                .foregroundStyle(FreshPalette.muted)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(FreshPalette.muted)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FreshQuickLink: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FreshPalette.ink)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FreshPalette.muted)
            }
            .padding(12)
            .background(FreshPalette.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FreshLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FreshPalette.ink)
            Text(subtitle)
                .font(.system(size: 11))
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
