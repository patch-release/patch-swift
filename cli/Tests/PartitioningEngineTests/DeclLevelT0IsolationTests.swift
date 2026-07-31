// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PartitioningEngine
@testable import CodeGenerator

/// Unit coverage for the DECL-LEVEL T0-ISOLATION extractor mode (no toolchain): when
/// `excludeEmbeddedBlockerExtensions` is set, a clean-math export's minimal decl closure
/// pulls the type + its CLEAN extensions but ROUTES AROUND the type's Codable/reflection
/// extension — the embedded blocker a clean export never calls. This is what lets a real
/// library's geometry/crypto math ride T0 while its serialization surface stays at T2.
final class DeclLevelT0IsolationTests: XCTestCase {

    /// A Euclid-shaped corpus: a clean value type with a clean math extension (`dot`)
    /// AND a `Codable` extension (`init(from:)`/`encode(to:)`) AND a `CustomReflectable`
    /// extension (`Mirror`). The clean `dot` closure must NOT pull the Codable/Mirror
    /// extensions in isolation mode, but the default mode pulls everything.
    private func vectorCorpus() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("decliso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        import Foundation
        public struct Vec: Hashable, Sendable {
            public var x: Double
            public var y: Double
        }
        public extension Vec {
            func dot(_ o: Vec) -> Double { x * o.x + y * o.y }
        }
        extension Vec: Codable {
            public init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                self.init(x: try c.decode(Double.self), y: try c.decode(Double.self))
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(x); try c.encode(y)
            }
        }
        extension Vec: CustomReflectable {
            public var customMirror: Mirror { Mirror(self, children: ["x": x, "y": y]) }
        }
        """.write(to: dir.appendingPathComponent("Vec.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    func testIsolationModeRoutesAroundCodableAndMirror() throws {
        let dir = try vectorCorpus()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [dir.appendingPathComponent("Vec.swift")]

        // Seed the clean math export: `Vec.dot` + the `Vec` boundary type (same seeds the
        // BuildPipeline computes for an instance-method export).
        let seeds = ["Vec.dot", "Vec"]

        // DEFAULT mode pulls EVERYTHING — including the Codable + Mirror extensions.
        let plain = DeclLevelExtractor(registry: .standard)
        let plainOut = plain.extract(seeds: seeds, index: plain.index(files: files))
        let plainJoined = plainOut.spans.joined(separator: "\n")
        XCTAssertTrue(plainJoined.contains("func dot"), "default: math member present")
        XCTAssertTrue(plainJoined.contains("Codable") || plainJoined.contains("init(from"),
                      "default mode pulls the Codable extension (the embedded blocker)")
        XCTAssertTrue(plainJoined.contains("customMirror") || plainJoined.contains("Mirror"),
                      "default mode pulls the CustomReflectable/Mirror extension")

        // ISOLATION mode pulls the type + its CLEAN math extension but ROUTES AROUND the
        // Codable + Mirror extensions — the clean closure that can ride T0.
        let iso = DeclLevelExtractor(registry: .standard, excludeEmbeddedBlockerExtensions: true)
        let isoOut = iso.extract(seeds: seeds, index: iso.index(files: files))
        let isoJoined = isoOut.spans.joined(separator: "\n")
        XCTAssertTrue(isoJoined.contains("struct Vec"), "isolation: the value type ships")
        XCTAssertTrue(isoJoined.contains("func dot"), "isolation: the clean math member ships")
        XCTAssertFalse(isoJoined.contains("init(from"), "isolation: Codable init routed AROUND")
        XCTAssertFalse(isoJoined.contains("encode(to"), "isolation: Codable encode routed AROUND")
        XCTAssertFalse(isoJoined.contains("customMirror"), "isolation: Mirror reflection routed AROUND")
        XCTAssertFalse(isoJoined.contains("Decoder"), "isolation: no Decoder reference leaks into the T0 closure")
        XCTAssertFalse(isoJoined.contains("Encoder"), "isolation: no Encoder reference leaks into the T0 closure")
        // Isolation must NEVER reject the clean seed (the math closure is fully clean).
        XCTAssertTrue(isoOut.rejectedSeeds.isEmpty, "clean math seed must not be rejected")
        XCTAssertLessThan(isoOut.spans.count, plainOut.spans.count,
                          "isolation pulls strictly fewer spans (the blocker extensions are dropped)")
    }

    /// `isEmbeddedBlockerExtension` classifies a Codable/Mirror extension as a blocker but
    /// a clean math extension as not.
    func testEmbeddedBlockerExtensionClassification() throws {
        let dir = try vectorCorpus()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = DeclLevelExtractor(registry: .standard, excludeEmbeddedBlockerExtensions: true)
        let idx = iso.index(files: [dir.appendingPathComponent("Vec.swift")])
        let exts = idx.extensionsByType["Vec"] ?? []
        XCTAssertFalse(exts.isEmpty, "Vec has extensions")
        let blockers = exts.filter { iso.isEmbeddedBlockerExtension($0) }
        let clean = exts.filter { !iso.isEmbeddedBlockerExtension($0) }
        // Codable + CustomReflectable extensions are blockers; the `dot` extension is clean.
        XCTAssertGreaterThanOrEqual(blockers.count, 2, "Codable + Mirror extensions are blockers")
        XCTAssertTrue(clean.contains { $0.span.contains("func dot") }, "the math extension is clean")
    }
}
