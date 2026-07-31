// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Patch OVERLAY ARTIFACT wrapper — a thin outer envelope that bundles an
/// optional resource-overlay chunk (`PatchResourceOverlay`) IN FRONT OF the existing
/// WASM artifact (a raw `.wasm` OR a `PMOD` container), as ONE blob.
///
/// ## Why a wrapper (and not extending `PMOD`)
/// The `PMOD` container is decoded into independent WasmKit *runtimes* — it is a list
/// of WASM modules and nothing else. The resource overlay is NON-WASM data, so folding
/// it into `PMOD` would tangle two concerns. Instead the overlay rides as an OUTER
/// envelope: `[POVR header][overlay chunk][inner artifact]`. On device the SDK strips
/// the overlay (installs it as the name-lookup redirection table) and hands the INNER
/// bytes — byte-for-byte the same raw `.wasm` / `PMOD` it ships today — to the
/// unchanged module-instantiation path. This keeps the WASM pipeline 100% untouched and
/// is fully back-compatible: a patch with NO overlay is NEVER wrapped (the artifact is
/// byte-identical to today), and an old SDK that doesn't know `POVR` still treats a raw
/// `.wasm`/`PMOD` exactly as before.
///
/// The backend stays oblivious: it stores/serves/SHAs/diffs the whole blob as opaque
/// bytes (it already never parses the wasm magic), so the overlay rides the EXISTING
/// upload/download/storage/diff path with NO contract change.
///
/// ## Wire format (little-endian) — KEEP IN SYNC with the SDK decoder
/// ```
/// magic    : 4 bytes = "POVR"   (Patch OVerlay aRtifact) — distinct from "\0asm"/"PMOD"
/// version  : u8      = 1
/// reserved : u8      = 0
/// reserved : u16     = 0
/// overlayLen : u32   = byte length of the overlay chunk
/// overlayBytes : overlayLen bytes   (a `PatchResourceOverlay` chunk — magic "PROV")
/// innerLen   : u32   = byte length of the inner artifact
/// innerBytes : innerLen bytes        (a verbatim raw `.wasm` OR a `PMOD` container)
/// ```
public enum PatchOverlayArtifact {

    /// Artifact-wrapper magic `POVR`. First byte `0x50` (= "P") matches `PMOD`'s
    /// first byte, but the full 4-byte magic disambiguates; the SDK checks all four.
    public static let magic: [UInt8] = [0x50, 0x4F, 0x56, 0x52]  // "POVR"
    public static let version: UInt8 = 1

    /// True iff `bytes` begins with the overlay-artifact magic.
    public static func isOverlayArtifact(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    /// Wrap `inner` (a raw `.wasm` or a `PMOD` container) together with `overlay`
    /// (an already-serialized `PatchResourceOverlay` chunk) into one artifact blob.
    public static func encode(inner: [UInt8], overlay: [UInt8]) -> [UInt8] {
        var out = magic
        out.append(version)
        out.append(0)             // reserved u8
        out.append(0); out.append(0)   // reserved u16
        appendU32(&out, UInt32(overlay.count))
        out.append(contentsOf: overlay)
        appendU32(&out, UInt32(inner.count))
        out.append(contentsOf: inner)
        return out
    }

    /// The split halves of a decoded artifact: the overlay chunk + the inner WASM bytes.
    public struct Decoded: Equatable, Sendable {
        public let overlay: [UInt8]
        public let inner: [UInt8]
    }

    /// Decode an overlay artifact into (overlay chunk, inner WASM artifact). Returns
    /// nil when `bytes` is not a well-formed `POVR` wrapper — callers then treat the
    /// whole blob as a raw module / `PMOD` (the unchanged legacy path).
    public static func decode(_ bytes: [UInt8]) -> Decoded? {
        guard isOverlayArtifact(bytes), bytes.count >= 8, bytes[4] == version else { return nil }
        var i = 8
        guard let overlayLen = readU32(bytes, &i), i + Int(overlayLen) <= bytes.count else { return nil }
        let overlay = Array(bytes[i..<i + Int(overlayLen)]); i += Int(overlayLen)
        guard let innerLen = readU32(bytes, &i), i + Int(innerLen) <= bytes.count else { return nil }
        let inner = Array(bytes[i..<i + Int(innerLen)]); i += Int(innerLen)
        return Decoded(overlay: overlay, inner: inner)
    }

    /// Convenience for the CLI packaging path: wrap `inner` with a `Table`, or — when
    /// the table is empty — return `inner` UNCHANGED (no wrapper), so an overlay-free
    /// build is byte-identical to today.
    public static func package(inner: [UInt8], table: PatchResourceOverlay.Table) -> [UInt8] {
        guard !table.isEmpty else { return inner }
        return encode(inner: inner, overlay: PatchResourceOverlay.encode(table))
    }

    // MARK: - Byte helpers (little-endian)

    private static func appendU32(_ out: inout [UInt8], _ n: UInt32) {
        out.append(UInt8(n & 0xFF)); out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF)); out.append(UInt8((n >> 24) & 0xFF))
    }
    private static func readU32(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let n = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
            | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        i += 4; return n
    }
}
