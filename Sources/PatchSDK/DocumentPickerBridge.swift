import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

// MARK: - DocumentPickerBridge (system services)
//
// present_document_picker(ptr,len) — open the system document picker so the user
//   can import (pick) or export (place) a document. The guest passes a JSON
//   object `{"mode":"import|export","types":["public.json"]}` as `(ptr,len)`; the
//   host decodes it to a `PickerRequest` and hands it to an injected closure.
// export_document(ptr,len)        — write a file out via the document picker. The
//   guest passes `{"filename":"…","data_base64":"…"}`; the host decodes it (and
//   base64-decodes the payload) to an `ExportRequest` and hands it off.
//
// Both are fire-and-forget: the picker is interactive, so no result is returned
// to the guest call. The native shell delivers the picked URL / written file
// back natively (e.g. via NavigationBridge or a notification), out of band.
//
// Like NavigationBridge / ShareSheetBridge, the native capability is injected as
// a `@Sendable` closure so the bridge compiles + unit-tests on macOS (no UIKit
// at the top level). The cross-platform designated init takes the handlers the
// tests inject; the `#if canImport(UIKit)` convenience `init()` wires a real
// `UIDocumentPickerViewController`, presented from the key window's top view
// controller.
public struct DocumentPickerBridge: Bridge {
    /// A decoded `present_document_picker` request.
    public struct PickerRequest: Sendable, Equatable {
        /// "import" (pick existing) or "export" (place new). Free-form String so
        /// an unknown mode still reaches the handler verbatim.
        public let mode: String
        /// UTI / content types to constrain the picker (e.g. "public.json").
        public let types: [String]
        public init(mode: String, types: [String]) {
            self.mode = mode
            self.types = types
        }
    }

    /// A decoded `export_document` request — the bytes already base64-decoded.
    public struct ExportRequest: Sendable, Equatable {
        public let filename: String
        public let data: Data
        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// Present the document picker for the given request.
    public typealias PresentHandler = @Sendable (_ request: PickerRequest) -> Void
    /// Export (write out) a document for the given request.
    public typealias ExportHandler = @Sendable (_ request: ExportRequest) -> Void

    public let module = "patch"
    private let present: PresentHandler
    private let exportDoc: ExportHandler

    /// Cross-platform designated init. Tests inject spies that record the decoded
    /// requests; apps can inject any custom presenter/exporter.
    public init(present: @escaping PresentHandler, export: @escaping ExportHandler) {
        self.present = present
        self.exportDoc = export
    }

    #if canImport(UIKit)
    /// Convenience default init that presents a real
    /// `UIDocumentPickerViewController` from the key window's top view
    /// controller. iOS-only.
    public init() {
        self.init(
            present: { request in
                DocumentPickerBridge.presentPicker(request)
            },
            export: { request in
                DocumentPickerBridge.exportDocument(request)
            })
    }
    #endif

    /// Decode the `present_document_picker` JSON payload into a `PickerRequest`.
    ///
    /// Missing / non-string `mode` → "" ; missing / non-array `types` → [] ;
    /// non-string entries in `types` are dropped. Invalid / non-object JSON →
    /// `nil`. Pulled out as a pure `static` func so the decode is unit-tested
    /// directly (per the bridge guide).
    public static func parsePicker(_ bytes: [UInt8]) -> PickerRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return nil
        }
        let mode = obj["mode"] as? String ?? ""
        let types = (obj["types"] as? [Any])?.compactMap { $0 as? String } ?? []
        return PickerRequest(mode: mode, types: types)
    }

    /// Decode the `export_document` JSON payload into an `ExportRequest`,
    /// base64-decoding `data_base64`.
    ///
    /// Missing / non-string `filename` → "" ; missing / non-string / malformed
    /// `data_base64` → empty `Data`. Invalid / non-object JSON → `nil`. Pure +
    /// directly unit-tested.
    public static func parseExport(_ bytes: [UInt8]) -> ExportRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return nil
        }
        let filename = obj["filename"] as? String ?? ""
        let data: Data
        if let b64 = obj["data_base64"] as? String, let decoded = Data(base64Encoded: b64) {
            data = decoded
        } else {
            data = Data()
        }
        return ExportRequest(filename: filename, data: data)
    }

    public func register(into imports: inout Imports, store: Store) {
        let present = self.present
        let exportDoc = self.exportDoc
        imports.host(module, "present_document_picker", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let request = Self.parsePicker(bytes) {
                present(request)
            }
            return []
        }
        imports.host(module, "export_document", [.i32, .i32], [], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            if let request = Self.parseExport(bytes) {
                exportDoc(request)
            }
            return []
        }
    }

    #if canImport(UIKit)
    /// Present a real `UIDocumentPickerViewController` for the request from the
    /// key window's top view controller on the main thread. Used for the
    /// interactive "import" path (and as a placeholder for "export" mode, whose
    /// concrete write path is `export_document`).
    private static func presentPicker(_ request: PickerRequest) {
        let types = request.types
        DispatchQueue.main.async {
            guard let presenter = topViewController() else { return }
            let contentTypes = types.compactMap { UTType($0) }
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: contentTypes.isEmpty ? [.item] : contentTypes)
            presenter.present(picker, animated: true)
        }
    }

    /// Write `request.data` to a temporary file and present a
    /// `UIDocumentPickerViewController` for exporting it on the main thread.
    private static func exportDocument(_ request: ExportRequest) {
        let filename = request.filename.isEmpty ? "export" : request.filename
        let data = request.data
        DispatchQueue.main.async {
            guard let presenter = topViewController() else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: tmp)
            } catch {
                return
            }
            let picker = UIDocumentPickerViewController(forExporting: [tmp])
            presenter.present(picker, animated: true)
        }
    }

    /// Walk from the key window's root to the topmost presented/visible view
    /// controller so the picker is presented from the right place.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while true {
            if let presented = top?.presentedViewController {
                top = presented
            } else if let nav = top as? UINavigationController {
                top = nav.visibleViewController ?? nav.topViewController
            } else if let tab = top as? UITabBarController {
                top = tab.selectedViewController ?? top
            } else {
                break
            }
        }
        return top
    }
    #endif
}
