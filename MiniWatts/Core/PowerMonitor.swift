import Foundation
import Observation

/// One point in the rolling live chart.
nonisolated struct LiveSample: Identifiable, Hashable {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
    /// Signed battery power inferred from the percentage trend; never a sensor reading.
    let estimatedBatteryWatts: Double?
    let hottestTemperature: Double?
    var id: Date { date }
}

/// Result of a ten-second foreground standby check. Estimated values are never
/// represented as hardware measurements.
nonisolated struct StandbyDetectionResult: Sendable {
    let averageCurrentAmps: Double?
    let averagePowerWatts: Double?
    let sampleCount: Int
    let isMeasured: Bool
    let note: String
}

/// Drives every probe on a one-second tick and merges the results into one
/// observable object the whole UI reads from.
@Observable
final class PowerMonitor {
    // MARK: Published state

    private(set) var snapshot = PowerSnapshot()
    private(set) var live: [LiveSample] = []
    private(set) var devices: [ExternalBatteryDevice] = []
    private(set) var sessions: [ChargeSession] = []
    private(set) var currentSession: ChargeSession?
    private(set) var sessionTotals = EnergyTotals()
    /// Watts estimated from how fast the percentage moves. The only way to see
    /// discharge power: no discharge-current sensor is exposed to a sandboxed app.
    private(set) var rateEstimateWatts: Double?
    /// Signed current inferred from the battery-level trend and pack energy.
    /// Positive means charging; negative means discharging. Never replaces a
    /// direct battery-current sensor reading.
    var rateEstimateCurrentAmps: Double? {
        // A previous slope is not a live estimate after its observation window
        // has been invalidated. Require the two measured transitions as well as
        // a current power estimate before deriving amps from the latest voltage.
        guard percentLog.count >= 3,
              let watts = rateEstimateWatts,
              let voltage = snapshot.batteryVoltage,
              voltage.isFinite, (2.5...5.0).contains(voltage) else { return nil }
        return watts / voltage
    }

    /// Evidence for why the percentage-trend estimate is or is not available.
    /// The first level sample is deliberately discarded: two subsequent transitions
    /// are needed to avoid treating an arbitrary mid-percent launch as a full interval.
    var rateEstimateDiagnosticLines: [String] {
        let samples = percentLog.count
        // The first level is deliberately discarded because the app may have
        // launched part-way through that percentage. Diagnostics must report the
        // same effective window that the estimator actually uses.
        let estimatePoints = Array(percentLog.dropFirst())
        let span = estimatePoints.count >= 2
            ? estimatePoints[estimatePoints.count - 1].date.timeIntervalSince(estimatePoints[0].date)
            : 0
        let levels = estimatePoints.map { String($0.percent) }.joined(separator: " → ")
        let status: String
        if snapshot.percent == nil {
            status = "waiting: system battery percentage unavailable"
        } else if samples < 3 {
            status = "waiting: need 3 distinct percentage samples; currently \(samples)"
        } else if span < Self.minimumRateEstimateSpan {
            status = "waiting: effective estimate window needs at least \(Int(Self.minimumRateEstimateSpan))s; currently \(Int(span))s"
        } else if rateEstimateWatts == nil {
            status = "not produced: inspect observation continuity and elapsed time"
        } else {
            status = "available: inferred from battery-level trend, not a direct sensor"
        }
        return [
            "rateEstimateStatus = \(status)",
            "rateEstimateWatts = \(rateEstimateWatts.map { String(format: "%.4f W", $0) } ?? "nil")",
            "rateEstimateCurrentAmps = \(rateEstimateCurrentAmps.map { String(format: "%.4f A", $0) } ?? "nil")",
            "rateEstimateSamples = \(samples) (3 required)",
            "rateEstimateLevels = \(levels.isEmpty ? "none" : levels)",
            "rateEstimateWindowSeconds = \(String(format: "%.1f", span))",
            "rateEstimatePackWattHours = \(String(format: "%.3f Wh", batteryWattHours))",
            "cellPowerEstimate = \(snapshot.batteryWatts != nil ? "direct sensor" : (snapshot.batteryEstimateLabel ?? "unavailable"))",
            "calibratedInputToCellRatio = \(calibratedInputToCellRatio.map { String(format: "%.3f", $0) } ?? "not calibrated")"
        ]
    }
    /// Time to 80 % and to full, from the same level changes, while charging. See
    /// `ChargeForecast`.
    private(set) var chargeForecast: ChargeForecast?
    /// The level's rise against the cell sensors over the same stretch, while
    /// charging. See `LevelRateCheck`.
    private(set) var levelRateCheck: LevelRateCheck?
    /// Resistance of the whole charging path — charger, cable, both plugs — inferred
    /// from how the port voltage sags as the current rises. Nil until the current
    /// has moved far enough for the fit to mean anything. See `PathResistanceMeter`.
    private(set) var pathResistance: PathResistanceEstimate?
    private(set) var diagnostics: [String] = []
    /// Every power source powerd reports, not just the internal battery.
    ///
    /// BatteryCenter is built on this same list — it has a `_BCPowerSourceController`
    /// and registers for power-source change notifications — so if accessories are
    /// reachable at all from a sandboxed app, they show up here.
    private(set) var powerSources: [[String: Any]] = []
    /// False until the session file has been read. Nothing is written before then:
    /// the load is asynchronous now, and a save that landed first would overwrite
    /// the whole history with an empty array.
    private(set) var isLoaded = false

    /// State for the dedicated ten-second standby measurement.
    private(set) var isStandbyDetectionRunning = false
    private(set) var standbyDetectionSecondsRemaining = 0
    private(set) var standbyDetectionResult: StandbyDetectionResult?
    private var recentInputToCellRatios: [Double] = []

    /// Whether to hold the screen awake while the phone is plugged in.
    ///
    /// The screen locking is what used to end a charge session two minutes in — the
    /// tick stops with the app, and a full charge could never be recorded. Applied
    /// by `RootView`, which is where UIKit belongs; `Core` stays UI-free.
    var keepScreenAwakeWhileCharging: Bool {
        didSet { UserDefaults.standard.set(keepScreenAwakeWhileCharging, forKey: Self.keepAwakeKey) }
    }

    /// Whether to show the charging live activity on the Lock Screen, in the Dynamic
    /// Island and in StandBy. Applied by `RootView`, like the setting above.
    var showsLiveActivityWhileCharging: Bool {
        didSet { UserDefaults.standard.set(showsLiveActivityWhileCharging, forKey: Self.liveActivityKey) }
    }

    /// The reading used by the compact Dynamic Island presentation. This changes
    /// presentation only; the activity remains charger-bound.
    var liveActivityMetric: LiveActivityMetric {
        didSet {
            UserDefaults.standard.set(liveActivityMetric.rawValue,
                                      forKey: Self.liveActivityMetricKey)
        }
    }

    /// Celsius, Fahrenheit, or whatever the system's region asks for (#25). Kept in
    /// the standard defaults like every other setting, and mirrored into the App
    /// Group's so the widget extension can follow it.
    var temperatureUnitSetting: TemperatureUnitSetting {
        didSet {
            UserDefaults.standard.set(temperatureUnitSetting.rawValue, forKey: TemperatureUnitSetting.storageKey)
            TemperatureUnitSetting.sharedDefaults?.set(temperatureUnitSetting.rawValue,
                                                       forKey: TemperatureUnitSetting.storageKey)
        }
    }

    /// The scale every temperature on screen is written in.
    var temperatureUnit: TemperatureDisplayUnit { temperatureUnitSetting.resolved }

    let thermal = ThermalMonitor()

    /// Called at the end of every tick. `RootView` installs it and fans the reading
    /// out to the live activity, the widget and the floating meter.
    ///
    /// A closure rather than SwiftUI's `onChange`, which is what this used to be:
    /// view updates stop when the app leaves the screen, and off screen is exactly
    /// when the floating meter is the only thing still showing a number.
    var onTick: ((PowerSnapshot) -> Void)?

    /// Usable pack energy, used to turn %/h into watts. Read from IOKit where the
    /// sandbox allows it, otherwise from the value the user sets in Settings.
    var batteryWattHours: Double {
        get {
            if let capacity = snapshot.designCapacity, capacity > 0 {
                return Double(capacity) * Self.nominalCellVoltage / 1000
            }
            return configuredBatteryWattHours
        }
    }

    var configuredBatteryWattHours: Double {
        didSet { UserDefaults.standard.set(configuredBatteryWattHours, forKey: Self.wattHoursKey) }
    }

    var sensorsAvailable: Bool { sensorServiceCount > 0 }
    var deviceModelIdentifier: String {
        #if targetEnvironment(simulator)
        return "\(PowerSnapshot.modelIdentifier) (simulator)"
        #else
        return PowerSnapshot.modelIdentifier
        #endif
    }

    /// A rated pack energy for the models one has been found for, with where it came
    /// from. It only sets the default: a value entered in Settings always wins.
    struct ModelRating: Sendable {
        let wattHours: Double
        let source: String
    }

    /// Kept short on purpose. Every entry is a figure someone checked, and a wrong
    /// default is worse than the generic one — the user sees a number, not a guess.
    ///
    /// - iPhone 18 Pro Max (iPhone19,7 from issue #16's dump; iPhone19,3 per
    ///   ChargeSpeed): 5,567 mAh in iFixit's teardown, 21.75 Wh.
    /// - iPhone 17 Pro Max (iPhone18,2): 5,088 mAh × 3.87 V, 19.7 Wh, ChargeSpeed's
    ///   figure, which its author notes was not checked against a source. That is the
    ///   eSIM-only pack; models with a SIM tray are listed smaller.
    static let modelRating: ModelRating? = {
        switch PowerSnapshot.modelIdentifier {
        case "iPhone19,3", "iPhone19,7":
            return ModelRating(wattHours: 21.75, source: "iFixit teardown, 5,567 mAh")
        case "iPhone18,2":
            return ModelRating(wattHours: 19.7, source: "5,088 mAh × 3.87 V")
        case "iPhone13,1":
            return ModelRating(wattHours: 8.57, source: "iFixit teardown, 2,227 mAh")
        default:
            return nil
        }
    }()

    /// What the pack energy starts at before anything is set in Settings.
    static var defaultBatteryWattHours: Double { modelRating?.wattHours ?? 15.0 }

    // MARK: Private

    private static let nominalCellVoltage = 3.87
    private static let wattHoursKey = "batteryWattHours"
    private static let keepAwakeKey = "keepScreenAwakeWhileCharging"
    private static let liveActivityKey = "showsLiveActivityWhileCharging"
    private static let liveActivityMetricKey = "liveActivityMetric"
    private static let liveWindow = 180
    private static let holdDebounceInterval: TimeInterval = 30
    private static let maximumRateObservationGap: TimeInterval = 120
    /// Ignore short percentage windows: a one-point quantization step can dominate
    /// the slope when only a minute or two of data is available.
    private static let minimumRateEstimateSpan: TimeInterval = 120
    /// Longest step between two ticks that still counts as watching continuously.
    /// The same ten seconds the energy integrator allows.
    private static let rateContinuityInterval: TimeInterval = 10

    private let probeService = SensorProbe()
    private let batteryCenter = BatteryCenterBridge()
    private let energy = EnergyAccumulator()
    private let resistance = PathResistanceMeter()
    private let store = SessionStore()

    private var task: Task<Void, Never>?
    private var tick = 0
    private var lastSampleWrite: Date = .distantPast
    private var lastPersist: Date = .distantPast
    private var lastExternalConnected: Bool?
    /// The last moment the phone was actually observed plugged in. A session is
    /// closed at this point rather than at `.now`, so a charge that ended while the
    /// app was suspended is not recorded as having run until the app came back.
    private var lastConnectedObservation: Date?
    /// Last foreground observation used to accumulate thermal-pressure time. Long
    /// gaps are excluded for the same reason the energy integrator excludes them:
    /// the app cannot know what happened while it was suspended.
    private var lastThermalObservationDate: Date?
    /// Set by `deleteAllSessions`. The load is asynchronous, so a delete that lands
    /// while it is still in flight would otherwise have the file's contents merged
    /// back in on top of it a moment later.
    private var discardedStoredSessions = false
    /// Each moment the level changed, with the running cell-sensor energy at that
    /// moment, so the level's rise and the sensors can be compared over one stretch.
    private var percentLog: [(date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval)] = []
    /// Running integral of the cell sensors' watts, and how many seconds of it were
    /// actually observed. Only differences between two log entries are ever used.
    private var cellWattHours: Double = 0
    private var cellSeconds: TimeInterval = 0
    private var lastCellSample: (date: Date, watts: Double)?
    private var lastChargingFlag: Bool?
    /// Learns the net cell/input ratio from the battery-level slope after enough
    /// distinct level changes have accumulated. The initial estimate is deliberately
    /// conservative and is always labelled as an estimate.
    private var calibratedInputToCellRatio: Double?
    private var lastCalibrationPercent: Int?
    private var lastRateObservationDate: Date?
    private var stableHoldState: ChargeHoldState?
    private var holdCandidate: ChargeHoldState?
    private var holdCandidateSince: Date?
    private var sensorServiceCount: Int = 0
    /// Why the session history came up empty, when the file was there and could not
    /// be read. Kept apart from `diagnostics` because that list is rebuilt whenever
    /// the sensor count changes — on the first plug event, an appended line was gone.
    private var storeWarning: String?

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.wattHoursKey)
        configuredBatteryWattHours = stored > 0 ? stored : Self.defaultBatteryWattHours
        // Defaults to on: recording a whole charge is the point of the History tab,
        // and it cannot happen if the screen locks after thirty seconds.
        keepScreenAwakeWhileCharging = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        showsLiveActivityWhileCharging = defaults.object(forKey: Self.liveActivityKey) as? Bool ?? true
        liveActivityMetric = defaults.string(forKey: Self.liveActivityMetricKey)
            .flatMap(LiveActivityMetric.init(rawValue:)) ?? .chargingPower
        temperatureUnitSetting = defaults.string(forKey: TemperatureUnitSetting.storageKey)
            .flatMap(TemperatureUnitSetting.init(rawValue:)) ?? .automatic
        sensorServiceCount = probeService.initialServiceCount
        collectDiagnostics()
        Task { await loadStoredSessions() }
    }

    /// Reads the session file off the main thread and merges it in.
    private func loadStoredSessions() async {
        let stored = await store.loaded()
        if let warning = await store.readWarning() {
            storeWarning = warning
            collectDiagnostics()
        }
        guard !discardedStoredSessions else {
            isLoaded = true
            return
        }
        let restored = stored.map { session in
            // A session left open by a crash or a force quit is closed at its
            // last recorded point rather than being resumed.
            guard session.end == nil else { return session }
            var closed = session
            closed.end = session.start.addingTimeInterval(session.samples.last?.offset ?? 0)
            return closed
        }
        .filter(Self.isWorthKeeping)
        // A charge may have started and finished while the file was being read, so
        // merge rather than assign, keeping whatever this run has already recorded.
        let known = Set(sessions.map(\.id))
        sessions = (sessions + restored.filter { !known.contains($0.id) })
            .sorted { $0.start > $1.start }
        isLoaded = true
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops the tick but leaves any open session open.
    ///
    /// This is what backgrounding does now. It used to close the session, which made
    /// the History tab close to useless: `scenePhase` leaves `.active` for a pulled-down
    /// Control Center, an incoming call, the app switcher and the screen locking, so an
    /// overnight charge was recorded as a scatter of two-minute fragments instead of one
    /// session. The integrator already discards gaps longer than ten seconds, so a
    /// resumed session reports honest totals and `integratedSeconds` records how much of
    /// the wall clock was actually watched.
    func pause() {
        task?.cancel()
        task = nil
        persist()
    }

    // MARK: Refresh

    private func refresh() async {
        tick += 1
        thermal.update()

        let result = await probeService.read(lastExternalConnected: lastExternalConnected,
                                             periodicRescan: tick % 15 == 0)
        guard !Task.isCancelled else { return }
        var current = stabilizedHoldSnapshot(result.snapshot)
        // Only Raw data reads this. It used to be assigned under `#if DEBUG`, when that
        // screen was Debug-only; now that the page ships, the guard made its "powerd
        // power sources" panel report none in every release build — a false statement
        // on the one page whose job is to show what the probes actually returned. The
        // write costs nothing while that page is closed: `@Observable` invalidates only
        // views that read the property, and no other view does.
        powerSources = result.sources
        if sensorServiceCount != result.serviceCount {
            sensorServiceCount = result.serviceCount
            collectDiagnostics()
        }
        if tick % 5 == 1 {
            devices = batteryCenter.read()
        }

        updateRateEstimate(current)
        applyCellPowerEstimate(to: &current)
        snapshot = current
        appendLive(current)
        resistance.add(current)
        pathResistance = resistance.estimate
        updateSession(current)
        lastExternalConnected = current.externalConnected
        onTick?(current)
    }

    /// One fresh reading for the Shortcuts action, with none of the tick's side effects.
    ///
    /// `refresh()` cannot be reused for this. It opens and samples charge sessions and
    /// persists them, feeds the resistance fit, drives the live activity and the widget
    /// through `onTick`, and republishes `snapshot`. Shortcuts wakes the app in the
    /// background — possibly every few minutes, for an automation — and each of those
    /// would leave a one-sample session in History. This reads and returns.
    ///
    /// The HID service list is re-enumerated first. The tick does that on plug events,
    /// but the tick is paused whenever the app is in the background, which is exactly
    /// when Shortcuts runs it: a charger plugged in since the last tick would have no
    /// sensors in the list, and charging power would come back as no reading while the
    /// phone was plainly charging. Enumerating is cheap; a stale list is not.
    func readNow() async -> PowerSnapshot {
        await probeService.readNow()
    }

    /// Samples the battery-side current for ten seconds while the app remains
    /// foregrounded. A true device lock suspends this app on iOS, so the UI uses
    /// a black, minimum-brightness foreground surface instead.
    func runStandbyDetection() async {
        guard !isStandbyDetectionRunning else { return }
        isStandbyDetectionRunning = true
        standbyDetectionResult = nil
        standbyDetectionSecondsRemaining = 10
        defer {
            isStandbyDetectionRunning = false
            standbyDetectionSecondsRemaining = 0
        }

        var currentReadings: [Double] = []
        var powerReadings: [Double] = []
        var usedEstimate = false

        for index in 0..<10 {
            guard !Task.isCancelled else { return }
            let sample = await probeService.readNow()
            if let current = sample.batteryCurrent, current.isFinite, abs(current) <= 20 {
                currentReadings.append(current)
                if let voltage = sample.batteryVoltage, voltage.isFinite, (2.5...5.0).contains(voltage) {
                    powerReadings.append(current * voltage)
                }
            } else if let watts = sample.batteryWatts, watts.isFinite,
                      let voltage = sample.batteryVoltage, voltage.isFinite, (2.5...5.0).contains(voltage) {
                currentReadings.append(watts / voltage)
                powerReadings.append(watts)
            } else if sample.externalConnected, sample.isCharging,
                      let input = sample.inputWatts, input.isFinite, input > 0.1,
                      let voltage = sample.batteryVoltage, voltage.isFinite, (2.5...5.0).contains(voltage) {
                // Port power is reduced by a learned net ratio. The fallback is
                // deliberately labelled and never confused with a cell sensor.
                let ratio = calibratedInputToCellRatio ?? 0.75
                let estimatedWatts = input * ratio
                currentReadings.append(estimatedWatts / voltage)
                powerReadings.append(estimatedWatts)
                usedEstimate = true
            }
            standbyDetectionSecondsRemaining = 9 - index
            if index < 9 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }

        guard !currentReadings.isEmpty else {
            standbyDetectionResult = StandbyDetectionResult(
                averageCurrentAmps: nil, averagePowerWatts: nil,
                sampleCount: 0, isMeasured: false,
                note: "10 秒内没有取得可用的电池电流或电池侧功率读数；没有用充电器电流冒充电池电流。")
            return
        }

        // A trimmed mean suppresses one-off HID spikes without throwing away
        // the useful trend in a short ten-second window.
        let current = Self.trimmedMean(currentReadings)
        let power = powerReadings.isEmpty ? nil : Self.trimmedMean(powerReadings)
        let measured = !usedEstimate
        standbyDetectionResult = StandbyDetectionResult(
            averageCurrentAmps: current,
            averagePowerWatts: power,
            sampleCount: currentReadings.count,
            isMeasured: measured,
            note: measured
                ? "来自电池侧传感器的 10 秒稳健平均值。"
                : "估算值：使用输入功率、校准效率和电池电压推算；不是电芯电流实测。")
    }

    private static func trimmedMean(_ values: [Double]) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let trimmed = sorted.count >= 5 ? Array(sorted.dropFirst().dropLast()) : sorted
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    private func appendLive(_ snapshot: PowerSnapshot) {
        let sample = LiveSample(date: snapshot.date,
                                inputWatts: snapshot.inputWatts,
                                batteryWatts: snapshot.batteryWatts,
                                estimatedBatteryWatts: snapshot.estimatedBatteryWatts,
                                hottestTemperature: snapshot.hottestSensor?.value)
        live.append(sample)
        if live.count > Self.liveWindow {
            live.removeFirst(live.count - Self.liveWindow)
        }
    }

    // MARK: Sessions

    private func updateSession(_ snapshot: PowerSnapshot) {
        if snapshot.externalConnected {
            lastConnectedObservation = snapshot.date
            if currentSession == nil {
                openSession(snapshot)
            }
            energy.add(snapshot)
            sessionTotals = energy.totals
            recordSample(snapshot)
        } else {
            closeSessionIfNeeded()
        }

        if currentSession != nil, snapshot.date.timeIntervalSince(lastPersist) >= 30 {
            persist()
        }
    }

    private func openSession(_ snapshot: PowerSnapshot) {
        calibratedInputToCellRatio = nil
        recentInputToCellRatios.removeAll(keepingCapacity: true)
        lastCalibrationPercent = nil
        energy.reset()
        sessionTotals = energy.totals
        currentSession = ChargeSession(start: snapshot.date,
                                       startPercent: snapshot.percent ?? 0,
                                       adapterName: snapshot.adapterName,
                                       adapterRatedWatts: snapshot.adapterRatedWatts,
                                       isWireless: snapshot.isWirelessInput)
        lastSampleWrite = .distantPast
        lastThermalObservationDate = snapshot.date
    }

    private func recordSample(_ snapshot: PowerSnapshot) {
        guard var session = currentSession else { return }

        session.endPercent = snapshot.percent ?? session.endPercent
        session.totals = energy.totals
        session.peakInputWatts = max(session.peakInputWatts, snapshot.inputWatts ?? 0)
        session.peakBatteryWatts = max(session.peakBatteryWatts, snapshot.batteryWatts ?? 0)
        if let temperature = snapshot.batteryTemperature {
            session.peakBatteryTemperature = max(session.peakBatteryTemperature ?? temperature, temperature)
        }
        // The adapter identifies itself a beat after the plug event, so the name
        // is filled in whenever it first becomes available.
        if session.adapterName == nil { session.adapterName = snapshot.adapterName }
        if session.adapterRatedWatts == nil { session.adapterRatedWatts = snapshot.adapterRatedWatts }
        if let previous = lastThermalObservationDate {
            let interval = snapshot.date.timeIntervalSince(previous)
            if interval > 0, interval <= 10, thermal.state.isThrottling {
                session.throttledSeconds += interval
            }
        }
        lastThermalObservationDate = snapshot.date
        // Carried on every tick rather than at close: the fit is what History uses to
        // compare one cable with another, and a session that ends while the app is
        // suspended is closed from `lastConnectedObservation` without another reading.
        session.recordPathFit(resistance.estimate)

        if snapshot.date.timeIntervalSince(lastSampleWrite) >= SessionStore.sampleInterval {
            lastSampleWrite = snapshot.date
            session.samples.append(ChargeSample(offset: snapshot.date.timeIntervalSince(session.start),
                                                inputWatts: snapshot.inputWatts,
                                                batteryWatts: snapshot.batteryWatts,
                                                estimatedBatteryWatts: snapshot.estimatedBatteryWatts,
                                                percent: snapshot.percent ?? session.endPercent,
                                                batteryTemperature: snapshot.batteryTemperature,
                                                hottestTemperature: snapshot.hottestSensor?.value,
                                                throttled: thermal.state.isThrottling))
            // A very long charge is thinned in place: every other point goes, which
            // halves the resolution without losing the shape of the curve.
            if session.samples.count > SessionStore.sampleLimit {
                session.samples = session.samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            }
        }
        currentSession = session
    }

    private func closeSessionIfNeeded() {
        guard var session = currentSession else { return }
        // The end is the last moment the charger was actually seen, not now. Unplug
        // the phone while the app is suspended and the next tick after it wakes is
        // the first that knows — dating the end from that tick would stretch every
        // such session across however long the app was away.
        session.end = max(lastConnectedObservation ?? snapshot.date, session.start)
        lastConnectedObservation = nil
        session.totals = energy.totals
        currentSession = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        lastThermalObservationDate = nil
        if Self.isWorthKeeping(session) {
            sessions.insert(session, at: 0)
        }
        // Persist either way: the periodic save wrote this session while it was
        // open, so the file has to be rewritten even when it is being discarded.
        persist()
    }

    /// A stretch of being plugged in that moved no energy is a cable reseat, or a
    /// phone sitting at 100 %, not a charge worth keeping.
    private static func isWorthKeeping(_ session: ChargeSession) -> Bool {
        session.totals.inputWattHours > 0.001 || session.gainedPercent > 0
    }

    private func persist() {
        guard isLoaded else { return }
        lastPersist = .now
        store.save(sessions + (currentSession.map { [$0] } ?? []))
    }

    func deleteSession(_ session: ChargeSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    /// Every recorded session on the same adapter that produced a path-resistance
    /// fit, including this one, lowest resistance first.
    ///
    /// This is the comparison the number is actually for. A path resistance on its
    /// own is hard to judge — it carries the charger's regulation and both sets of
    /// contacts as well as the cable — but the same charger measured through two
    /// cables differs only by the cable and the plugs, so the difference between two
    /// rows here is the thing a user can act on.
    ///
    /// Matched on the adapter's own name, which is hardware and is compared verbatim.
    /// Wireless sessions are excluded: there is no cable in them to compare.
    func pathFitsSharingAdapter(with session: ChargeSession) -> [ChargeSession] {
        // This session has to be in the comparison for the comparison to be about it.
        // Without a fit of its own it would be a list of other sessions under a
        // heading that claims to say something about this one.
        guard let adapter = session.adapterName, !session.isWireless,
              session.pathMilliohms != nil else { return [] }
        let matching = sessions.filter {
            $0.adapterName == adapter && !$0.isWireless && $0.pathMilliohms != nil
        }
        // One row is not a comparison; it is the same number again.
        guard matching.count > 1 else { return [] }
        return matching.sorted { ($0.pathMilliohms ?? 0) < ($1.pathMilliohms ?? 0) }
    }

    func deleteAllSessions() {
        discardedStoredSessions = true
        sessions.removeAll()
        currentSession = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        lastThermalObservationDate = nil
        store.deleteAll()
    }

    // MARK: Charge hold state

    /// Apply a short hysteresis window to the inferred hold state. A single HID
    /// sample can lose the battery-current rail while the phone is still charging;
    /// requiring the opposite state to persist avoids flickering between “hold” and
    /// “not charging”. Explicit unplug/charge/full transitions clear immediately.
    ///
    /// The first reading of a run is taken as it stands; only a change from it has
    /// to persist. Making the first one settle as well put thirty seconds of “hold
    /// status unknown” on every cold launch during a real hold — which, with an 80 %
    /// charge limit, is most launches — and `.unknown` is reserved for a missing
    /// current sensor, which that was not: the sensor was answering, with zero.
    private func stabilizedHoldSnapshot(_ snapshot: PowerSnapshot) -> PowerSnapshot {
        let observed = snapshot.measuredHoldState

        if stableHoldState == nil {
            stableHoldState = observed
            holdCandidate = nil
            holdCandidateSince = nil
        } else if !snapshot.externalConnected || snapshot.isCharging || snapshot.fullyCharged {
            stableHoldState = .notHeld
            holdCandidate = nil
            holdCandidateSince = nil
        } else if observed == .unknown {
            // Preserve the last known state while the current sensor is absent.
            holdCandidate = nil
            holdCandidateSince = nil
        } else if observed == stableHoldState {
            holdCandidate = nil
            holdCandidateSince = nil
        } else if holdCandidate != observed {
            holdCandidate = observed
            holdCandidateSince = snapshot.date
        } else if let since = holdCandidateSince,
                  snapshot.date.timeIntervalSince(since) >= Self.holdDebounceInterval {
            stableHoldState = observed
            holdCandidate = nil
            holdCandidateSince = nil
        }

        var adjusted = snapshot
        adjusted.setHoldStateOverride(stableHoldState ?? observed)
        return adjusted
    }

    // MARK: Rate estimate

    /// Tracks 1 % transitions and converts the slope into watts. Two transitions
    /// are needed because the first sample lands mid-percent.
    private func updateRateEstimate(_ snapshot: PowerSnapshot) {
        integrateCellEnergy(snapshot)
        guard let percent = snapshot.percent else {
            rateEstimateWatts = nil
            levelRateCheck = nil
            chargeForecast = nil
            lastRateObservationDate = nil
            return
        }

        // What a hole in the observations costs depends on what happened in it, so
        // the log is not thrown away on every `pause()`: two transitions take
        // minutes to arrive, and someone who only ever glances at the app would
        // never see an estimate at all.
        if let previousDate = lastRateObservationDate {
            let gap = snapshot.date.timeIntervalSince(previousDate)
            if gap > Self.maximumRateObservationGap || gap < 0 {
                // The app was suspended or the source clock moved. A slope across
                // that hole would look like a near-zero discharge rate.
                percentLog.removeAll()
                rateEstimateWatts = nil
                levelRateCheck = nil
                chargeForecast = nil
            } else if gap > Self.rateContinuityInterval, percentLog.last?.percent != percent {
                // A short hole, and the level moved somewhere inside it. When is
                // not known — only that it was before now — and stamping it now
                // would shorten the next step and overstate the rate. Start again
                // from this level: a log's first entry is never used as a time.
                // The previous slope no longer describes this new observation
                // window, so clear it rather than pairing stale watts with a new
                // battery voltage in the current estimate.
                percentLog.removeAll()
                rateEstimateWatts = nil
            }
            // A short hole the level sat still through has lost nothing: the log
            // only holds the moments the level changed.
        }
        lastRateObservationDate = snapshot.date

        if lastChargingFlag != snapshot.isCharging {
            lastChargingFlag = snapshot.isCharging
            percentLog.removeAll()
            rateEstimateWatts = nil
            levelRateCheck = nil
            chargeForecast = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snapshot.date, percent, cellWattHours, cellSeconds))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = Array(percentLog.dropFirst())
        guard transitions.count >= 2,
              let first = transitions.first,
              let last = transitions.last else {
            rateEstimateWatts = nil
            chargeForecast = nil
            return
        }

        // Require a useful observation window. With integer percentage readings,
        // a short interval can turn one quantization step into an implausible power.
        let span = last.date.timeIntervalSince(first.date)
        guard span >= Self.minimumRateEstimateSpan,
              span.isFinite, span > 0,
              batteryWattHours.isFinite, batteryWattHours > 0 else {
            rateEstimateWatts = nil
            chargeForecast = nil
            return
        }

        // Fit a least-squares slope across every retained transition instead of
        // dividing only the first and last points. This uses the whole rolling
        // window and reduces sensitivity to a single delayed percentage update.
        let points = transitions.map {
            (seconds: $0.date.timeIntervalSince(first.date), percent: Double($0.percent))
        }
        let meanSeconds = points.reduce(0.0) { $0 + $1.seconds } / Double(points.count)
        let meanPercent = points.reduce(0.0) { $0 + $1.percent } / Double(points.count)
        let covariance = points.reduce(0.0) {
            $0 + ($1.seconds - meanSeconds) * ($1.percent - meanPercent)
        }
        let variance = points.reduce(0.0) {
            $0 + ($1.seconds - meanSeconds) * ($1.seconds - meanSeconds)
        }
        guard variance > 0 else {
            rateEstimateWatts = nil
            chargeForecast = nil
            return
        }

        let percentagePointsPerHour = covariance / variance * 3600
        let estimate = percentagePointsPerHour / 100 * batteryWattHours
        guard estimate.isFinite else {
            rateEstimateWatts = nil
            chargeForecast = nil
            return
        }

        rateEstimateWatts = estimate
        chargeForecast = snapshot.isCharging
            ? ChargeForecast(levelChanges: transitions.map { ($0.date, $0.percent) })
            : nil
        updateLevelRateCheck(levelWatts: estimate, from: first, to: last, charging: snapshot.isCharging)
    }

    /// Produces a continuous, explicitly estimated cell reading when the direct
    /// battery-current rail is unavailable. Port power is never presented as cell
    /// power: a conservative initial 75% net ratio accounts for conversion loss and
    /// phone load together. Once the percentage trend has two usable transitions,
    /// its pack-energy slope calibrates that ratio for this charging session.
    private func applyCellPowerEstimate(to snapshot: inout PowerSnapshot) {
        // A working battery rail is the strongest calibration reference. Smooth
        // its measured cell/input ratio so a later temporary sensor dropout can
        // fall back to a device/session-specific estimate.
        if snapshot.isCharging,
           let measuredCell = snapshot.batteryWatts, measuredCell > 0,
           let input = snapshot.inputWatts, input > 0.5 {
            updateInputToCellRatio(measuredCell / input)
        } else if let percent = snapshot.percent, percent != lastCalibrationPercent {
            lastCalibrationPercent = percent
            if snapshot.isCharging,
               let trend = rateEstimateWatts, trend > 0,
               let input = snapshot.inputWatts, input > 0.5 {
                updateInputToCellRatio(trend / input)
            }
        }

        guard snapshot.batteryWatts == nil else { return }

        let watts: Double?
        let label: String?
        if snapshot.externalConnected, snapshot.isCharging,
           let input = snapshot.inputWatts, input > 0.1 {
            if let trend = rateEstimateWatts, trend > 0 {
                watts = min(trend, input)
                label = "Battery-level calibrated estimate"
            } else {
                let ratio = calibratedInputToCellRatio ?? 0.75
                watts = input * ratio
                label = calibratedInputToCellRatio == nil
                    ? "Initial input estimate (75% net efficiency)"
                    : "Input estimate using calibrated ratio"
            }
        } else if !snapshot.externalConnected, let trend = rateEstimateWatts {
            watts = trend
            label = "Battery-level trend estimate"
        } else {
            watts = nil
            label = nil
        }

        snapshot.estimatedBatteryWatts = watts
        snapshot.batteryEstimateLabel = label
        if snapshot.batteryCurrent == nil,
           let watts,
           let voltage = snapshot.batteryVoltage,
           voltage.isFinite, (2.5...5.0).contains(voltage) {
            snapshot.estimatedBatteryCurrent = watts / voltage
        }
    }

    private func updateInputToCellRatio(_ candidate: Double) {
        // Keep a short robust history: a single percentage transition or sensor
        // spike must not swing the session calibration. Median rejects outliers;
        // a slower EMA then avoids visible jumps between successive updates.
        guard candidate.isFinite, (0.15...0.98).contains(candidate) else { return }
        recentInputToCellRatios.append(candidate)
        if recentInputToCellRatios.count > 7 { recentInputToCellRatios.removeFirst() }
        let ordered = recentInputToCellRatios.sorted()
        let median = ordered[ordered.count / 2]
        calibratedInputToCellRatio = calibratedInputToCellRatio.map {
            $0 * 0.8 + median * 0.2
        } ?? median
    }

    /// Adds this tick's cell-sensor watts to the running integral, trapezoid by
    /// trapezoid. Only intervals that were watched continuously and read at both
    /// ends count; `cellSeconds` records how much that was, so a stretch the sensors
    /// were missing from is visible as missing rather than read as zero.
    private func integrateCellEnergy(_ snapshot: PowerSnapshot) {
        guard snapshot.isCharging, let watts = snapshot.batteryWatts else {
            lastCellSample = nil
            return
        }
        if let previous = lastCellSample {
            let step = snapshot.date.timeIntervalSince(previous.date)
            if step > 0, step <= Self.rateContinuityInterval {
                cellWattHours += (previous.watts + watts) / 2 * step / 3600
                cellSeconds += step
            }
        }
        lastCellSample = (snapshot.date, watts)
    }

    /// Sets the level against the cell sensors over the stretch the %-rate estimate
    /// was just taken from. Leaves the last result up when this stretch cannot say
    /// anything — too short, too little rise, or too much of it unwatched.
    private func updateLevelRateCheck(levelWatts: Double,
                                      from first: (date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval),
                                      to last: (date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval),
                                      charging: Bool) {
        guard charging else {
            levelRateCheck = nil
            return
        }
        let span = last.date.timeIntervalSince(first.date)
        let rise = last.percent - first.percent
        let watched = last.cellSeconds - first.cellSeconds
        let energy = last.cellWattHours - first.cellWattHours
        guard rise >= LevelRateCheck.minimumRise, span >= LevelRateCheck.minimumSpan,
              watched >= span * 0.9, energy > 0 else { return }
        let cellWatts = energy / (watched / 3600)
        guard cellWatts >= LevelRateCheck.minimumCellWatts, levelWatts > 0 else { return }
        levelRateCheck = LevelRateCheck(levelWatts: levelWatts,
                                        cellWatts: cellWatts,
                                        packWattHours: batteryWattHours,
                                        percentRise: rise,
                                        span: span)
    }

    // MARK: Headline

    /// The number on the dial and the caption under it.
    ///
    /// This lives here rather than in `PowerSnapshot` because the last fallback —
    /// the %-rate estimate — is the monitor's, not the snapshot's: it is derived
    /// from how the percentage moved across several snapshots. `PowerSnapshot` used
    /// to carry a `primaryWatts` that answered a simpler version of the same
    /// question, which nothing called, while `DashboardView` open-coded this. One
    /// answer, in the layer that can actually give it.
    var headline: (watts: Double, caption: LocalizedStringResource)? {
        if snapshot.externalConnected {
            if let watts = snapshot.inputWatts {
                // Written out rather than as a ternary in the tuple. `LocalizedStringResource`
                // literals want to be at their own return site so both transport labels
                // reach the catalog.
                if snapshot.isWirelessInput { return (watts, "at charging coil") }
                return (watts, "at phone port")
            }
            // Wireless charging has no input-current sensor — the PMU exposes the
            // coil voltage and nothing to multiply it by — so rather than reading
            // "no reading" while the phone is visibly charging, the dial drops to
            // the battery side and says so. A measured zero is still a reading: a
            // phone sitting at 100 % on a charger is genuinely taking nothing.
            if let watts = snapshot.displayBatteryWatts { return (max(watts, 0), "into battery") }
            return nil
        }
        if let watts = snapshot.displayBatteryWatts, watts != 0 {
            return (abs(watts), snapshot.batteryWattsAreEstimated ? "estimated from battery" : "drawn from battery")
        }
        if let watts = rateEstimateWatts { return (abs(watts), "from battery (%-rate estimate)") }
        return nil
    }

    // MARK: Diagnostics

    private func collectDiagnostics() {
        var lines: [String] = []
        lines.append("IOKit: \(probeService.batteryAvailable ? "loaded" : "unavailable")")
        lines.append("HID sensors: \(probeService.hidAvailable ? "\(sensorServiceCount) services" : "unavailable")")
        lines.append("BatteryCenter: \(batteryCenter.status) via \(batteryCenter.controllerOrigin)")
        lines.append("Device: \(deviceModelIdentifier)")
        lines.append("SMC IOServiceOpen probe: \(probeService.smcConnectionDiagnostic)")
        #if targetEnvironment(simulator)
        lines.append("Simulator: IOKit reads the Mac's battery, HID sensors are absent.")
        #endif
        if let storeWarning { lines.append(storeWarning) }
        diagnostics = lines
    }

    /// Why the accessory list is empty, in the app's voice, for the Devices screen.
    var batteryCenterStatus: LocalizedStringResource? { batteryCenter.status.userMessage }

    /// The same thing with the failing step named, for Raw data.
    var batteryCenterDiagnostic: LocalizedStringResource? { batteryCenter.status.diagnostic }

    /// Every HID service in the system, for the debug view.
    func hidInventory() async -> [HIDSensors.ServiceInfo] {
        await probeService.fullInventory()
    }

    /// Runs the manual HID event sweep without changing the regular sampling path.
    func hidDeepProbe() async -> [HIDSensors.DeepProbeReading] {
        await probeService.deepProbe()
    }

    /// Captures 10 seconds of selected power rails at 0.5-second intervals.
    /// This does not alter the live sampling or any displayed power calculation.
    func hidPowerSeriesProbe() async -> [HIDSensors.PowerSeriesPoint] {
        await probeService.powerSeriesProbe()
    }

    /// What the accessory-manager registry family will admit to, for the debug view.
    /// Built on demand rather than held: it is a one-shot scan behind a button, and
    /// nothing outside Raw data reads it. See `AccessoryProbe` for what it asks and why.
    func accessoryProbe() -> AccessoryProbe.Report? {
        AccessoryProbe()?.run()
    }

    /// Walks the visible IOService registry tree on demand. This is a read-only
    /// diagnostic and does not alter the live sensor or power-calculation path.
    func registryTreeProbe() -> RegistryTreeProbe.Report? {
        RegistryTreeProbe()?.run()
    }
}
