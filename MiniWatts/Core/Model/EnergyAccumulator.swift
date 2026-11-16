import Foundation

/// Charge-session totals. Hardware readings and estimates are accumulated into
/// separate buckets; paired totals only compare adapter and cell energy over the
/// same watched intervals.
nonisolated struct EnergyTotals: Codable, Hashable {
    /// Adapter-side input energy, ∫ V·I dt.
    var inputWattHours: Double = 0
    /// Cell energy integrated from the direct battery power rail.
    var batteryWattHours: Double = 0
    /// Cell charge integrated from the direct battery current rail.
    var batteryMilliAmpHours: Double = 0
    /// Cell energy estimated from the charging input when its direct rail is absent.
    var estimatedBatteryWattHours: Double = 0
    /// Cell charge estimated from cell watts ÷ cell voltage.
    var estimatedBatteryMilliAmpHours: Double = 0
    var estimatedBatteryMeasuredSeconds: TimeInterval = 0
    var estimatedBatteryCurrentSeconds: TimeInterval = 0

    /// Time coverage for each independent channel.
    var integratedSeconds: TimeInterval = 0
    var inputMeasuredSeconds: TimeInterval = 0
    var batteryMeasuredSeconds: TimeInterval = 0
    var batteryCurrentMeasuredSeconds: TimeInterval = 0

    /// Input/cell energy accumulated only where both rails were available at both
    /// ends of the interval. Estimated cell energy has its own paired bucket.
    var pairedInputWattHours: Double = 0
    var pairedBatteryWattHours: Double = 0
    var pairedEstimatedBatteryWattHours: Double = 0
    var pairedEstimatedBatterySeconds: TimeInterval = 0

    private enum CodingKeys: String, CodingKey {
        case inputWattHours, batteryWattHours, batteryMilliAmpHours
        case estimatedBatteryWattHours, estimatedBatteryMilliAmpHours
        case estimatedBatteryMeasuredSeconds, estimatedBatteryCurrentSeconds
        case integratedSeconds, inputMeasuredSeconds, batteryMeasuredSeconds
        case batteryCurrentMeasuredSeconds, pairedInputWattHours
        case pairedBatteryWattHours, pairedEstimatedBatteryWattHours
        case pairedEstimatedBatterySeconds
    }

    init() {}

    /// All added fields decode as zero in older session files.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputWattHours = try values.decodeIfPresent(Double.self, forKey: .inputWattHours) ?? 0
        batteryWattHours = try values.decodeIfPresent(Double.self, forKey: .batteryWattHours) ?? 0
        batteryMilliAmpHours = try values.decodeIfPresent(Double.self, forKey: .batteryMilliAmpHours) ?? 0
        estimatedBatteryWattHours = try values.decodeIfPresent(Double.self, forKey: .estimatedBatteryWattHours) ?? 0
        estimatedBatteryMilliAmpHours = try values.decodeIfPresent(Double.self, forKey: .estimatedBatteryMilliAmpHours) ?? 0
        estimatedBatteryMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .estimatedBatteryMeasuredSeconds) ?? 0
        estimatedBatteryCurrentSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .estimatedBatteryCurrentSeconds) ?? 0
        integratedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .integratedSeconds) ?? 0
        inputMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .inputMeasuredSeconds)
            ?? (inputWattHours > 0.001 ? integratedSeconds : 0)
        batteryMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .batteryMeasuredSeconds)
            ?? (batteryWattHours > 0 ? integratedSeconds : 0)
        batteryCurrentMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .batteryCurrentMeasuredSeconds)
            ?? (batteryMilliAmpHours > 0 ? integratedSeconds : 0)
        let hadBothMeasured = inputWattHours > 0.001 && batteryWattHours > 0
        pairedInputWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedInputWattHours)
            ?? (hadBothMeasured ? inputWattHours : 0)
        pairedBatteryWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedBatteryWattHours)
            ?? (hadBothMeasured ? batteryWattHours : 0)
        pairedEstimatedBatteryWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedEstimatedBatteryWattHours) ?? 0
        pairedEstimatedBatterySeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .pairedEstimatedBatterySeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inputWattHours, forKey: .inputWattHours)
        try values.encode(batteryWattHours, forKey: .batteryWattHours)
        try values.encode(batteryMilliAmpHours, forKey: .batteryMilliAmpHours)
        try values.encode(estimatedBatteryWattHours, forKey: .estimatedBatteryWattHours)
        try values.encode(estimatedBatteryMilliAmpHours, forKey: .estimatedBatteryMilliAmpHours)
        try values.encode(estimatedBatteryMeasuredSeconds, forKey: .estimatedBatteryMeasuredSeconds)
        try values.encode(estimatedBatteryCurrentSeconds, forKey: .estimatedBatteryCurrentSeconds)
        try values.encode(integratedSeconds, forKey: .integratedSeconds)
        try values.encode(inputMeasuredSeconds, forKey: .inputMeasuredSeconds)
        try values.encode(batteryMeasuredSeconds, forKey: .batteryMeasuredSeconds)
        try values.encode(batteryCurrentMeasuredSeconds, forKey: .batteryCurrentMeasuredSeconds)
        try values.encode(pairedInputWattHours, forKey: .pairedInputWattHours)
        try values.encode(pairedBatteryWattHours, forKey: .pairedBatteryWattHours)
        try values.encode(pairedEstimatedBatteryWattHours, forKey: .pairedEstimatedBatteryWattHours)
        try values.encode(pairedEstimatedBatterySeconds, forKey: .pairedEstimatedBatterySeconds)
    }

    /// Nil when there were no watched intervals. Zero is retained when the sensor
    /// was genuinely watched and measured zero.
    var displayedBatteryWattHours: Double? {
        guard batteryMeasuredSeconds + estimatedBatteryMeasuredSeconds > 0 else { return nil }
        return batteryWattHours + estimatedBatteryWattHours
    }

    var displayedBatteryMilliAmpHours: Double? {
        guard batteryCurrentMeasuredSeconds + estimatedBatteryCurrentSeconds > 0 else { return nil }
        return batteryMilliAmpHours + estimatedBatteryMilliAmpHours
    }

    var includesEstimatedBatteryEnergy: Bool { estimatedBatteryMeasuredSeconds > 0 }
    var includesEstimatedBatteryCurrent: Bool { estimatedBatteryCurrentSeconds > 0 }
    var includesEstimatedCellShare: Bool { pairedEstimatedBatterySeconds > 0 }

    var measuredInputWattHours: Double? {
        inputMeasuredSeconds > 0 && inputWattHours > 0.001 ? inputWattHours : nil
    }

    /// Cell share uses paired intervals only, including a separately marked
    /// estimated cell bucket. It never divides energy totals from different spans.
    var chargePathEfficiencyPercent: Double? {
        let pairedCell = pairedBatteryWattHours + pairedEstimatedBatteryWattHours
        guard pairedInputWattHours > 0.001, pairedCell > 0 else { return nil }
        return min(pairedCell / pairedInputWattHours, 1) * 100
    }

    var unaccountedWattHours: Double? {
        guard pairedInputWattHours > 0.001 else { return nil }
        return max(pairedInputWattHours - pairedBatteryWattHours - pairedEstimatedBatteryWattHours, 0)
    }

    var averageInputWatts: Double? {
        guard inputMeasuredSeconds > 0 else { return nil }
        return inputWattHours * 3600 / inputMeasuredSeconds
    }
}

/// Trapezoidal integration of observed charge samples. The selected cell power
/// and current retain a per-interval measured/estimated flag so a zero-valued
/// unavailable rail cannot suppress a positive estimate.
nonisolated final class EnergyAccumulator {
    private struct Sample {
        let date: Date
        let inputWatts: Double?
        let cellWatts: Double?
        let cellWattsEstimated: Bool
        let cellAmps: Double?
        let cellAmpsEstimated: Bool
    }

    private static let maximumInterval: TimeInterval = 10
    private(set) var totals = EnergyTotals()
    private var previous: Sample?

    func reset() {
        totals = EnergyTotals()
        previous = nil
    }

    func add(_ snapshot: PowerSnapshot) {
        let measuredWatts = snapshot.batteryWatts
        let estimatedWatts = snapshot.estimatedBatteryWatts
        let useEstimatedWatts = snapshot.isCharging
            && (measuredWatts == nil || abs(measuredWatts ?? 0) <= 0.02)
            && (estimatedWatts ?? 0) > 0.02
        let cellWatts = useEstimatedWatts
            ? estimatedWatts
            : (measuredWatts ?? estimatedWatts)
        let cellWattsEstimated = useEstimatedWatts
            || (measuredWatts == nil && estimatedWatts != nil)

        let measuredAmps = snapshot.batteryCurrent
        let shouldDeriveAmps = measuredAmps == nil
            || (snapshot.isCharging && abs(measuredAmps ?? 0) <= 0.02 && (cellWatts ?? 0) > 0.02)
        let derivedAmps: Double? = {
            if let current = snapshot.estimatedBatteryCurrent, current.isFinite {
                return current
            }
            guard let watts = cellWatts,
                  let voltage = snapshot.batteryVoltage,
                  voltage.isFinite, (2.5...5.0).contains(voltage) else { return nil }
            return watts / voltage
        }()
        let cellAmps: Double?
        let cellAmpsEstimated: Bool
        if shouldDeriveAmps, snapshot.isCharging, let derivedAmps {
            cellAmps = max(derivedAmps, 0)
            cellAmpsEstimated = true
        } else if let measuredAmps {
            cellAmps = max(measuredAmps, 0)
            cellAmpsEstimated = false
        } else {
            cellAmps = nil
            cellAmpsEstimated = false
        }

        let sample = Sample(date: snapshot.date,
                            inputWatts: snapshot.inputWatts,
                            cellWatts: cellWatts.map { max($0, 0) },
                            cellWattsEstimated: cellWattsEstimated,
                            cellAmps: cellAmps,
                            cellAmpsEstimated: cellAmpsEstimated)
        defer { previous = sample }
        guard let previous else { return }

        let interval = sample.date.timeIntervalSince(previous.date)
        guard interval > 0, interval <= Self.maximumInterval else { return }
        let hours = interval / 3600

        if let oldInput = previous.inputWatts, let newInput = sample.inputWatts {
            totals.inputWattHours += (oldInput + newInput) / 2 * hours
            totals.inputMeasuredSeconds += interval
        }

        if let oldCell = previous.cellWatts, let newCell = sample.cellWatts {
            let energy = (oldCell + newCell) / 2 * hours
            if previous.cellWattsEstimated || sample.cellWattsEstimated {
                totals.estimatedBatteryWattHours += energy
                totals.estimatedBatteryMeasuredSeconds += interval
            } else {
                totals.batteryWattHours += energy
                totals.batteryMeasuredSeconds += interval
            }
        }

        if let oldAmps = previous.cellAmps, let newAmps = sample.cellAmps {
            let charge = (oldAmps + newAmps) / 2 * hours * 1000
            if previous.cellAmpsEstimated || sample.cellAmpsEstimated {
                totals.estimatedBatteryMilliAmpHours += charge
                totals.estimatedBatteryCurrentSeconds += interval
            } else {
                totals.batteryMilliAmpHours += charge
                totals.batteryCurrentMeasuredSeconds += interval
            }
        }

        // Pair adapter and cell energy over precisely the same interval. An
        // interval containing an estimated endpoint stays labelled as estimated.
        if let oldInput = previous.inputWatts, let newInput = sample.inputWatts,
           let oldCell = previous.cellWatts, let newCell = sample.cellWatts {
            totals.pairedInputWattHours += (oldInput + newInput) / 2 * hours
            let cellEnergy = (oldCell + newCell) / 2 * hours
            if previous.cellWattsEstimated || sample.cellWattsEstimated {
                totals.pairedEstimatedBatteryWattHours += cellEnergy
                totals.pairedEstimatedBatterySeconds += interval
            } else {
                totals.pairedBatteryWattHours += cellEnergy
            }
        }

        totals.integratedSeconds += interval
    }
}
