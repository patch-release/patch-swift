# Proposal: Android support for the Patch SDK

**Status:** Draft for discussion
**Author:** Gregorio Torrezan
**Date:** 2026-10-11

## Summary

Swift now builds for Android with an official toolchain (the Swift SDK for
Android from the swift.org Android workgroup) and with tools like
[Skip](https://skip.tools). Teams that share Swift code between iOS and Android
have no over-the-air update option for the Android side. Flutter has Shorebird
and React Native has CodePush / EAS Update; Swift on Android has nothing.

Patch is well placed to fill that gap. Its update unit is a WebAssembly module,
which doesn't depend on the platform. The same `.wasm` file, backend, dashboard,
channels and rollouts could serve both stores. What's missing is an SDK that
compiles and runs on Android.

I built a prototype on a fork to find out how far the SDK is from building for
Android. The compression and crypto dependencies are solved, and several
targets already build. The rest is mostly structural: deciding where the
Apple-only host bridges live and what they do on Android. Those are product
decisions, so this document lays out the options rather than picking one.

## Why do this

1. **New market with no competitor.** Every Swift-on-Android app is a possible
   customer, and nobody offers OTA updates for them. The pitch stays "this
   patches **Swift**", now on both platforms.
2. **One release, two stores.** A customer fixes a bug in shared Swift code and
   ships one patch to iOS and Android users, with the same rollout controls,
   rollback and analytics.
3. **Most of the stack is reused.** The backend, module format, signing and
   hashing, diffs (BSDIFF40), channels and the dashboard need no changes. The
   SDK core (WasmKit runtime, marshalling, loader, update lifecycle) is mostly
   plain Swift.
4. **Policy precedent exists.** Google Play's Device and Network Abuse policy
   forbids downloading executable code (dex, JAR, `.so`) but exempts "code that
   runs in a virtual machine or an interpreter where either provides indirect
   access to Android APIs". CodePush and Shorebird rely on this exemption, and
   a WebAssembly interpreter is the same model. *This needs legal review before
   we make any public claim.*
5. **Better engineering on iOS too.** A hard line between the
   platform-neutral core and platform bridges makes the core easier to test on
   Linux CI and keeps Apple-framework code from leaking into it.

## Current state (prototype findings)

Prototype setup: Swift 6.4.0 with `swift-6.4.0-RELEASE_android`, Android NDK 27,
Skip 1.9.10, target `aarch64-unknown-linux-android28`. The full macOS test suite
still passes with the prototype changes (1031 tests, 0 failures) and the iOS
Simulator build succeeds.

### Build status on Android

On the `android-prototype` branch, **every target in the package and the full
test bundle build and link for Android** (`swift build --swift-sdk
aarch64-unknown-linux-android28 --build-tests`, and `skip android build`).

**The test suite passes on an Android emulator** (`skip android test`, Android
17, arm64, 16 KB page size): **771 tests, 0 failures, 6 skipped**. The skips
are the same ones that skip on macOS: a fixture that isn't committed, and one
source-audit test. That covers the WasmKit interpreter running real
Swift-compiled guest modules, value marshalling, the module loader, Brotli and
BSDIFF40 diff application, SHA-256 verification, the update lifecycle and
fallback, and the platform-neutral bridges. The remaining ~260 tests of the
macOS suite exercise Apple-only code (SwiftUI/UIKit renderers, CoreImage, PDF)
and are compiled out on Android.

Device findings:

- **HTTPS works** through Foundation's `URLSession` (libcurl) on the emulator.
  TLS and certificate validation needed no extra setup.
- **`file://` URLs are not supported** by `URLSession` on Android
  (`NSURLErrorUnsupportedURL`). `FileDownloadBridge` now copies local files
  directly off Apple platforms. Any other code that loads `file://` URLs
  through `URLSession` will need the same treatment.

| Target | Builds for Android | Notes |
| --- | --- | --- |
| `PatchViewIR` | Yes | Plain Foundation `Codable` types |
| `PatchHostBridge` (with WasmKit) | Yes | The WASM interpreter itself compiles for Android |
| `CBrotliDec` (new) | Yes | See dependency changes below |
| `CBZ2` (vendored) | Yes | See dependency changes below |
| `PatchSDK` | Yes | Apple-only bridges are not registered on Android, see below |
| `PatchRender`, `PatchRenderUIKit`, `PatchSwiftUI`, `PatchUIKit` | Yes, but empty | SwiftUI/UIKit code is guarded out, so there is no renderer on Android yet |
| `PatchSDKTests` | Yes | Tests of Apple-only code use the same guards as that code |

### Dependencies replaced in the prototype

Each one is the reference or vendor-maintained implementation, not a
single-maintainer library.

| Apple-only dependency | Used for | Replacement | Licence |
| --- | --- | --- | --- |
| `Compression` (`COMPRESSION_BROTLI`) | Inflating `.wasm.br` modules | Google's reference Brotli decoder (v1.2.0), vendored as `CBrotliDec`, decoder only | MIT |
| System `libbz2` (not in the Android NDK) | Inflating BSDIFF40 diff blocks | Reference libbzip2 1.0.8 from sourceware.org, vendored as `CBZ2`. It's the same library Apple ships | BSD-style |
| `CryptoKit` | SHA-256 module verification | Apple's [`swift-crypto`](https://github.com/apple/swift-crypto), same API, linked **only** on non-Apple platforms | Apache-2.0 |
| `URLSession` in Foundation | HTTP | `FoundationNetworking` on Android (conditional import) | — |

None of these change behaviour on iOS. The Brotli decoder now also rejects
truncated streams and trailing bytes, and there are tests for both.

### Small portability fixes in the prototype

- `AnalyticsBridge`: CoreFoundation number type checks guarded, with a
  portable fallback.
- `UpdateState`: `ObservableObject` / `@Published` (Combine) only where
  Combine exists.
- `ProcessInfoBridge`: thermal state / low-power mode report neutral values
  off Apple platforms.
- `ResourceOverlayRedirect`: ObjC swizzles skipped without the ObjC runtime.
- `HandoffBridge`: does nothing off Apple platforms.
- `KeychainBridge` and `relative_date_format`: **not registered** on Android.
  There's no `Security` framework, and Foundation on Android has no
  `RelativeDateTimeFormatter`. A no-op keychain would silently drop or expose
  secrets; the right replacement (Android Keystore) needs real Android code.

### What the Android build has today

- 67 source files in `PatchSDK`, 48 of them host bridges. 38 import Apple-only
  frameworks (UIKit, AVFoundation, StoreKit, EventKit, CoreLocation,
  LocalAuthentication, Speech, CoreNFC, CoreMotion, Contacts, …). All of
  those are guarded out on Android, so an Android build gets the core runtime
  plus only the platform-neutral bridges.
- The SDK already follows a "cross-platform core + injected native dependency"
  pattern (see `LocationBridge`). Real Android bridges plug into that, so the
  work is filling it in rather than rewriting.

Still open: a real Android app integration (not just the test runner);
performance and binary size on a physical device; deciding which bridges get
native Android implementations; the package structure (below).

## Decision 1: package structure

### Option A — Split into `PatchCore` + platform packages (recommended)

```
PatchViewIR        portable IR (exists)
PatchHostBridge    portable generic bridge runtime (exists)
PatchCore          runtime, loader, update lifecycle, diff/brotli, SHA-256,
                   HTTP, analytics, platform-neutral bridges
PatchApple         Apple bridges (UIKit, AVFoundation, StoreKit, Keychain, …)
PatchAndroid       Android bridges (Keystore, location, haptics, …)
PatchUI            renderers: SwiftUI / UIKit today, Compose later
PatchSDK           umbrella product that re-exports Core + the right platform
                   package, so existing iOS integrations keep working
```

- **Pros:** clear boundaries; `PatchCore` testable on Linux CI; Android work
  can't regress iOS; every bridge shows plainly which platform it serves.
- **Cons:** largest refactor; public module names change (an umbrella
  `PatchSDK` product limits the damage); `BridgeRegistry` registration has
  to become pluggable per platform.

### Option B — One package, `#if` guards everywhere

Keep the current layout and finish guarding each Apple-only bridge.

- **Pros:** smallest diff; no change to the public API.
- **Cons:** platform code stays mixed into the core; each new bridge is a new
  chance to break Android; harder to tell which bridges an Android customer
  actually gets.

### Option C — Option B now, Option A later

Use guards to get a working Android build soon, then split once there's real
demand.

- **Pros:** fastest proof on a real device; the split can wait for
  customer feedback.
- **Cons:** the refactor still has to happen later, after more code exists.

## Decision 2: what Apple-only bridges do on Android

Every bridge needs a decision, but most will fall into the same buckets.

| Strategy | What the guest sees | Good for |
| --- | --- | --- |
| **Not registered** | The import is missing, so WasmKit fails to instantiate the **whole module** (`WASMRuntime.swift`) and `FallbackManager` falls back to the previous module or native code. Never wrong, but coarse: one call to an unregistered bridge rejects the entire patch on Android | Features with no Android equivalent (Handoff, WatchConnectivity, Spotlight) and anything not yet ported |
| **Portable implementation** | Same behaviour as iOS | Things Swift / Foundation already cover. For example, `SecureRandomBridge` can use `SystemRandomNumberGenerator` (cryptographically secure everywhere) instead of `Security` |
| **Native Android implementation** | Same contract, Android-backed | High-value bridges: secure storage (Android Keystore), location, haptics, open URL, share sheet, biometrics, in-app review |
| **"Unavailable" stub** | Defined error / sentinel value | Only where the bridge contract already has an "unavailable" result (for example, location returns `0` when denied) |

How to call Android APIs from Swift:

- [**swift-java**](https://github.com/swiftlang/swift-java) — official
  swiftlang project for Swift ↔ Java/JNI interop.
- **Skip** — its Fuse mode bridges Swift and Kotlin and already powers
  Swift-on-Android apps.
- **Raw JNI / NDK C APIs** — no dependencies, but the most code to maintain.

Recommendation: ship **"not registered"** as the default (safe: no fake
successes), make the cheap portable fixes, and port the top 5–10 bridges
natively based on what customers actually use. Because one missing import
rejects the whole module, the engine should eventually know which bridges each
platform provides. It could then warn at build time, or emit per-platform
modules, instead of the SDK rejecting the patch at load time.

## Decision 3: UI rendering on Android

`PatchViewIR` already builds for Android. It's the schema the engine emits
for patched views. The renderers are Apple-only.

1. **No patched UI on Android at first.** Ship logic-only patching; views
   always render natively. Lowest risk, still useful (pricing, feature
   flags, business rules, networking).
2. **A Compose renderer for `PatchViewIR`** (Kotlin, or Swift through Skip).
   Same IR, different backend. Gives real UI patching on Android.
3. **Reuse the SwiftUI renderer through Skip**, whose SwiftUI layer renders
   to Jetpack Compose. Possibly the least code, but it ties the product to
   Skip.

Recommendation: ship option 1 first and evaluate options 2 and 3 separately.

## Other work outside the SDK

- **Engine / `patchcli`:** partitioning and the host-bridge resolver thunks
  are generated for the app's native binary. On Android they need building
  with the Android Swift SDK and wiring into a Gradle build. This needs its
  own scoping.
- **Backend:** no change to the module format. We may need a `platform`
  field on update checks, so a release can target iOS only, Android only, or
  both.
- **CI:** add an Android cross-compile job (`swift build --swift-sdk
  aarch64-unknown-linux-android28`) so the core can't regress, and an
  emulator run of the WasmKit test fixtures.

## Risks and open questions

| Risk / question | Notes |
| --- | --- |
| Google Play policy | The interpreter exemption looks like a clear fit, but needs legal sign-off |
| Positioning | The README says "Not a cross-platform runtime". This doesn't change that: it's still native Swift. But marketing should frame it as "Swift, wherever Swift runs" |
| WasmKit on Android | Runs correctly on an arm64 emulator (full runtime test suite passes); performance on a physical device is not yet measured |
| Ecosystem maturity | Swift on Android is new; customer demand needs validating before a large investment |
| Maintenance cost | Two platforms in the bridge test matrix; partly offset by the core split |
| Vendored C code | Brotli and bzip2 need tracking for security advisories. Each vendored folder has a README with the pinned version, commit and update steps |
| Binary size on Android | Not yet measured |

## Proposed phases

| Phase | Scope | Size |
| --- | --- | --- |
| 0 — Done (prototype) | Portable compression and crypto, portability guards; whole package builds for Android and the test suite passes on an emulator (Option C style) | — |
| 1 — Core on Android | Pick an option for Decision 1; CI job running `skip android test` | S–M |
| 2 — Logic patching on a device | Loader + runtime + update flow end to end in a sample Android app; "not registered" default for Apple-only bridges | M |
| 3 — Native Android bridges | Keystore, location, haptics, open URL, share, biometrics, picked by usage data | M–L |
| 4 — Engine + Gradle integration | `patchcli` support for Android projects | L |
| 5 — UI patching | Compose renderer for `PatchViewIR` (or the Skip route) | L |

## Appendix: prototype changes

All on the `android-prototype` branch of a fork, nothing upstream.

- `Package.swift`: new `CBrotliDec` target; `CBZ2` switched from a system
  library to a vendored target; `swift-crypto` added, conditional on
  Android/Linux.
- `Sources/CBrotliDec/`, `Sources/CBZ2/`: vendored sources, upstream
  `LICENSE`, and a `README.md` with provenance and update steps.
- `Brotli.swift`: rewritten on the Brotli streaming decoder API; same public
  API.
- `SHA256.swift` and 2 test files: CryptoKit / Crypto conditional import.
- 9 source files and 12 test files: `FoundationNetworking` conditional import.
- `AnalyticsBridge`, `UpdateState`, `ProcessInfoBridge`,
  `ResourceOverlayRedirect`, `HandoffBridge`, `Bridges.swift` (keychain,
  `jsonGetBool`, `relative_date_format`): guards described above.
- Tests: those exercising Apple-only code (SwiftUI glue, CoreImage, PDF,
  Combine) use the same guard as the code under test; `autoreleasepool` is
  only used where the ObjC runtime exists.
- `DiffApplyTests`: three new Brotli failure-case tests.
- `FileDownloadBridge`: copies `file://` URLs directly off Apple platforms.
- Verified: full macOS suite 1031 tests / 0 failures; iOS Simulator build
  succeeds; Android emulator suite 771 tests / 0 failures.
