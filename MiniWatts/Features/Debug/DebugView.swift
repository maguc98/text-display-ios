import SwiftUI
import UIKit

/// Everything the probes returned, unedited. This is the page that made the rest
/// of the app possible: sensor names differ between iPhone models, so the way to
/// support a new one is to read the inventory here and extend `SensorCatalog`.
struct DebugView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var inventory: [HIDSensors.ServiceInfo] = []
    @State private var deepProbe: [HIDSensors.DeepProbeReading] = []
    @State private var powerSeries: [HIDSensors.PowerSeriesPoint] = []
    @State private var powerSeriesLoading = false
    @State private var accessory: AccessoryProbe.Report?
    @State private var copied = false
    @State private var query = ""

    /// Case-insensitive substring match against a row's name and its value. The
    /// lists here run to seventy-odd sensors and dictionaries of fifty keys, which
    /// is not something to read top to bottom looking for one rail.
    private func matches(_ parts: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return parts.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Backdrop(glow: .mwMuted, glowIntensity: 0.5)
            ScrollView {
                VStack(spacing: 14) {
                    diagnosticsPanel
                    sensorsPanel
                    temperatureWarningsPanel
                    inventoryPanel
                    deepProbePanel
                    powerSeriesPanel
                    accessoryPanel
                    dictionaryPanel("IOPMPowerSource", systemImage: "cpu", dictionary: monitor.snapshot.registry)
                    dictionaryPanel("powerd power source", systemImage: "battery.100", dictionary: monitor.snapshot.powerSource)
                    dictionaryPanel("Adapter details", systemImage: "powerplug", dictionary: monitor.snapshot.adapterDetails)
                    dictionaryPanel("Charge status", systemImage: "pause.circle", dictionary: monitor.snapshot.chargeStatus)
                    powerSourcesPanel
                    batteryCenterPanel
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // Pinned to the container's width so nothing inside can widen the
                // scroll content. A paragraph inside an HStack reports an enormous
                // ideal width — the text unwrapped onto one line — and
                // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                // that width propagates up and the page starts scrolling sideways.
                // The cap is part of the pin: see `PageScaffold`.
                .containerRelativeFrame(.horizontal) { width, _ in min(width, 760) }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Raw data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Filter sensors and keys"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = fullDump()
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .tint(.mwAccent)
            }
        }
    }

    private var diagnosticsPanel: some View {
        Panel("Probes", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(monitor.diagnostics, id: \.self) { line in
                    Text(line).mwMono(size: 11).foregroundStyle(Color.mwMuted)
                }
            }
        }
    }

    private var sensorsPanel: some View {
        Panel("Live sensors", systemImage: "sensor",
              trailing: Text(verbatim: "\(monitor.snapshot.sensors.count)")) {
            if monitor.snapshot.sensors.isEmpty {
                EmptyNote(text: "No sensors returned a finite value.")
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.snapshot.sensors
                        .filter { matches($0.name, $0.key, $0.formatted) }
                        .sorted { $0.name < $1.name }) { reading in
                        DetailRow(rawLabel: reading.key.isEmpty
                                      ? "[\(reading.index)] \(reading.name)"
                                      : "[\(reading.index)] \(reading.name) (\(reading.key))",
                                  value: reading.formatted)
                    }
                }
            }
        }
    }

    private var temperatureWarningsPanel: some View {
        Panel("Derived temperature filters", systemImage: "thermometer.variable.and.figure") {
            if monitor.snapshot.temperatureWarnings.isEmpty {
                EmptyNote(text: "No temperature readings were excluded from derived values.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(monitor.snapshot.temperatureWarnings, id: \.self) { warning in
                        Text(verbatim: warning)
                            .mwMono(size: 11)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var inventoryPanel: some View {
        Panel("HID service inventory", systemImage: "list.number",
              trailing: inventory.isEmpty ? nil : Text(verbatim: "\(inventory.count)")) {
            VStack(alignment: .leading, spacing: 10) {
                if inventory.isEmpty {
                    Button {
                        Task { inventory = await monitor.hidInventory() }
                    } label: {
                        Label("Enumerate every HID service", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "Lists every service the HID event system exposes, matched or not, with its usage page and usage. This is how the power and temperature sensors were found in the first place.")
                } else {
                    ForEach(inventory.filter { matches($0.name, $0.key, String(format: "0x%04x", $0.usagePage)) }) { service in
                        HStack {
                            Text(service.key.isEmpty ? service.name : "\(service.name) · \(service.key)")
                                .mwMono(size: 11)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(String(format: "0x%04x / %d", service.usagePage, service.usage))
                                .mwMono(size: 10)
                                .foregroundStyle(Color.mwMuted)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var deepProbePanel: some View {
        Panel("HID deep probe", systemImage: "waveform.path.ecg",
              trailing: deepProbe.isEmpty ? nil : Text(verbatim: "\(deepProbe.count) checks")) {
            VStack(alignment: .leading, spacing: 10) {
                if deepProbe.isEmpty {
                    Button {
                        Task { deepProbe = await monitor.hidDeepProbe() }
                    } label: {
                        Label("Probe existing HID services", systemImage: "waveform.path.ecg")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "One-shot, read-only test of all enumerated services with the app's existing temperature and power event types. It reuses the single HID client. A finite value is not automatically a battery reading.")
                } else {
                    let finite = deepProbe.filter { $0.value != nil }
                    let visible = deepProbe.filter {
                        matches($0.name, $0.key, String(format: "0x%04x", $0.usagePage), String($0.usage), String($0.eventType))
                    }
                    Text(verbatim: "\(finite.count) finite results · \(deepProbe.count - finite.count) unavailable/non-finite")
                        .mwCaption()
                    if visible.isEmpty {
                        EmptyNote(text: "No HID probe rows match this filter.")
                    } else {
                        // Failed reads matter too: "service absent", "no event" and
                        // "non-finite" have different implications for IQ0B.
                        ForEach(visible) { reading in
                            let powerType = reading.powerType.map { " · powerType=\($0) (0=power, 1=current, 2=voltage)" } ?? ""
                            let powerSubType = reading.powerSubType.map { " · powerSubType=\($0)" } ?? ""
                            DetailRow(rawLabel: "[\(reading.serviceIndex)] \(reading.name) · 0x\(String(format: "%04x", reading.usagePage))/\(reading.usage) · event \(reading.eventType)\(powerType)\(powerSubType)",
                                      value: reading.value.map { String(format: "%.8f", $0) } ?? reading.status)
                        }
                    }
                }
            }
        }
    }

    private var powerSeriesPanel: some View {
        Panel("Power rail time series", systemImage: "waveform.path",
              trailing: powerSeries.isEmpty ? nil : Text(verbatim: "\(powerSeries.count) samples")) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    powerSeriesLoading = true
                    Task {
                        powerSeries = await monitor.hidPowerSeriesProbe()
                        powerSeriesLoading = false
                    }
                } label: {
                    Label(powerSeriesLoading ? "Sampling power rails…" : "Capture 10-second power series",
                          systemImage: "waveform.path")
                        .font(.system(size: 13, weight: .medium))
                }
                .disabled(powerSeriesLoading)
                .tint(.mwAccent)

                EmptyNote(text: "Samples QQ0u, WQ0u, IQ0u, IQ0B and voltage rails every 0.5 seconds. Diagnostic only: cumulative subtype values are not converted into amps or watts until their units and reset behaviour are verified.")

                if !powerSeries.isEmpty {
                    let grouped = Dictionary(grouping: powerSeries, by: { $0.serviceIndex })
                    ForEach(grouped.keys.sorted(), id: \.self) { serviceIndex in
                        if let samples = grouped[serviceIndex]?.sorted(by: { $0.sampleIndex < $1.sampleIndex }),
                           let first = samples.first, let last = samples.last {
                            let resets = zip(samples, samples.dropFirst()).filter { $1.value < $0.value }.count
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "\(first.key) · \(first.name) · service \(serviceIndex)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(verbatim: String(format: "n=%d · %.3f → %.3f · Δ %.3f · resets %d",
                                                      samples.count, first.value, last.value,
                                                      last.value - first.value, resets))
                                    .mwMono(size: 11)
                                    .foregroundStyle(Color.mwMuted)
                                Text(verbatim: samples.map { String(format: "%.3f", $0.value) }.joined(separator: "  "))
                                    .mwMono(size: 10)
                                    .foregroundStyle(Color.mwMuted)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    /// The accessory-manager scan. This is the panel that decides whether MiniWatts
    /// can ever say anything about the charger's own identity or the cable, so the
    /// rows that came back empty are shown as well as the ones that answered: a key
    /// that is absent everywhere is the finding.
    private var accessoryPanel: some View {
        Panel("Accessory manager", systemImage: "cable.connector",
              trailing: accessory.map { Text(verbatim: $0.headline) }) {
            VStack(alignment: .leading, spacing: 10) {
                if let accessory {
                    Text(verbatim: accessory.library).mwMono(size: 11).foregroundStyle(Color.mwMuted)
                    ForEach(accessory.classes) { reading in
                        accessoryClass(reading)
                    }
                } else {
                    Button {
                        accessory = monitor.accessoryProbe()
                    } label: {
                        Label("Probe the accessory registry", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "Reads the IOAccessoryManager registry family — the charger's connect type, current limit, manufacturer, model and serial — plus the USB-PD nodes macOS publishes for the cable. Registry reads only: nothing is opened and nothing is written.")
                }
            }
        }
    }

    @ViewBuilder
    private func accessoryClass(_ reading: AccessoryProbe.ClassReading) -> some View {
        let status = reading.matchError ?? (reading.services.isEmpty ? "no service" : "\(reading.services.count)")
        if matches(reading.className, status) || reading.services.contains(where: { service in
            service.readableKeys.contains { matches($0.key, $0.value ?? "") }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: reading.className).mwMono(size: 11).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: status).mwMono(size: 10).foregroundStyle(Color.mwMuted)
                }
                .padding(.vertical, 2)
                ForEach(reading.services) { service in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "\(service.className) · \(service.name)")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                            .padding(.leading, 10)
                        // The targeted reads first: these are the keys the question
                        // is actually about. Then whatever the bulk fetch returned
                        // that they did not already cover.
                        ForEach(service.readableKeys.filter { matches($0.key, $0.value ?? "") }) { key in
                            DetailRow(rawLabel: key.key, value: key.value)
                        }
                        let extra = service.bulk.keys.sorted()
                            .filter { key in !service.readableKeys.contains { $0.key == key } }
                            .filter { matches($0, service.bulk[$0] ?? "") }
                        ForEach(extra, id: \.self) { key in
                            DetailRow(rawLabel: key, value: service.bulk[key])
                        }
                        if let bulkError = service.bulkError {
                            DetailRow(rawLabel: "bulk fetch", value: bulkError)
                        }
                        if service.readableKeys.isEmpty, service.bulk.isEmpty {
                            EmptyNote(text: "Matched, but every key came back empty.")
                        }
                    }
                }
            }
        }
    }

    private func dictionaryPanel(_ title: LocalizedStringResource, systemImage: String, dictionary: [String: Any]?) -> some View {
        Panel(title, systemImage: systemImage, trailing: dictionary.map { Text("\($0.count) keys") }) {
            if let dictionary, !dictionary.isEmpty {
                VStack(spacing: 0) {
                    ForEach(dictionary.keys.sorted()
                        .filter { matches($0, String(describing: dictionary[$0] ?? "")) }, id: \.self) { key in
                        DetailRow(rawLabel: key, value: String(describing: dictionary[key] ?? ""))
                    }
                }
            } else {
                EmptyNote(text: "Empty. On a device the sandbox filters most of this away; on the simulator it is the Mac's data.")
            }
        }
    }

    /// Every power source powerd will admit to, which is where an accessory would
    /// have to appear for any of this to be reachable without private entitlements.
    private var powerSourcesPanel: some View {
        Panel("powerd power sources", systemImage: "list.bullet.rectangle",
              trailing: Text(verbatim: "\(monitor.powerSources.count)")) {
            if monitor.powerSources.isEmpty {
                EmptyNote(text: "powerd reported no power sources.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(monitor.powerSources.enumerated()), id: \.offset) { index, source in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: (source["Name"] as? String)
                                 ?? (source["Type"] as? String)
                                 ?? "source \(index)").mwCaption()
                            ForEach(source.keys.sorted()
                                .filter { matches($0, String(describing: source[$0] ?? "")) }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: String(describing: source[key] ?? ""))
                            }
                        }
                    }
                }
            }
        }
    }

    private var batteryCenterPanel: some View {
        Panel("BatteryCenter", systemImage: "square.stack.3d.up",
              trailing: Text("\(monitor.devices.count) devices")) {
            if monitor.devices.isEmpty {
                EmptyNote(text: monitor.batteryCenterDiagnostic ?? "No devices reported.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.devices) { device in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).mwCaption()
                            ForEach(device.raw.keys.sorted()
                                .filter { matches($0, device.raw[$0] ?? "") }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: device.raw[key])
                            }
                        }
                    }
                }
            }
        }
    }

    private func fullDump() -> String {
        let snapshot = monitor.snapshot
        var lines: [String] = [
            "MiniWatts \(SettingsView.versionText) battery diagnostics — \(Formatting.timestamp(.now))",
            "model = \(PowerSnapshot.modelIdentifier)",
            "externalConnected = \(snapshot.externalConnected)",
            "isCharging = \(snapshot.isCharging)"
        ]

        func amps(_ value: Double?) -> String {
            value.map { String(format: "%.6f A", $0) } ?? "nil"
        }
        func volts(_ value: Double?) -> String {
            value.map { String(format: "%.6f V", $0) } ?? "nil"
        }
        func rawNumber(_ key: String, in dictionary: [String: Any]?) {
            guard let value = dictionary?[key] else {
                lines.append("\(key) raw = unavailable")
                return
            }
            lines.append("\(key) runtimeType = \(String(reflecting: type(of: value)))")
            if let number = value as? NSNumber {
                lines.append("\(key) objCType = \(String(cString: number.objCType))")
                lines.append("\(key) doubleValue = \(String(format: "%.8f", number.doubleValue))")
                lines.append("\(key) stringValue = \(number.stringValue)")
            } else {
                lines.append("\(key) rawValue = \(String(describing: value))")
            }
        }

        lines.append("\n# Battery cell current")
        lines.append("batteryRailCurrent (HID IQ0B) = \(amps(snapshot.batteryRailCurrent))")
        lines.append("registryCurrent (IOKit InstantAmperage) = \(amps(snapshot.registryCurrent))")
        lines.append("powerdCurrent (IOPSCurrentKey candidate) = \(amps(snapshot.powerSourceCurrent))")
        lines.append("batteryCurrentSource = \(snapshot.batteryCurrentSource ?? "unavailable")")
        lines.append("batteryCurrent (resolved) = \(amps(snapshot.batteryCurrent))")
        lines.append("batteryRailVoltage = \(volts(snapshot.batteryRailVoltage))")
        lines.append("powerdVoltage (IOPSVoltageKey candidate) = \(volts(snapshot.powerSourceVoltage))")
        rawNumber("InstantAmperage", in: snapshot.registry)
        rawNumber("Current", in: snapshot.powerSource)
        rawNumber("Voltage", in: snapshot.powerSource)

        lines.append("\n# Charger input — separate from battery cell")
        lines.append("usbInputCurrent (HID IQ0u) = \(amps(snapshot.usbInputCurrent))")
        lines.append("usbInputVoltage = \(volts(snapshot.usbInputVoltage))")
        lines.append("inputWatts (port-side; never treated as cell current) = \(snapshot.inputWatts.map { String(format: "%.4f W", $0) } ?? "nil")")

        // Only instantaneous rails that help distinguish battery-side from port-side.
        // Cumulative counters (QQ0u/WQ0u) and unrelated charger rails stay out of this log.
        let relevantRailKeys: Set<String> = ["IQ0B", "IQ0u", "VP0u", "VQDD"]
        let railCandidates = snapshot.sensors
            .filter { ($0.kind == .current || $0.kind == .voltage) && relevantRailKeys.contains($0.key) }
        let electricalSensors = railCandidates
            .filter { $0.hasInstantaneousPowerSubtype && $0.powerMetadataMatchesKind }
            .sorted { ($0.kind.rawValue, $0.key, $0.index) < ($1.kind.rawValue, $1.key, $1.index) }
        lines.append("\n# Relevant instantaneous rails")
        lines.append("electricalSensorCount = \(electricalSensors.count)")
        lines.append(contentsOf: electricalSensors.map {
            "[\($0.index)] key=\($0.key) name=\($0.name) value=\($0.formatted) event=\($0.eventType) usagePage=0x\(String(format: "%04x", $0.usagePage)) usage=\($0.usage) powerType=\($0.powerType.map { String($0) } ?? "nil") powerSubType=\($0.powerSubType.map { String($0) } ?? "nil")"
        })
        let rejectedRails = railCandidates.filter { !$0.hasInstantaneousPowerSubtype || !$0.powerMetadataMatchesKind }
        if !rejectedRails.isEmpty {
            lines.append("\n# Rejected rail candidates")
            lines.append(contentsOf: rejectedRails.map {
                "[\($0.index)] key=\($0.key) value=\($0.formatted) powerType=\($0.powerType.map { String($0) } ?? "nil") powerSubType=\($0.powerSubType.map { String($0) } ?? "nil")"
            })
        }

        lines.append("\n# Battery percentage precision")
        let wasBatteryMonitoringEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        let deviceBatteryLevel = UIDevice.current.batteryLevel
        UIDevice.current.isBatteryMonitoringEnabled = wasBatteryMonitoringEnabled
        lines.append("batteryMonitoringPreviouslyEnabled = \(wasBatteryMonitoringEnabled)")
        lines.append("UIDevice.batteryLevel.rawFloat = \(String(format: "%.8f", Double(deviceBatteryLevel)))")
        if deviceBatteryLevel >= 0 {
            lines.append("UIDevice.batteryLevel.percent = \(String(format: "%.8f", Double(deviceBatteryLevel) * 100))")
        } else {
            lines.append("UIDevice.batteryLevel = unavailable (-1)")
        }
        rawNumber("Current Capacity", in: snapshot.powerSource)
        rawNumber("Max Capacity", in: snapshot.powerSource)
        rawNumber("AppleRawCurrentCapacity", in: snapshot.powerSource)
        lines.append(contentsOf: monitor.rateEstimateDiagnosticLines.map { "rateEstimate: \($0)" })

        if let partial = snapshot.partialInputWatts {
            lines.append(String(format: "partialInputWatts = %.4f W (not used as cell power)", partial))
        }
        if let check = monitor.levelRateCheck {
            lines.append(String(format: "levelRateCheck = +%d%% in %.0f s; level %.2f W; cell %.2f W; ratio %.2f; verdict %@",
                                check.percentRise, check.span, check.levelWatts, check.cellWatts,
                                check.ratio, String(describing: check.verdict)))
        }

        if !powerSeries.isEmpty {
            lines.append("\n# Selected power-rail time series (0.5 s interval)")
            lines.append(contentsOf: powerSeries.map { point in
                let type = point.powerType.map { " powerType=\($0)" } ?? ""
                let subtype = point.powerSubType.map { " powerSubType=\($0)" } ?? ""
                return String(format: "[%@] t=%.1fs %@ service=%d value=%.8f%@%@",
                              point.key, point.elapsedSeconds, point.name, point.serviceIndex,
                              point.value, type, subtype)
            })
        }

        // Keep the complete manual HID sweep in the copied report. The on-screen
        // panel only emphasizes finite values, but failed reads (no event / non-finite)
        // are equally important when checking whether a battery-current endpoint exists.
        if !deepProbe.isEmpty {
            let finiteCount = deepProbe.filter { $0.value != nil }.count
            lines.append("\n# HID deep probe — all services × event types 15 and 25")
            lines.append("deepProbeChecks = \(deepProbe.count)")
            lines.append("deepProbeFinite = \(finiteCount)")
            lines.append("deepProbeUnavailable = \(deepProbe.count - finiteCount)")
            let orderedProbe = deepProbe.sorted {
                if $0.serviceIndex != $1.serviceIndex { return $0.serviceIndex < $1.serviceIndex }
                return $0.eventType < $1.eventType
            }
            lines.append(contentsOf: orderedProbe.map { reading in
                let value = reading.value.map { String(format: "%.8f", $0) } ?? "nil"
                let powerType = reading.powerType.map { String($0) } ?? "nil"
                let powerSubType = reading.powerSubType.map { String($0) } ?? "nil"
                let key = reading.key.isEmpty ? "—" : reading.key
                return "[\(reading.serviceIndex)] key=\(key) name=\(reading.name) usagePage=0x\(String(format: "%04x", reading.usagePage)) usage=\(reading.usage) eventType=\(reading.eventType) value=\(value) powerType=\(powerType) powerSubType=\(powerSubType) status=\(reading.status)"
            })
        }

        // Only battery/charging state fields are retained from the two source dictionaries.
        let relevantKeys: Set<String> = [
            "Current", "Voltage", "Current Capacity", "Max Capacity",
            "AppleRawCurrentCapacity", "InstantAmperage", "ExternalConnected",
            "IsCharging", "Is Charging", "Charging", "FullyCharged", "Fully Charged",
            "BatteryInstalled", "Temperature", "Amperage"
        ]
        func appendRelevantDictionary(_ title: String, _ dictionary: [String: Any]?) {
            guard let dictionary else { return }
            lines.append("\n# \(title) — selected keys")
            for key in dictionary.keys.sorted() where relevantKeys.contains(key) {
                lines.append("\(key) = \(String(describing: dictionary[key]!))")
            }
        }
        appendRelevantDictionary("IOKit battery registry", snapshot.registry)
        if let matches = snapshot.registry["_MiniWattsBatteryServiceMatches"] as? String {
            lines.append("\n# IOKit battery service/property visibility")
            lines.append(matches)
        }
        appendRelevantDictionary("powerd battery source", snapshot.powerSource)

        return lines.joined(separator: "\n")
    }
}
