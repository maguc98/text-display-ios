import SwiftUI
import UIKit
import Observation
import ReplayKit
import ScreenCaptureKit
import CoreMedia

struct DashboardView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var showingSettings = false
    @State private var showingRecordingPreview = false
    @State private var showingRecorderError = false
    @State private var recorder = MiniWattsScreenRecorder()

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var plugged: Bool { snapshot.externalConnected }

    var body: some View {
        PageScaffold("MiniWatts", glow: glowColor, toolbar: AnyView(toolbarButtons)) {
            heroPanel
            if monitor.thermal.state.isThrottling { throttleBanner }
            batteryPanel
            standbyDetectionPanel
            forecastPanel
            breakdownPanel
            livePanel
            sessionPanel
            if !monitor.sensorsAvailable { sensorNote }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingRecordingPreview, onDismiss: { recorder.dismissLegacyPreview() }) {
            if let preview = recorder.legacyPreviewController {
                LegacyRecordingPreview(controller: preview)
                    .ignoresSafeArea()
            }
        }
        .modifier(AvailableRecordingEditor(url: $recorder.completedRecordingURL))
        .alert("录屏未能完成", isPresented: $showingRecorderError) {
            Button("好", role: .cancel) { recorder.clearError() }
        } message: {
            Text(recorder.errorMessage ?? "请重试。")
        }
        .onChange(of: recorder.legacyPreviewController != nil) { _, visible in
            showingRecordingPreview = visible
        }
        .onChange(of: recorder.errorMessage != nil) { _, visible in
            showingRecorderError = visible
        }
    }

    private var glowColor: Color {
        if monitor.thermal.state.isThrottling { return .mwDanger }
        if snapshot.isWirelessInput { return .mwWireless }
        return plugged ? .mwAccent : .mwLoss
    }

    private var toolbarButtons: some View {
        HStack(spacing: 14) {
            Button {
                if recorder.isRecording || recorder.isStarting {
                    recorder.stop()
                } else {
                    recorder.start()
                }
            } label: {
                Label(recorder.isRecording ? "停止" : (recorder.isStarting ? "准备中" : "录屏"),
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .labelStyle(.titleAndIcon)
            }
            .tint(recorder.isRecording ? .mwDanger : .mwAccent)
            .disabled(recorder.isStarting && !recorder.isRecording)

            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .tint(.mwAccent)
        }
    }

    // MARK: Hero

    private var heroPanel: some View {
        Panel {
            VStack(spacing: 14) {
                PowerRing(inputWatts: monitor.headline?.watts,
                          batteryWatts: plugged ? snapshot.displayBatteryWatts.map { max($0, 0) } : nil,
                          batteryWattsIsEstimate: snapshot.batteryWattsAreEstimated,
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
                    if recorder.isRecording {
                        Pill(text: Text("录屏中"), systemImage: "record.circle.fill", tint: .mwDanger)
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
                if let percent = snapshot.percent {
                    BarRow(title: Text("Charge level"),
                           detail: "\(percent)%",
                           fraction: Double(percent) / 100,
                           tint: percent <= 20 ? .mwDanger : .mwBattery,
                           subtitle: snapshot.timeRemainingMinutes.map { minutes in
                               // Two whole sentences rather than a fragment glued to a
                               // number: word order around the duration is not the same
                               // in every language.
                               let remaining = Formatting.minutesRemaining(minutes)
                               return snapshot.isCharging ? Text("full in \(remaining)")
                                                          : Text("empty in \(remaining)")
                           })
                }
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Cell voltage",
                               value: snapshot.batteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "V", size: 20)
                        let shownCurrent = snapshot.displayBatteryCurrent
                        let isEstimatedCurrent = snapshot.batteryCurrentIsEstimated
                        Metric(caption: isEstimatedCurrent ? "Estimated current" : "Cell current",
                               value: shownCurrent.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "A",
                               tint: shownCurrent.map { $0 > 0 ? .mwBattery : ($0 < 0 ? .mwLoss : .primary) } ?? .primary,
                               footnote: isEstimatedCurrent ? Text(snapshot.batteryEstimateLabel ?? "Estimated from input power") : nil,
                               size: 20)
                        Metric(caption: "Cell temp",
                               value: snapshot.batteryTemperature.map { monitor.temperatureUnit.number($0) } ?? "—",
                               unit: monitor.temperatureUnit.symbol,
                               tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? .primary,
                               size: 20)
                    }
                    if snapshot.batteryCurrentIsEstimated {
                        Text("\(snapshot.batteryEstimateLabel ?? "Estimated from input power") · not a direct sensor reading")
                            .font(.caption2)
                            .foregroundStyle(Color.mwMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
           let percent = snapshot.percent, percent < 100 {
            Panel("Charge forecast", systemImage: "clock") {
                if let forecast = monitor.chargeForecast {
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
                    EmptyNote(text: "Waiting for the battery level to move twice. The forecast comes from how fast it actually rises, so it takes a few minutes to appear.",
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
                    let shownCellWatts = snapshot.displayBatteryWatts
                    let isEstimatedCellWatts = snapshot.batteryWattsAreEstimated
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
                           value: snapshot.displayUnaccountedPowerWatts.map(Formatting.watts) ?? "—",
                           unit: "W", tint: .mwLoss,
                           footnote: snapshot.batteryWattsAreEstimated ? Text("Estimated") : nil,
                           size: 22)
                    Metric(caption: "Cell share",
                           value: snapshot.displayChargePathEfficiency.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "%",
                           tint: efficiencyTint,
                           footnote: Text(snapshot.batteryWattsAreEstimated ? "Estimated cell watts ÷ input watts" : "cell watts ÷ measured input watts"),
                           size: 22)
                }
                if let input = snapshot.inputWatts, input > 0.2,
                   let battery = snapshot.displayBatteryWatts, battery > 0 {
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


/// One-tap screen recording. iOS 27 uses ScreenCaptureKit and the system
/// content-sharing picker, limited to MiniWatts itself. Earlier iOS versions retain
/// a ReplayKit fallback. Microphone capture is intentionally disabled.
@MainActor
@Observable
private final class MiniWattsScreenRecorder: NSObject, RPPreviewViewControllerDelegate {
    private(set) var isStarting = false
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var legacyPreviewController: RPPreviewViewController?
    var completedRecordingURL: URL?

    @ObservationIgnored private let legacyRecorder = RPScreenRecorder.shared()
    @ObservationIgnored private var activeRecordingURL: URL?
    @available(iOS 27.0, *)
    @ObservationIgnored private var modernStream: SCStream?
    @available(iOS 27.0, *)
    @ObservationIgnored private var modernOutput: SCRecordingOutput?

    func start() {
        errorMessage = nil
        isStarting = true
        if #available(iOS 27.0, *) {
            startModernRecording()
        } else {
            startLegacyRecording()
        }
    }

    func stop() {
        if #available(iOS 27.0, *) {
            stopModernRecording()
        } else {
            stopLegacyRecording()
        }
    }

    func clearError() { errorMessage = nil }
    func dismissLegacyPreview() { legacyPreviewController = nil }

    private func startLegacyRecording() {
        guard legacyRecorder.isAvailable else {
            isStarting = false
            errorMessage = "当前设备暂时无法使用系统录屏服务。"
            return
        }
        legacyRecorder.startRecording(withMicrophoneEnabled: false) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                if let error {
                    self.errorMessage = error.localizedDescription
                } else {
                    self.isRecording = true
                }
            }
        }
    }

    private func stopLegacyRecording() {
        guard legacyRecorder.isRecording else { return }
        isStarting = true
        legacyRecorder.stopRecording { [weak self] preview, error in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                self.isRecording = false
                if let error {
                    self.errorMessage = error.localizedDescription
                } else if let preview {
                    preview.previewControllerDelegate = self
                    self.legacyPreviewController = preview
                }
            }
        }
    }

    func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        legacyPreviewController = nil
    }

    @available(iOS 27.0, *)
    private func startModernRecording() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        // Limit the picker to this app; it cannot capture another app or the
        // iPhone Home Screen through this entry point.
        picker.presentForCurrentApplication()
    }

    @available(iOS 27.0, *)
    private func beginModernRecording(with filter: SCContentFilter) async {
        do {
            let bounds = UIScreen.main.bounds
            let scale = UIScreen.main.scale
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = max(Int(bounds.width * scale), 1)
            streamConfiguration.height = max(Int(bounds.height * scale), 1)
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            streamConfiguration.capturesAudio = false

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiniWatts-\(UUID().uuidString).mov")
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = url
            outputConfiguration.outputFileType = .mov
            outputConfiguration.videoCodecType = .hevc

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
            try stream.addRecordingOutput(output)
            modernStream = stream
            modernOutput = output
            activeRecordingURL = url
            try await stream.startCapture()
            isStarting = false
            isRecording = true
        } catch {
            isStarting = false
            isRecording = false
            modernStream = nil
            modernOutput = nil
            activeRecordingURL = nil
            SCContentSharingPicker.shared.remove(self)
            errorMessage = error.localizedDescription
        }
    }

    @available(iOS 27.0, *)
    private func stopModernRecording() {
        guard let stream = modernStream else {
            // While the system picker is open, pressing stop cancels this request.
            SCContentSharingPicker.shared.remove(self)
            isStarting = false
            return
        }
        isStarting = true
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                isStarting = false
                isRecording = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

@available(iOS 27.0, *)
extension MiniWattsScreenRecorder: SCContentSharingPickerObserver, SCRecordingOutputDelegate {
    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beginModernRecording(with: filter)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        isStarting = false
        picker.remove(self)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        isStarting = false
        errorMessage = error.localizedDescription
        SCContentSharingPicker.shared.remove(self)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        isStarting = false
        isRecording = true
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        isStarting = false
        isRecording = false
        errorMessage = error.localizedDescription
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        isStarting = false
        isRecording = false
        completedRecordingURL = activeRecordingURL
        activeRecordingURL = nil
        modernStream = nil
        modernOutput = nil
        SCContentSharingPicker.shared.remove(self)
    }
}

private struct AvailableRecordingEditor: ViewModifier {
    @Binding var url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.recordingEditor($url, mode: .preview)
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
private struct LegacyRecordingPreview: UIViewControllerRepresentable {
    let controller: RPPreviewViewController

    func makeUIViewController(context: Context) -> RPPreviewViewController { controller }
    func updateUIViewController(_ uiViewController: RPPreviewViewController, context: Context) {}
}

