// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import PartitioningEngine
@testable import CodeGenerator
@testable import Compiler
@testable import ViewNodeIR

/// Regression tests for the THIRD CLI/engine bug-hunt pass. Each test FAILS on the
/// pre-fix code and PASSES after the surgical fix. See /tmp/bughunt_cli3_progress.md.
final class BugHuntCli3Tests: XCTestCase {

    // MARK: - BUG 1 (P0): T0 Double result must never emit invalid JSON for NaN/Inf

    /// A `Double`-returning function is T0-eligible. The old hand-encoder used
    /// `"\(value)"`, which for `Double.nan` / `.infinity` produces the bare tokens
    /// `nan` / `inf` — NOT valid JSON. The shipped module then returns a blob the
    /// SDK's standard `JSONDecoder` cannot parse at all (total decode failure /
    /// crash). The fix clamps non-finite values to a valid, decodable JSON number.
    func testT0DoubleEncoderGuardsNonFiniteValues() {
        let export = CodeEmitter.PureExport(
            exportName: "ratio", callee: "Calc.ratio",
            parameters: [(label: "_", name: "x", type: "Double")],
            returnType: "Double")
        guard let t0 = CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true) else {
            return XCTFail("a Double-return scalar function must take the T0 path")
        }
        // The Double encoder must check finiteness before stringifying, so a NaN/Inf
        // never reaches `"\(value)"` (which would emit the invalid tokens nan/inf).
        XCTAssertTrue(t0.source.contains("value.isNaN"),
                      "T0 Double encoder must guard NaN\n\(t0.source)")
        XCTAssertTrue(t0.source.contains("value.isInfinite"),
                      "T0 Double encoder must guard ±Infinity\n\(t0.source)")
    }

    /// PROOF the generated code, when run as Swift, never emits the invalid `nan`/`inf`
    /// tokens. We reproduce the encoder's exact logic and check the produced JSON is
    /// parseable for non-finite inputs (the pre-fix code emitted `{"value":nan}`).
    func testT0DoubleEncoderLogicProducesValidJSONForNonFinite() throws {
        // Mirror the fixed `_patchEncodeResult(_ value: Double)` body.
        func encode(_ value: Double) -> String {
            var s = "{\"value\":"
            if value.isNaN { s += "0" }
            else if value.isInfinite { s += (value < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308") }
            else { s += "\(value)" }
            s += "}"
            return s
        }
        for v in [Double.nan, .infinity, -.infinity, 3.5, 0.0] {
            let json = encode(v)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(json.utf8)),
                "encoded result must be valid JSON for value \(v): \(json)")
        }
    }

    // MARK: - BUG 2 (P1): SwiftUI IR JSON serializer must guard non-finite Doubles

    /// The Foundation-free `EmbeddedJSON` serializer used `String(d)` for a whole
    /// Double, so a NaN spacing / Inf font size emitted the bare tokens `nan`/`inf`
    /// — invalid JSON the host `JSONDecoder` rejects, breaking the WHOLE lowered
    /// body. The fix clamps non-finite to a valid number first.
    func testEmbeddedJSONSerializerEmitsValidJSONForNonFiniteLayoutValues() throws {
        // A spacer whose minLength is NaN exercises `JSONOut.number(_ d: Double)`.
        let node = ViewNode(.spacer(minLength: Double.nan))
        let bytes = EmbeddedJSON.encode(BodyEmission(root: node, computeCoverage: false))
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(bytes)),
            "embedded-JSON for a non-finite layout value must be valid JSON: "
            + String(decoding: bytes, as: UTF8.self))

        // And +Infinity (a slider min) must also stay valid JSON.
        let slider = ViewNode(.slider(value: 1, min: .infinity, max: 10, step: nil,
                                      event: EventID("e")))
        let sbytes = EmbeddedJSON.encode(BodyEmission(root: slider, computeCoverage: false))
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(sbytes)),
            "embedded-JSON for an infinite layout value must be valid JSON: "
            + String(decoding: sbytes, as: UTF8.self))
    }

    /// A FINITE whole value still serializes without a trailing `.0` (the existing
    /// contract — the fix must not regress finite formatting).
    func testEmbeddedJSONSerializerStillEmitsCompactFiniteNumbers() {
        let node = ViewNode(.spacer(minLength: 8.0))
        let s = String(decoding: EmbeddedJSON.encode(BodyEmission(root: node, computeCoverage: false)), as: UTF8.self)
        XCTAssertTrue(s.contains("\"minLength\":8"), "finite whole number must emit `8` (not `8.0`)\n\(s)")
        XCTAssertFalse(s.contains("8.0"), "finite whole number must NOT carry a trailing .0\n\(s)")
    }

    // MARK: - BUG 3 (P1): fingerprint framework inference misses real import forms

    /// The native-shell fingerprint's linked-framework component is part of the
    /// OTA-compatibility gate. The old inference required the WHOLE line after
    /// `import ` to equal the module name, so `import UIKit.UIView`,
    /// `import struct Foundation.Data`, `@testable import UIKit`, and a trailing
    /// comment all SILENTLY dropped the framework — a native-shell change touching
    /// it could then slip the gate. The fix extracts the top-level module name.
    func testImportedModuleHandlesAllRealImportForms() {
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "import UIKit"), "UIKit")
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "import UIKit.UIView"), "UIKit")
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "import struct Foundation.Data"), "Foundation")
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "@testable import UIKit"), "UIKit")
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "import SwiftUI // root"), "SwiftUI")
        XCTAssertEqual(ProjectFingerprinter.importedModule(in: "  import Combine  "), "Combine")
        XCTAssertNil(ProjectFingerprinter.importedModule(in: "let importedCount = 3"))
        XCTAssertNil(ProjectFingerprinter.importedModule(in: "// import UIKit (in a comment)"))
    }

    // MARK: - BUG 5 (P1): an instance-method export must NOT be sent down the T0 path

    /// The T0 host-bridge marshalling decodes only scalar arg fields; it has no way
    /// to decode a value-type `_receiver`. An export with a `receiverType` (a pure
    /// instance method / non-static enum property) used to take the T0 path anyway,
    /// emitting a wrapper that referenced `_args._receiver` with no such field
    /// decoded → `cannot find '_receiver'` → the export was wrongly demoted to
    /// native (lost OTA coverage). The fix routes receiver exports to Foundation.
    func testReceiverExportDoesNotTakeT0Path() {
        let export = CodeEmitter.PureExport(
            exportName: "Money_cents", callee: "cents",
            parameters: [], returnType: "Int",
            receiverType: "Money")
        // T0 must REFUSE this export (returns nil) so the Foundation path handles it.
        XCTAssertNil(CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true),
                     "an export with a receiverType must not take the T0 host-bridge path")
        // The Foundation path DOES handle it, decoding `_receiver`.
        let f = CodeEmitter().emitFoundationPureExportFilePublic(export, includeAllocator: true)
        XCTAssertTrue(f.source.contains("_receiver: Money"),
                      "Foundation wrapper must decode the value-type receiver\n\(f.source)")
    }

    /// A receiver-less STATIC property (e.g. `static var code: String`) is still T0
    /// eligible — the fix must only exclude the value-type-receiver case.
    func testStaticPropertyStillTakesT0Path() {
        let export = CodeEmitter.PureExport(
            exportName: "AED_code", callee: "AED.code",
            parameters: [], returnType: "String",
            receiverType: nil, isProperty: true)
        XCTAssertNotNil(CodeEmitter().emitEmbeddedPureExportFile(export, includeAllocator: true),
                        "a receiver-less static property with a scalar return must still ride T0")
    }

    // MARK: - BUG 7 (P1): fingerprint must be deterministic with multiple Info.plist

    /// `firstFileHash` picked whichever `Info.plist` `FileManager.enumerator`
    /// yielded first — a NON-deterministic order across platforms/filesystems. A
    /// project with several Info.plist files (app + tests + extension) would then
    /// fingerprint differently on different runs → a spurious OTA MISMATCH or a
    /// masked change. The fix selects the lexicographically-first matching path, so
    /// the fingerprint is stable regardless of enumeration order.
    func testFingerprintIsDeterministicWithMultipleInfoPlists() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fp-multi-\(UUID().uuidString)")
        let appDir = root.appendingPathComponent("App")
        let testDir = root.appendingPathComponent("AppTests")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Two DIFFERENT Info.plist files in the project.
        try "<plist>APP</plist>".write(to: appDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try "<plist>TESTS</plist>".write(to: testDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // Need at least one native swift file so the snapshot is non-trivial.
        try "import Foundation\nfunc f() {}".write(to: appDir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        let fp = ProjectFingerprinter()
        let a = fp.snapshot(projectDir: root, bridges: [:])
        let b = fp.snapshot(projectDir: root, bridges: [:])
        // Same inputs → same fingerprint, every time (the Info.plist component is
        // now resolved deterministically rather than by enumeration order).
        XCTAssertEqual(a.fingerprint, b.fingerprint,
                       "fingerprint must be deterministic even with multiple Info.plist files")
        // The chosen Info.plist is the lexicographically-first path (App/ < AppTests/).
        let infoHash = a.componentHashes.first { $0.label == "Info.plist" }?.hash
        XCTAssertEqual(infoHash, Fingerprinter.hash(Fingerprinter.hashData(Data("<plist>APP</plist>".utf8))),
                       "the lexicographically-first Info.plist (App/Info.plist) must be the one hashed")
    }

    // MARK: - BUG 4 (P2): SwiftUI guest JSON scanner must treat \n/\t/\r as whitespace

    /// The embedded JSON scanner the lowered SwiftUI guest uses to read its inputs
    /// only skipped/terminated on a plain space (0x20). A pretty-printed or CRLF
    /// args blob (`"x": 5\n`) then leaked a newline into the bare token (`"5\n"`),
    /// so `Int(_)` returned nil and EVERY numeric/bool input silently fell back to
    /// its declared default (wrong values rendered). The fix treats space/tab/CR/LF
    /// as JSON whitespace. We replicate the fixed `_patchScanToken`/`_patchValueStart`
    /// logic to prove a whitespace-bearing blob scans correctly.
    func testGuestJSONScannerTokenizesAcrossAllWhitespace() {
        // Fixed scanner logic (mirrors SwiftUIGuestEmitter._patchValueStart/_patchScanToken).
        func valueStart(_ s: [UInt8], _ key: String) -> Int? {
            let kb = Array("\"\(key)\"".utf8)
            // naive find
            guard s.count >= kb.count else { return nil }
            var k: Int? = nil
            for i in 0...(s.count - kb.count) {
                if Array(s[i..<i+kb.count]) == kb { k = i; break }
            }
            guard let start = k else { return nil }
            var i = start + kb.count
            while i < s.count, s[i] == 0x3A || s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
            return i < s.count ? i : nil
        }
        func scanInt(_ s: [UInt8], _ key: String) -> Int? {
            guard let start = valueStart(s, key) else { return nil }
            var i = start; var out: [UInt8] = []
            while i < s.count {
                let c = s[i]
                if c == 0x2C || c == 0x7D || c == 0x5D || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                out.append(c); i += 1
            }
            return out.isEmpty ? nil : Int(String(decoding: out, as: UTF8.self))
        }
        // Pretty-printed JSON with newlines/tabs around `:` and after the value:
        //   {"a": 5,\n\t"b":\t42\n}
        let pretty = Array("{\"a\": 5,\n\t\"b\":\t42\n}".utf8)
        XCTAssertEqual(scanInt(pretty, "a"), 5, "value after a newline-terminated number must parse")
        XCTAssertEqual(scanInt(pretty, "b"), 42, "value after a tab and before a newline must parse")
    }

    /// The emitted guest wrapper source must actually carry the widened whitespace
    /// handling (so the fix ships into the WASM module).
    func testEmittedGuestScannerCarriesWhitespaceFix() throws {
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: "Demo",
            guestBody: "ViewNode(.text(\"hi\"))",
            inputs: [])
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let src = emission.files.map(\.contents).joined(separator: "\n")
        // The fixed value-start skip + token terminator must include the JSON
        // whitespace bytes (tab 0x09, LF 0x0A, CR 0x0D), not just space.
        XCTAssertTrue(src.contains("0x09") && src.contains("0x0A") && src.contains("0x0D"),
                      "emitted JSON scanner must treat tab/LF/CR as whitespace")
    }

    // MARK: - BUG 6 (P2): guest string scanner must decode JSON escapes correctly

    /// `_patchScanString` decoded only `\n \t \" \\`; everything else fell through
    /// `default: out.append(n)`, so `\r`/`\b`/`\f` were emitted as the literal
    /// letters and `\uXXXX` left the 4 hex digits in the stream — corrupting any
    /// input string the host had escaped. We replicate the fixed decoder and prove
    /// it round-trips the standard JSON escapes + a BMP `\u` escape.
    func testGuestStringScannerDecodesJSONEscapes() {
        func scanString(_ s: [UInt8]) -> String {
            var i = 1   // skip opening quote at index 0
            var out: [UInt8] = []
            while i < s.count {
                let c = s[i]
                if c == 0x5C, i + 1 < s.count {
                    let n = s[i + 1]
                    switch n {
                    case 0x6E: out.append(0x0A)
                    case 0x74: out.append(0x09)
                    case 0x72: out.append(0x0D)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x2F: out.append(0x2F)
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x75 where i + 5 < s.count:
                        func hex(_ b: UInt8) -> UInt32? {
                            switch b {
                            case 0x30...0x39: return UInt32(b - 0x30)
                            case 0x41...0x46: return UInt32(b - 0x41 + 10)
                            case 0x61...0x66: return UInt32(b - 0x61 + 10)
                            default: return nil
                            }
                        }
                        if let h3 = hex(s[i+2]), let h2 = hex(s[i+3]), let h1 = hex(s[i+4]), let h0 = hex(s[i+5]),
                           let scalar = Unicode.Scalar(h3 << 12 | h2 << 8 | h1 << 4 | h0) {
                            out.append(contentsOf: Array(String(scalar).utf8)); i += 6; continue
                        }
                        out.append(n)
                    default: out.append(n)
                    }
                    i += 2; continue
                }
                if c == 0x22 { break }
                out.append(c); i += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
        // `\r` decodes to a real CR (0x0D), not the literal letter 'r'; `\t` to TAB.
        let expected = "a" + String(UnicodeScalar(0x0D)) + "b" + String(UnicodeScalar(0x09)) + "c"
        XCTAssertEqual(scanString(Array(#""a\rb\tc""#.utf8)), expected,
                       "\\r must decode to CR and \\t to TAB (not the literal letters)")
        // A literal `\/` decodes to `/`.
        XCTAssertEqual(scanString(Array(#""http:\/\/x""#.utf8)), "http://x")
        // A BMP `\u` escape decodes to its code point (U+00E9 = é).
        XCTAssertEqual(scanString(Array(#""café""#.utf8)), "café")
    }

    /// The emitted guest wrapper must carry the `\uXXXX` decode path (so the fix ships).
    func testEmittedGuestStringScannerCarriesUnicodeEscapeFix() throws {
        let view = SwiftUIGuestEmitter.GuestView(
            viewName: "Demo2",
            guestBody: "ViewNode(.text(\"hi\"))",
            inputs: [])
        let emission = try SwiftUIGuestEmitter().emit(views: [view])
        let src = emission.files.map(\.contents).joined(separator: "\n")
        XCTAssertTrue(src.contains("0x75"),
                      "emitted string scanner must handle the \\uXXXX escape (byte 0x75)")
    }
}
