// BodyEmission.swift — the wire envelope the guest emits (Foundation-FREE).
//
// Kept separate from ABI.swift (which pulls in Foundation for `JSONEncoder`) so
// this type — and the `EmbeddedJSON` serializer that consumes it — compiles
// under the T0 *Embedded* Swift wasm tier (no Foundation). The host still gets
// `Codable` synthesis (stdlib), so `JSONDecoder` reads it unchanged.

/// The envelope the guest emits: the root node plus a self-reported coverage
/// summary (so the host can show "this body is N% WASM-native" without
/// re-deriving it). The host trusts but also independently verifies the tree.
public struct BodyEmission: Equatable, Sendable {
    public var root: ViewNode
    /// Optional guest-computed coverage (nodes/modifiers lowered vs opaque).
    public var coverage: Coverage?
    /// The IR wire-format schema version the guest emitted with (see
    /// `PatchViewIRSchema`). Optional + defaulting to `nil` so a guest built
    /// before the stamp (the legacy fixtures) still decodes — the host treats a
    /// `nil` version as the current/v1 wire shape. A guest emitted by an engine
    /// that vendors this IR should stamp `PatchViewIRSchema.version` here so the
    /// host can reject a tree it cannot decode (`PatchViewIRSchema.check`).
    public var schemaVersion: Int?
    public init(root: ViewNode, coverage: Coverage? = nil,
                schemaVersion: Int? = nil) {
        self.root = root
        self.coverage = coverage
        self.schemaVersion = schemaVersion
    }

    public struct Coverage: Equatable, Sendable {
        public var totalNodes: Int
        public var opaqueNodes: Int
        public var totalModifiers: Int
        public var opaqueModifiers: Int
        public init(totalNodes: Int, opaqueNodes: Int,
                    totalModifiers: Int, opaqueModifiers: Int) {
            self.totalNodes = totalNodes
            self.opaqueNodes = opaqueNodes
            self.totalModifiers = totalModifiers
            self.opaqueModifiers = opaqueModifiers
        }
    }

    public init(root: ViewNode, computeCoverage: Bool, schemaVersion: Int? = nil) {
        self.root = root
        self.schemaVersion = schemaVersion
        if computeCoverage {
            self.coverage = Coverage(
                totalNodes: root.nodeCount,
                opaqueNodes: root.opaqueNodeCount,
                totalModifiers: root.modifierCount,
                opaqueModifiers: root.opaqueModifierCount)
        } else {
            self.coverage = nil
        }
    }
}

// MARK: - Codable (host / T2 only; Embedded Swift has no Codable)
#if !FRONTIER_EMBEDDED
extension BodyEmission: Codable {}
extension BodyEmission.Coverage: Codable {}
#endif
