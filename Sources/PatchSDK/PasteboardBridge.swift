import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Pasteboard (clipboard)
//
// A host bridge giving OTA guests read/write access to the system clipboard
// (`UIPasteboard.general` on iOS). Three host functions under the `"patch"`
// module:
//
//   * `pasteboard_get_string() -> i64`   packed (ptr,len) of the current
//        clipboard string, or `0` if the pasteboard holds no string.
//   * `pasteboard_set_string(ptr,len)`   set the clipboard to the given UTF-8
//        string. Void.
//   * `pasteboard_has_strings() -> i32`  `1` if the pasteboard currently holds
//        a string, else `0`.
//
// Per the bridge guide's TWO HARD RULES the cross-platform core compiles on
// macOS (UIKit is iOS-only): the native capability is injected as a small
// `PasteboardProviding` protocol. The cross-platform designated init takes the
// injected provider (tests pass a spy backed by an in-memory string); the
// convenience default init wires the real `UIPasteboard.general` under
// `#if canImport(UIKit)`.

/// The injected clipboard capability. Implemented by the real iOS pasteboard
/// (default init) and by an in-memory spy (tests).
public protocol PasteboardProviding: Sendable {
    /// Current clipboard string, or nil if the pasteboard holds no string.
    func getString() -> String?
    /// Replace the clipboard string with `value`.
    func setString(_ value: String)
    /// Whether the pasteboard currently holds a string.
    func hasStrings() -> Bool
}

public struct PasteboardBridge: Bridge {
    public let module = "patch"
    private let provider: PasteboardProviding

    /// Cross-platform designated init — inject the clipboard capability. Used by
    /// tests (spy) and by the default init (real `UIPasteboard`).
    public init(provider: PasteboardProviding) {
        self.provider = provider
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real `UIPasteboard.general` (iOS).
    public init() {
        self.init(provider: UIPasteboardProvider())
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let provider = self.provider

        // pasteboard_get_string() -> i64 packed (ptr,len); 0 if empty/no string.
        imports.host(module, "pasteboard_get_string", [], [.i64], store: store) { caller, _ in
            let ctx = BridgeContext(caller: caller)
            return [try ctx.packedResult(provider.getString())]
        }

        // pasteboard_set_string(ptr, len) -> [] — copy a UTF-8 string in.
        imports.host(module, "pasteboard_set_string", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let value = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            provider.setString(value)
            return []
        }

        // pasteboard_has_strings() -> i32 (1/0).
        imports.host(module, "pasteboard_has_strings", [], [.i32], store: store) { _, _ in
            [.i32(provider.hasStrings() ? 1 : 0)]
        }
    }
}

#if canImport(UIKit)
/// Real iOS clipboard, backed by `UIPasteboard.general`.
struct UIPasteboardProvider: PasteboardProviding {
    func getString() -> String? { UIPasteboard.general.string }
    func setString(_ value: String) { UIPasteboard.general.string = value }
    func hasStrings() -> Bool { UIPasteboard.general.hasStrings }
}
#endif
