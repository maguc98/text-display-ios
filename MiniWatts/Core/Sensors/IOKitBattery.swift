import Foundation

/// Reads battery and power-adapter state through IOKit.
///
/// IOKit is a private framework on iOS, so every symbol is resolved with `dlsym`
/// at runtime instead of being linked. Fine for a sideloaded build; this is the
/// reason MiniWatts can never pass App Store review.
///
/// What actually survives the iOS sandbox (verified on iOS 26):
/// - `IOPMPowerSource` registry: only `BatteryInstalled` and `ExternalConnected`.
/// - powerd `IOPSCopyPowerSourcesInfo`: percent, charging flags, low power mode.
/// - powerd `IOPSCopyExternalPowerAdapterDetails`: the full USB-PD handshake.
/// - `IOPSCopyChargeStatus`: refused (kIOReturnNotPrivileged), kept for the record.
nonisolated final class IOKitBattery {
    private typealias ServiceMatchingFn =
        @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServicesFn =
        @convention(c) (mach_port_t, CFDictionary?, UnsafeMutablePointer<UInt32>) -> kern_return_t
    private typealias IteratorNextFn = @convention(c) (UInt32) -> UInt32
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t
    private typealias ServiceOpenFn =
        @convention(c) (UInt32, mach_port_t, UInt32, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
    private typealias ServiceCloseFn = @convention(c) (mach_port_t) -> kern_return_t
    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyPowerSourcesListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias GetPowerSourceDescriptionFn =
        @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private typealias CopyAdapterDetailsFn = @convention(c) () -> Unmanaged<CFDictionary>?
    private typealias CopyChargeStatusFn =
        @convention(c) (UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    private let serviceMatching: ServiceMatchingFn
    private let getMatchingServices: GetMatchingServicesFn
    private let iteratorNext: IteratorNextFn
    private let createProperties: CreatePropertiesFn
    private let objectRelease: ObjectReleaseFn
    private let serviceOpen: ServiceOpenFn?
    private let serviceClose: ServiceCloseFn?
    private let copyPowerSourcesInfo: CopyPowerSourcesInfoFn?
    private let copyPowerSourcesList: CopyPowerSourcesListFn?
    private let powerSourceDescription: GetPowerSourceDescriptionFn?
    private let copyAdapterDetails: CopyAdapterDetailsFn?
    private let copyChargeStatus: CopyChargeStatusFn?

    /// Last IOReturn from `IOPSCopyChargeStatus`; 0xe00002c1 means the sandbox refused.
    private(set) var chargeStatusError: Int32 = 0
    /// Result of a read-only IOServiceOpen/close probe against AppleSMCKeysEndpoint.
    private(set) var smcConnectionDiagnostic = "not run"

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let matching = sym("IOServiceMatching", ServiceMatchingFn.self),
              let matchingServices = sym("IOServiceGetMatchingServices", GetMatchingServicesFn.self),
              let next = sym("IOIteratorNext", IteratorNextFn.self),
              let properties = sym("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self),
              let release = sym("IOObjectRelease", ObjectReleaseFn.self)
        else { return nil }
        serviceMatching = matching
        getMatchingServices = matchingServices
        iteratorNext = next
        createProperties = properties
        objectRelease = release
        serviceOpen = sym("IOServiceOpen", ServiceOpenFn.self)
        serviceClose = sym("IOServiceClose", ServiceCloseFn.self)
        copyPowerSourcesInfo = sym("IOPSCopyPowerSourcesInfo", CopyPowerSourcesInfoFn.self)
        copyPowerSourcesList = sym("IOPSCopyPowerSourcesList", CopyPowerSourcesListFn.self)
        powerSourceDescription = sym("IOPSGetPowerSourceDescription", GetPowerSourceDescriptionFn.self)
        copyAdapterDetails = sym("IOPSCopyExternalPowerAdapterDetails", CopyAdapterDetailsFn.self)
        copyChargeStatus = sym("IOPSCopyChargeStatus", CopyChargeStatusFn.self)
        smcConnectionDiagnostic = probeSMCConnection()
    }

    /// Tests whether this ordinary app process can open the SMC user client.
    /// This deliberately does not issue any SMC commands or read/write sensor keys;
    /// a successful open proves only connection permission, not data-read permission.
    private func probeSMCConnection() -> String {
        guard let serviceOpen, let serviceClose else {
            return "symbols: IOServiceOpen/IOServiceClose unavailable"
        }
        guard let matching = serviceMatching("AppleSMCKeysEndpoint") else {
            return "matching: AppleSMCKeysEndpoint dictionary unavailable"
        }
        var iterator: UInt32 = 0
        let matchResult = getMatchingServices(0, matching.takeUnretainedValue(), &iterator)
        guard matchResult == KERN_SUCCESS else {
            return "IOServiceGetMatchingServices = " + String(format: "0x%08x", UInt32(bitPattern: matchResult))
        }
        guard iterator != 0 else { return "AppleSMCKeysEndpoint: no matching services (iterator=0)" }
        defer { _ = objectRelease(iterator) }

        var lines: [String] = []
        var index = 0
        while true {
            let service = iteratorNext(iterator)
            guard service != 0 else { break }
            defer { _ = objectRelease(service) }
            var connection: mach_port_t = 0
            let openResult = serviceOpen(service, mach_task_self_, 0, &connection)
            if openResult == KERN_SUCCESS {
                let closeResult = serviceClose(connection)
                lines.append("endpoint[\(index)] IOServiceOpen=0x00000000 (opened); IOServiceClose=" +
                             String(format: "0x%08x", UInt32(bitPattern: closeResult)))
            } else {
                lines.append("endpoint[\(index)] IOServiceOpen=" +
                             String(format: "0x%08x", UInt32(bitPattern: openResult)))
            }
            index += 1
        }
        return lines.isEmpty ? "AppleSMCKeysEndpoint: iterator returned no services" : lines.joined(separator: " | ")
    }

    /// Reads every matching battery-related registry service, not merely the first.
    /// The previous implementation used IOServiceGetMatchingService, which silently
    /// discarded any additional instances. The raw dump showed the matching classes
    /// but only a tiny property set; enumerating all instances lets us verify whether
    /// another instance exposes electrical properties such as InstantAmperage.
    ///
    /// More specific service dictionaries are merged last. Every instance and its
    /// property keys are retained in the diagnostic string so a device-side dump
    /// can show exactly what the sandbox allowed us to inspect.
    func readRegistryProperties(className: String = "IOPMPowerSource") -> [String: Any]? {
        // On iOS, IOPMPowerSource itself often exposes only a small property set.
        // Capacity/cycle data may instead be attached to SmartBattery, pack, or PMU services.
        let candidates = ["AppleSmartBattery", "AppleSmartBatteryPack",
                          "AppleSmartBatteryManager", "AppleARMPMUCharger", className]
        var merged: [String: Any] = [:]
        var mergedBatteryData: [String: Any] = [:]
        var matches: [String] = []

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            let instances = readProperties(for: candidate)
            for (index, properties) in instances.enumerated() {
                for (key, value) in properties {
                    merged[key] = value
                }
                if let batteryData = properties["BatteryData"] as? [String: Any] {
                    for (key, value) in batteryData {
                        // Later, more specific service matches (notably BatteryPack)
                        // take precedence over the generic SmartBattery dictionary.
                        mergedBatteryData[key] = value
                    }
                }
                let keys = properties.keys.sorted().joined(separator: ",")
                matches.append("\(candidate)[\(index)]: [\(keys)]")
            }
        }

        guard !matches.isEmpty else { return nil }
        if !mergedBatteryData.isEmpty {
            merged["_MiniWattsBatteryData"] = mergedBatteryData
        }
        merged["_MiniWattsBatteryServiceMatches"] = matches.joined(separator: " | ")
        return merged
    }

    /// IOServiceGetMatchingServices consumes the matching dictionary and returns an
    /// iterator. Each service and the iterator are released as soon as they are read.
    private func readProperties(for className: String) -> [[String: Any]] {
        guard let matching = serviceMatching(className) else { return [] }
        var iterator: UInt32 = 0
        let result = getMatchingServices(
            0 /* kIOMainPortDefault */,
            matching.takeUnretainedValue(),
            &iterator
        )
        guard result == KERN_SUCCESS, iterator != 0 else { return [] }
        defer { _ = objectRelease(iterator) }

        var all: [[String: Any]] = []
        while true {
            let service = iteratorNext(iterator)
            guard service != 0 else { break }
            defer { _ = objectRelease(service) }

            var properties: Unmanaged<CFDictionary>?
            guard createProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() else { continue }
            all.append(dictionary as? [String: Any] ?? [:])
        }
        return all
    }

    /// One dictionary per power source from powerd.
    func readPowerSources() -> [[String: Any]] {
        guard let copyPowerSourcesInfo, let copyPowerSourcesList, let powerSourceDescription,
              let blob = copyPowerSourcesInfo()?.takeRetainedValue(),
              let list = copyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { powerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// The connected adapter's description, including the advertised USB-PD profile menu.
    func readAdapterDetails() -> [String: Any]? {
        copyAdapterDetails?()?.takeRetainedValue() as? [String: Any]
    }

    /// powerd's charge status, e.g. `chargeStatus = "Charging On Hold"`.
    /// Privileged on iOS; kept because it works on macOS and in the simulator.
    func readChargeStatus() -> [String: Any]? {
        guard let copyChargeStatus else { return nil }
        var out: Unmanaged<CFTypeRef>?
        let result = copyChargeStatus(&out)
        chargeStatusError = result
        guard result == 0, let value = out?.takeRetainedValue() else { return nil }
        return value as? [String: Any]
    }
}
