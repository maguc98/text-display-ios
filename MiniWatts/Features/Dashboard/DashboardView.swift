import SwiftUI
import UIKit
import Observation

struct DashboardView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var showingSettings = false

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var plugged: Bool { snapshot.externalConnected }

    var body: some View {
        PageScaffold("MiniWatts", glow: glowColor, toolbar: AnyView(toolbarButtons)) {
            heroPanel
            if monitor.thermal.state.isThrottling { throttleBanner }
            batteryPanel
            manualBatteryPanel
            standbyDetectionPanel
            forecastPanel
            breakdownPanel
            livePanel
            sessionPanel
            if !monitor.sensorsAvailable { sensorNote }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private var glowColor: Color {
        if monitor.thermal.state.isThrottling { return .mwDanger }
        if snapshot.isWirelessInput { return .mwWireless }
        return plugged ? .mwAccent : .mwLoss
    }

    private var toolbarButtons: some View {
        HStack(spacing: 14) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .tint(.mwAccent)
        }
    }

    // MARK: Hero

    private var heroPanel: some View {
        Panel {
            VStack(spacing: 14) {
                PowerRing(inputWatts: monitor.headline?.watts,
                          batteryWatts: plugged ? monitor.displayedBatteryPower.map { max($0, 0) } : nil,
                          batteryWattsIsEstimate: monitor.displayedBatteryPowerIsEstimated,
                          fullScale: fullScale,
                          caption: monitor.headline?.caption,
                          tint: glowColor)
                    .padding(.top, 4)

                FlowRow(spacing: 6) {
                    Pill(text: Text(snapshot.statusText),
                         systemImage: plugged ? "bolt.fill" : "battery.50",
                         tint: plugged ? .mwAccent : .mwMuted)
                    if snapshot.isWirelessInput {
                        Pill(text: Text("MagSafe"), systemImage: "wave.3.right", tint: .mwWireless)
                    }
                    if monitor.levelRateCheck?.verdict == .sensorsShort {
                        Pill(text: Text("reading low"), systemImage: "exclamationmark.triangle.fill", tint: .mwDanger)
                    } else if InputShortfallNotes.applies(to: snapshot, check: monitor.levelRateCheck) {
                        Pill(text: Text("may read half"), systemImage: "exclamationmark.triangle", tint: .mwLoss)
                    }
                    if snapshot.holdIsInferred {
                        Pill(text: Text("inferred"), systemImage: "questionmark.circle", tint: .mwLoss)
                    }
                    if snapshot.holdIsUnknown {
                        Pill(text: Text("hold status unknown"), systemImage: "questionmark.circle", tint: .mwLoss)
                    }
                    if monitor.thermal.lowPowerMode || snapshot.lowPowerMode {
                        Pill(text: Text("Low Power"), systemImage: "battery.25", tint: .mwLoss)
                    }
                    Pill(text: Text(monitor.thermal.state.title),
                         systemImage: monitor.thermal.state.symbol,
                         tint: thermalTint)
                }
            }
        }
    }

    /// True while charging wirelessly with no way to measure what comes in.
    private var wirelessInputUnmeasurable: Bool {
        plugged && snapshot.inputWatts == nil && snapshot.isWirelessInput
    }



    /// Full scale is the adapter's nameplate when it declares one, so the dial
    /// shows how much of the charger is actually being used.
    private var fullScale: Double {
        guard plugged else { return 15 }
        // With no input reading the dial is showing battery-side watts, which never
        // exceed what the adapter can supply — but a low wireless ceiling would put
        // the needle near full for an ordinary trickle, so keep a floor under it.
        if snapshot.inputWatts == nil { return max(snapshot.adapterRatedWatts ?? 25, 10) }
        return max(snapshot.adapterRatedWatts ?? 30, 5)
    }

    private var thermalTint: Color {
        switch monitor.thermal.state {
        case .nominal: return .mwBattery
        case .fair: return .mwLoss
        default: return .mwDanger
        }
    }

    private var throttleBanner: some View {
        Panel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                VStack(alignment: .leading, spacing: 3) {
                    Text("High system thermal pressure")
                        .font(.system(size: 14, weight: .semibold))
                    Text(monitor.thermal.state.chargingEffect)
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Text(monitor.thermal.state.title)) for \(Formatting.duration(Date.now.timeIntervalSince(monitor.thermal.stateSince)))")
                        .mwMono(size: 10)
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwDanger.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: Battery

    private var batteryPanel: some View {
        Panel("Battery", systemImage: "battery.100") {
            VStack(spacing: 12) {
                if let percent = monitor.displayedBatteryPercent {
                    let forecast = monitor.displayedChargeForecast
                    let estimatedRemaining: Text? = {
                        guard snapshot.isCharging, let forecast, percent < 100 else { return nil }
                        let remainingSeconds = forecast.secondsRemaining(to: 100,
                                                                         from: percent,
                                                                         at: snapshot.date)
                        return Text("预计充满 \(Self.duration(remainingSeconds))")
                    }()
                    let systemRemaining = snapshot.timeRemainingMinutes.map { minutes in
                        let remaining = Formatting.minutesRemaining(minutes)
                        return snapshot.isCharging ? Text("full in \(remaining)") : Text("empty in \(remaining)")
                    }
                    BarRow(title: Text(monitor.virtualBattery.isEnabled ? "校准电量" : (monitor.manualBatteryPercent == nil ? "Charge level" : "Manual charge level")),
                           detail: "\(percent)%",
                           fraction: Double(percent) / 100,
                           tint: percent <= 20 ? .mwDanger : .mwBattery,
                           subtitle: monitor.virtualBattery.isEnabled ? estimatedRemaining : systemRemaining)
                }
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: monitor.displayedBatteryVoltageIsEstimated ? "Estimated voltage" : "Cell voltage",
                               value: monitor.displayedBatteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "V",
                               footnote: monitor.displayedBatteryVoltageIsEstimated
                                   ? Text("SOC curve estimate · not a direct sensor reading")
                                   : nil,
                               size: 20)
                        let shownCurrent = monitor.displayedBatteryCurrent
                        let isEstimatedCurrent = monitor.displayedBatteryCurrentIsEstimated
                        Metric(caption: isEstimatedCurrent ? "Estimated current" : "Cell current",
                               value: shownCurrent.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "A",
                               tint: shownCurrent.map { $0 > 0 ? .mwBattery : ($0 < 0 ? .mwLoss : .primary) } ?? .primary,
                               footnote: isEstimatedCurrent
                                   ? Text(monitor.virtualBattery.isEnabled && monitor.virtualRateEstimateWatts != nil
                                          ? "Estimated from calibrated level trend"
                                          : (snapshot.batteryEstimateLabel ?? "Estimated from input power"))
                                   : nil,
                               size: 20)
                        Metric(caption: "Cell temp",
                               value: snapshot.batteryTemperature.map { monitor.temperatureUnit.number($0) } ?? "—",
                               unit: monitor.temperatureUnit.symbol,
                               tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? .primary,
                               size: 20)
                    }
                    Metric(caption: monitor.displayedBatteryPowerIsEstimated ? "Estimated cell power" : "Cell power",
                           value: monitor.displayedBatteryPower.map { String(format: "%.2f", abs($0)) } ?? "—",
                           unit: "W", tint: .mwAccent,
                           footnote: monitor.displayedBatteryPowerIsEstimated
                               ? Text(monitor.virtualBattery.isEnabled && monitor.virtualRateEstimateWatts != nil
                                      ? "Estimated from calibrated level trend · not a direct sensor reading"
                                      : (snapshot.batteryEstimateLabel ?? "Estimated · not a direct sensor reading"))
                               : nil,
                           size: 20)
                }
            }
        }
    }

    // MARK: Percentage calibration

    private var manualBatteryPanel: some View {
        Panel("手动电量校准", systemImage: "battery.100percent") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前校准电量")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                        Text("\(monitor.displayedBatteryPercent.map { String($0) } ?? "—")%")
                            .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                            .foregroundStyle(monitor.virtualBattery.isEnabled ? Color.mwAccent : Color.primary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("系统原始电量")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                        Text(monitor.systemStatusBarBatteryPercent.map { "\($0)%" } ?? "暂不可用")
                            .font(.system(.title3, design: .rounded).monospacedDigit().weight(.medium))
                        if monitor.virtualBattery.isEnabled {
                            let offset = monitor.virtualBattery.systemPercentOffset
                            Text("校准偏移 \(offset > 0 ? "+" : "")\(offset)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.mwMuted)
                        }
                    }
                }

                if monitor.virtualBattery.isEnabled {
                    VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            Button {
                                monitor.adjustVirtualBatteryPercent(by: -1)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.bordered)
                            .clipShape(Circle())
                            .accessibilityLabel("电量减少 1%")
                            .disabled(monitor.virtualBattery.percent <= 0)

                            Spacer(minLength: 8)

                            Text("\(monitor.virtualBattery.percent)%")
                                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())

                            Spacer(minLength: 8)

                            Button {
                                monitor.adjustVirtualBatteryPercent(by: 1)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.bordered)
                            .clipShape(Circle())
                            .accessibilityLabel("电量增加 1%")
                            .disabled(monitor.virtualBattery.percent >= 100)
                        }
                        .tint(.mwAccent)

                        HStack {
                            Text("0%")
                            Spacer()
                            Text("100%")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.mwMuted)

                        Slider(
                            value: Binding(
                                get: { Double(monitor.virtualBattery.percent) },
                                set: { monitor.setVirtualBatteryPercentPreview(Int($0.rounded())) }
                            ),
                            in: 0...100,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing { monitor.commitVirtualBatteryPercentChange() }
                            }
                        )
                        .tint(.mwAccent)

                        HStack {
                            Spacer()
                            Button {
                                _ = monitor.calibrateVirtualBatteryToSystem()
                            } label: {
                                Label("恢复系统电量", systemImage: "arrow.counterclockwise")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(monitor.virtualBattery.systemPercentOffset == 0)
                        }
                    }

                    Slider(
                        value: Binding(
                            get: { Double(monitor.virtualBattery.percent) },
                            set: { monitor.setVirtualBatteryPercentPreview(Int($0.rounded())) }
                        ),
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { monitor.commitVirtualBatteryPercentChange() }
                        }
                    )
                    .tint(.mwAccent)

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(Color.mwAccent)
                        Text("校准值会跟随系统电量自然变化。手动调整只改变百分比偏移，不会篡改系统读数或传感器数据。")
                            .font(.caption2)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let watts = monitor.virtualRateEstimateWatts {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundStyle(Color.mwBattery)
                            Text("电量变化趋势")
                                .font(.caption)
                                .foregroundStyle(Color.mwMuted)
                            Spacer()
                            Text("\(String(format: "%.2f", abs(watts))) W")
                                .font(.system(.subheadline, design: .rounded).monospacedDigit().weight(.semibold))
                                .foregroundStyle(Color.mwBattery)
                            Text(watts >= 0 ? "充入" : "消耗")
                                .font(.caption2)
                                .foregroundStyle(Color.mwMuted)
                        }
                    } else {
                        EmptyNote(
                            text: "正在收集连续电量变化。系统电量发生变化并积累至少两分钟记录后，才会生成趋势功率和时间估算。",
                            systemImage: "clock"
                        )
                    }

                    Text("校准来源：\(monitor.virtualBattery.lastCalibrationSource.title) · 电压优先使用电芯实测值；缺失时会明确标记为估算。")
                        .font(.caption2)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        monitor.disableVirtualBattery()
                    } label: {
                        Label("退出校准，恢复系统电量", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("开启后可手动修正电量。校准值会持续跟随系统电量变化，电流、功率和充电时间根据真实电量变化趋势自动估算。")
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        monitor.enableVirtualBattery()
                    } label: {
                        Label("启动手动电量校准", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mwAccent)
                }
            }
        }
    }

    // MARK: Standby detection

    private var standbyDetectionPanel: some View {
        Panel("静默电流采样", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 8) {
                if monitor.isStandbyDetectionRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.mwAccent)
                        Text("正在自动采样电池侧数据")
                            .font(.footnote)
                        Spacer()
                        Text("\(monitor.standbyDetectionSecondsRemaining)s")
                            .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.mwAccent)
                    }
                } else if let result = monitor.standbyDetectionResult {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(result.averageCurrentAmps.map { String(format: "%.3f A", $0) } ?? "—")
                            .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                            .foregroundStyle(result.isMeasured ? Color.mwBattery : Color.mwLoss)
                        Text(result.isMeasured ? "电池侧实测平均" : "电池侧估算平均")
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                    }
                    if let watts = result.averagePowerWatts {
                        Text(String(format: "平均功率 %.2f W · %d 条样本", watts, result.sampleCount))
                            .font(.caption2)
                            .foregroundStyle(Color.mwMuted)
                    }
                } else {
                    Text(plugged
                         ? "充电状态稳定后自动采样，无需操作。"
                         : "插入充电线后自动开始 10 秒采样。")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                }
                Text("采样期间首页保持正常显示和亮度，不会切换黑屏。")
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
            }
        }
    }

    // MARK: Forecast

    /// Time to 80 % and to full, asked for in #27. Only while the battery is actually
    /// charging: on hold, full, or on battery there is nothing to count down to.
    @ViewBuilder
    private var forecastPanel: some View {
        if plugged, snapshot.isCharging, !snapshot.isChargingOnHold,
           let percent = monitor.displayedBatteryPercent, percent < 100 {
            Panel("Charge forecast", systemImage: "clock") {
                if let forecast = monitor.displayedChargeForecast {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            if percent < ChargeForecast.taperStart {
                                Metric(caption: "To 80%",
                                       value: Self.duration(forecast.secondsRemaining(to: 80, from: percent, at: snapshot.date)),
                                       tint: .mwBattery,
                                       footnote: Self.arrival(forecast.secondsRemaining(to: 80, from: percent, at: snapshot.date),
                                                              after: snapshot.date),
                                       size: 22)
                            }
                            Metric(caption: "To 100%",
                                   value: Self.duration(forecast.secondsRemaining(to: 100, from: percent, at: snapshot.date)),
                                   tint: .mwBattery,
                                   footnote: Self.arrival(forecast.secondsRemaining(to: 100, from: percent, at: snapshot.date),
                                                          after: snapshot.date),
                                   size: 22)
                        }
                        Text("Worked out from how fast the level has been rising — \(forecast.measuredRise)% in the last \(Formatting.duration(forecast.measuredSpan)). Charging slows past 80%, so the time beyond it follows a typical charging curve and is approximate. A charge limit or Optimized Charging stops the battery short of 100%.")
                            .font(.caption2)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    EmptyNote(text: monitor.virtualBattery.isEnabled
                              ? "需要两次带时间戳的校准电量记录，且观察间隔至少两分钟，才会生成可靠的趋势估算。"
                              : "Waiting for the battery level to move twice. The forecast comes from how fast it actually rises, so it takes a few minutes to appear.",
                              systemImage: "clock")
                }
            }
        }
    }

    /// "38m", "1h 38m", in the locale's own words for hours and minutes. Never under a
    /// minute: a countdown to "0m" reads as already there.
    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max((seconds / 60).rounded(), 1)
        return Formatting.duration(minutes * 60)
    }

    private static func arrival(_ seconds: TimeInterval, after date: Date) -> Text {
        Text("around \(date.addingTimeInterval(seconds).formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh-Hans"))))")
    }

    // MARK: Breakdown

    private var breakdownPanel: some View {
        Panel("Power path", systemImage: "arrow.triangle.branch",
              trailing: snapshot.adapterUtilisation.map { Text("\(Int($0 * 100))% of adapter") }) {
            VStack(spacing: 12) {
                let isEstimatedCellWatts = monitor.displayedBatteryPowerIsEstimated
                if plugged && !snapshot.isWirelessInput {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Input voltage",
                               value: snapshot.usbInputVoltage.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "V", tint: .mwAccent, size: 20)
                        Metric(caption: "Input current",
                               value: snapshot.usbInputCurrent.map { String(format: "%.3f", $0) } ?? "—",
                               unit: "A", tint: .mwAccent,
                               footnote: Text("Measured at USB port"), size: 20)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: snapshot.isWirelessInput ? "At charging coil" : "At phone port",
                           value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                           unit: "W",
                           tint: .mwAccent,
                           footnote: snapshot.isWirelessInput
                               ? Text(verbatim: "coil voltage × current")
                               : Text(verbatim: "Charger VQ0u × IQ0u"),
                           size: 22)
                    let shownCellWatts = monitor.displayedBatteryPower
                    Metric(caption: isEstimatedCellWatts ? "Estimated into cell" : "Into cell",
                           value: shownCellWatts.map { Formatting.watts(max($0, 0)) } ?? "—",
                           unit: "W",
                           tint: .mwBattery,
                           footnote: isEstimatedCellWatts
                               ? Text(snapshot.batteryEstimateLabel ?? "Estimated from input power · not a direct sensor reading")
                               : nil,
                           size: 22)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Load + loss",
                           value: monitor.displayedUnaccountedPowerWatts.map(Formatting.watts) ?? "—",
                           unit: "W", tint: .mwLoss,
                           footnote: isEstimatedCellWatts ? Text("Estimated") : nil,
                           size: 22)
                    Metric(caption: "Cell share",
                           value: monitor.displayedChargePathEfficiency.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "%",
                           tint: efficiencyTint,
                           footnote: Text(isEstimatedCellWatts ? "Estimated cell watts ÷ input watts" : "cell watts ÷ measured input watts"),
                           size: 22)
                }
                if let input = snapshot.inputWatts, input > 0.2,
                   let battery = monitor.displayedBatteryPower, battery > 0 {
                    PowerFlowBar(input: input, toBattery: battery)
                }
                if let partial = snapshot.partialInputWatts, let battery = snapshot.batteryWatts {
                    PartialInputNote(sensedWatts: partial, cellWatts: battery)
                }
                if plugged {
                    InputShortfallNotes(snapshot: snapshot, check: monitor.levelRateCheck)
                }
                if wirelessInputUnmeasurable {
                    EmptyNote(text: "Charging wirelessly. The charge IC exposes the coil's voltage but no current to pair with it, so the power coming in cannot be measured — only what reaches the cell. The figure the charger reports about itself is a ceiling, not a reading, and does not move.",
                              systemImage: "wave.3.right")
                }
            }
        }
    }

    private var efficiencyTint: Color {
        guard let efficiency = snapshot.displayChargePathEfficiency else { return .primary }
        return efficiency >= 85 ? .mwBattery : (efficiency >= 70 ? .mwLoss : .mwDanger)
    }

    // MARK: Live

    private var livePanel: some View {
        Panel("Last 3 minutes", systemImage: "waveform.path.ecg",
              trailing: Text("\(monitor.live.count) samples")) {
            VStack(alignment: .leading, spacing: 8) {
                LivePowerChart(samples: monitor.live)
                HStack(spacing: 14) {
                    if monitor.live.contains(where: { $0.inputWatts != nil }) {
                        LegendDot(color: .mwAccent, text: "From charger")
                    }
                    if monitor.live.contains(where: { $0.batteryWatts != nil }) {
                        LegendDot(color: .mwBattery, text: "Into battery", dashed: true)
                    }
                    if monitor.live.contains(where: { $0.estimatedBatteryWatts != nil }) {
                        LegendDot(color: .mwLoss, text: "Estimated", dashed: true)
                    }
                }
            }
        }
    }

    // MARK: Session

    private var sessionPanel: some View {
        Panel("This charge", systemImage: "sum",
              trailing: monitor.currentSession.map { Text(verbatim: Formatting.duration($0.duration)) } ?? Text("idle")) {
            if monitor.currentSession != nil {
                let totals = monitor.sessionTotals
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Delivered",
                               value: totals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "Wh", tint: .mwAccent, size: 20)
                        Metric(caption: "Stored",
                               value: totals.displayedBatteryWattHours.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "Wh", tint: .mwBattery,
                               footnote: totals.includesEstimatedBatteryEnergy ? Text("Includes estimated cell-power intervals") : nil,
                               size: 20)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Into cell",
                               value: totals.displayedBatteryMilliAmpHours.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "mAh",
                               footnote: totals.includesEstimatedBatteryCurrent ? Text("Estimated from cell watts ÷ battery voltage") : nil,
                               size: 20)
                        Metric(caption: "Cell share",
                               value: totals.chargePathEfficiencyPercent.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "%", tint: .mwLoss,
                               footnote: totals.includesEstimatedCellShare ? Text("Paired adapter input vs. estimated cell energy") : nil,
                               size: 20)
                    }
                }
            } else {
                EmptyNote(text: "Plug in to start measuring. Energy is integrated from the live sensors while the app is open, and saved to History when you unplug.",
                          systemImage: "powerplug")
            }
        }
    }

    private var sensorNote: some View {
        Panel("Sensors", systemImage: "sensor") {
            EmptyNote(text: "No HID power sensors were found. On the simulator this is expected — IOKit reads the Mac's battery and the phone's PMU sensors do not exist. Run on the device for real numbers.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}

/// The input-versus-stored split, drawn as one bar so unaccounted power has a size.
struct PowerFlowBar: View {
    let input: Double
    let toBattery: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let stored = CGFloat(min(toBattery / input, 1))
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Theme.gradient(.mwBattery))
                        .frame(width: max(2, geometry.size.width * stored - 1))
                    Capsule()
                        .fill(Theme.gradient(.mwLoss).opacity(0.7))
                }
                // Ease out quickly, then settle gently as the battery/load split moves.
                .animation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.68), value: stored)
            }
            .frame(height: 8)
            HStack {
                Text("stored in cell").font(.caption2).foregroundStyle(Color.mwBattery)
                Spacer()
                Text("system load + losses").font(.caption2).foregroundStyle(Color.mwLoss)
            }
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: LocalizedStringResource
    var dashed: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            // One stroked line with a dash pattern, rather than two capsules —
            // the second capsule used to be offset out of its own frame and
            // landed on top of the label.
            LegendLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5,
                                                  lineCap: .round,
                                                  dash: dashed ? [3.5, 3.5] : []))
                .frame(width: 16, height: 2.5)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.mwMuted)
        }
    }
}

nonisolated private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A wrapping row of pills. `LazyVGrid` cannot do variable-width items on iOS 17,
/// so the layout is done by hand.
nonisolated struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: width, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
