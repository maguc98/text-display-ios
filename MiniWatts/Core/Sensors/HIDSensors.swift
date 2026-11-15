import Foundation

/// Reads Apple's vendor power and temperature sensors through the private
/// `IOHIDEventSystemClient` API.
///
/// On iOS a sandboxed process may create exactly one client; every additional
/// client in the same process returns NaN for every service. So a single
/// instance is created at launch and reused for the life of the app.
///
/// Two vendor usage pages carry what we want:
///   0xff08  AppleVendorPowerSensor  usage 2 = current (A), usage 3 = voltage (V)
///   0xff00  AppleVendor             usage 5 = temperature (°C)
///
/// Names seen on recent iPhones (they vary by model, so nothing here is hardcoded
/// as required — see `SensorCatalog` for the classification):
///   Charger VQ0u / IQ0u    USB-C input voltage / current
///   Charger VQ1u / IQ1u    wireless (MagSafe) input voltage / current
///   Charger IQ0B           current delivered into the battery
///   Charger VQ0l, PMU VP0u battery-side voltage
///   gas gauge battery      battery temperature
///   Charger TQ0j / TQ0d    charger junction / die temperature
///   PMU tdie1…n            SoC die temperatures
///
/// Each service is an `AppleSMCKeysEndpoint` whose `LocationID` is the four-letter
/// SMC key in ASCII (0x49513075 = "IQ0u"). The key is the stable identifier, the
/// name is not: names repeat across keys (`PMU tdie1` is both TP1b and TP1l), and
/// iOS 27 publishes every key through two services. `PowerSnapshot` merges those
/// copies by key; this layer reports them as they come.
nonisolated final class HIDSensors {
    enum Kind: Int, Sendable {
        case other = 0
        case power = 1
        case current = 2
        case voltage = 3
        case temperature = 5

        /// IOHIDPowerType: 0 = power, 1 = current, 2 = voltage.
        var expectedPowerType: Int64? {
            switch self {
            case .power: return 0
            case .current: return 1
            case .voltage: return 2
            case .temperature, .other: return nil
            }
        }
    }

    struct Reading: Identifiable, Hashable, Sendable {
        let name: String
        let kind: Kind
        let value: Double
        /// SMC key from the service's LocationID, e.g. "IQ0u".
        let key: String
        /// Position in the service list. Names repeat, so retain the service index.
        let index: Int
        /// Original HID descriptor and event metadata, needed to identify cumulative
        /// values and to avoid guessing units from the four-character key alone.
        let eventType: Int64
        let usagePage: Int
        let usage: Int
        let powerType: Int64?
        let powerSubType: Int64?

        var id: String { "\(index)#\(name)" }
        var isCumulative: Bool { powerSubType == 1 }
        /// Nil is retained for older systems without the metadata accessor. Known
        /// instantaneous subtype is 0; every other reported subtype is raw-only.
        var hasInstantaneousPowerSubtype: Bool { powerSubType == nil || powerSubType == 0 }
        var powerMetadataMatchesKind: Bool {
            guard let powerType, let expected = kind.expectedPowerType else { return true }
            return powerType == expected
        }

        var formatted: String {
            // A cumulative counter is not a live A/V/W measurement.
            if isCumulative {
                return String(format: "cumulative raw %.6f", value)
            }
            if let powerSubType, powerSubType != 0 {
                return String(format: "non-instantaneous subtype %lld raw %.6f", powerSubType, value)
            }
            switch kind {
            case .power: return String(format: "%.3f W", value)
            case .current: return String(format: "%.3f A", value)
            case .voltage: return String(format: "%.3f V", value)
            case .temperature: return Formatting.temperature(value, in: .celsius)
            case .other: return String(format: "%.3f", value)
            }
        }
    }

    /// One HID service as the system reports it, before any value is read.
    struct ServiceInfo: Identifiable, Hashable, Sendable {
        let name: String
        let usagePage: Int
        let usage: Int
        /// Four-character SMC key decoded from LocationID, when this service has one.
        /// Keeping it in the inventory lets us distinguish an absent key from a
        /// discovered service whose event cannot be read.
        let key: String
        /// Names and usage pairs can repeat. Keep the discovery index in the
        /// identity so DebugView does not collapse duplicate services into one row.
        let index: Int
        var id: String { "\(index)#\(name)#\(usagePage)#\(usage)" }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double
    private typealias GetIntegerFn = @convention(c) (CFTypeRef, Int32) -> Int64

    private static let powerEventType: Int64 = 25       // kIOHIDEventTypePower
    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    static let powerUsagePage = 0xff08
    static let vendorUsagePage = 0xff00

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let key: String
        let usagePage: Int
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    /// Optional on iOS builds where this private symbol is not exported.
    private let getInteger: GetIntegerFn?
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.getInteger = sym("IOHIDEventGetIntegerValue", GetIntegerFn.self)
        rescan()
    }

    var isEmpty: Bool { services.isEmpty }
    var serviceCount: Int { services.count }

    /// Re-enumerates the sensor services. Cheap enough to call every few seconds;
    /// the charger's sensors only appear once something is plugged in.
    func rescan() {
        var found: [Service] = []
        // Every service on the power page, not just the handful we name: unknown
        // rails still carry usable volts and amps and are worth showing.
        found += discover(matching: ["PrimaryUsagePage": Self.powerUsagePage],
                          eventType: Self.powerEventType)
        // Temperature sensors. The whole matrix, so wireless coils, NAND and every
        // PMU die show up alongside the battery.
        found += discover(matching: ["PrimaryUsagePage": Self.vendorUsagePage, "PrimaryUsage": 5],
                          eventType: Self.temperatureEventType)
        services = found
    }

    /// Current value of every discovered sensor. Sensors that return NaN (nothing
    /// plugged in, rail powered down) are skipped rather than shown as zero.
    ///
    /// Nothing else is filtered here: the Raw data screen shows this list and says it
    /// is unedited. Values that cannot be temperatures are dropped a layer up, where
    /// `PowerSnapshot` decides what counts as one — see `plausibleCelsius`.
    func read() -> [Reading] {
        services.enumerated().compactMap { index, service in
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }

            let powerType = service.eventType == Self.powerEventType
                ? getInteger?(event, Int32((service.eventType << 16) + 1)) : nil
            let powerSubType = service.eventType == Self.powerEventType
                ? getInteger?(event, Int32((service.eventType << 16) + 2)) : nil

            let kind: Kind
            if service.eventType == Self.temperatureEventType {
                kind = .temperature
            } else if service.eventType == Self.powerEventType, let powerType {
                // Prefer the event's explicit measurement discriminator. Unknown
                // types stay untyped rather than being mislabeled as amps or volts.
                switch powerType {
                case 0: kind = .power
                case 1: kind = .current
                case 2: kind = .voltage
                default: kind = .other
                }
            } else {
                // Compatibility fallback when the integer metadata accessor is absent.
                kind = Kind(rawValue: service.usage) ?? .other
            }

            return Reading(name: service.name,
                           kind: kind,
                           value: value,
                           key: service.key,
                           index: index,
                           eventType: service.eventType,
                           usagePage: service.usagePage,
                           usage: service.usage,
                           powerType: powerType,
                           powerSubType: powerSubType)
        }
    }

    /// What a temperature sensor on a phone can physically report.
    ///
    /// NaN is not the only way a sensor says "nothing here". Reports from models this
    /// app has never run on include a charge IC reading −9199.4 °C, which is a
    /// sentinel or a raw counter that happens to sit on the temperature page — and the
    /// app dutifully printed it as a temperature. A reading outside this range is not
    /// a cold phone, it is a sensor that does not mean what its usage page says, so it
    /// is dropped and the value shows as absent.
    ///
    /// Only temperature is checked. Volts and amps have shown no comparable sentinel,
    /// and a range tight enough to catch one would risk hiding a real rail on a model
    /// nobody here has seen.
    static let plausibleCelsius = -40.0...150.0

    /// Every HID service in the system, matched or not. Debug view only: this is how
    /// the sensor names above were found in the first place, and how they get found
    /// again on a phone model this app has never seen.
    func fullInventory() -> [ServiceInfo] {
        // nil, not an empty dictionary: an empty matching dictionary matches
        // nothing, which is why this used to come back empty and the button in the
        // debug view looked dead.
        let all = discover(matching: nil, eventType: 0).enumerated().map { index, service in
            ServiceInfo(name: service.name,
                        usagePage: service.usagePage,
                        usage: service.usage,
                        key: service.key,
                        index: index)
        }
        rescan() // the matching dictionary is client state; put it back
        return all.sorted { ($0.usagePage, $0.usage, $0.name) < ($1.usagePage, $1.usage, $1.name) }
    }

    /// One-shot diagnostic result for probing existing HID services with the two
    /// event types already used by MiniWatts. This is exploratory only: a finite
    /// value is not evidence that the usage represents battery state or SOC.
    struct DeepProbeReading: Identifiable, Hashable, Sendable {
        let name: String
        let usagePage: Int
        let usage: Int
        let key: String
        let serviceIndex: Int
        let eventType: Int64
        let value: Double?
        /// IOHIDPowerType: 0=power, 1=current, 2=voltage. Nil when unavailable/not a power event.
        let powerType: Int64?
        /// IOHIDPowerSubType: 0=normal, 1=cumulative. Nil when unavailable/not a power event.
        let powerSubType: Int64?
        let status: String

        var id: String { "\(serviceIndex)#\(usagePage)#\(usage)#\(eventType)" }
    }

    /// Manually invoked, read-only sweep. Reuses this process's single HID client;
    /// never creates another IOHIDEventSystemClient. Only event types 15 and 25 are
    /// tried because those are the event types already verified by the app.
    /// The regular power/temperature matching is restored before returning.
    func deepProbe() -> [DeepProbeReading] {
        let candidates: [Int64] = [Self.temperatureEventType, Self.powerEventType]
        let all = discover(matching: nil, eventType: 0)
        defer { rescan() }

        return all.enumerated().flatMap { index, service in
            candidates.map { eventType in
                let base = (name: service.name,
                            usagePage: service.usagePage,
                            usage: service.usage,
                            key: service.key,
                            serviceIndex: index,
                            eventType: eventType)
                guard let event = copyEvent(service.ref, eventType, 0, 0)?.takeRetainedValue() else {
                    return DeepProbeReading(name: base.name, usagePage: base.usagePage,
                                             usage: base.usage, key: base.key,
                                             serviceIndex: base.serviceIndex, eventType: eventType,
                                             value: nil, powerType: nil, powerSubType: nil,
                                             status: "no event")
                }
                let value = getFloat(event, Int32(eventType << 16))
                guard value.isFinite else {
                    return DeepProbeReading(name: base.name, usagePage: base.usagePage,
                                             usage: base.usage, key: base.key,
                                             serviceIndex: base.serviceIndex, eventType: eventType,
                                             value: nil, powerType: nil, powerSubType: nil,
                                             status: "non-finite")
                }
                // Power events carry a separate discriminator. The measurement field
                // alone is not enough to tell amps from watts or volts.
                let powerType = eventType == Self.powerEventType
                    ? self.getInteger?(event, Int32((eventType << 16) + 1)) : nil
                let powerSubType = eventType == Self.powerEventType
                    ? self.getInteger?(event, Int32((eventType << 16) + 2)) : nil
                return DeepProbeReading(name: base.name, usagePage: base.usagePage,
                                        usage: base.usage, key: base.key,
                                        serviceIndex: base.serviceIndex, eventType: eventType,
                                        value: value, powerType: powerType,
                                        powerSubType: powerSubType,
                                        status: "finite; meaning unverified")
            }
        }
    }

    /// A timed sample from a power-page SMC endpoint. This is diagnostic data:
    /// cumulative subtype values must not be treated as instantaneous amps/watts.
    struct PowerSeriesPoint: Identifiable, Hashable, Sendable {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let name: String
        let key: String
        let serviceIndex: Int
        let value: Double
        let powerType: Int64?
        let powerSubType: Int64?
        var id: String { "\(serviceIndex)#\(sampleIndex)" }
    }

    /// Samples selected power rails over a short, timed window. QQ0u/WQ0u are
    /// included because their cumulative subtype may encode counters rather than
    /// instantaneous current/power. The series is intentionally diagnostic-only:
    /// no unit conversion or battery-current mapping is made here.
    func powerSeriesProbe(sampleCount: Int = 21,
                          intervalNanoseconds: UInt64 = 500_000_000) -> [PowerSeriesPoint] {
        // Keep only instantaneous rails relevant to battery-vs-port diagnosis.
        // QQ0u/WQ0u are cumulative counters (powerSubType=1), not live amps/volts.
        let keys: Set<String> = ["IQ0u", "IQ0B", "VQDD", "VP0u"]
        let candidates = services.enumerated().filter { keys.contains($0.element.key) }
        guard !candidates.isEmpty else { return [] }

        var points: [PowerSeriesPoint] = []
        points.reserveCapacity(candidates.count * sampleCount)
        for sampleIndex in 0..<max(sampleCount, 1) {
            let elapsed = Double(sampleIndex) * Double(intervalNanoseconds) / 1_000_000_000
            for (serviceIndex, service) in candidates {
                guard let event = copyEvent(service.ref, Self.powerEventType, 0, 0)?.takeRetainedValue() else { continue }
                let value = getFloat(event, Int32(Self.powerEventType << 16))
                guard value.isFinite else { continue }
                points.append(PowerSeriesPoint(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsed,
                    name: service.name,
                    key: service.key,
                    serviceIndex: serviceIndex,
                    value: value,
                    powerType: getInteger?(event, Int32((Self.powerEventType << 16) + 1)),
                    powerSubType: getInteger?(event, Int32((Self.powerEventType << 16) + 2))
                ))
            }
            if sampleIndex + 1 < max(sampleCount, 1) {
                // This runs on SensorProbe's serial actor. A blocking sleep here
                // keeps the process's single HID client from being sampled or rescanned
                // concurrently by the regular monitor tick during this diagnostic.
                Thread.sleep(forTimeInterval: Double(intervalNanoseconds) / 1_000_000_000)
            }
        }
        return points
    }

    /// The four-character SMC key packed into a `LocationID`, or "" when the number is
    /// not four printable ASCII characters — not every service on these pages is an
    /// SMC endpoint, and a sequential location must not turn into a made-up key.
    static func smcKey(_ location: UInt32) -> String {
        let bytes = withUnsafeBytes(of: location.bigEndian) { Array($0) }
        guard location != 0, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func discover(matching: [String: Any]?, eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary?)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            func number(_ key: String) -> Int {
                (copyProperty(ref, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let location = (copyProperty(ref, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            return Service(ref: ref,
                           name: name,
                           key: Self.smcKey(location),
                           usagePage: number("PrimaryUsagePage"),
                           usage: number("PrimaryUsage"),
                           eventType: eventType)
        }
    }
}
