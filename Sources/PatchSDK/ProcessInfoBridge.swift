import Foundation
import WasmKit

// MARK: - ProcessInfoBridge (system / environment facts)
//
// `process_info()` -> packed-i64 JSON blob describing the current process /
// environment. The guest unpacks `(ptr,len)`, reads the JSON, and frees it (the
// standard Patch v0 ABI). Shape:
//
//   {"thermalState":"nominal","lowPowerMode":false,
//    "osVersion":"14.4.0","processorCount":10,"activeProcessorCount":10,
//    "physicalMemory":17179869184}
//
// `thermalState` is one of: "nominal" | "fair" | "serious" | "critical".
//
// ## Cross-platform core + injected dependency (Rule 2)
// `ProcessInfo` is plain Foundation — it compiles AND runs on macOS directly, so
// unlike the UIKit/StoreKit bridges there is no platform guard needed for the
// real path. We still inject a `@Sendable () -> ProcessFacts` provider so the
// JSON encoding can be unit-tested with deterministic inputs (no dependency on
// the host machine's live thermal state / memory). The convenience `init()`
// wires the real `ProcessInfo.processInfo` snapshot under `#if canImport(Foundation)`
// (always true on Apple platforms, kept explicit to mirror the guide's pattern).

/// A snapshot of process / environment facts. Injected into `ProcessInfoBridge`
/// so the marshalling/encoding is testable without reading the live machine.
public struct ProcessFacts: Sendable, Equatable {
    /// The device's current thermal pressure level.
    public enum ThermalState: String, Sendable {
        case nominal, fair, serious, critical
    }

    /// Current thermal pressure.
    public var thermalState: ThermalState
    /// Whether Low Power Mode is enabled.
    public var lowPowerMode: Bool
    /// Operating system version string ("major.minor.patch").
    public var osVersion: String
    /// Total number of processing cores.
    public var processorCount: Int
    /// Number of cores currently available to the process.
    public var activeProcessorCount: Int
    /// Physical RAM in bytes.
    public var physicalMemory: UInt64

    public init(
        thermalState: ThermalState,
        lowPowerMode: Bool,
        osVersion: String,
        processorCount: Int,
        activeProcessorCount: Int,
        physicalMemory: UInt64
    ) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.osVersion = osVersion
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemory = physicalMemory
    }
}

/// Exposes `process_info()` returning a packed-i64 JSON blob describing the
/// current process / environment. Inject a `@Sendable () -> ProcessFacts`
/// provider for deterministic tests; the default `init()` reads `ProcessInfo`.
public struct ProcessInfoBridge: Bridge {
    public let module = "patch"
    private let provider: @Sendable () -> ProcessFacts

    /// Cross-platform designated init: the provider supplies the current facts.
    public init(provider: @escaping @Sendable () -> ProcessFacts) {
        self.provider = provider
    }

    #if canImport(Foundation)
    /// Convenience default init: snapshot the real `ProcessInfo` on each call so
    /// the guest always reads the latest thermal state / low-power-mode.
    public init() {
        self.init(provider: { Self.snapshot() })
    }

    /// Read a live `ProcessFacts` snapshot from `ProcessInfo.processInfo`. Pulled
    /// out so the convenience init stays a one-liner.
    static func snapshot() -> ProcessFacts {
        let info = ProcessInfo.processInfo
        let thermal: ProcessFacts.ThermalState
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        let v = info.operatingSystemVersion
        return ProcessFacts(
            thermalState: thermal,
            lowPowerMode: info.isLowPowerModeEnabled,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            processorCount: info.processorCount,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemory: info.physicalMemory)
    }
    #endif

    /// Pure JSON encoder for a `ProcessFacts`. Exposed (and unit-tested) directly
    /// so the round-trip can be asserted without a wasm instance. Key order is
    /// fixed so the output is deterministic. The OS version string is JSON-escaped
    /// (quotes / backslashes) defensively even though real version strings have none.
    public static func encode(_ facts: ProcessFacts) -> [UInt8] {
        let json = "{"
            + "\"thermalState\":\"\(facts.thermalState.rawValue)\","
            + "\"lowPowerMode\":\(facts.lowPowerMode),"
            + "\"osVersion\":\"\(escape(facts.osVersion))\","
            + "\"processorCount\":\(facts.processorCount),"
            + "\"activeProcessorCount\":\(facts.activeProcessorCount),"
            + "\"physicalMemory\":\(facts.physicalMemory)"
            + "}"
        return [UInt8](json.utf8)
    }

    /// Minimal JSON string escaping for the one free-form field (osVersion).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    public func register(into imports: inout Imports, store: Store) {
        let provider = self.provider
        imports.host(module, "process_info", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(Self.encode(provider()))]
        }
    }

    /// Internal accessor exercising the injected provider exactly as the
    /// registered `process_info` host closure does. Used by tests to assert dispatch.
    func currentFacts() -> ProcessFacts { provider() }
}
