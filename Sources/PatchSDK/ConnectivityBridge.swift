import Foundation
import WasmKit
#if canImport(Network)
import Network
#endif

// MARK: - Connectivity (network reachability) bridge
//
// `connectivity_status()` -> packed-i64 JSON blob describing the current network
// path. The guest unpacks `(ptr,len)`, reads the JSON, and frees it (the standard
// Patch v0 ABI). Shape:
//
//   {"online":true,"isExpensive":false,"isConstrained":false,"interface":"wifi"}
//
// `interface` is one of: "wifi" | "cellular" | "wired" | "loopback" | "other" | "none".
//
// ## Cross-platform core + injected dependency (Rule 2)
// The bridge itself compiles on macOS: it stores a `@Sendable () -> ConnectivityStatus`
// provider and the JSON encoding lives in a pure `static func encode(...)`. Tests
// inject a fixed `ConnectivityStatus` and assert the JSON. The convenience default
// `init()` wires the real reachability source via `NWPathMonitor` under
// `#if canImport(Network)` — it starts a monitor on a background queue and caches
// the latest `NWPath`, so the synchronous guest call reads the most recent snapshot.

/// A snapshot of the device's current network reachability. Injected into
/// `ConnectivityBridge` so the marshalling/encoding is testable without `Network`.
public struct ConnectivityStatus: Sendable, Equatable {
    /// The kind of interface satisfying the current path.
    public enum Interface: String, Sendable {
        case wifi, cellular, wired, loopback, other, none
    }

    /// Whether the network path can currently carry traffic.
    public var online: Bool
    /// Whether the path uses an interface considered expensive (e.g. cellular).
    public var isExpensive: Bool
    /// Whether the path is in constrained mode (e.g. Low Data Mode).
    public var isConstrained: Bool
    /// The primary interface type for the current path.
    public var interface: Interface

    public init(
        online: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        interface: Interface
    ) {
        self.online = online
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interface = interface
    }

    /// A fully-offline status (no usable interface).
    public static let offline = ConnectivityStatus(
        online: false, isExpensive: false, isConstrained: false, interface: .none)
}

/// Exposes `connectivity_status()` returning a packed-i64 JSON blob describing
/// the current network path. Inject a `@Sendable () -> ConnectivityStatus`
/// provider for deterministic tests; the default `init()` wires `NWPathMonitor`.
public struct ConnectivityBridge: Bridge {
    public let module = "patch"
    private let provider: @Sendable () -> ConnectivityStatus

    /// Cross-platform designated init: the provider supplies the current status.
    public init(provider: @escaping @Sendable () -> ConnectivityStatus) {
        self.provider = provider
    }

    #if canImport(Network)
    /// Convenience default init: start an `NWPathMonitor` and cache the latest
    /// `NWPath`, mapping it to a `ConnectivityStatus` on demand. The monitor runs
    /// on a private background queue; the synchronous guest call reads the most
    /// recently observed path (or `.offline` until the first update arrives).
    public init() {
        let cache = PathCache()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in cache.set(path) }
        monitor.start(queue: DispatchQueue(label: "com.patch.sdk.connectivity"))
        self.init(provider: { cache.currentStatus() })
    }
    #endif

    /// Pure JSON encoder for a `ConnectivityStatus`. Exposed (and unit-tested)
    /// directly so the round-trip can be asserted without a wasm instance. The
    /// key order is fixed so the output is deterministic.
    public static func encode(_ status: ConnectivityStatus) -> [UInt8] {
        // Hand-rolled to guarantee key order + boolean literals (no Foundation
        // formatter ambiguity), keeping the blob minimal and stable.
        let json = "{"
            + "\"online\":\(status.online),"
            + "\"isExpensive\":\(status.isExpensive),"
            + "\"isConstrained\":\(status.isConstrained),"
            + "\"interface\":\"\(status.interface.rawValue)\""
            + "}"
        return [UInt8](json.utf8)
    }

    public func register(into imports: inout Imports, store: Store) {
        let provider = self.provider
        imports.host(module, "connectivity_status", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(Self.encode(provider()))]
        }
    }

    /// Internal accessor exercising the injected provider exactly as the registered
    /// `connectivity_status` host closure does. Used by tests to assert dispatch.
    func currentStatus() -> ConnectivityStatus { provider() }
}

#if canImport(Network)
/// Thread-safe cache of the latest `NWPath`, mapping it to `ConnectivityStatus`.
/// The monitor's update handler writes from a background queue; the guest call
/// reads synchronously, so access is locked.
private final class PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var path: NWPath?

    func set(_ p: NWPath) { lock.lock(); path = p; lock.unlock() }

    func currentStatus() -> ConnectivityStatus {
        lock.lock(); let p = path; lock.unlock()
        guard let p else { return .offline }
        return ConnectivityBridge.map(p)
    }
}

extension ConnectivityBridge {
    /// Map an `NWPath` to a `ConnectivityStatus`, picking the first available
    /// interface type in priority order (wifi > cellular > wired > loopback > other).
    static func map(_ path: NWPath) -> ConnectivityStatus {
        let online = path.status == .satisfied
        let interface: ConnectivityStatus.Interface
        if !online {
            interface = .none
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wired
        } else if path.usesInterfaceType(.loopback) {
            interface = .loopback
        } else {
            interface = .other
        }
        return ConnectivityStatus(
            online: online,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interface: interface)
    }
}
#endif
