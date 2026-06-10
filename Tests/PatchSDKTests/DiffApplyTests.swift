import XCTest
@testable import PatchSDK

/// D2 — client-side BSDIFF40 diff application + brotli decompression + SHA-256.
/// Fixtures (`diff_*`) are produced by the backend's `bsdiff4` / `brotli`
/// packages, so a passing test proves wire-format alignment with the backend.
final class DiffApplyTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("fixture \(name).\(ext) missing")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - bsdiff4 (BSDIFF40)

    func testBSDIFF40ReconstructsBackendPatch() throws {
        let old = try fixture("diff_old", "bin")
        let expectedNew = try fixture("diff_new", "bin")
        let patch = try fixture("diff", "patch")  // diff.bsdiff4.patch

        let reconstructed = try BSDIFF40Patch.apply(patch: patch, to: old)
        XCTAssertEqual(reconstructed, expectedNew, "BSDIFF40 reconstruction must match backend output byte-for-byte")
    }

    func testBSDIFF40RejectsBadMagic() throws {
        var bad = [UInt8]("XXDIFF40".utf8) + [UInt8](repeating: 0, count: 24)
        bad.append(contentsOf: [1, 2, 3])
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: Data(bad), to: Data([0, 1, 2]))) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .badMagic)
        }
    }

    func testBSDIFF40RejectsTruncatedHeader() throws {
        let bad = Data([UInt8]("BSDIFF4".utf8))  // < 32 bytes
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: bad, to: Data())) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .truncatedHeader)
        }
    }

    func testOfftinSignMagnitudeDecoding() {
        // bsdiff uses sign-magnitude, NOT two's complement.
        // +100 little-endian: 64 00 ... 00
        var pos = [UInt8](repeating: 0, count: 8); pos[0] = 100
        XCTAssertEqual(BSDIFF40Patch.readOfftin(pos, 0), 100)
        // -100: magnitude 100 with the high bit of byte 7 set.
        var neg = [UInt8](repeating: 0, count: 8); neg[0] = 100; neg[7] = 0x80
        XCTAssertEqual(BSDIFF40Patch.readOfftin(neg, 0), -100)
        // zero
        XCTAssertEqual(BSDIFF40Patch.readOfftin([UInt8](repeating: 0, count: 8), 0), 0)
    }

    // MARK: - malformed-header hardening

    /// Build a BSDIFF40 header (32 bytes) with the three offtin lengths, then
    /// append `payload`. Used to craft hostile headers for the overflow tests.
    private func header(controlLen: UInt64, diffLen: UInt64, newSize: UInt64,
                        payload: [UInt8] = []) -> Data {
        var bytes = BSDIFF40Patch.magic            // 8 bytes
        func offtin(_ v: UInt64) -> [UInt8] {
            // Plain little-endian magnitude (high bit clear → positive offtin).
            var out = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { out[i] = UInt8((v >> (8 * UInt64(i))) & 0xff) }
            return out
        }
        bytes += offtin(controlLen)
        bytes += offtin(diffLen)
        bytes += offtin(newSize)
        bytes += payload
        return Data(bytes)
    }

    /// A control-block length near Int64.max must be REJECTED (not crash). The
    /// old code computed `32 + Int(controlLen)`, which traps on overflow before
    /// the bounds check — an uncatchable crash on a corrupt/hostile patch.
    func testHugeControlLenIsRejectedNotOverflowTrap() {
        // 0x7fffffffffffffff = Int64.max as a positive offtin magnitude.
        let huge = header(controlLen: 0x7fff_ffff_ffff_ffff, diffLen: 0, newSize: 0)
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: huge, to: Data([1, 2, 3]))) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .blockOverrun("control"))
        }
    }

    /// A diff-block length near Int64.max must be rejected without overflow trap.
    func testHugeDiffLenIsRejectedNotOverflowTrap() {
        let huge = header(controlLen: 0, diffLen: 0x7fff_ffff_ffff_ffff, newSize: 0)
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: huge, to: Data([1, 2, 3]))) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .blockOverrun("diff"))
        }
    }

    /// A `newSize` near Int64.max must be rejected before sizing the output
    /// buffer (`[UInt8](repeating: 0, count: Int(newSize))` would OOM-crash).
    func testHugeNewSizeIsRejectedNotOOM() {
        let huge = header(controlLen: 0, diffLen: 0, newSize: 0x7fff_ffff_ffff_ffff)
        XCTAssertThrowsError(try BSDIFF40Patch.apply(patch: huge, to: Data([1, 2, 3]))) { err in
            XCTAssertEqual(err as? BSDIFF40Patch.DiffError, .blockOverrun("new-size"))
        }
    }

    // MARK: - brotli

    func testBrotliDecompressesBackendStream() throws {
        let compressed = try fixture("diff_new", "br")
        let expected = try fixture("diff_new", "bin")
        let out = try Brotli.decompress(compressed, sizeHint: expected.count)
        XCTAssertEqual(out, expected, "brotli decode must match the raw module the backend compressed")
    }

    func testBrotliDecompressesWithoutSizeHint() throws {
        let compressed = try fixture("diff_new", "br")
        let expected = try fixture("diff_new", "bin")
        // No hint: the buffer must grow automatically.
        let out = try Brotli.decompress(compressed)
        XCTAssertEqual(out, expected)
    }

    func testBrotliRejectsEmpty() {
        XCTAssertThrowsError(try Brotli.decompress(Data())) { err in
            XCTAssertEqual(err as? Brotli.BrotliError, .empty)
        }
    }

    // MARK: - SHA-256

    func testSHA256MatchesBackendHexFormat() throws {
        // Backend stores hashlib.sha256(bytes).hexdigest() (lowercase hex).
        let data = Data("hello".utf8)
        XCTAssertEqual(SHA256Hash.hexString(of: data),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertTrue(SHA256Hash.verify(data, matches: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertTrue(SHA256Hash.verify(data, matches: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"))
        XCTAssertFalse(SHA256Hash.verify(data, matches: "deadbeef"))
    }

    func testEndToEndDiffThenVerify() throws {
        // Simulate the loader's diff path: apply patch, then verify the
        // reconstruction against the new module's SHA-256.
        let old = try fixture("diff_old", "bin")
        let patch = try fixture("diff", "patch")
        let expectedNew = try fixture("diff_new", "bin")
        let expectedSHA = SHA256Hash.hexString(of: expectedNew)

        let reconstructed = try BSDIFF40Patch.apply(patch: patch, to: old)
        XCTAssertTrue(SHA256Hash.verify(reconstructed, matches: expectedSHA))
    }
}
