import Foundation

/// Energy totals for one stretch of charging, integrated from the live sensors.
///
/// The sandbox never hands out the pack's design capacity, but it does hand out
/// voltage and current at ~1 Hz on both sides of the charge IC. Integrating those
/// gives the two numbers that actually matter — how much energy the adapter
/// delivered, and how much of it reached the cell.
nonisolated struct EnergyTotals: Codable, Hashable {
    /// ∫ V·I dt at the adapter, in watt-hours.
    var inputWattHours: Double = 0
    /// ∫ V·I dt at the battery rail, in watt-hours.
    var batteryWattHours: Double = 0
    /// ∫ I dt at the battery rail, in milliamp-hours. Comparable to a pack's mAh rating.
    var batteryMilliAmpHours: Double = 0
    /// Seconds of integration, which is not the same as wall-clock time: gaps
    /// longer than the sample window are dropped rather than extrapolated.
    var integratedSeconds: TimeInterval = 0
    /// Seconds for which both ends of the input-power interval were measured.
    /// This is separate from `integratedSeconds` because wireless charging can
    /// expose the battery side while the adapter-side current is unavailable.
    var inputMeasuredSeconds: TimeInterval = 0
    /// Seconds for which both ends of the battery-power interval were measured.
    var batteryMeasuredSeconds: TimeInterval = 0
    /// Seconds for which both ends of the battery-current interval were measured.
    var batteryCurrentMeasuredSeconds: TimeInterval = 0
    /// The adapter's energy over the intervals in which the battery rail was
    /// measured as well, and the battery's over those same intervals. A ratio of
    /// the two full totals compares stretches of different length whenever one
    /// rail drops out — up to a quarter too generous at the 80 % overlap that was
    /// once allowed — so efficiency and the remainder are taken from this pair.
    var pairedInputWattHours: Double = 0
    var pairedBatteryWattHours: Double = 0

    private enum CodingKeys: String, CodingKey {
        case inputWattHours
        case batteryWattHours
        case batteryMilliAmpHours
        case integratedSeconds
        case inputMeasuredSeconds
        case batteryMeasuredSeconds
        case batteryCurrentMeasuredSeconds
        case pairedInputWattHours
        case pairedBatteryWattHours
    }

    init() {}

    /// Older session files predate per-channel coverage. Decode them with the
    /// old aggregate duration as a conservative compatibility fallback.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputWattHours = try values.decodeIfPresent(Double.self, forKey: .inputWattHours) ?? 0
        batteryWattHours = try values.decodeIfPresent(Double.self, forKey: .batteryWattHours) ?? 0
        batteryMilliAmpHours = try values.decodeIfPresent(Double.self, forKey: .batteryMilliAmpHours) ?? 0
        integratedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .integratedSeconds) ?? 0
        inputMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .inputMeasuredSeconds)
            ?? (inputWattHours > 0.001 ? integratedSeconds : 0)
        batteryMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .batteryMeasuredSeconds)
            ?? (batteryWattHours > 0 ? integratedSeconds : 0)
        batteryCurrentMeasuredSeconds = try values.decodeIfPresent(TimeInterval.self,
                                                                    forKey: .batteryCurrentMeasuredSeconds)
            ?? (batteryMilliAmpHours > 0 ? integratedSeconds : 0)
        // Before the pair existed both rails were integrated over every interval,
        // a missing reading counting as zero, so the totals were the pair.
        let hadBoth = inputWattHours > 0.001 && batteryWattHours > 0
        pairedInputWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedInputWattHours)
            ?? (hadBoth ? inputWattHours : 0)
        pairedBatteryWattHours = try values.decodeIfPresent(Double.self, forKey: .pairedBatteryWattHours)
            ?? (hadBoth ? batteryWattHours : 0)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inputWattHours, forKey: .inputWattHours)
        try values.encode(batteryWattHours, forKey: .batteryWattHours)
        try values.encode(batteryMilliAmpHours, forKey: .batteryMilliAmpHours)
        try values.encode(integratedSeconds, forKey: .integratedSeconds)
        try values.encode(inputMeasuredSeconds, forKey: .inputMeasuredSeconds)
        try values.encode(batteryMeasuredSeconds, forKey: .batteryMeasuredSeconds)
        try values.encode(batteryCurrentMeasuredSeconds, forKey: .batteryCurrentMeasuredSeconds)
        try values.encode(pairedInputWattHours, forKey: .pairedInputWattHours)
        try values.encode(pairedBatteryWattHours, forKey: .pairedBatteryWattHours)
    }

    /// Delivered energy, or nil when none could be measured.
    ///
    /// Wireless charging exposes no input-current sensor, so this stays at zero
    /// for a whole MagSafe session while the battery side accumulates normally.
    /// Nil says "not measured" where a bare 0.00 Wh would read as "nothing came in".
    var measuredInputWattHours: Double? {
        inputWattHours > 0.001 ? inputWattHours : nil
    }

    /// Share of measured adapter energy that reached the cell, 0…100.
    /// This is charge-path efficiency, not a round-trip battery efficiency.
    var chargePathEfficiencyPercent: Double? {
        guard pairedInputWattHours > 0.001, pairedBatteryWattHours > 0 else { return nil }
        return min(pairedBatteryWattHours / pairedInputWattHours, 1) * 100
    }

    /// Adapter energy not observed at the battery rail. It includes phone load,
    /// cable/coil loss and charge-IC conversion loss, so it must not be labelled
    /// as pure heat. Nil when the two rails were never measured together. Taken
    /// from the paired totals, so where one rail dropped out for part of a
    /// session it is not quite Delivered minus Stored.
    var unaccountedWattHours: Double? {
        guard pairedInputWattHours > 0.001 else { return nil }
        return max(pairedInputWattHours - pairedBatteryWattHours, 0)
    }

    var averageInputWatts: Double? {
        guard inputMeasuredSeconds > 0 else { return nil }
        return inputWattHours * 3600 / inputMeasuredSeconds
    }
}

/// Trapezoidal integration of the live power readings.
///
/// Samples arrive about once a second while the app is in the foreground and stop
/// entirely when it is backgrounded. Rather than extrapolate across those gaps,
/// any interval longer than `maximumInterval` is discarded — the totals then read
/// as "energy measured while watching", which is honest, and `integratedSeconds`
/// records how much of the wall clock that covered.
nonisolated final class EnergyAccumulator {
    private struct Sample {
        let date: Date
        let inputWatts: Double?
        let batteryWatts: Double?
        let batteryAmps: Double?
    }

    /// Longest gap that still counts as continuous measurement.
    private static let maximumInterval: TimeInterval = 10

    private(set) var totals = EnergyTotals()
    private var previous: Sample?

    func reset() {
        totals = EnergyTotals()
        previous = nil
    }

    func add(_ snapshot: PowerSnapshot) {
        let sample = Sample(date: snapshot.date,
                            inputWatts: snapshot.inputWatts,
                            batteryWatts: snapshot.batteryWatts.map { max($0, 0) },
                            batteryAmps: snapshot.batteryCurrent.map { max($0, 0) })
        defer { previous = sample }
        guard let previous else { return }

        let interval = sample.date.timeIntervalSince(previous.date)
        guard interval > 0, interval <= Self.maximumInterval else { return }

        let hours = interval / 3600
        if let previousInput = previous.inputWatts, let input = sample.inputWatts {
            totals.inputWattHours += (previousInput + input) / 2 * hours
            totals.inputMeasuredSeconds += interval
        }
        if let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts {
            totals.batteryWattHours += (previousBattery + battery) / 2 * hours
            totals.batteryMeasuredSeconds += interval
        }
        if let previousAmps = previous.batteryAmps, let amps = sample.batteryAmps {
            totals.batteryMilliAmpHours += (previousAmps + amps) / 2 * hours * 1000
            totals.batteryCurrentMeasuredSeconds += interval
        }
        if let previousInput = previous.inputWatts, let input = sample.inputWatts,
           let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts {
            totals.pairedInputWattHours += (previousInput + input) / 2 * hours
            totals.pairedBatteryWattHours += (previousBattery + battery) / 2 * hours
        }
        // Every watched interval, whichever rails answered in it. History sets
        // this against the session's length to say how much of the charge the app
        // was in front for; what each rail covered is in the fields above.
        totals.integratedSeconds += interval
    }
}
