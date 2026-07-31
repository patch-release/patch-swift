// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// The components that go into a build fingerprint, per the plan's
/// "Fingerprint Components" section. A change to ANY of these is
/// OTA-incompatible (requires an App Store submission). The WASM module binary
/// and WASM-compiled source files are intentionally NOT included — those are
/// what OTA updates are allowed to change.
public struct FingerprintComponents: Sendable, Equatable {
    public var sdkVersion: String
    public var wasmKitVersion: String
    public var bridgeDefinitions: [String]
    public var nativeSwiftFiles: [String]
    public var nativeGeneratedStubs: [String]
    public var infoPlist: String
    public var entitlements: String
    public var linkedFrameworks: [String]
    public var deploymentTarget: String
    public var swiftCompilerVersion: String

    public init(
        sdkVersion: String,
        wasmKitVersion: String,
        bridgeDefinitions: [String],
        nativeSwiftFiles: [String],
        nativeGeneratedStubs: [String],
        infoPlist: String,
        entitlements: String,
        linkedFrameworks: [String],
        deploymentTarget: String,
        swiftCompilerVersion: String
    ) {
        self.sdkVersion = sdkVersion
        self.wasmKitVersion = wasmKitVersion
        self.bridgeDefinitions = bridgeDefinitions
        self.nativeSwiftFiles = nativeSwiftFiles
        self.nativeGeneratedStubs = nativeGeneratedStubs
        self.infoPlist = infoPlist
        self.entitlements = entitlements
        self.linkedFrameworks = linkedFrameworks
        self.deploymentTarget = deploymentTarget
        self.swiftCompilerVersion = swiftCompilerVersion
    }
}

/// Computes a deterministic SHA-256 fingerprint over the components.
///
/// FINGERPRINT = SHA-256( sorted([ "<label>=" + hash(component), ... ]) ).
/// Each component is individually hashed and PREFIXED WITH A STABLE LABEL, the
/// labeled per-component hashes are sorted (so input order doesn't matter),
/// concatenated, and hashed again. Deterministic AND collision-safe.
///
/// ## Why the label prefix matters (safety fix)
/// The previous formula sorted the BARE component hashes. Sorting a set of bare
/// hashes is invariant under SWAPPING TWO COMPONENTS' VALUES: if `infoPlist` and
/// `entitlements` swapped contents, the multiset of hashes was identical → the
/// SAME fingerprint, even though the native shell genuinely differed. Since the
/// fingerprint is the OTA-compatibility gate, that collision could let an
/// INCOMPATIBLE module push through (a real safety hole). Binding each hash to its
/// component label makes a value swap change the fingerprint while keeping the
/// order-independence the plan asked for.
///
/// NOTE: this changes the fingerprint value, so apps must re-register their
/// native-shell fingerprint once (`Patch fingerprint register`) after upgrading.
public enum Fingerprinter {
    /// SHA-256 hex of a single string component.
    public static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 hex of RAW bytes. Use this for FILE CONTENTS (Info.plist, entitlements,
    /// source files) so a binary or non-UTF-8 file is hashed byte-exactly. Decoding a
    /// binary file as UTF-8 first (the old `hash(String(decoding:as:))` path) replaced
    /// every invalid byte with U+FFFD, so two DIFFERENT binaries that differ only in
    /// invalid-UTF-8 bytes (a binary `Info.plist`, a compiled `.nib`) hashed
    /// IDENTICALLY — a real native-shell change the OTA-compatibility gate could miss.
    public static func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hash an array component as the hash of its element hashes (order-independent
    /// within the array is NOT assumed — arrays preserve order, but we join with a
    /// separator so two different splits never collide).
    static func hashArray(_ values: [String]) -> String {
        hash(values.map(hash).joined(separator: "|"))
    }

    /// Compute the full fingerprint.
    public static func fingerprint(_ c: FingerprintComponents) -> String {
        // Each entry is bound to a STABLE LABEL so swapping two components' values
        // changes the fingerprint (the value-swap collision the old formula missed).
        let labeled: [String] = [
            "sdkVersion=" + hash(c.sdkVersion),
            "wasmKitVersion=" + hash(c.wasmKitVersion),
            "bridgeDefinitions=" + hashArray(c.bridgeDefinitions),
            "nativeSwiftFiles=" + hashArray(c.nativeSwiftFiles),
            "nativeGeneratedStubs=" + hashArray(c.nativeGeneratedStubs),
            "infoPlist=" + hash(c.infoPlist),
            "entitlements=" + hash(c.entitlements),
            "linkedFrameworks=" + hashArray(c.linkedFrameworks),
            "deploymentTarget=" + hash(c.deploymentTarget),
            "swiftCompilerVersion=" + hash(c.swiftCompilerVersion),
        ]
        // sorted([...]) per the plan: order of components must not matter, but the
        // label prefix preserves the component→value binding under the sort.
        let combined = labeled.sorted().joined()
        return hash(combined)
    }
}
