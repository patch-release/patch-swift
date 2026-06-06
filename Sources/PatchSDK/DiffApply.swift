import Foundation
import CBZ2

/// Client-side binary-diff application.
///
/// The backend produces patches with the `bsdiff4` algorithm, which writes the
/// classic **BSDIFF40** container:
///
/// ```
/// offset 0   : magic "BSDIFF40"            (8 bytes)
/// offset 8   : control block length        (int64, little-endian)  — bz2-compressed size
/// offset 16  : diff block length           (int64, little-endian)  — bz2-compressed size
/// offset 24  : length of the new file      (int64, little-endian)  — uncompressed
/// offset 32  : bz2(control)                 (controlLen bytes)
/// .........  : bz2(diff)                    (diffLen bytes)
/// .........  : bz2(extra)                   (remaining bytes)
/// ```
///
/// The three streams are independently **bz2-compressed**. `control` is a run of
/// triples `(diffLen, extraLen, seekLen)`, each an int64 in bsdiff's
/// sign–magnitude ("offtin") encoding (high bit = sign, NOT two's-complement).
/// Reconstruction walks the triples: copy `diffLen` bytes from old (added to the
/// diff stream byte-wise), then copy `extraLen` bytes verbatim from extra, then
/// seek the old-file cursor by `seekLen`.
///
/// libbz2 (the `CBZ2` system target) inflates the bz2 streams; everything else is
/// pure Swift. This is a **full, working** implementation, not a stub — the
/// loader prefers it when the backend offers a `diff_url`, and always falls back
/// to a full-module download on any diff failure (see `ModuleLoader`).
public enum BSDIFF40Patch {

    public enum DiffError: Error, CustomStringConvertible, Equatable {
        case badMagic
        case truncatedHeader
        case negativeBlockLength
        case blockOverrun(String)
        case bz2Failure(code: Int32, block: String)
        case controlNotMultipleOf24
        case reconstructionOverrun
        case sizeMismatch(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .badMagic: return "bsdiff: missing BSDIFF40 magic"
            case .truncatedHeader: return "bsdiff: header truncated (need >= 32 bytes)"
            case .negativeBlockLength: return "bsdiff: negative block length in header"
            case .blockOverrun(let w): return "bsdiff: \(w) block extends past end of patch"
            case .bz2Failure(let c, let b): return "bsdiff: bz2 decompress failed (code=\(c)) for \(b) block"
            case .controlNotMultipleOf24: return "bsdiff: control stream length is not a multiple of 24"
            case .reconstructionOverrun: return "bsdiff: patch references bytes outside old/new bounds"
            case .sizeMismatch(let e, let g): return "bsdiff: reconstructed size \(g) != header size \(e)"
            }
        }
    }

    static let magic: [UInt8] = Array("BSDIFF40".utf8)

    /// Upper bound on any single inflated block / the reconstructed module size.
    /// Caps attacker-controlled header lengths so a corrupt patch can't drive a
    /// multi-GB allocation. 256 MiB is far past any on-device module (3–6 MB).
    static let maxBlockBytes = 256 * 1024 * 1024

    /// Apply a BSDIFF40 `patch` to `old`, returning the reconstructed new bytes.
    public static func apply(patch: Data, to old: Data) throws -> Data {
        let patchBytes = [UInt8](patch)
        guard patchBytes.count >= 32 else { throw DiffError.truncatedHeader }
        guard Array(patchBytes[0..<8]) == magic else { throw DiffError.badMagic }

        let controlLen = readOfftin(patchBytes, 8)
        let diffLen = readOfftin(patchBytes, 16)
        let newSize = readOfftin(patchBytes, 24)
        guard controlLen >= 0, diffLen >= 0, newSize >= 0 else {
            throw DiffError.negativeBlockLength
        }
        // The header's `newSize` directly sizes the output allocation
        // (`[UInt8](repeating: 0, count: Int(newSize))`). It is attacker-controlled,
        // so cap it: a hostile patch claiming `newSize = Int64.max` would otherwise
        // OOM-crash the host. 256 MiB matches the bz2 inflate cap and is well past
        // any sane on-device module (plan budget 3–6 MB).
        guard newSize <= Int64(Self.maxBlockBytes) else {
            throw DiffError.blockOverrun("new-size")
        }

        // The header lengths are attacker-controlled (a corrupt/hostile patch can
        // carry values up to Int64.max). Compute block offsets with OVERFLOW-SAFE
        // arithmetic: `32 + Int(controlLen)` would TRAP (uncatchable crash) on
        // overflow before the `<= count` bounds check could reject it. Use
        // `addingReportingOverflow` so an out-of-range length is rejected, not a
        // crash. A length can't exceed the patch size anyway.
        let controlStart = 32
        let (controlEnd, controlOvf) = controlStart.addingReportingOverflow(Int(controlLen))
        guard !controlOvf, controlEnd <= patchBytes.count else {
            throw DiffError.blockOverrun("control")
        }
        let (diffEnd, diffOvf) = controlEnd.addingReportingOverflow(Int(diffLen))
        guard !diffOvf, diffEnd <= patchBytes.count else {
            throw DiffError.blockOverrun("diff")
        }

        let controlComp = Array(patchBytes[controlStart..<controlEnd])
        let diffComp = Array(patchBytes[controlEnd..<diffEnd])
        let extraComp = Array(patchBytes[diffEnd..<patchBytes.count])

        // bsdiff control entries are 24 bytes (3 int64) each; bound the inflate
        // so a corrupt header can't request an absurd allocation. `controlLen * 8`
        // is computed overflow-safe (clamped) — `Int(controlLen) * 8` would TRAP
        // for a near-Int64.max length.
        let controlHint = (Int(controlLen).multipliedReportingOverflow(by: 8)).overflow
            ? Self.maxBlockBytes : Int(controlLen) * 8
        let control = try bz2Decompress(controlComp, block: "control", hint: controlHint)
        let diff = try bz2Decompress(diffComp, block: "diff", hint: Int(newSize))
        let extra = try bz2Decompress(extraComp, block: "extra", hint: Int(newSize))

        guard control.count % 24 == 0 else { throw DiffError.controlNotMultipleOf24 }

        let oldBytes = [UInt8](old)
        var newBytes = [UInt8](repeating: 0, count: Int(newSize))

        var oldPos = 0
        var newPos = 0
        var diffPos = 0
        var extraPos = 0
        var ci = 0
        while ci + 24 <= control.count {
            let addLen = readOfftin(control, ci)
            let copyLen = readOfftin(control, ci + 8)
            let seekLen = readOfftin(control, ci + 16)
            ci += 24

            // 1. Add: newPos..<newPos+addLen = old[oldPos...] + diff[diffPos...]
            //
            // `addLen`/`copyLen` are attacker-controlled offtin int64s up to
            // 2^63-1. `newPos + add`, `diffPos + add`, `newPos + copy`, … would
            // TRAP on Int overflow (an uncatchable crash, NOT a thrown error, so
            // the loader's diff→full fallback never gets a chance) for such a
            // length. Use OVERFLOW-REPORTING addition so an out-of-range length
            // is rejected cleanly as `reconstructionOverrun`.
            if addLen < 0 { throw DiffError.reconstructionOverrun }
            let add = Int(addLen)
            let (newEndAdd, ovfNewAdd) = newPos.addingReportingOverflow(add)
            let (diffEnd, ovfDiff) = diffPos.addingReportingOverflow(add)
            guard !ovfNewAdd, !ovfDiff,
                  newEndAdd <= newBytes.count,
                  diffEnd <= diff.count else { throw DiffError.reconstructionOverrun }
            for i in 0..<add {
                let oldIdx = oldPos + i
                let oldByte: UInt8 = (oldIdx >= 0 && oldIdx < oldBytes.count) ? oldBytes[oldIdx] : 0
                newBytes[newPos + i] = oldByte &+ diff[diffPos + i]
            }
            newPos = newEndAdd
            oldPos += add   // bounded by `add` (already range-checked above)
            diffPos = diffEnd

            // 2. Copy: newPos..<newPos+copyLen = extra[extraPos...]
            if copyLen < 0 { throw DiffError.reconstructionOverrun }
            let copy = Int(copyLen)
            let (newEndCopy, ovfNewCopy) = newPos.addingReportingOverflow(copy)
            let (extraEnd, ovfExtra) = extraPos.addingReportingOverflow(copy)
            guard !ovfNewCopy, !ovfExtra,
                  newEndCopy <= newBytes.count,
                  extraEnd <= extra.count else { throw DiffError.reconstructionOverrun }
            if copy > 0 {
                newBytes.replaceSubrange(newPos..<newEndCopy,
                                         with: extra[extraPos..<extraEnd])
            }
            newPos = newEndCopy
            extraPos = extraEnd

            // 3. Seek the old cursor (may be negative). Overflow-safe: a hostile
            // `seekLen` near ±Int64.max would otherwise trap on `oldPos += …`.
            let (seekedOld, ovfSeek) = oldPos.addingReportingOverflow(Int(seekLen))
            guard !ovfSeek else { throw DiffError.reconstructionOverrun }
            oldPos = seekedOld
        }

        guard newPos == newBytes.count else {
            throw DiffError.sizeMismatch(expected: newBytes.count, got: newPos)
        }
        return Data(newBytes)
    }

    // MARK: - bsdiff "offtin" int64 (sign-magnitude, little-endian)

    /// Decode bsdiff's 8-byte sign–magnitude integer at `offset`.
    /// The low 63 bits are the magnitude; the top bit of the most-significant
    /// byte is the sign (set = negative). This is NOT two's complement.
    static func readOfftin(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var y: UInt64 = 0
        y = UInt64(bytes[offset + 7] & 0x7f)
        for i in stride(from: 6, through: 0, by: -1) {
            y = y << 8
            y |= UInt64(bytes[offset + i])
        }
        let magnitude = Int64(bitPattern: y)
        return (bytes[offset + 7] & 0x80) != 0 ? -magnitude : magnitude
    }

    // MARK: - bz2 one-shot decompression via libbz2

    /// Inflate a single bz2 stream using libbz2's one-shot buffer API, growing
    /// the destination buffer until it fits. `hint` is a starting size guess.
    static func bz2Decompress(_ input: [UInt8], block: String, hint: Int) throws -> [UInt8] {
        if input.isEmpty { return [] }
        // Start generously; bz2 of these blocks expands, and `hint` is the
        // uncompressed size estimate. Floor at 4 KiB so tiny streams still work.
        var capacity = max(hint, max(input.count * 4, 4096))
        // Cap growth to avoid unbounded allocation on a malicious patch (256 MiB
        // is well past any sane on-device module — see plan budget 3–6 MB).
        let maxCapacity = 256 * 1024 * 1024
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            var destLen = UInt32(capacity)
            var src = input
            let rc = out.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                src.withUnsafeMutableBufferPointer { srcBuf in
                    BZ2_bzBuffToBuffDecompress(
                        outBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: capacity) { $0 },
                        &destLen,
                        srcBuf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: srcBuf.count) { $0 },
                        UInt32(srcBuf.count),
                        0,  // small: 0 = faster, more memory
                        0   // verbosity
                    )
                }
            }
            switch rc {
            case BZ_OK:
                out.removeSubrange(Int(destLen)..<out.count)
                return out
            case BZ_OUTBUFF_FULL:
                guard capacity < maxCapacity else {
                    throw DiffError.bz2Failure(code: rc, block: block)
                }
                capacity = min(capacity * 2, maxCapacity)
                continue
            default:
                throw DiffError.bz2Failure(code: rc, block: block)
            }
        }
    }
}
