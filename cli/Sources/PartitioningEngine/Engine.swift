// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A coverage report over a directory of Swift sources.
public struct CoverageReport: Sendable {
    public let fileCount: Int
    public let functionCount: Int
    public let edgeCount: Int
    public let countsByClassification: [Classification: Int]
    public let perCategoryNativeHits: [NativeCategory: Int]
    public let results: [ClassificationResult]
    public let records: [String: FunctionRecord]
    /// Per-function inferred types of params + locals from the type-resolution
    /// layer (`ResolvedProject.localTypes`), keyed by `FunctionRecord.id`. Empty
    /// when type resolution was disabled. The splitter folds these in so fragments
    /// threading locals carry concrete types and compile.
    public let inferredTypes: [String: [String: String]]

    /// OTA-updatable percentage = (wasmEligible + bridged + mixed) / total.
    /// `mixed` counts because its pure portion ships OTA after splitting.
    public var otaUpdatablePercent: Double {
        guard functionCount > 0 else { return 0 }
        let ota = (countsByClassification[.wasmEligible] ?? 0)
            + (countsByClassification[.bridged] ?? 0)
            + (countsByClassification[.mixed] ?? 0)
        return (Double(ota) / Double(functionCount)) * 100.0
    }

    public func count(_ c: Classification) -> Int { countsByClassification[c] ?? 0 }
}

// MARK: - JSON report (Encodable)

extension CoverageReport {
    /// Realized-split metrics layered onto the JSON report when the analyzer ran
    /// the (expensive) realized-split pass. Mirrors the `Analyze` command's
    /// private `Realized` summary; passed in as plain values so the report DTO
    /// stays in the engine module (and is unit-testable without the CLI target).
    public struct RealizedMetrics: Sendable, Equatable {
        public var otaPercent: Double
        public var abiOtaPercent: Double
        public var mixedSplit: Int
        public var fragments: Int
        public var abiSplits: Int
        public var abiFragments: Int
        public var subtreeSplits: Int
        public var subtreeFragments: Int

        public init(otaPercent: Double, abiOtaPercent: Double, mixedSplit: Int,
                    fragments: Int, abiSplits: Int, abiFragments: Int,
                    subtreeSplits: Int, subtreeFragments: Int) {
            self.otaPercent = otaPercent
            self.abiOtaPercent = abiOtaPercent
            self.mixedSplit = mixedSplit
            self.fragments = fragments
            self.abiSplits = abiSplits
            self.abiFragments = abiFragments
            self.subtreeSplits = subtreeSplits
            self.subtreeFragments = subtreeFragments
        }
    }

    /// The `analyze --format json` payload. A typed, `Encodable` mirror of the
    /// fields the CLI emits, so the output is produced by `JSONEncoder` (valid by
    /// construction) instead of hand-assembled strings. Field (JSON key) names are
    /// the exact ones the previous hand-rolled emitter used so consumers/CI that
    /// parse this output keep working.
    ///
    /// Shape note: when `realized` is supplied, `otaUpdatablePercent` reports the
    /// *realized* OTA percentage (the honest headline) and the realized-only keys
    /// are present; otherwise `otaUpdatablePercent` falls back to the optimistic
    /// percentage and the realized-only keys are omitted.
    public struct JSONReport: Encodable, Equatable {
        public let files: Int
        public let functions: Int
        public let edges: Int
        public let wasmEligible: Int
        public let bridged: Int
        public let mixed: Int
        public let native: Int
        public let otaUpdatablePercentOptimistic: Double
        public let otaUpdatablePercent: Double
        // Realized-only (nil → omitted from the JSON via `encodeIfPresent`).
        public let otaUpdatablePercentABI: Double?
        public let mixedSplit: Int?
        public let fragments: Int?
        public let abiSplits: Int?
        public let abiFragments: Int?
        public let subtreeSplits: Int?
        public let subtreeFragments: Int?
    }

    /// Build the `--format json` payload from this report plus optional realized
    /// metrics. Use with a `JSONEncoder` (sorted keys + pretty printing) to emit.
    public func jsonReport(realized: RealizedMetrics? = nil) -> JSONReport {
        JSONReport(
            files: fileCount,
            functions: functionCount,
            edges: edgeCount,
            wasmEligible: count(.wasmEligible),
            bridged: count(.bridged),
            mixed: count(.mixed),
            native: count(.native),
            otaUpdatablePercentOptimistic: otaUpdatablePercent,
            otaUpdatablePercent: realized?.otaPercent ?? otaUpdatablePercent,
            otaUpdatablePercentABI: realized?.abiOtaPercent,
            mixedSplit: realized?.mixedSplit,
            fragments: realized?.fragments,
            abiSplits: realized?.abiSplits,
            abiFragments: realized?.abiFragments,
            subtreeSplits: realized?.subtreeSplits,
            subtreeFragments: realized?.subtreeFragments
        )
    }
}

/// Top-level façade wiring Parser → (TypeResolver) → CallGraph → Classifier.
public struct PartitioningEngine {
    public let parser: SwiftParserEngine
    public let classifier: Classifier
    /// When true (default), the type-resolution layer runs first and feeds the
    /// call graph precise edges + the splitter inferred local types. Disable to
    /// fall back to the original name-based path (for the perf/safety A/B tests).
    public let useTypeResolution: Bool

    public init(registry: NativeRegistry = .standard, useTypeResolution: Bool = true) {
        self.parser = SwiftParserEngine()
        self.classifier = Classifier(registry: registry)
        self.useTypeResolution = useTypeResolution
    }

    /// Analyze a directory and produce a coverage report.
    public func analyze(directory: URL) throws -> CoverageReport {
        let files = try SwiftParserEngine.swiftFiles(in: directory)
        let records = try parser.parseDirectory(directory)
        let resolved = useTypeResolution ? ProjectResolver().resolve(files: files) : nil
        return makeReport(records: records, fileCount: files.count, resolved: resolved)
    }

    /// Analyze already-parsed records (used by tests). When `resolved` is supplied
    /// the type-resolved call graph is built.
    public func analyze(records: [FunctionRecord], fileCount: Int,
                        resolved: ResolvedProject? = nil) -> CoverageReport {
        makeReport(records: records, fileCount: fileCount, resolved: resolved)
    }

    private func makeReport(records: [FunctionRecord], fileCount: Int,
                            resolved: ResolvedProject?) -> CoverageReport {
        let graphBuilder = CallGraphBuilder(resolved: resolved)
        let graph = graphBuilder.build(from: records)
        // When type resolution ran, seed the classifier with the project's
        // declared nominal type names so a registry symbol the project itself
        // redeclares (e.g. swift-collections' `Path`/`Index`, RxSwift's
        // `Observable`) is treated as the PROJECT type, not the framework one.
        // SAFE: only ever suppresses a hit the project provably shadows; with no
        // resolver the set is empty and behaviour is unchanged.
        let analysisClassifier: Classifier
        if let resolved, !resolved.table.types.isEmpty {
            analysisClassifier = Classifier(
                registry: classifier.registry,
                projectTypeNames: ResolvedProject.projectTypeNames(
                    from: resolved.table, registry: classifier.registry))
        } else {
            analysisClassifier = classifier
        }
        let resultsByID = analysisClassifier.classifyAll(graph)
        // Exclude the synthetic ambiguous-dispatch sink from the coverage report:
        // it is an analysis artifact, not a real function in the corpus.
        let results = resultsByID.values
            .filter { $0.functionID != CallGraphBuilder.ambiguousSinkID }
            .sorted { $0.functionID < $1.functionID }

        var counts: [Classification: Int] = [:]
        for c in Classification.allCases { counts[c] = 0 }
        for r in results { counts[r.classification, default: 0] += 1 }

        var perCategory: [NativeCategory: Int] = [:]
        for r in results {
            for hit in r.nativeHits {
                perCategory[hit.category, default: 0] += 1
            }
        }

        return CoverageReport(
            fileCount: fileCount,
            functionCount: results.count,
            edgeCount: graph.edgeCount,
            countsByClassification: counts,
            perCategoryNativeHits: perCategory,
            results: results,
            records: graph.records,
            inferredTypes: resolved?.localTypes ?? [:]
        )
    }

    /// Build just the call graph (used by tests / codegen).
    public func buildGraph(from records: [FunctionRecord], resolved: ResolvedProject? = nil) -> CallGraph {
        CallGraphBuilder(resolved: resolved).build(from: records)
    }
}
