// Conformance.swift — `Codable` for the IR, but ONLY off the Embedded tier.
// =========================================================================
// The IR value types declare bare `Equatable, Sendable` (so they parse + build
// under Embedded Swift, where `Codable` is `@_unavailableInEmbedded`). On the
// host / T2 tier we add `Codable` via empty extensions — which is enough to
// trigger the compiler's automatic `Codable` synthesis (all stored properties
// are themselves `Codable`). The guest's Foundation-free `EmbeddedJSON` emits
// the SAME JSON shape, so the host `JSONDecoder` reads either tier's output.
//
// Compile the embedded guest with `-D FRONTIER_EMBEDDED` to drop all of this.

// NOTE: the actual `Codable` extensions are co-located in the same files as the
// type declarations (ViewNode.swift, BodyEmission.swift), because Swift only
// auto-synthesizes `Codable` for an extension in the type's OWN file. They are
// each `#if !FRONTIER_EMBEDDED`-guarded. This file is now just documentation of
// the strategy.
