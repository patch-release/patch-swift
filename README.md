# Patch

**Over-the-air code updates for native Swift iOS apps.**

Write ordinary Swift. Patch works out which parts can run as WebAssembly,
compiles those, and ships them as a small module that runs on-device in
[WasmKit](https://github.com/swiftwasm/WasmKit). Your signed App Store binary
never changes — only the interpreted layer updates. No App Store review, instant
rollback.

```bash
brew install patch-release/tap/patchcli
cd MyApp && patchcli init
```

```
Swift source ──▶ partition ──▶ WebAssembly ──▶ device (WasmKit)
                     │
                     └──▶ anything touching OS APIs stays in your signed binary
```

Not React Native. Not a web view. Not a cross-platform runtime. CodePush and
Expo/EAS Update patch a JavaScript bundle; Shorebird patches Dart. This patches
**Swift**.

📖 **[docs.patchrelease.com](https://docs.patchrelease.com)** · 🚀 [patchrelease.com](https://patchrelease.com)

---

## What's in this repo

| Path | What | Licence |
|---|---|---|
| `Sources/`, `Tests/` | **PatchSDK** — the on-device runtime: WasmKit, value marshalling, update lifecycle, host bridges, the SwiftUI renderer | MIT |
| `cli/` | **patchcli** — the engine: partitioning, Swift→WebAssembly compilation, SwiftUI/UIKit lowering, project integration | Apache-2.0 |
| `docs/` | The documentation site (Astro + Starlight) | MIT |
| `tools/` | Coverage measurement harness and dev tooling | MIT |

The SDK executes a WebAssembly interpreter **inside your users' app**, so it is
MIT — maximally permissive and auditable. The engine is Apache-2.0 for its
**express patent grant**.

The hosted control plane — rollouts, cohorts, targeting, analytics, audit, team
accounts — is a commercial service and is not in this repo. The **update protocol
it speaks is documented**, so you can serve patches from your own infrastructure:
see [Running it yourself](https://docs.patchrelease.com/self-hosting/).

## Install

**SDK** — Swift Package Manager:

```swift
.package(url: "https://github.com/patch-release/patch-swift", from: "1.5.0")
```

**CLI** — Homebrew:

```bash
brew install patch-release/tap/patchcli
```

Or build it from source (see below).

## What it can and can't update

This is the part worth reading before you invest any time.

Across a **24-app public benchmark** — our own apps and well-known open-source
ones — **74.6% of SwiftUI view bodies** lower to WebAssembly and ship over the
air (82.5% measured per element). Per app it ranges from **45% to 98%**.

Three limits are permanent:

- **The binary-symbol wall.** A patch can only call symbols already linked into
  your signed binary. New frameworks, new entitlements, and new native symbols
  need an App Store release.
- **Roughly a quarter of views stay native.** Mostly custom child views the
  engine can't reconstruct, and unsupported modifiers. They still render — they
  just render natively, from your binary.
- **Changing native code invalidates pending patches.** The native shell is
  fingerprinted; edit it and patches built against the old shell stop applying
  until you re-register. That's the safety mechanism, and it's what people hit
  most often.

A view that can't lower is never silently broken, and if a patch fails to run at
all the SDK falls back to the code you shipped through review. An update cannot
take your app down.

Full detail: [what Patch can & can't update](https://docs.patchrelease.com/coverage/).

### Reproduce those numbers

They're generated from a committed census, not typed by hand:

```bash
./corpus/fetch.sh                       # 20 open-source apps, pinned commits
./tools/swiftui-corpus-coverage/run.sh  # the census
```

## Is this allowed by Apple?

Yes, under the provision of the Developer Program License Agreement that permits
an app to download and run **interpreted** code — the same provision Expo/EAS
Update and CodePush have relied on for close to a decade across tens of thousands
of App Store apps.

Your signed binary is never modified, only interpreted WebAssembly updates, and
patched code can only reach the system through host functions your binary already
exposes. Read the detail and the caveats:
[Apple compliance](https://docs.patchrelease.com/apple-compliance/).

## Building from source

```bash
git clone https://github.com/patch-release/patch-swift
cd patch-swift

# SDK
swift build && swift test

# Engine
cd cli && swift build -c release
.build/release/patchcli --help
```

Compiling *to* WebAssembly additionally needs the **swift.org** toolchain plus
the WebAssembly SDK — the Apple/Xcode toolchain cannot target WebAssembly.

```bash
patchcli setup    # installs the pinned toolchain + WASM SDK
patchcli doctor   # checks your setup
```

> **PATH order matters.** Building the CLI for your Mac uses the Apple toolchain;
> compiling patches uses the swift.org one. `setup` and `doctor` handle this — if
> you're doing it by hand, put `/usr/bin` first for host builds and
> `~/.swiftly/bin` first for WebAssembly builds.

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Two things make a bug report immediately actionable:

```bash
patchcli doctor --report   # versions, toolchain, fingerprint state — no source
```

and, if a view didn't patch when you expected it to, the per-view demote
diagnostic that `patchcli build` already prints.

Security issues: please don't open a public issue — see [SECURITY.md](SECURITY.md).

## Licence

SDK MIT · engine Apache-2.0 · see [LICENSE](LICENSE), [cli/LICENSE](cli/LICENSE)
and [NOTICE](NOTICE).
