// MarshalFixture — a tiny stdlib-only WASI reactor module used by the PatchSDK
// tests to round-trip marshalled values through real guest linear memory.
//
// ABI ("Patch v0"):
//   - patch_malloc(i32 size) -> i32 ptr   : reserve `size` bytes of guest memory
//   - patch_free(i32 ptr)                 : release a buffer from patch_malloc
//   - strings/Data cross as (ptr:i32, len:i32) into the exported `memory`
//   - a guest function may "return" a (ptr,len) blob by stashing it in two
//     globals readable via last_result_ptr() / last_result_len().

// MARK: - Linear-memory allocator (host writes args into these buffers)

@_cdecl("patch_malloc")
public func patch_malloc(_ size: Int32) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
}

@_cdecl("patch_free")
public func patch_free(_ ptr: UnsafeMutableRawPointer?) {
    ptr?.deallocate()
}

// MARK: - String / Data round-trips through (ptr,len)

/// Reads `len` bytes at `ptr` as UTF-8 and returns the Swift String's count
/// (Character count) — proves the host wrote a valid, decodable string.
@_cdecl("echo_len")
public func echo_len(_ ptr: UnsafePointer<UInt8>, _ len: Int32) -> Int32 {
    let buf = UnsafeBufferPointer(start: ptr, count: Int(len))
    let s = String(decoding: buf, as: UTF8.self)
    return Int32(s.count)
}

/// Sums the raw bytes at [ptr, ptr+len) — proves Data bytes survive intact.
@_cdecl("sum_bytes")
public func sum_bytes(_ ptr: UnsafePointer<UInt8>, _ len: Int32) -> Int32 {
    let buf = UnsafeBufferPointer(start: ptr, count: Int(len))
    var total: Int32 = 0
    for b in buf { total &+= Int32(b) }
    return total
}

// MARK: - Scalar round-trips

@_cdecl("add_i64")
public func add_i64(_ a: Int64, _ b: Int64) -> Int64 { a &+ b }

@_cdecl("mul_f64")
public func mul_f64(_ a: Double, _ b: Double) -> Double { a * b }

@_cdecl("not_bool")
public func not_bool(_ v: Int32) -> Int32 { v == 0 ? 1 : 0 }

// MARK: - Returning a (ptr,len) blob via globals

// wasm32-unknown-wasip1 is single-threaded; this global is never raced.
nonisolated(unsafe) private var _resultPtr: Int32 = 0
nonisolated(unsafe) private var _resultLen: Int32 = 0

/// Copies the input [ptr,len) into a freshly malloc'd buffer, reverses the
/// bytes, and stashes (ptr,len) for the host to read back. Proves a guest can
/// produce a host-readable blob. Returns the new ptr.
@_cdecl("store_result")
public func store_result(_ ptr: UnsafePointer<UInt8>, _ len: Int32) -> Int32 {
    let n = Int(len)
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    for i in 0..<n { out[i] = ptr[n - 1 - i] }
    // On wasm32 a pointer is a 32-bit linear-memory offset.
    _resultPtr = Int32(bitPattern: UInt32(UInt(bitPattern: UnsafeRawPointer(out))))
    _resultLen = len
    return _resultPtr
}

@_cdecl("last_result_ptr")
public func last_result_ptr() -> Int32 { _resultPtr }

@_cdecl("last_result_len")
public func last_result_len() -> Int32 { _resultLen }

// MARK: - Packed (ptr,len) -> i64 ABI (the engine's generated-export convention)

/// Reverses the input bytes into a freshly `patch_malloc`'d buffer and returns
/// the packed `(outPtr << 32) | outLen` i64 — exactly the ABI the engine's
/// auto-generated `@_cdecl` wrappers and `Patch.callPacked` use. Lets the SDK
/// test the packed-result host primitive against real guest memory.
@_cdecl("reverse_packed")
public func reverse_packed(_ ptr: Int32, _ len: Int32) -> Int64 {
    let n = Int(len)
    let out = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
    let outBytes = out.assumingMemoryBound(to: UInt8.self)
    if n > 0, let inBase = UnsafePointer<UInt8>(bitPattern: Int(ptr)) {
        for i in 0..<n { outBytes[i] = inBase[n - 1 - i] }
    }
    let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
    return (Int64(outPtr) << 32) | Int64(len)
}

/// Copies the input bytes verbatim into a fresh buffer and returns the packed
/// `(ptr,len)` — an identity over the structured blob, so a JSON payload survives
/// unchanged. Lets the SDK test `callJSON` (encode → callPacked → decode) against
/// real guest memory without the guest needing a JSON codec.
@_cdecl("identity_packed")
public func identity_packed(_ ptr: Int32, _ len: Int32) -> Int64 {
    let n = Int(len)
    let out = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
    let outBytes = out.assumingMemoryBound(to: UInt8.self)
    if n > 0, let inBase = UnsafePointer<UInt8>(bitPattern: Int(ptr)) {
        for i in 0..<n { outBytes[i] = inBase[i] }
    }
    let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
    return (Int64(outPtr) << 32) | Int64(len)
}

// MARK: - SwiftUI value-lift exports (`_pv_<Type>_<member>`)
//
// These mirror EXACTLY what the CLI's value-lift codegen emits: a `(ptr,len)->i64`
// export that returns a JSON `{ "value": … }` blob (the generated `_Out`
// envelope). The SDK's `valueJSON`/`callValueJSON` map the dotted key
// (`ProfileCard.primaryFontSize`) → the `_pv_` symbol, dispatch, decode `.value`,
// and cache. The guest hardcodes the JSON bytes (the OTA-editable value lives in
// the WASM module — here, the fixture stands in for that module) so the SDK's
// resolution/marshalling/caching path can be tested against real guest memory
// without bundling Foundation in the stdlib-only fixture.

/// Emit a JSON blob into a fresh `patch_malloc`'d buffer, return packed (ptr,len).
private func emitJSON(_ json: String) -> Int64 {
    let bytes = Array(json.utf8)
    let n = bytes.count
    let out = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 8)
    let outBytes = out.assumingMemoryBound(to: UInt8.self)
    for i in 0..<n { outBytes[i] = bytes[i] }
    let outPtr = Int32(bitPattern: UInt32(UInt(bitPattern: out)))
    return (Int64(outPtr) << 32) | Int64(n)
}

/// `ProfileCard.primaryFontSize` — a CGFloat token lifted as Double. The OTA edit
/// (17 → 22) is captured here as the value the module returns.
@_cdecl("_pv_ProfileCard_primaryFontSize")
public func _pv_ProfileCard_primaryFontSize(_ ptr: Int32, _ len: Int32) -> Int64 {
    emitJSON("{\"value\":22}")   // OTA EDIT: was 17
}

/// `ProfileCard.greeting` — a String label lifted whole ("Hi" → "Welcome back").
@_cdecl("_pv_ProfileCard_greeting")
public func _pv_ProfileCard_greeting(_ ptr: Int32, _ len: Int32) -> Int64 {
    emitJSON("{\"value\":\"Welcome back\"}")   // OTA EDIT: was "Hi"
}

/// `ProfileCard.rowHeight` — a value helper WITH an Int input. Decodes the input
/// JSON minimally (the fixture is stdlib-only, so we scan for the `index` value
/// rather than use Foundation) and returns 64 for index 0, else 44.
@_cdecl("_pv_ProfileCard_rowHeight")
public func _pv_ProfileCard_rowHeight(_ ptr: Int32, _ len: Int32) -> Int64 {
    // Minimal parse: the args envelope is `{"index":<n>}`. Find the digit run.
    var index = -1
    if len > 0, let base = UnsafePointer<UInt8>(bitPattern: Int(ptr)) {
        let buf = UnsafeBufferPointer(start: base, count: Int(len))
        let s = String(decoding: buf, as: UTF8.self)
        if let colon = s.lastIndex(of: ":") {
            let digits = s[s.index(after: colon)...].filter { $0.isNumber }
            index = Int(digits) ?? -1
        }
    }
    return emitJSON("{\"value\":\(index == 0 ? 64 : 44)}")
}
