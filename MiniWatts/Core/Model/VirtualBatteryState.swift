import Foundation

/// The source of the latest battery-level calibration.
enum BatteryLevelCalibrationSource: String, Codable, Sendable {
    case manual
    case system

    var title: String {
        switch self {
        case .manual: return "手动调整"
        case .system: return "系统电量"
        }
    }

    /// Keep installations that imported a recording in the previous build readable
    /// even though the recording feature and its source case have been removed.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = BatteryLevelCalibrationSource(rawValue: rawValue)
            ?? (rawValue == "screenRecording" ? .manual : .system)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One observed level transition used to infer the battery's energy rate.
/// It is deliberately only a percentage and timestamp; voltage/current/power
/// are always measured or derived by PowerMonitor, never entered by the user.
struct VirtualBatteryObservation: Codable, Hashable, Sendable, Identifiable {
    let date: Date
    let percent: Int

    var id: Date { date }
}

/// A calibration overlay for the displayed state of charge. Electrical values
/// remain owned by PowerSnapshot and PowerMonitor's sensor/estimation pipeline.
struct VirtualBatteryState: Codable {
    var isEnabled = false
    var percent = 80
    /// Calibrated level = current system level + this persistent user offset.
    var systemPercentOffset = 0
    /// Set only when decoding a pre-offset saved calibration; resolved on the first live system sample.
    var needsSystemOffsetMigration = false
    var observations: [VirtualBatteryObservation] = []
    var lastCalibrationSource: BatteryLevelCalibrationSource = .system

    private enum CodingKeys: String, CodingKey {
        case isEnabled, percent, systemPercentOffset, observations, lastCalibrationSource
        // Legacy keys from the former editable simulation are intentionally ignored.
        case mode, voltage, currentAmps, powerWatts
    }

    init() {}

    /// Keep existing installations working: older builds stored mode, voltage,
    /// current and power alongside isEnabled/percent. Those legacy fields are
    /// ignored and are never restored as electrical overrides.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        percent = try container.decodeIfPresent(Int.self, forKey: .percent) ?? 80
        systemPercentOffset = try container.decodeIfPresent(Int.self, forKey: .systemPercentOffset) ?? 0
        needsSystemOffsetMigration = !container.contains(.systemPercentOffset)
        observations = try container.decodeIfPresent([VirtualBatteryObservation].self,
                                                       forKey: .observations) ?? []
        lastCalibrationSource = try container.decodeIfPresent(BatteryLevelCalibrationSource.self,
                                                                forKey: .lastCalibrationSource) ?? .system
        clamp()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(percent, forKey: .percent)
        try container.encode(systemPercentOffset, forKey: .systemPercentOffset)
        try container.encode(observations, forKey: .observations)
        try container.encode(lastCalibrationSource, forKey: .lastCalibrationSource)
    }

    mutating func clamp() {
        percent = min(max(percent, 0), 100)
        systemPercentOffset = min(max(systemPercentOffset, -100), 100)
        observations = observations
            .map { VirtualBatteryObservation(date: $0.date, percent: min(max($0.percent, 0), 100)) }
            .sorted { $0.date < $1.date }
        if observations.count > 120 {
            observations.removeFirst(observations.count - 120)
        }
    }
}
