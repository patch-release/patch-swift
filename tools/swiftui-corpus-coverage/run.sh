#!/usr/bin/env bash
# SwiftUI-lowering CORPUS COVERAGE harness — one-command runner.
# =============================================================
# Builds the census driver (against THIS worktree's engine) and runs it over a
# corpus of real apps, printing per-app coverage + the ranked demote histogram.
#
# Usage:
#   ./run.sh                         # census the default corpus (corpus.manifest.txt)
#   ./run.sh --markdown              # emit the Markdown report (for docs/CI artifacts)
#   ./run.sh /path/to/app ...        # census specific app dirs (ignores the manifest)
#   ./run.sh --manifest mylist.txt   # census the dirs listed in a manifest file
#   COVERAGE_MANIFEST=foo.txt ./run.sh   # override the default manifest path
#
# The corpus itself is LOCAL/gitignored — this script ships only the runner +
# driver + the manifest of well-known paths. Missing paths are skipped + reported
# (so it degrades gracefully on a machine without the full corpus).
#
# Exit status: 0 on a successful census (it's a measurement, not a gate); non-zero
# only on a build failure or bad invocation. To use as a CI GATE, parse the
# "CORPUS-COVERAGE headline" line on stderr and threshold it (see README).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Host toolchain (Apple/Xcode) — NOT the WASM toolchain. The census never compiles
# to WASM, so we want the host Swift on PATH.
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
hash -r

echo ">> building census driver (release) against the local engine ..." >&2
swift build -c release >&2

BIN="$(swift build -c release --show-bin-path)/swiftui-coverage"
if [[ ! -x "$BIN" ]]; then
  echo "!! build did not produce $BIN" >&2
  exit 1
fi

# Detect whether the caller supplied their own targets: any explicit positional
# path, or an explicit --manifest. If so, don't inject the default manifest.
HAS_TARGETS=0
prev=""
for a in "$@"; do
  if [[ "$a" == "--manifest" ]]; then HAS_TARGETS=1; fi
  if [[ "$a" != --* && "$prev" != "--manifest" && "$prev" != "--examples" ]]; then
    HAS_TARGETS=1
  fi
  prev="$a"
done

ARGS=("$@")
if [[ "$HAS_TARGETS" == "0" ]]; then
  MANIFEST="${COVERAGE_MANIFEST:-$HERE/corpus.manifest.txt}"
  if [[ -f "$MANIFEST" ]]; then
    echo ">> using default corpus manifest: $MANIFEST" >&2
    ARGS+=(--manifest "$MANIFEST")
  else
    echo "!! no app dirs given and no manifest at $MANIFEST" >&2
    echo "   pass app dirs explicitly, or create the manifest (see README)." >&2
    exit 2
  fi
fi

exec "$BIN" "${ARGS[@]}"
