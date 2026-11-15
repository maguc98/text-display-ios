import Foundation

/// Read-only walk of the IOService registry plane.
///
/// The existing battery probe asks for a short list of known classes. This probe
/// answers a different question: which service classes actually exist in the
/// process-visible IOService tree, and which of those expose telemetry-shaped
/// property names? It records property names only, never property values, so
/// serial numbers, identifiers and other device-specific values are not copied.
nonisolated final class RegistryTreeProbe {
    struct Candidate: Identifiable, Hashable {
        let className: String
        let depth: Int
        let propertyKeys: [String]
        var id: String { "\(depth)#\(className)#\(propertyKeys.joined(separator: ","))" }
    }

    struct ClassCount: Identifiable, Hashable {
        let className: String
        let count: Int
        var id: String { className }
    }

    struct Report: Hashable {
        let scannedEntries: Int
        let truncated: Bool
        let rootStatus: String
        let apiStatus: String
        let classCounts: [ClassCount]
        let candidates: [Candidate]

        var headline: String {
            "\(scannedEntries) entries scanned · \(candidates.count) candidate nodes"
                + (truncated ? " · capped" : "")
        }

        var dumpLines: [String] {
            var lines = [
                "rootStatus = \(rootStatus)",
                "apiStatus = \(apiStatus)",
                "scannedEntries = \(scannedEntries)",
                "truncated = \(truncated)",
                "candidateCount = \(candidates.count)",
                "distinctClassCount = \(classCounts.count)"
            ]
            lines.append("\n# IORegistry class counts (top 60)")
            lines.append(contentsOf: classCounts.prefix(60).map { "\($0.className) = \($0.count)" })
            lines.append("\n# IORegistry candidate nodes (property names only)")
            lines.append(contentsOf: candidates.map { candidate in
                "depth=\(candidate.depth) class=\(candidate.className) keys=[\(candidate.propertyKeys.joined(separator: ","))]"
            })
            return lines
        }
    }

    private typealias RootEntryFn = @convention(c) (mach_port_t, UnsafePointer<CChar>) -> UInt32
    private typealias ChildIteratorFn =
        @convention(c) (UInt32, UnsafePointer<CChar>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IteratorNextFn = @convention(c) (UInt32) -> UInt32
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> Int32
    private typealias NameFn = @convention(c) (UInt32, UnsafeMutablePointer<CChar>) -> Int32
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> Int32

    private struct Pending {
        let entry: UInt32
        let depth: Int
    }

    private let rootEntry: RootEntryFn?
    private let childIterator: ChildIteratorFn?
    private let iteratorNext: IteratorNextFn?
    private let objectRelease: ObjectReleaseFn?
    private let objectGetClass: NameFn?
    private let entryGetName: NameFn?
    private let createProperties: CreatePropertiesFn?

    private static let plane = "IOService"
    private static let maxEntries = 1600
    private static let maxDepth = 14
    private static let candidateLimit = 160
    private static let terms = [
        "battery", "smartbattery", "gasgauge", "gauge", "fuel",
        "power", "pmu", "smc", "charger", "charge", "energy",
        "amper", "current", "voltage", "capacity", "bms"
    ]

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        rootEntry = sym("IORegistryGetRootEntry", RootEntryFn.self)
        childIterator = sym("IORegistryEntryGetChildIterator", ChildIteratorFn.self)
        iteratorNext = sym("IOIteratorNext", IteratorNextFn.self)
        objectRelease = sym("IOObjectRelease", ObjectReleaseFn.self)
        objectGetClass = sym("IOObjectGetClass", NameFn.self)
        entryGetName = sym("IORegistryEntryGetName", NameFn.self)
        createProperties = sym("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self)
    }

    func run() -> Report {
        guard let rootEntry, let childIterator, let iteratorNext, let objectRelease,
              let objectGetClass, let createProperties else {
            return Report(scannedEntries: 0, truncated: false,
                          rootStatus: "required IOKit symbols unavailable",
                          apiStatus: "missing root/child/class/properties/release symbol",
                          classCounts: [], candidates: [])
        }

        let root: UInt32 = Self.plane.withCString { rootEntry(0, $0) }
        guard root != 0 else {
            return Report(scannedEntries: 0, truncated: false,
                          rootStatus: "IORegistryGetRootEntry returned 0",
                          apiStatus: "symbols available; root unavailable",
                          classCounts: [], candidates: [])
        }

        var queue: [Pending] = [Pending(entry: root, depth: 0)]
        var cursor = 0
        var scanned = 0
        var truncated = false
        var counts: [String: Int] = [:]
        var candidates: [Candidate] = []

        while cursor < queue.count {
            if scanned >= Self.maxEntries {
                truncated = true
                break
            }
            let item = queue[cursor]
            cursor += 1
            scanned += 1

            let className = readName(entry: item.entry, using: objectGetClass) ?? "(class unavailable)"
            counts[className, default: 0] += 1
            let keys = readPropertyKeys(entry: item.entry, using: createProperties)
            let matchedTerms = Self.terms.contains { term in
                className.localizedCaseInsensitiveContains(term)
                    || keys.contains { $0.localizedCaseInsensitiveContains(term) }
            }
            if matchedTerms, candidates.count < Self.candidateLimit {
                candidates.append(Candidate(
                    className: className,
                    depth: item.depth,
                    propertyKeys: keys.filter { key in
                        Self.terms.contains { key.localizedCaseInsensitiveContains($0) }
                    }.sorted()
                ))
            } else if matchedTerms {
                truncated = true
            }

            if item.depth < Self.maxDepth {
                var iterator: UInt32 = 0
                let result = Self.plane.withCString {
                    childIterator(item.entry, $0, &iterator)
                }
                if result == 0, iterator != 0 {
                    while true {
                        let child = iteratorNext(iterator)
                        if child == 0 { break }
                        queue.append(Pending(entry: child, depth: item.depth + 1))
                        if queue.count + scanned >= Self.maxEntries * 2 {
                            truncated = true
                            break
                        }
                    }
                    _ = objectRelease(iterator)
                }
            } else {
                truncated = true
            }
            _ = objectRelease(item.entry)
        }

        // Release entries not visited because the node cap was reached.
        if cursor < queue.count {
            for item in queue[cursor...] { _ = objectRelease(item.entry) }
        }

        let sortedCounts = counts.map { ClassCount(className: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.className < rhs.className : lhs.count > rhs.count
            }
        let sortedCandidates = candidates.sorted {
            $0.depth == $1.depth ? $0.className < $1.className : $0.depth < $1.depth
        }
        return Report(
            scannedEntries: scanned,
            truncated: truncated,
            rootStatus: "IORegistryGetRootEntry(IOService) succeeded",
            apiStatus: "root, child iterator, class lookup, properties and release available",
            classCounts: sortedCounts,
            candidates: sortedCandidates
        )
    }

    private func readName(entry: UInt32, using function: NameFn) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            function(entry, pointer.baseAddress!)
        }
        guard result == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private func readPropertyKeys(entry: UInt32, using function: CreatePropertiesFn) -> [String] {
        var properties: Unmanaged<CFDictionary>?
        guard function(entry, &properties, kCFAllocatorDefault, 0) == 0,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        return dictionary.keys
    }
}
