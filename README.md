# Patch Swift SDK

**Patch** ships over-the-air updates to native iOS and macOS apps. You write
Swift; Patch compiles the changed code to a tiny WebAssembly module and delivers
it to devices without an App Store release. This package is the **on-device
runtime**: it downloads, verifies, caches, and executes those modules safely,
with an always-correct fallback to your shipped app if anything goes wrong.

> **Docs:** full guides and the API reference live at
> **[docs.patchrelease.com](https://docs.patchrelease.com)**.

---

## Install

Add the package with Swift Package Manager:

```swift
// Package.swift
.package(url: "https://github.com/patch-release/patch-swift", from: "1.0.0")
```

```swift
// target dependencies
.product(name: "PatchSDK",     package: "patch-swift"),   // runtime + loader + bridges
.product(name: "PatchSwiftUI", package: "patch-swift"),   // optional: live SwiftUI rendering
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL.

**Requirements:** Swift 6 (Xcode 16+). Platforms: macOS 14+, iOS 16+, tvOS 16+,
visionOS 1+.

The runtime is pure Swift, built on
[WasmKit](https://github.com/swiftwasm/WasmKit) and its WASI Preview 1 host. The
only additional linkages are system frameworks that already ship with the OS
(CryptoKit, Compression, Security, and libbz2), so the SDK adds **no third-party
dependencies** and cross-compiles unchanged for the iOS Simulator and device.

---

## Quick start

```swift
import PatchSDK

// Configure once, early in app launch.
// `apiBaseURL` is optional — it defaults to the production Patch API.
Patch.configure(PatchConfiguration(
    appKey: "<your app key>",
    appID: "<your app id>",
    fingerprint: "<build fingerprint>",
    deviceID: "<stable anonymous id>"))

// Optionally ship an in-app module as the bundled fallback.
Patch.shared.registerBundledModule(version: "1.0.0", bytes: bundledWasmBytes)

// Activate the best cached/bundled module immediately (offline-safe),
// then poll for an update in the background.
await Patch.shared.start()

// Call into the active module:
let total = try Patch.shared.call("calculate_order_total", order, returning: Int.self)
```

`Patch.configure(_:)` sets up the on-disk cache, the default host bridges, and
the update checker. `Patch.shared.start()` activates the best available module
through the fallback chain (so the app always launches, even offline) and then
checks the backend for a newer one. Point `apiBaseURL` at a self-hosted or
staging backend if you aren't using the hosted Patch API, or pass `nil` to
disable remote update checks entirely.

### Imperative updates

If you'd rather control when updates apply, use the report-only API instead of
`start()`'s auto-apply:

```swift
if let info = try await Patch.shared.checkForUpdate() {
    try await Patch.shared.fetchUpdate()   // download + verify, don't apply yet
    try Patch.shared.reloadAsync()         // hot-swap the new module in now
}
```

`Patch.shared.updateState` is a `@MainActor` observable you can bind directly in
SwiftUI to drive update banners or prompts.

---

## How it works

### Safe activation and fallback

`Patch` keeps three module slots: **current** (the active OTA module),
**previous** (the prior OTA module, for one-step rollback without a network
call), and **bundled** (a module you ship inside the app, the last rung before
running no OTA module at all).

On activation, `FallbackManager` walks **current → previous → bundled →
disabled**. Each rung is validated by actually instantiating it (with an
optional smoke-test probe), so a module that fails to load or traps on a key
export is skipped. If nothing activates, Patch lands on **disabled** — your
native app keeps working and is never crashed by a bad patch.

### Download, verify, decompress

`ModuleLoader` runs the full pipeline: download → (brotli) decompress → SHA-256
verify against the backend's hash → cache → activate. Verification is over the
raw, uncompressed bytes; a mismatch is rejected before anything is cached or
activated. When the backend offers a binary diff, the loader applies a
client-side **bsdiff4 (BSDIFF40)** patch against the cached previous module and
re-verifies the result. Any diff problem cleanly falls back to a full download,
so the diff path is purely a bandwidth optimization — the full download is
always correct.

### Thread safety

Every host→WASM call funnels through a serial dispatch queue, so the
single-threaded WASM instance is never re-entered concurrently. A
`pthread_rwlock` guards the active module: calls hold the read lock for their
whole duration, while hot-swap builds the new instance off-lock and swaps it in
under the write lock — so a swap can never free a runtime out from under an
in-flight call.

---

## Calling convention (the Patch ABI)

### Scalars

| Swift type        | WASM value |
|-------------------|------------|
| `Bool`, `Int32`   | `i32`      |
| `Int`, `Int64`    | `i64`      |
| `Double`          | `f64`      |

(`Int` is 64-bit on all Apple targets, so it marshals as `i64`.)

### Strings, Data, and Codable

Variable-length values cross as a `(ptr: i32, len: i32)` pair into the module's
exported `memory` (no NUL terminator; the length is explicit). The host reserves
guest memory through the module's exported allocator (`patch_malloc`), writes
the bytes, calls the export, then frees with `patch_free`.

- **String** — UTF-8 bytes.
- **Data** — raw bytes.
- **Codable** — a MessagePack-encoded blob. Wrap a value in `MessagePackBridge`
  to marshal it. The codec is a small, vendored, pure-Swift implementation, so
  the SDK has zero native-only dependencies.

### Optionals

`tag = 0` means `nil` (no value words follow); `tag = 1` means present, followed
by the wrapped type's own value words.

### Marshalling API

```swift
let ctx = MarshalContext(runtime: runtime)
defer { ctx.release() }                  // frees buffers allocated during the call
let args = try "hello".lower(into: ctx)  // -> [.i32(ptr), .i32(len)]
var i = 0
let s = try String.raise(from: results, index: &i, ctx: ctx)

// Codable via MessagePack:
let blob = MessagePackBridge(myCodableStruct)
```

---

## Host bridges

A bridge exposes a native capability to the guest module as an importable host
function. PatchSDK ships a broad set of bridges (networking, storage,
notifications, navigation, Keychain, date/locale, JSON, logging, analytics,
camera, location, contacts, calendar, haptics, biometrics, and many more), all
registered under the `patch` / `patch_host` import namespaces.

Variable-length results use a packed convention: a bridge writes bytes into
guest memory via `patch_malloc` and returns a single `i64` packing
`(ptr << 32) | len`; the guest unpacks, reads the range, and frees it. `0` means
nil. `BridgeContext` wraps the call so bridges get bounds-checked
read/write/alloc against the calling instance's memory.

### Custom bridges

`Patch.shared.bridges` is a `BridgeRegistry`. Register your own before
`configure`/`start`:

```swift
// A whole Bridge:
Patch.shared.bridges.register(MyAnalyticsBridge())

// Or a single raw host function (lowest level):
Patch.shared.bridges.registerFunction(
    module: "patch", name: "my_fn",
    parameters: [.i32, .i32], results: [.i64]
) { caller, args in
    let ctx = BridgeContext(caller: caller)
    let input = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
    return [try ctx.packedResult(myNativeWork(input))]
}
```

---

## Live SwiftUI rendering (optional)

`PatchSwiftUI` lets a module's SwiftUI view render as **real** SwiftUI on device
and run its interaction logic in the sandbox. The guest emits a `ViewNode` tree
across the boundary; `PatchRender` reconstitutes it into real `Text`, stacks,
modifiers, and controls. A user interaction dispatches back into the guest,
which re-emits the tree, and the host re-renders. `PatchViewIR` is the shared,
dependency-free IR; depend on it alone to build or inspect a `ViewNode` tree.

---

## Binary size

The realistic, dead-stripped contribution to a shipping iOS app is **~1.1–1.5
MiB** (≈1.1 MiB of loadable code/data; ~1.5 MiB as a conservative on-disk
number). PatchSDK links only the three WasmKit runtime products it needs — the
text-format and component tooling are never pulled in. System frameworks
(CryptoKit, Compression, Security, libbz2) ship with the OS and add effectively
nothing.

---

## Build & test

Use the standard Apple/Xcode toolchain — this is a normal Swift package:

```bash
swift build
swift test
```

### iOS cross-compile

```bash
# Simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build -Xswiftc -sdk -Xswiftc "$SDK" \
  -Xswiftc -target -Xswiftc arm64-apple-ios16.0-simulator

# Device
ISDK=$(xcrun --sdk iphoneos --show-sdk-path)
swift build -Xswiftc -sdk -Xswiftc "$ISDK" \
  -Xswiftc -target -Xswiftc arm64-apple-ios16.0
```

`Examples/PatchSDKDemo` is a minimal SwiftUI app that links the SDK and runs a
real WebAssembly module on the iOS Simulator; see `Examples/README.md`.

---

## License

[MIT](LICENSE).
