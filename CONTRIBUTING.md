# Contributing to Patch

Thanks for your interest. This repository holds two Swift packages:

| Directory | What it is | License |
|---|---|---|
| `sdk/` | **PatchSDK** — the on-device runtime: WebAssembly execution, value marshalling, update lifecycle, host bridges, the SwiftUI/UIKit renderers. | MIT (`LICENSE`) |
| `cli/` | The **engine** and the `patchcli` tool — project partitioning, the Swift→WebAssembly compile pipeline, SwiftUI/UIKit lowering, fingerprinting. | Apache-2.0 (`cli/LICENSE`) |

They are independent SwiftPM packages with no cross-import. A change that
touches the view IR wire format must be applied to **both** — each vendors its
own copy of the schema, and they must stay in sync.

---

## Prerequisites

### Two toolchains, and the difference matters

This is the single thing that trips up new contributors.

* **Building and testing the packages themselves** uses the **Apple toolchain**
  that ships with Xcode. Xcode 16 or newer; the packages declare
  `swift-tools-version:6.0`.
* **Compiling Swift *to* WebAssembly** — what the engine actually does — needs a
  **swift.org toolchain plus the WebAssembly SDK**, installed via
  [swiftly](https://www.swift.org/swiftly/). **Apple's toolchain cannot target
  WebAssembly at all**; there is no flag that makes it work.

Install the swift.org toolchain and the WASM SDK:

```bash
curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash
swiftly install latest
swift sdk install <the WebAssembly SDK bundle URL for your toolchain version>
```

### PATH order is load-bearing

Both toolchains put a `swift` on your PATH. Which one wins is decided purely by
order, and picking the wrong one produces confusing failures (a host build
against the swift.org toolchain, or "unable to find WebAssembly SDK" against
Apple's). Export the right one for what you are doing:

```bash
# Host build / running the test suites — Apple toolchain first:
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; hash -r

# Compiling to WebAssembly — swiftly toolchain first:
export PATH="$HOME/.swiftly/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"; hash -r
```

The `hash -r` matters: your shell caches resolved binary paths, so without it
you can change `PATH` and still invoke the previous `swift`.

Tests that need the WebAssembly toolchain check for it and **skip** when it is
absent, so you can contribute to most of the codebase with Xcode alone.

---

## Building and testing

Each package builds and tests independently:

```bash
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; hash -r

cd sdk && swift build && swift test
cd ../cli && swift build && swift test
```

Run a focused suite while iterating — the full engine suite is slow locally
because the WebAssembly-compiling tests run serially:

```bash
swift test --filter SwiftUILoweringTests
swift test --filter FingerprintRound2Tests
```

CI runs the full suite and is the authoritative gate. Locally, prefer
fail-fast on the suites your change touches, then let CI run everything.

### Benchmarks and measurement harnesses

Some suites are measurement harnesses rather than assertions. They are gated
behind environment variables and skip by default:

| Variable | Enables |
|---|---|
| `PATCH_CORPUS` / `PATCH_CORPUS_ROOT` | Where the local app corpus lives (defaults to `<repo>/corpus/repos`). The corpus is not in git; suites that need it skip when it is absent. |
| `PATCH_T0_MEASURE=1` | Module-size / tier-routing measurements. |
| `PATCH_THUNK_CORPUS=1`, `PATCH_UIKIT_CORPUS_MEASURE=1` | Corpus-wide lowering measurements. |
| `PATCH_BENCH_OUT` | Where the SDK render benchmarks write their reports (defaults under the system temp dir). |

### "AppA", "AppB" … in comments

Many engine comments explain *why* a lowering rule or a demote-guard exists by
pointing at the real app whose view first exposed the problem. Where that app is
closed-source, it is referred to by a stable alias — `AppA`, `AppB`, and so on.
The aliases are consistent across the codebase, so "AppA 44→45" in one comment
and "the AppA `SettingsScreen`" in another mean the same app. Open-source corpus
apps are named directly.

Nothing in the suite may depend on a path inside a particular contributor's home
directory. If you add a harness that reads or writes outside the repo, drive it
from an environment variable with a repo-relative or temp-directory default, and
skip cleanly when the input is missing.

---

## Making a change

1. **Open an issue first** for anything substantial, so we can agree on the
   approach before you spend time on it. Small fixes can go straight to a PR.
2. **Branch from `main`.**
3. **Keep the change focused.** Unrelated reformatting makes review harder.
4. **Add a test.** Engine changes especially: a lowering change should come with
   a test that pins both the positive case *and* the case that must still demote
   to native. Silent over-lowering is the failure mode that matters here.
5. **Do not regress demote-safety.** The engine's core guarantee is that
   anything it cannot prove it can lower correctly stays native. A change that
   widens coverage must not widen it past what it can prove.
6. **Run the relevant suites** before pushing.

### Commit style

Conventional-commit prefixes, with the affected component in parentheses:

```
fix(cli): non-ASCII Text literals ride WASM regardless of guest toolchain
feat(sdk): per-row indexed native-action slot renderer path
docs: clarify the two-toolchain setup
```

---

## Developer Certificate of Origin

Contributions to this project are accepted under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/). It is
a short statement that you wrote the patch, or otherwise have the right to
submit it under the project's license.

You certify the DCO by adding a `Signed-off-by` line to each commit, with your
real name and an email address you can be reached at:

```
Signed-off-by: Jane Developer <jane@example.com>
```

`git commit -s` adds it for you. To sign off a series you already wrote:

```bash
git rebase --signoff main
```

Commits without a sign-off cannot be merged.

By contributing, you agree your contribution is licensed under the license of
the directory it lands in — MIT for `sdk/`, Apache-2.0 for `cli/`.

### License headers

New Swift source files carry an SPDX identifier on the first line:

```swift
// SPDX-License-Identifier: MIT          // for files under sdk/
// SPDX-License-Identifier: Apache-2.0   // for files under cli/
```

---

## Reporting bugs

Include the output of `patchcli doctor`, your Xcode and swift.org toolchain
versions, and — for a lowering or fingerprint issue — the smallest SwiftUI view
that reproduces it. A view that reproduces the problem is worth more than a
description of it.

**Do not open a public issue for a security vulnerability.** See
[`SECURITY.md`](SECURITY.md).

---

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
