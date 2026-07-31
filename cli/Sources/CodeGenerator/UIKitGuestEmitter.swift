// SPDX-License-Identifier: Apache-2.0

// UIKitGuestEmitter.swift — emits the UIKit guest WASM module that ships a lowered
// cell construction.
// =============================================================================
// The UIKit analogue of `SwiftUIGuestEmitter`. Given a `UIKitCellLowering.LoweredCell`
// (its `UI.`-builder expression + the model inputs), it produces a self-contained
// guest compile unit:
//
//   * the embeddable UIKit IR sources (UIKitNode + UIKitBuilder + UIKitJSONEmit) AND
//     the SwiftUI IR sources (ViewNode + JSONEmit — they carry the SHARED value
//     types `IRColor`/`ColorRef`/`IRFont`/`EventID` + the `JSONOut`/`EmbeddedJSON`
//     plumbing the UIKit emitter reuses; a UIKit guest ships BOTH), and
//   * a `_PatchUIKit.swift` wrapper with the SDK `patch_malloc`/`patch_free`
//     allocator, the Foundation-free input scanners (REUSED verbatim from the
//     SwiftUI emitter's preamble — the SAME flat-JSON marshalling), and one
//     `@_cdecl("uikit_configure__<Cell>")(ptr,len) -> i64` export per lowered cell.
//     Each export binds the marshalled model fields, BUILDS the `UIKitNode` tree via
//     the emitted `UI.` expression, and returns the packed (ptr,len) of the
//     JSON-encoded `UIKitEmission` (via the Foundation-free `UIKitEmbeddedJSON`).
//
// ## Wire format (the contract the SDK UIKit host must match)
//   * ABI: `uikit_configure[/__<Cell>](ptr,len) -> i64` packed `(outPtr<<32)|outLen`.
//   * Payload: JSON of `UIKitEmission` = `{ "root": <UIKitNode>, "coverage": {…}? }`,
//     Swift's synthesized-Codable shape, which `UIKitEmbeddedJSON` reproduces.
//   * A `patch_uikit_manifest` export carries a compile-time JSON literal describing
//     every lowered cell (type → export/thunkSafe), so the SDK host decides routing.
//
// The single `uikit_configure` export (no suffix) is also emitted for the FIRST cell,
// so a single-cell module keeps a canonical export name.

import Foundation

public struct UIKitGuestEmitter {
    public init() {}

    /// A lowered cell ready to emit into the guest module.
    public struct GuestCell: Sendable {
        public let typeName: String
        /// The `UI.<…>` expression that builds the UIKitNode tree.
        public let guestBody: String
        /// The model fields the body reads, marshalled in from the flat JSON blob.
        public let inputs: [BodyLowering.ViewInput]
        /// Whether the cell lowered with no unslotable leaf + no unmarshalled input —
        /// surfaced in the manifest so the SDK host auto-routes only safe cells.
        public let thunkSafe: Bool

        public init(typeName: String, guestBody: String,
                    inputs: [BodyLowering.ViewInput], thunkSafe: Bool) {
            self.typeName = typeName
            self.guestBody = guestBody
            self.inputs = inputs
            self.thunkSafe = thunkSafe
        }

        /// Build directly from a lowering result.
        public init(from lowered: UIKitCellLowering.LoweredCell) {
            self.init(typeName: lowered.typeName, guestBody: lowered.guestBody,
                      inputs: lowered.inputs, thunkSafe: lowered.thunkSafe)
        }
    }

    public typealias File = SwiftUIGuestEmitter.File

    public struct Emission: Sendable {
        public let files: [File]
        public let exports: [String]
        public init(files: [File], exports: [String]) {
            self.files = files; self.exports = exports
        }
    }

    /// The manifest export name (must match the SDK host's `PatchUIKitManifest.exportName`).
    public static let manifestExport = "patch_uikit_manifest"
    /// The manifest schema version (independent of the SwiftUI view manifest's).
    public static let manifestSchemaVersion = 1

    /// The guest export symbol for a cell's configure. The FIRST cell also gets the
    /// bare `uikit_configure` (the canonical single-cell contract).
    public static func exportSymbol(forCell name: String) -> String {
        "uikit_configure__" + SwiftUIGuestEmitter.sanitizedViewName(name)
    }

    /// Emit the complete UIKit guest module (IR sources + wrapper) for `cells`.
    public func emit(cells: [GuestCell]) throws -> Emission {
        let su = SwiftUIGuestEmitter()
        // SHARED + UIKit IR sources. The UIKit IR reuses `IRColor`/`ColorRef`/`IRFont`/
        // `EventID` + the `JSONOut`/`EmbeddedJSON` plumbing declared in the SwiftUI IR,
        // so we ship BOTH (never the UIKit IR alone).
        var files = try su.irSources()
        files.append(contentsOf: try su.uikitIRSources())
        var exports = ["patch_malloc", "patch_free"]

        var wrapper = Self.preamble

        var firstEmitted = false
        var manifestEntries: [String] = []
        for (i, cell) in cells.enumerated() {
            let sym = Self.exportSymbol(forCell: cell.typeName)
            let body = cell.guestBody.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        " + $0 }.joined(separator: "\n")
            let binds = Self.inputBindings(cell.inputs)
            let buildSym = "_patchBuildUIKit__" + SwiftUIGuestEmitter.sanitizedViewName(cell.typeName)
            wrapper += """

            // Build the lowered `\(cell.typeName)` tree from a flat model JSON blob.
            private func \(buildSym)(_ _patchInputs: [UInt8]) -> UIKitNode {
            \(binds)
                let root: UIKitNode =
            \(body)
                return root
            }

            /// Lowered construction of `\(cell.typeName)` — built + serialized in WASM.
            @_cdecl("\(sym)")
            public func \(sym)(_ ptr: Int32, _ len: Int32) -> Int64 {
                let root = \(buildSym)(_patchReadBytes(ptr, len))
                let cov = UIKitCoverage(totalNodes: root.nodeCount,
                                        slotNodes: root.slotNodeCount,
                                        totalConstraints: root.constraintCount)
                let emission = UIKitEmission(root: root, coverage: cov)
                return _patchEmit(UIKitEmbeddedJSON.encode(emission))
            }

            """
            exports.append(sym)

            if i == 0 {
                wrapper += """

                @_cdecl("uikit_configure")
                public func uikit_configure(_ ptr: Int32, _ len: Int32) -> Int64 {
                    \(sym)(ptr, len)
                }

                """
                exports.append("uikit_configure")
                firstEmitted = true
            }
            _ = firstEmitted

            manifestEntries.append(
                "{\"type\":\"\(SwiftUIGuestEmitter.sanitizedViewName(cell.typeName))\","
                + "\"export\":\"\(sym)\","
                + "\"thunkSafe\":\(cell.thunkSafe ? "true" : "false")}")
        }

        // The UIKit view manifest export (compile-time JSON literal).
        let manifestJSON = "{\"schemaVersion\":\(Self.manifestSchemaVersion),\"cells\":["
            + manifestEntries.joined(separator: ",") + "]}"
        wrapper += """

        // MARK: - UIKit cell manifest (out-of-the-box auto-routing)

        @_cdecl("\(Self.manifestExport)")
        public func \(Self.manifestExport)(_ ptr: Int32, _ len: Int32) -> Int64 {
            _ = (ptr, len)
            let json = "\(SwiftUIGuestEmitter.swiftStringLiteralBody(manifestJSON))"
            return _patchEmit(Array(json.utf8))
        }

        """
        exports.append(Self.manifestExport)

        files.append(File(fileName: "_PatchUIKit.swift", contents: wrapper))
        return Emission(files: files, exports: exports)
    }

    /// The model-field bindings: each input decoded from the flat JSON blob with a
    /// fallback to its default. The flat field NAME is the marshalled key (`title`),
    /// stripping any `model.` prefix the lowering kept on the input name. Reuses the
    /// SAME scanners the SwiftUI guest preamble declares.
    static func inputBindings(_ inputs: [BodyLowering.ViewInput]) -> String {
        guard !inputs.isEmpty else { return "    _ = _patchInputs" }
        var lines: [String] = []
        for inp in inputs {
            let key = UIKitEmitter.flatInputName(inp.name)
            switch inp.kind {
            case .string:
                lines.append("    let \(key) = _patchScanString(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .bool:
                lines.append("    let \(key) = _patchScanBool(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .int:
                lines.append("    let \(key) = _patchScanInt(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .double:
                lines.append("    let \(key) = _patchScanDouble(_patchInputs, \"\(key)\") ?? Double(\(inp.defaultLiteral))")
            case .intArray:
                lines.append("    let \(key) = _patchScanIntArray(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .doubleArray:
                lines.append("    let \(key) = _patchScanDoubleArray(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .boolArray:
                lines.append("    let \(key) = _patchScanBoolArray(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .stringArray:
                lines.append("    let \(key) = _patchScanStringArray(_patchInputs, \"\(key)\") ?? \(inp.defaultLiteral)")
            case .structArray, .flatStruct, .enumValue, .unsupported:
                // A `.structArray`/`.flatStruct`/`.enumValue`/`.unsupported` model field
                // that the body actually READS makes the cell `referencesUnmarshalledInput`
                // ⇒ it's EXCLUDED from emission upstream (never reaches here). (UIKit cell
                // lowering builds its own scalar inputs and never assigns the SwiftUI-only
                // `.flatStruct`/`.enumValue` kinds.) Emit no binding (dead code).
                break
            }
        }
        lines.append("    _ = _patchInputs")
        return lines.joined(separator: "\n")
    }
}
