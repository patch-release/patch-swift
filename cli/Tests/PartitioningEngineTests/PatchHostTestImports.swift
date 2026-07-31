// SPDX-License-Identifier: Apache-2.0

import Foundation
import WasmKit

/// Shared test helper: register the FULL `patch_host` host-bridge surface into a
/// WasmKit `Imports`, mirroring `PatchSDK.FoundationBridge` (incl. the expanded
/// formatter/regex/date/typed-JSON bridges from research/foundation-bridges).
///
/// The generated C header (`CHeaderBridge.chost.h`) declares ALL host imports, and
/// the C shim's `#include` emits every one as a module import — so a module built
/// with the current `CodeEmitter` imports the whole surface even when a given
/// fragment only calls one. Every test runner must therefore satisfy all of them
/// at instantiation. Implementations are faithful native-Foundation so String /
/// Double T0 fragments round-trip correctly.
enum PatchHostTestImports {
    static func register(into imports: inout Imports, store: Store) {
        func readBytes(_ caller: Caller, _ p: UInt32, _ l: UInt32) -> [UInt8] {
            guard let mem = caller.instance?.exports[memory: "memory"] else { return [] }
            let all = mem.data
            let s = Int(p), e = Int(p) + Int(l)
            guard s >= 0, e <= all.count, l > 0 else { return [] }
            return [UInt8](all[s..<e])
        }
        func packString(_ caller: Caller, _ str: String?) -> Value {
            guard let str, !str.isEmpty,
                  let malloc = caller.instance?.exports[function: "patch_malloc"],
                  let mem = caller.instance?.exports[memory: "memory"] else { return .i64(0) }
            let bytes = [UInt8](str.utf8)
            guard let res = try? malloc.invoke([.i32(UInt32(bytes.count))]),
                  case .i32(let ptr) = res[0], ptr != 0 else { return .i64(0) }
            mem.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { raw in
                raw.copyBytes(from: bytes)
            }
            return .i64((UInt64(ptr) << 32) | UInt64(bytes.count))
        }

        imports.define(module: "patch_host", name: "json_get_i64",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let json = readBytes(caller, args[0].i32, args[1].i32)
                let key = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                      let n = obj[key] as? NSNumber else { return [.i64(0)] }
                return [.i64(UInt64(bitPattern: n.int64Value))]
            })
        imports.define(module: "patch_host", name: "decimal_op",
            Function(store: store, parameters: [.i32, .i64, .i64, .i32], results: [.i64]) { _, _ in [.i64(0)] })
        imports.define(module: "patch_host", name: "now_unix_millis",
            Function(store: store, parameters: [], results: [.i64]) { _, _ in [.i64(0)] })

        imports.define(module: "patch_host", name: "json_get_string",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let json = readBytes(caller, args[0].i32, args[1].i32)
                let key = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any]
                return [packString(caller, obj?[key] as? String)]
            })
        imports.define(module: "patch_host", name: "json_get_f64",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let json = readBytes(caller, args[0].i32, args[1].i32)
                let key = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                      let n = obj[key] as? NSNumber else { return [.i64(0)] }
                return [.i64(n.doubleValue.bitPattern)]
            })
        imports.define(module: "patch_host", name: "json_get_bool",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i32]) { caller, args in
                let json = readBytes(caller, args[0].i32, args[1].i32)
                let key = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                      let raw = obj[key], let b = raw as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID()
                else { return [.i32(UInt32(bitPattern: -1))] }
                return [.i32(b.boolValue ? 1 : 0)]
            })
        imports.define(module: "patch_host", name: "json_get_subobject",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let json = readBytes(caller, args[0].i32, args[1].i32)
                let key = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                      let sub = obj[key], JSONSerialization.isValidJSONObject(sub),
                      let data = try? JSONSerialization.data(withJSONObject: sub, options: [.sortedKeys])
                else { return [.i64(0)] }
                return [packString(caller, String(decoding: data, as: UTF8.self))]
            })
        imports.define(module: "patch_host", name: "number_format",
            Function(store: store, parameters: [.i64, .i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let value = Double(bitPattern: args[0].i64)
                let style = Int32(bitPattern: args[1].i32)
                let frac = Int(Int32(bitPattern: args[2].i32))
                let loc = String(decoding: readBytes(caller, args[3].i32, args[4].i32), as: UTF8.self)
                let f = NumberFormatter()
                f.locale = Locale(identifier: loc.isEmpty ? "en_US" : loc)
                switch style { case 1: f.numberStyle = .currency; case 2: f.numberStyle = .percent; default: f.numberStyle = .decimal }
                f.minimumFractionDigits = frac; f.maximumFractionDigits = frac
                return [packString(caller, f.string(from: NSNumber(value: value)))]
            })
        imports.define(module: "patch_host", name: "regex_find",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let s = String(decoding: readBytes(caller, args[0].i32, args[1].i32), as: UTF8.self)
                let pat = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let re = try? NSRegularExpression(pattern: pat) else { return [.i64(0)] }
                let ns = s as NSString
                guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return [.i64(0)] }
                return [packString(caller, ns.substring(with: m.range))]
            })
        imports.define(module: "patch_host", name: "regex_count",
            Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i32]) { caller, args in
                let s = String(decoding: readBytes(caller, args[0].i32, args[1].i32), as: UTF8.self)
                let pat = String(decoding: readBytes(caller, args[2].i32, args[3].i32), as: UTF8.self)
                guard let re = try? NSRegularExpression(pattern: pat) else { return [.i32(0)] }
                let ns = s as NSString
                return [.i32(UInt32(bitPattern: Int32(re.numberOfMatches(in: s, range: NSRange(location: 0, length: ns.length)))))]
            })
        imports.define(module: "patch_host", name: "date_format",
            Function(store: store, parameters: [.i64, .i32, .i32, .i32, .i32], results: [.i64]) { caller, args in
                let millis = Int64(bitPattern: args[0].i64)
                let fmt = String(decoding: readBytes(caller, args[1].i32, args[2].i32), as: UTF8.self)
                let tz = String(decoding: readBytes(caller, args[3].i32, args[4].i32), as: UTF8.self)
                let f = DateFormatter(); f.dateFormat = fmt
                f.timeZone = TimeZone(identifier: tz.isEmpty ? "UTC" : tz); f.locale = Locale(identifier: "en_US_POSIX")
                return [packString(caller, f.string(from: Date(timeIntervalSince1970: Double(millis) / 1000.0)))]
            })
    }
}
