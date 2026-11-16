import Foundation

/// A clearly separated, presentation-only battery model. It never writes to
/// PowerSnapshot or feeds the real sensor/energy/session pipeline.
enum VirtualBatteryControlMode: String, CaseIterable, Codable, Identifiable {
    case free
    case linked

    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "自由控制"
        case .linked: return "智能联动"
        }
    }
}

struct VirtualBatteryState: Codable {
    var isEnabled = false
    var mode: VirtualBatteryControlMode = .linked
    var percent = 80
    var voltage = 3.92
    /// Positive means charging; negative means discharging.
    var currentAmps = -0.85
    /// Used only in free mode. Positive is the magnitude shown in the dashboard.
    var powerWatts = 3.33

    var displayedPowerWatts: Double {
        mode == .linked ? abs(voltage * currentAmps) : max(0, powerWatts)
    }

    var directionLabel: String {
        if abs(currentAmps) < 0.01 { return "待机" }
        return currentAmps > 0 ? "充电中" : "放电中"
    }

    mutating func clamp() {
        percent = min(max(percent, 0), 100)
        voltage = min(max(voltage, 2.5), 5.0)
        currentAmps = min(max(currentAmps, -8.0), 8.0)
        powerWatts = min(max(powerWatts, 0), 40)
    }
}
