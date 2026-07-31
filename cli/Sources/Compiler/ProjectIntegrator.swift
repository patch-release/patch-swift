// SPDX-License-Identifier: Apache-2.0

// ProjectIntegrator.swift — wire the generated thunk file + the PatchSwiftUI
// product into a developer's project so `patchcli prepare` is turnkey.
//
// NOTE: full pbxproj source-file + product surgery is implemented incrementally.
// For SwiftPM / synchronized-folder / xcodegen projects the generated file is in
// the compile set by LOCATION, so only the PatchSwiftUI product link is needed.
// For a classic `.xcodeproj` the file needs explicit Sources-phase membership.

import Foundation

public enum ProjectIntegrator {
    public enum Outcome: Sendable, Equatable { case added, alreadyPresent }

    public enum IntegratorError: Error, CustomStringConvertible {
        case unsupported(String)
        public var description: String {
            switch self {
            case .unsupported(let s): return s
            }
        }
    }

    /// Wire into an `.xcodeproj`: add `fileURL` to `target`'s Sources phase and
    /// link the PatchSwiftUI product. (Implemented in PBXThunkIntegration.)
    public static func wire(projectURL: URL, target: String, fileURL: URL, fm: FileManager) throws -> Outcome {
        try PBXThunkIntegration.wire(projectURL: projectURL, target: target, fileURL: fileURL, fm: fm)
    }

    /// Ensure a SwiftPM target depends on the PatchSwiftUI product.
    public static func wirePackage(packageDir: URL, target: String, fm: FileManager) throws -> Outcome {
        try PBXThunkIntegration.wirePackage(packageDir: packageDir, target: target, fm: fm)
    }
}
