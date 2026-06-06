import Foundation
import WasmKit
#if canImport(CoreNFC)
import CoreNFC
#endif

// MARK: - NfcReadBridge (begin an NFC NDEF read session)
//
// `begin_nfc_read(ptr,len) -> []` — present the system NFC scanning sheet to read
// an NDEF tag. The guest passes a UTF-8 prompt string `(ptr,len)` shown on the
// scanning UI; the host hands it to an injected presenter. Fire-and-forget — no
// result is returned synchronously to the guest. The scanned payload is delivered
// **natively** through the CoreNFC reader-session delegate (the iOS shell routes
// it back into the app), exactly the same shape as a UIKit picker bridge:
// present-and-forget at the bridge boundary, native callback delivers the data.
//
// ## Cross-platform core + injected dependency (Rule 2)
// `NFCNDEFReaderSession` is CoreNFC-only, so the native capability is injected as a
// `@Sendable (_ prompt: String) -> Void` presenter. The bridge struct + its
// `register(...)` + the prompt-normalisation logic therefore compile on macOS (no
// direct CoreNFC at the top level); tests inject a spy and assert the normalised
// prompt. The convenience `init()` begins a real `NFCNDEFReaderSession` (only when
// `NFCNDEFReaderSession.readingAvailable`), guarded by `#if canImport(CoreNFC)`.
public struct NfcReadBridge: Bridge {
    /// The injected native capability: begin an NDEF read session showing `prompt`.
    public typealias Present = @Sendable (_ prompt: String) -> Void

    public let module = "patch"
    private let present: Present

    /// Cross-platform designated init — tests inject a spy here.
    public init(present: @escaping Present) {
        self.present = present
    }

    #if canImport(CoreNFC)
    /// Convenience default init beginning a real `NFCNDEFReaderSession`. A single
    /// session holder owns the in-flight session + delegate (CoreNFC requires a
    /// retained delegate for the session's lifetime). No-op when NFC reading is
    /// unavailable (e.g. unsupported device). Guarded by `canImport(CoreNFC)` so the
    /// macOS host build never references CoreNFC.
    public init() {
        self.init(present: { prompt in NfcSessionHolder.shared.begin(prompt: prompt) })
    }
    #endif

    /// Normalise the alert prompt shown on the scanning sheet. Trims surrounding
    /// whitespace/newlines; an empty/blank prompt falls back to a sensible default.
    /// Pure + unit-tested directly so the prompt handling is asserted without
    /// CoreNFC.
    public static func normalizePrompt(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Hold your iPhone near the tag." : trimmed
    }

    public func register(into imports: inout Imports, store: Store) {
        let present = self.present
        imports.host(module, "begin_nfc_read", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let raw = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            present(Self.normalizePrompt(raw))
            return []
        }
    }
}

#if canImport(CoreNFC)
/// Owns the in-flight `NFCNDEFReaderSession` + its delegate. CoreNFC requires the
/// delegate to be retained for the session's lifetime, so a single shared holder
/// keeps it alive. Scanned messages are delivered natively through the delegate
/// (the bridge call itself is fire-and-forget). Begins on the main thread.
private final class NfcSessionHolder: NSObject, @unchecked Sendable {
    static let shared = NfcSessionHolder()

    private let lock = NSLock()
    private var session: NFCNDEFReaderSession?

    func begin(prompt: String) {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        let start: @Sendable () -> Void = { [self] in
            let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
            s.alertMessage = prompt
            lock.lock(); session = s; lock.unlock()
            s.begin()
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async { start() } }
    }

    // MARK: NFCNDEFReaderSessionDelegate
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Native delivery point: the iOS shell routes `messages` back into the app.
        // (No synchronous path back to the guest; this bridge is present-and-forget.)
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        lock.lock(); self.session = nil; lock.unlock()
    }
}
#endif
