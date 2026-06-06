import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DeviceInfo value type
//
// A cross-platform snapshot of the host device's identity + screen metrics. This
// is the value the `DeviceInfoBridge` serializes to JSON and hands the guest. It
// is deliberately a plain `Sendable` struct (no UIKit types) so the bridge core
// compiles + unit-tests on macOS; the iOS shell fills it from
// `UIDevice.current` / `UIScreen.main` via the `#if canImport(UIKit)`
// convenience init below.
public struct DeviceInfo: Sendable {
    /// Hardware model identifier, e.g. "iPhone15,3".
    public let model: String
    /// OS family name, e.g. "iOS".
    public let systemName: String
    /// OS version, e.g. "17.4".
    public let systemVersion: String
    /// User-assigned device name, e.g. "Jane's iPhone".
    public let name: String
    /// UI idiom: "phone" | "pad" | "tv" | "carPlay" | "mac" | "vision" | "unspecified".
    public let idiom: String
    /// Logical screen width in points.
    public let screenWidth: Double
    /// Logical screen height in points.
    public let screenHeight: Double
    /// Display scale factor (e.g. 3.0 on a 3x retina screen).
    public let scale: Double

    public init(
        model: String,
        systemName: String,
        systemVersion: String,
        name: String,
        idiom: String,
        screenWidth: Double,
        screenHeight: Double,
        scale: Double
    ) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.name = name
        self.idiom = idiom
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
    }
}

// MARK: - DeviceInfo (systemServices)
//
// device_info() -> packed-i64 JSON blob describing the host device:
//   {"model":"iPhone15,3","systemName":"iOS","systemVersion":"17.4",
//    "name":"…","idiom":"phone","screenWidth":390,"screenHeight":844,"scale":3.0}
//
// The native capability (reading UIDevice/UIScreen) is iOS-only, so it is injected
// as a `@Sendable () -> DeviceInfo` provider. Tests inject a fixed DeviceInfo and
// assert the JSON. The convenience `init()` wires the real UIKit reads under
// `#if canImport(UIKit)`. The JSON encoding is pulled into a `static func encode`
// so it can be unit-tested directly with deterministic inputs.
public struct DeviceInfoBridge: Bridge {
    public let module = "patch"
    private let provider: @Sendable () -> DeviceInfo

    /// Cross-platform designated init: tests inject a fixed `DeviceInfo` provider.
    public init(provider: @escaping @Sendable () -> DeviceInfo) {
        self.provider = provider
    }

    #if canImport(UIKit)
    /// Convenience default init for the iOS shell: reads `UIDevice.current` and
    /// `UIScreen.main` each time the guest asks.
    public init() {
        self.init(provider: { DeviceInfoBridge.current() })
    }

    /// Read the live device snapshot from UIKit.
    private static func current() -> DeviceInfo {
        let device = UIDevice.current
        let screen = UIScreen.main
        let bounds = screen.bounds
        let idiom: String
        switch device.userInterfaceIdiom {
        case .phone: idiom = "phone"
        case .pad: idiom = "pad"
        case .tv: idiom = "tv"
        case .carPlay: idiom = "carPlay"
        case .mac: idiom = "mac"
        default: idiom = "unspecified"
        }
        return DeviceInfo(
            model: Self.hardwareModel(),
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            name: device.name,
            idiom: idiom,
            screenWidth: Double(bounds.width),
            screenHeight: Double(bounds.height),
            scale: Double(screen.scale)
        )
    }

    /// The hardware identifier (e.g. "iPhone15,3") from `uname`. `UIDevice.model`
    /// only gives the marketing category ("iPhone"), so we read `hw.machine`.
    private static func hardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
    #endif

    /// Encode a `DeviceInfo` into the JSON byte payload the guest receives.
    /// Pulled out (and unit-tested directly) so the round-trip can be asserted
    /// without a wasm instance. Keys are emitted in a stable order; doubles are
    /// rendered without spurious trailing precision (e.g. 390, 844).
    public static func encode(_ info: DeviceInfo) -> [UInt8] {
        let payload: [(String, String)] = [
            ("model", jsonString(info.model)),
            ("systemName", jsonString(info.systemName)),
            ("systemVersion", jsonString(info.systemVersion)),
            ("name", jsonString(info.name)),
            ("idiom", jsonString(info.idiom)),
            ("screenWidth", jsonNumber(info.screenWidth)),
            ("screenHeight", jsonNumber(info.screenHeight)),
            ("scale", jsonNumber(info.scale)),
        ]
        let body = payload.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        return [UInt8]("{\(body)}".utf8)
    }

    /// JSON-escape + quote a string value (handles the characters that MUST be
    /// escaped per RFC 8259: quote, backslash, and control chars).
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// Render a Double as a JSON number. Integral values are emitted without a
    /// fractional part (390, 844); fractional values keep their exact shortest
    /// decimal. JSON treats `3` and `3.0` as the same number, so an integral
    /// `scale` of 3.0 renders as `3` — spec-equivalent and free of float artifacts.
    ///
    /// Non-finite values (NaN / ±Infinity) are NOT valid JSON — `String(.nan)`
    /// emits the bare token `nan`, which makes the WHOLE `device_info` blob
    /// unparseable by the guest's `JSONDecoder` (one bad metric corrupts every
    /// field). Collapse them to `0`, matching `LocationBridge.numberString`.
    private static func jsonNumber(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return String(d)
    }

    /// The exact bytes the `device_info` host function packs: it reads the current
    /// snapshot from the injected provider and encodes it. Exposed (internally) so
    /// tests can assert the dispatch path — provider consulted, JSON correct —
    /// without needing a wasm fixture that exports a `call_device_info`.
    func snapshotPayload() -> [UInt8] {
        Self.encode(provider())
    }

    public func register(into imports: inout Imports, store: Store) {
        let provider = self.provider
        imports.host(module, "device_info", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(Self.encode(provider()))]
        }
    }
}
