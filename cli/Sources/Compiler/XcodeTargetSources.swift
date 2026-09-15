// SPDX-License-Identifier: Apache-2.0

// XcodeTargetSources.swift — which Swift files does an Xcode target actually COMPILE?
//
// `patchcli prepare` scans every `.swift` file under the project root. In a multi-target
// project (an app + widget/watch/macOS targets, a local Swift package, a file on disk that
// was removed from the project) that set is much larger than the app target's compile set,
// and a thunk generated for a view the app target does not compile breaks the app build:
//   * the generated file (added to the app target) extends a type the target can't see
//     (`cannot find type 'DailyDonutWidgetView' in scope`), or a type from another module
//     whose members are `internal` there (`'module' is inaccessible due to 'internal'`);
//   * a same-file block lands in a widget/package file whose target doesn't link PatchSDK
//     (`no such module 'PatchSDK'`).
// This resolves the target's real compile set from the `.pbxproj` so prepare only thunks
// views the target builds. Handles classic `PBXSourcesBuildPhase` membership AND Xcode 16
// synchronized folders (`PBXFileSystemSynchronizedRootGroup` + membership exceptions).

import Foundation

public enum XcodeTargetSources {

    /// PatchSDK's minimum iOS deployment target (`sdk/Package.swift` `.iOS(.v16)`). An app target
    /// below it cannot `import PatchSDK` — `compiling for iOS 14.0, but module 'PatchSDK' has a
    /// minimum deployment target of iOS 16.0` in every generated thunk file.
    public static let sdkMinimumIOS = "16.0"

    /// The LOWEST `IPHONEOS_DEPLOYMENT_TARGET` the native target `target` builds with — the
    /// target's own build configurations, falling back to the project-level configurations for any
    /// that don't set it. nil when undeterminable (no such target, no iOS setting).
    public static func iOSDeploymentTarget(projectURL: URL, target: String) -> String? {
        let pbx = projectURL.appendingPathComponent("project.pbxproj")
        guard let text = try? String(contentsOf: pbx, encoding: .utf8) else { return nil }
        return iOSDeploymentTarget(pbxproj: text, target: target)
    }

    public static func iOSDeploymentTarget(pbxproj text: String, target: String) -> String? {
        guard let root = OpenStepPlist.parse(text) as? [String: Any],
              let objects = root["objects"] as? [String: Any] else { return nil }
        func obj(_ id: String) -> [String: Any]? { objects[id] as? [String: Any] }
        func settings(_ listID: String?) -> [[String: Any]] {
            guard let listID, let list = obj(listID) else { return [] }
            return (list["buildConfigurations"] as? [String] ?? []).compactMap { obj($0)?["buildSettings"] as? [String: Any] }
        }
        guard let t = objects.values.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == target }) else { return nil }
        let projectLevel = (root["rootObject"] as? String).flatMap { obj($0)?["buildConfigurationList"] as? String }
        let projectValues = settings(projectLevel).compactMap { $0["IPHONEOS_DEPLOYMENT_TARGET"] as? String }
        var values = settings(t["buildConfigurationList"] as? String).compactMap { $0["IPHONEOS_DEPLOYMENT_TARGET"] as? String }
        if values.isEmpty { values = projectValues }
        return values.filter { !$0.contains("$") }.min { versionPrecedes($0, $1) }
    }

    /// Numeric version order (`9.3` < `14.0` < `16.0`).
    public static func versionPrecedes(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// The target's iOS deployment target when it is BELOW PatchSDK's minimum, else nil.
    public static func deploymentTargetBelowSDKMinimum(projectURL: URL, target: String) -> String? {
        guard let dt = iOSDeploymentTarget(projectURL: projectURL, target: target),
              versionPrecedes(dt, sdkMinimumIOS) else { return nil }
        return dt
    }

    /// Standardized absolute paths of the `.swift` files the native target `target` compiles,
    /// or nil when membership can't be determined (unreadable/unparseable pbxproj, no target of
    /// that name, or a target with neither a Sources phase entry nor a synchronized folder) —
    /// callers treat nil as "don't filter".
    public static func swiftFiles(projectURL: URL, target: String,
                                  fm: FileManager = .default) -> Set<String>? {
        let pbx = projectURL.appendingPathComponent("project.pbxproj")
        guard let text = try? String(contentsOf: pbx, encoding: .utf8) else { return nil }
        return swiftFiles(pbxproj: text, projectDir: projectURL.deletingLastPathComponent(),
                          target: target, fm: fm)
    }

    /// Pure core over the pbxproj text (the project directory anchors `SOURCE_ROOT` paths).
    public static func swiftFiles(pbxproj text: String, projectDir: URL, target: String,
                                  fm: FileManager = .default) -> Set<String>? {
        guard let root = OpenStepPlist.parse(text) as? [String: Any],
              let objects = root["objects"] as? [String: Any] else { return nil }
        func obj(_ id: String) -> [String: Any]? { objects[id] as? [String: Any] }

        guard let (targetID, targetObj) = objects.lazy
            .compactMap({ (id, value) -> (String, [String: Any])? in
                guard let o = value as? [String: Any], o["isa"] as? String == "PBXNativeTarget",
                      o["name"] as? String == target else { return nil }
                return (id, o)
            }).first else { return nil }

        // Project directory (+ the root PBXProject's optional `projectDirPath`).
        var baseDir = projectDir
        if let rootID = root["rootObject"] as? String, let proj = obj(rootID),
           let dirPath = proj["projectDirPath"] as? String, !dirPath.isEmpty {
            baseDir = dirPath.hasPrefix("/") ? URL(fileURLWithPath: dirPath)
                : projectDir.appendingPathComponent(dirPath)
        }

        // child id → parent group id (for `<group>`-relative path resolution).
        var parent: [String: String] = [:]
        for (id, value) in objects {
            guard let o = value as? [String: Any], let children = o["children"] as? [String] else { continue }
            for c in children { parent[c] = id }
        }
        var resolved: [String: URL?] = [:]
        func resolve(_ id: String, depth: Int = 0) -> URL? {
            if let cached = resolved[id] { return cached }
            guard depth < 64, let o = obj(id) else { return nil }
            let path = o["path"] as? String
            let tree = o["sourceTree"] as? String ?? "<group>"
            var out: URL?
            switch tree {
            case "<absolute>":
                out = path.map { URL(fileURLWithPath: $0) }
            case "SOURCE_ROOT":
                out = path.map { baseDir.appendingPathComponent($0) } ?? baseDir
            case "<group>":
                let base: URL?
                if let p = parent[id] { base = resolve(p, depth: depth + 1) } else { base = baseDir }
                if let base { out = path.map { base.appendingPathComponent($0) } ?? base }
            default:
                out = nil   // BUILT_PRODUCTS_DIR / SDKROOT / DEVELOPER_DIR — never app sources.
            }
            resolved[id] = .some(out)
            return out
        }

        var files = Set<String>()
        var determinable = false

        // (1) Classic membership: the target's Sources build phase(s).
        for phaseID in targetObj["buildPhases"] as? [String] ?? [] {
            guard let phase = obj(phaseID), phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
            for buildFileID in phase["files"] as? [String] ?? [] {
                determinable = true
                guard let bf = obj(buildFileID), let ref = bf["fileRef"] as? String,
                      let url = resolve(ref), url.pathExtension == "swift" else { continue }
                files.insert(url.standardizedFileURL.path)
            }
        }

        // (2) Xcode 16 synchronized folders attached to the target, minus the exceptions that
        // exclude files from THIS target.
        for groupID in targetObj["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let group = obj(groupID), let dir = resolve(groupID) else { continue }
            determinable = true
            var excluded = Set<String>()
            for exID in group["exceptions"] as? [String] ?? [] {
                guard let ex = obj(exID),
                      ex["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet",
                      ex["target"] as? String == targetID else { continue }
                for rel in ex["membershipExceptions"] as? [String] ?? [] {
                    excluded.insert(dir.appendingPathComponent(rel).standardizedFileURL.path)
                }
            }
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                let p = url.standardizedFileURL.path
                if excluded.contains(p) || excluded.contains(where: { p.hasPrefix($0 + "/") }) { continue }
                files.insert(p)
            }
        }
        return determinable ? files : nil
    }
}

/// A minimal parser for the OpenStep-style property list `.pbxproj` files use: dictionaries
/// `{ k = v; }`, arrays `( a, b, )`, quoted/unquoted strings, and `/* */` + `//` comments.
/// Returns `[String: Any]` / `[Any]` / `String`, or nil on malformed input.
enum OpenStepPlist {
    static func parse(_ text: String) -> Any? {
        var p = Parser(Array(text.utf8))
        p.skipTrivia()
        // An optional `// !$*UTF8*$!` header is just a comment.
        let value = p.parseValue()
        return value
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { b = bytes }

        mutating func skipTrivia() {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
                if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2A {          // /* … */
                    i += 2
                    while i + 1 < b.count, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                    i = min(i + 2, b.count); continue
                }
                if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2F {          // // …
                    while i < b.count, b[i] != 0x0A { i += 1 }
                    continue
                }
                break
            }
        }

        mutating func parseValue() -> Any? {
            skipTrivia()
            guard i < b.count else { return nil }
            switch b[i] {
            case 0x7B: return parseDict()      // {
            case 0x28: return parseArray()     // (
            case 0x22: return parseQuoted()    // "
            default: return parseBare()
            }
        }

        mutating func parseDict() -> [String: Any]? {
            i += 1
            var out: [String: Any] = [:]
            while true {
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == 0x7D { i += 1; return out }                     // }
                guard let key = (b[i] == 0x22 ? parseQuoted() : parseBare()) else { return nil }
                skipTrivia()
                guard i < b.count, b[i] == 0x3D else { return nil }       // =
                i += 1
                guard let value = parseValue() else { return nil }
                out[key] = value
                skipTrivia()
                guard i < b.count, b[i] == 0x3B else { return nil }       // ;
                i += 1
            }
        }

        mutating func parseArray() -> [Any]? {
            i += 1
            var out: [Any] = []
            while true {
                skipTrivia()
                guard i < b.count else { return nil }
                if b[i] == 0x29 { i += 1; return out }                     // )
                guard let v = parseValue() else { return nil }
                out.append(v)
                skipTrivia()
                if i < b.count, b[i] == 0x2C { i += 1 }                    // ,
            }
        }

        mutating func parseQuoted() -> String? {
            i += 1
            var bytes: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return String(decoding: bytes, as: UTF8.self) }
                if c == 0x5C, i + 1 < b.count {                            // backslash escape
                    let n = b[i + 1]
                    switch n {
                    case 0x6E: bytes.append(0x0A)
                    case 0x74: bytes.append(0x09)
                    default: bytes.append(n)
                    }
                    i += 2; continue
                }
                bytes.append(c); i += 1
            }
            return nil
        }

        mutating func parseBare() -> String? {
            let start = i
            while i < b.count {
                let c = b[i]
                let ok = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                    || c == 0x5F || c == 0x24 || c == 0x2F || c == 0x3A || c == 0x2E || c == 0x2D || c == 0x2B
                    || c == 0x3C || c == 0x3E || c == 0x40 || c >= 0x80
                if !ok { break }
                i += 1
            }
            return i > start ? String(decoding: b[start..<i], as: UTF8.self) : nil
        }
    }
}
