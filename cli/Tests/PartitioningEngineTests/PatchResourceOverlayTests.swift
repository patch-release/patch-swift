// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
@testable import Compiler

/// Tests for the Phase-1b resource overlay (CLI producer side): the overlay-chunk
/// codec, the `POVR` artifact wrapper, and the JSON overlay-spec reader.
final class PatchResourceOverlayTests: XCTestCase {

    // MARK: - Overlay chunk codec

    func testOverlayChunkRoundTrip() throws {
        var table = PatchResourceOverlay.Table()
        table.colors["brand"] = PatchResourceOverlay.Color(
            r: 0.04, g: 0.48, b: 1.0, a: 1.0,
            dark: PatchResourceOverlay.RGBA(r: 0.2, g: 0.57, b: 1.0))
        table.colors["accent"] = PatchResourceOverlay.Color(r: 1.0, g: 0.23, b: 0.19)
        table.strings[""] = [
            "welcome": PatchResourceOverlay.StringOverride(key: "welcome", value: "Welcome back!"),
            "cta": PatchResourceOverlay.StringOverride(key: "cta", value: "Get started", table: "Onboarding"),
        ]
        table.strings["fr"] = [
            "welcome": PatchResourceOverlay.StringOverride(key: "welcome", value: "Bon retour !"),
        ]
        table.images["logo"] = PatchResourceOverlay.ImageOverride(
            kind: .inline, scale: 2, mime: "image/png", payload: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

        let bytes = PatchResourceOverlay.encode(table)
        XCTAssertTrue(PatchResourceOverlay.isOverlay(bytes))
        let decoded = try XCTUnwrap(PatchResourceOverlay.decode(bytes))
        XCTAssertEqual(decoded, table)
    }

    /// Encoding is STABLE (sorted keys), so a repeat build hashes identically.
    func testOverlayChunkEncodingIsStable() {
        var t1 = PatchResourceOverlay.Table()
        t1.colors["b"] = PatchResourceOverlay.Color(r: 0, g: 0, b: 0)
        t1.colors["a"] = PatchResourceOverlay.Color(r: 1, g: 1, b: 1)
        var t2 = PatchResourceOverlay.Table()
        t2.colors["a"] = PatchResourceOverlay.Color(r: 1, g: 1, b: 1)
        t2.colors["b"] = PatchResourceOverlay.Color(r: 0, g: 0, b: 0)
        XCTAssertEqual(PatchResourceOverlay.encode(t1), PatchResourceOverlay.encode(t2))
    }

    func testEmptyTableEncodeDecode() throws {
        let table = PatchResourceOverlay.Table()
        XCTAssertTrue(table.isEmpty)
        let bytes = PatchResourceOverlay.encode(table)
        let decoded = try XCTUnwrap(PatchResourceOverlay.decode(bytes))
        XCTAssertTrue(decoded.isEmpty)
    }

    func testCorruptOverlayDecodesToNil() {
        XCTAssertNil(PatchResourceOverlay.decode([0x00, 0x61, 0x73, 0x6d]))   // wasm magic
        // Truncated: claims 5 colors but no bytes follow.
        var blob = PatchResourceOverlay.magic + [PatchResourceOverlay.version, 0, 0, 0]
        blob += [5, 0, 0, 0]
        XCTAssertNil(PatchResourceOverlay.decode(blob))
    }

    // MARK: - POVR artifact wrapper

    func testArtifactWrapperRoundTrip() throws {
        let inner: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 42]   // a "wasm"
        var table = PatchResourceOverlay.Table()
        table.colors["brand"] = PatchResourceOverlay.Color(r: 0.1, g: 0.2, b: 0.3)
        let wrapped = PatchOverlayArtifact.package(inner: inner, table: table)

        XCTAssertTrue(PatchOverlayArtifact.isOverlayArtifact(wrapped))
        let decoded = try XCTUnwrap(PatchOverlayArtifact.decode(wrapped))
        XCTAssertEqual(decoded.inner, inner)
        let overlay = try XCTUnwrap(PatchResourceOverlay.decode(decoded.overlay))
        XCTAssertEqual(overlay.colors["brand"], table.colors["brand"])
    }

    /// An EMPTY overlay is NEVER wrapped — the artifact is byte-identical to the inner
    /// module (full back-compat: an overlay-free build ships exactly as today).
    func testEmptyTableLeavesInnerUnwrapped() {
        let inner: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 9, 9]
        let packaged = PatchOverlayArtifact.package(inner: inner, table: PatchResourceOverlay.Table())
        XCTAssertEqual(packaged, inner)
        XCTAssertFalse(PatchOverlayArtifact.isOverlayArtifact(packaged))
    }

    /// A raw wasm / PMOD blob is NOT a POVR artifact and decodes to nil.
    func testRawBlobIsNotArtifact() {
        XCTAssertNil(PatchOverlayArtifact.decode([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]))
        let pmod = PatchModuleContainer.encode([[0x00, 0x61, 0x73, 0x6d]])
        XCTAssertNil(PatchOverlayArtifact.decode(pmod))
    }

    /// The wrapper preserves a PMOD container verbatim as the inner artifact.
    func testWrapperAroundPMODContainer() throws {
        let a: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1]
        let b: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 2, 3]
        let pmod = PatchModuleContainer.encode([a, b])
        var table = PatchResourceOverlay.Table()
        table.strings[""] = ["k": PatchResourceOverlay.StringOverride(key: "k", value: "v")]
        let wrapped = PatchOverlayArtifact.package(inner: pmod, table: table)
        let decoded = try XCTUnwrap(PatchOverlayArtifact.decode(wrapped))
        XCTAssertEqual(decoded.inner, pmod)
        let parts = try XCTUnwrap(PatchModuleContainer.decode(decoded.inner))
        XCTAssertEqual(parts, [a, b])
    }

    /// Magic bytes are distinct from wasm and PMOD.
    func testMagicsDistinct() {
        XCTAssertNotEqual(PatchResourceOverlay.magic, WasmModuleMerger.wasmMagic)
        XCTAssertNotEqual(PatchResourceOverlay.magic, PatchModuleContainer.magic)
        XCTAssertNotEqual(PatchOverlayArtifact.magic, WasmModuleMerger.wasmMagic)
        XCTAssertNotEqual(PatchOverlayArtifact.magic, PatchModuleContainer.magic)
        XCTAssertNotEqual(PatchOverlayArtifact.magic, PatchResourceOverlay.magic)
    }

    // MARK: - Overlay-spec reader (the CLI authoring path)

    func testSpecReaderColors() throws {
        let json = """
        {
          "colors": {
            "brand":  { "light": "#0A7AFF", "dark": "#3391FF" },
            "accent": "#FF3B30",
            "panel":  { "light": [0.95, 0.95, 0.97, 1.0] }
          }
        }
        """
        let table = try OverlaySpecReader.parse(Data(json.utf8), baseDir: URL(fileURLWithPath: "/tmp"))
        let brand = try XCTUnwrap(table.colors["brand"])
        XCTAssertEqual(brand.r, 0x0A / 255.0, accuracy: 1e-9)
        XCTAssertEqual(brand.g, 0x7A / 255.0, accuracy: 1e-9)
        XCTAssertEqual(brand.b, 1.0, accuracy: 1e-9)
        let dark = try XCTUnwrap(brand.dark)
        XCTAssertEqual(dark.b, 1.0, accuracy: 1e-9)
        let accent = try XCTUnwrap(table.colors["accent"])
        XCTAssertNil(accent.dark)
        XCTAssertEqual(accent.r, 1.0, accuracy: 1e-9)
        let panel = try XCTUnwrap(table.colors["panel"])
        XCTAssertEqual(panel.g, 0.95, accuracy: 1e-9)
    }

    func testSpecReaderHexShortForms() throws {
        let rgb = try XCTUnwrap(OverlaySpecReader.parseHex("#abc"))
        XCTAssertEqual(rgb.r, Double(0xAA) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(rgb.g, Double(0xBB) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(rgb.b, Double(0xCC) / 255.0, accuracy: 1e-9)
        let rgba = try XCTUnwrap(OverlaySpecReader.parseHex("11223344"))
        XCTAssertEqual(rgba.a, Double(0x44) / 255.0, accuracy: 1e-9)
        XCTAssertNil(OverlaySpecReader.parseHex("#zz"))
    }

    func testSpecReaderStringsBaseAndLocale() throws {
        let json = """
        {
          "strings": {
            "welcome_title": "Welcome back!",
            "cta_button":    { "value": "Get started", "table": "Onboarding" },
            "fr": {
              "welcome_title": "Bon retour !",
              "cta_button":    { "value": "Commencer" }
            }
          }
        }
        """
        let table = try OverlaySpecReader.parse(Data(json.utf8), baseDir: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(table.strings[""]?["welcome_title"]?.value, "Welcome back!")
        XCTAssertEqual(table.strings[""]?["cta_button"]?.value, "Get started")
        XCTAssertEqual(table.strings[""]?["cta_button"]?.table, "Onboarding")
        XCTAssertEqual(table.strings["fr"]?["welcome_title"]?.value, "Bon retour !")
        XCTAssertEqual(table.strings["fr"]?["cta_button"]?.value, "Commencer")
        XCTAssertEqual(table.stringCount, 4)
    }

    func testSpecReaderImageInlineAndRef() throws {
        // Write a tiny image file to inline.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("logo@2x.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]).write(to: png)

        let json = """
        {
          "images": {
            "logo":   { "path": "logo@2x.png", "scale": 2 },
            "promo":  { "ref": "asset-123", "scale": 3 }
          }
        }
        """
        let table = try OverlaySpecReader.parse(Data(json.utf8), baseDir: dir)
        let logo = try XCTUnwrap(table.images["logo"])
        XCTAssertEqual(logo.kind, .inline)
        XCTAssertEqual(logo.scale, 2)
        XCTAssertEqual(logo.mime, "image/png")
        XCTAssertEqual(logo.payload.count, 8)
        let promo = try XCTUnwrap(table.images["promo"])
        XCTAssertEqual(promo.kind, .ref)
        XCTAssertEqual(String(decoding: promo.payload, as: UTF8.self), "asset-123")
    }

    func testSpecReaderMissingImageFileThrows() {
        let json = #"{ "images": { "logo": { "path": "nope.png" } } }"#
        XCTAssertThrowsError(
            try OverlaySpecReader.parse(Data(json.utf8), baseDir: URL(fileURLWithPath: "/tmp/does-not-exist")))
    }

    // MARK: - .Patch.yml `overlay:` key

    func testConfigOverlayKeyRoundTrips() throws {
        var cfg = PatchConfig(appKey: "k", project: "P", target: "P")
        cfg.overlaySpec = "overlay.json"
        let reparsed = try PatchConfig.parse(cfg.yamlString())
        XCTAssertEqual(reparsed.overlaySpec, "overlay.json")
    }

    func testConfigOverlayKeyAbsentIsNil() throws {
        let cfg = try PatchConfig.parse("""
        version: 1
        app_key: k
        project: P
        target: P
        """)
        XCTAssertNil(cfg.overlaySpec)
    }

    func testConfigParsesOverlayKey() throws {
        let cfg = try PatchConfig.parse("""
        version: 1
        app_key: k
        project: P
        target: P
        overlay: design/overlay.json
        """)
        XCTAssertEqual(cfg.overlaySpec, "design/overlay.json")
    }

    /// The full authoring path: spec → table → wrapped artifact → decoded back.
    func testSpecToArtifactEndToEnd() throws {
        let json = """
        {
          "colors": { "brand": "#112233" },
          "strings": { "hi": "Hello" }
        }
        """
        let table = try OverlaySpecReader.parse(Data(json.utf8), baseDir: URL(fileURLWithPath: "/tmp"))
        let inner: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
        let wrapped = PatchOverlayArtifact.package(inner: inner, table: table)
        let decoded = try XCTUnwrap(PatchOverlayArtifact.decode(wrapped))
        let back = try XCTUnwrap(PatchResourceOverlay.decode(decoded.overlay))
        XCTAssertEqual(try XCTUnwrap(back.colors["brand"]).r, Double(0x11) / 255.0, accuracy: 1e-9)
        XCTAssertEqual(back.strings[""]?["hi"]?.value, "Hello")
    }
}
