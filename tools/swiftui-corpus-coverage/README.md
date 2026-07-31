# SwiftUI-lowering corpus coverage

A repeatable census that measures **what fraction of real apps' SwiftUI views
actually lower to WASM (auto-route OTA) vs demote to native** — and ranks **why**
the demotes happen.

This exists because we discovered (the hard way, on a real app) that custom
design-system tokens make ~all views demote. We should have caught that by
measuring the corpus. This harness *is* that measurement, runnable as a one-liner
so it can become a dev/CI gate.

## What it measures

For every `: View` struct in an app's **developer source** (it deliberately skips
SwiftPM checkouts, `build/`/`DerivedData`, Pods, and Patch's own generated thunk/IR
files), the census runs the engine's `BodyLowering.lowerAllViews` and applies the
**exact production routing verdict** from `Compiler/BuildPipeline.runSwiftUILowering`:

- A view is **EXCLUDED** (renders native, not OTA-patchable) if it
  `referencesUnmarshalledInput` — it reads a struct/enum/dict/custom value the
  Foundation-free guest can't reconstruct (e.g. a model struct, a view-model, an
  `@ObservedObject`).
- Otherwise the engine computes
  `thunkSafe = opaqueLeaves.allSatisfy { $0.slotable } && report.hasLoweredContentNode`.
- A view with **0 classified elements** (empty/odd body) is nothing to ship.

A view **LOWERS** (the headline metric) iff it is emitted, `thunkSafe`, and not
excluded — i.e. the SDK would auto-route it OTA with **no `PatchView` wrapper**.
Anything else **DEMOTES**: it still renders, but an OTA patch never reaches it.

Two coverage numbers are reported:

1. **View-level coverage** (the headline) — `lowered views / total views`. This is
   what "an OTA patch can change this screen" means in practice.
2. **Element-level coverage** (secondary) — `lowered body elements / total body
   elements` (`LoweringReport.coverage`). A finer signal: a demoted view can still
   be 90% lowered and just trip on one token modifier.

It never compiles to WASM — the static classification + emission *is* the verdict,
and it's fast (the whole corpus censuses in seconds).

## Run it

```bash
cd tools/swiftui-corpus-coverage

./run.sh                      # census the default corpus (corpus.manifest.txt), plain text
./run.sh --markdown           # same, as a Markdown report (what docs/SWIFTUI-CORPUS-COVERAGE.md holds)
./run.sh /path/to/MyApp ...   # census specific app dirs instead
./run.sh --manifest list.txt  # census the dirs in a custom manifest
COVERAGE_MANIFEST=foo.txt ./run.sh   # override the default manifest path
./run.sh --examples 5         # show up to 5 examples per demote reason (default 3)
```

`run.sh` builds the driver against **this worktree's** engine (a local
`.package(path: "../../cli")` dependency — no fork, no copy) and runs it.

### Direct (no wrapper)

```bash
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; hash -r
swift build -c release
.build/release/swiftui-coverage --markdown ~/path/to/app1 ~/path/to/app2
```

## The corpus

The corpus is **local / gitignored** — only this harness (runner + driver +
manifest of well-known paths) is committed. `corpus.manifest.txt` lists the
default paths; the census **skips any path that doesn't exist and reports it**, so
it degrades gracefully on a machine without the full corpus.

Default corpus paths:

- **`~/patch-corpus/private-apps/*`** — 11 closed-source App Store apps
  (`AppA` … `AppK`). **These are the most important** — real apps with real
  design systems. Their sources aren't public, so a fresh checkout won't have
  them and the census will skip and report them; substitute your own apps.
- **`~/patch-corpus/repos/*`** — OSS SwiftUI apps
  (clean-architecture-swiftui, MovieSwiftUI, ACHNBrowserUI, isowords, IceCubesApp,
  SwiftHub, kiwix-apple, exyte-Chat, GoCycling, Pulse, WWDC, NetNewsWire, Gifski,
  WhatsNewKit, wire-ios, firefox-ios, wikipedia-ios, …).

Edit `corpus.manifest.txt` to add/remove apps.

## Using it as a CI / dev gate

The driver prints a machine-greppable headline to **stderr**:

```
CORPUS-COVERAGE headline: 412/930 views lower OTA = 44.3%
```

A gate can threshold it:

```bash
pct=$(./run.sh 2>&1 1>/dev/null | sed -n 's/.*= \([0-9.]*\)%/\1/p')
awk -v p="$pct" 'BEGIN { exit !(p+0 >= 40.0) }' || { echo "coverage regressed: $pct%"; exit 1; }
```

(The census itself always exits 0 on success — it's a measurement, not a gate —
so a wrapper owns the threshold policy.)

## Files

- `Package.swift` — standalone SwiftPM package; depends on the engine's
  `CodeGenerator` via `../../cli`.
- `Sources/swiftui-coverage/main.swift` — the driver (discovery, verdict, ranking,
  text + Markdown reporting).
- `run.sh` — the one-command runner.
- `corpus.manifest.txt` — the default list of app dirs.

The baseline results + ranked demote histogram live in
[`docs/SWIFTUI-CORPUS-COVERAGE.md`](../../docs/SWIFTUI-CORPUS-COVERAGE.md).
