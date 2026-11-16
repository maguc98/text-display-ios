import Foundation

/// The IOKit and HID clients belong to one actor, so a tick and a Shortcuts read
/// cannot use the process's single HID client at the same time. The synchronous
/// system calls and snapshot assembly run off the main actor.
actor SensorProbe {
    /// IOKit returns property-list dictionaries. They are bridged into Swift value
    /// dictionaries here and never mutated after crossing to the UI actor.
    /// TODO: replace the raw [String: Any] diagnostics fields with a typed,
    /// Sendable property-list value, then remove this unchecked conformance.
    struct Result: @unchecked Sendable {
        let snapshot: PowerSnapshot
        let sources: [[String: Any]]
        let serviceCount: Int
    }

    nonisolated let batteryAvailable: Bool
    nonisolated let hidAvailable: Bool
    nonisolated let initialServiceCount: Int
    nonisolated let smcConnectionDiagnostic: String

    private let battery: IOKitBattery?
    private let sensors: HIDSensors?

    init() {
        let battery = IOKitBattery()
        let sensors = HIDSensors()
        self.battery = battery
        self.sensors = sensors
        batteryAvailable = battery != nil
        hidAvailable = sensors != nil
        initialServiceCount = sensors?.serviceCount ?? 0
        smcConnectionDiagnostic = battery?.smcConnectionDiagnostic ?? "IOKit battery probe unavailable"
    }

    /// A charger changes the HID service list: the charge-IC endpoints may only
    /// appear after the cable is connected. Detect that transition, rescan, and
    /// immediately take a second snapshot so the first published plugged-in sample
    /// already includes the newly appeared sensors instead of waiting for the next
    /// one-second tick.
    ///
    /// Periodic rescans remain cheap and do not trigger a second full IOKit read.
    func read(lastExternalConnected: Bool?, periodicRescan: Bool) -> Result {
        let (initialSnapshot, initialSources) = probe()
        let connectionChanged = lastExternalConnected != initialSnapshot.externalConnected

        if connectionChanged {
            sensors?.rescan()
            let (snapshot, sources) = probe()
            return Result(snapshot: snapshot,
                          sources: sources,
                          serviceCount: sensors?.serviceCount ?? 0)
        }

        if periodicRescan {
            sensors?.rescan()
        }

        return Result(snapshot: initialSnapshot,
                      sources: initialSources,
                      serviceCount: sensors?.serviceCount ?? 0)
    }

    /// Shortcuts needs a fresh reading even while the foreground tick is paused.
    func readNow() -> PowerSnapshot {
        sensors?.rescan()
        return probe().snapshot
    }

    func fullInventory() -> [HIDSensors.ServiceInfo] {
        sensors?.fullInventory() ?? []
    }

    /// Manual diagnostic sweep using the existing HID client on this actor.
    func deepProbe() -> [HIDSensors.DeepProbeReading] {
        sensors?.deepProbe() ?? []
    }

    /// Timed power-rail capture for investigating cumulative HID values.
    func powerSeriesProbe() -> [HIDSensors.PowerSeriesPoint] {
        sensors?.powerSeriesProbe() ?? []
    }

    private func probe() -> (snapshot: PowerSnapshot, sources: [[String: Any]]) {
        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        let snapshot = PowerSnapshot(date: .now,
                                     registry: registry,
                                     powerSource: internalBattery,
                                     adapterDetails: battery?.readAdapterDetails(),
                                     sensors: sensors?.read() ?? [],
                                     chargeStatus: battery?.readChargeStatus())
        return (snapshot, sources)
    }
}
