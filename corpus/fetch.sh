#!/usr/bin/env bash
# Patch corpus fetcher — reconstitute the OSS half of the coverage corpus.
# =======================================================================
# `corpus/repos/` is gitignored (the apps are third-party source, and some are
# large). Without it the coverage census can only measure the private real-app
# half, and NOBODY OUTSIDE can reproduce a published coverage number at all.
#
# Every entry in `corpus/manifest.yml` carries a repo URL AND a pinned
# `commit_sha`, so the corpus is exactly reproducible — this script is the
# missing piece that turns "trust our number" into "run it yourself".
#
# Usage:
#   ./fetch.sh                   # fetch every repo the coverage manifest needs
#   ./fetch.sh --all             # fetch ALL repos in manifest.yml (~50), not just those
#   ./fetch.sh IceCubesApp Pulse # fetch specific repos by name
#   ./fetch.sh --list            # print what would be fetched, fetch nothing
#
# Idempotent: a repo already checked out at the pinned SHA is left alone, so
# re-running is cheap. Shallow-fetches the single pinned commit where the server
# allows it (GitHub does), falling back to a full clone.
#
# Exit status: 0 if every requested repo ended up at its pinned SHA.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.yml"
REPOS_DIR="$HERE/repos"
COVERAGE_MANIFEST="$HERE/../tools/swiftui-corpus-coverage/corpus.manifest.txt"

[[ -f "$MANIFEST" ]] || { echo "!! missing $MANIFEST" >&2; exit 2; }

MODE="coverage"
declare -a EXPLICIT=()
for arg in "$@"; do
  case "$arg" in
    --all)  MODE="all" ;;
    --list) MODE="${MODE}-list" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "!! unknown flag: $arg" >&2; exit 2 ;;
    *)  EXPLICIT+=("$arg") ;;
  esac
done
[[ ${#EXPLICIT[@]} -gt 0 ]] && MODE="explicit${MODE#coverage}"

# --- Resolve name → (url, sha) from the YAML manifest -----------------------
# Deliberately a small Python parse rather than a yaml dependency: the manifest
# is a flat list of `- name/repo/commit_sha` records and we want this script to
# run on a clean machine with nothing installed but git and python3.
resolve() {
  python3 - "$MANIFEST" "$COVERAGE_MANIFEST" "$MODE" "${EXPLICIT[@]:-}" <<'PY'
import re, sys, os
manifest, cov_manifest, mode = sys.argv[1], sys.argv[2], sys.argv[3]
explicit = [a for a in sys.argv[4:] if a]

txt = open(manifest).read()
entries = re.findall(r'- name:\s*"([^"]+)"\s*\n\s*repo:\s*"([^"]+)"(.*?)(?=\n- name:|\Z)', txt, re.S)
by_name = {}
for name, repo, rest in entries:
    m = re.search(r'commit_sha:\s*"([^"]+)"', rest)
    by_name[name] = (repo, m.group(1) if m else "")

def lookup(want):
    if want in by_name:
        return want, by_name[want]
    for n, v in by_name.items():           # tolerate the coverage manifest's
        if n.lower() == want.lower():      # slightly different naming
            return n, v
    for n, v in by_name.items():
        if n.lower().endswith(want.lower()) or want.lower().endswith(n.lower()):
            return n, v
    return None, None

if mode.startswith("explicit"):
    wanted = explicit
elif mode.startswith("all"):
    wanted = list(by_name)
else:
    wanted = []
    if os.path.exists(cov_manifest):
        for line in open(cov_manifest):
            m = re.search(r'corpus/repos/([A-Za-z0-9._-]+)', line)
            if m and m.group(1) not in wanted:
                wanted.append(m.group(1))

missing = []
for w in wanted:
    name, v = lookup(w)
    if not v:
        missing.append(w); continue
    print(f"{w}\t{v[0]}\t{v[1]}")
for w in missing:
    print(f"!!MISSING\t{w}\t", file=sys.stderr)
PY
}

# macOS ships bash 3.2, which has no `mapfile` — read into the array portably.
ROWS=()
while IFS= read -r _line; do
  [[ -n "$_line" ]] && ROWS+=("$_line")
done < <(resolve)
[[ ${#ROWS[@]} -eq 0 ]] && { echo "!! nothing to fetch (no matching entries)" >&2; exit 2; }

if [[ "$MODE" == *-list ]]; then
  printf '%s\n' "${ROWS[@]}" | awk -F'\t' '{printf "  %-28s %s @%s\n", $1, $2, substr($3,1,10)}'
  echo "(${#ROWS[@]} repos)"
  exit 0
fi

mkdir -p "$REPOS_DIR"
ok=0; skip=0; fail=0
declare -a FAILED=()

for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r name url sha <<<"$row"
  dest="$REPOS_DIR/$name"

  if [[ -d "$dest/.git" ]]; then
    have="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo none)"
    if [[ -n "$sha" && "$have" == "$sha" ]]; then
      echo "== $name  already at pinned SHA — skipping"
      skip=$((skip+1)); continue
    fi
    if [[ -z "$sha" ]]; then
      echo "== $name  present (manifest pins no SHA) — skipping"
      skip=$((skip+1)); continue
    fi
    echo "== $name  present at $have, want $sha — refetching"
    rm -rf "$dest"
  fi

  echo "== $name  <- $url @${sha:0:10}"
  mkdir -p "$dest"
  (
    cd "$dest" || exit 1
    git init -q .
    git remote add origin "$url"
    # Fast path: fetch only the pinned commit. Falls back to a full clone for
    # servers that refuse by-SHA fetches.
    if [[ -n "$sha" ]] && git fetch -q --depth 1 origin "$sha" 2>/dev/null; then
      git checkout -q FETCH_HEAD
    else
      git fetch -q --tags origin || exit 1
      if [[ -n "$sha" ]]; then git checkout -q "$sha" || exit 1
      else git checkout -q FETCH_HEAD || exit 1; fi
    fi
  )
  if [[ $? -eq 0 ]]; then
    ok=$((ok+1))
  else
    echo "!! $name FAILED" >&2
    rm -rf "$dest"; fail=$((fail+1)); FAILED+=("$name")
  fi
done

echo
echo "corpus fetch: $ok fetched, $skip already current, $fail failed (of ${#ROWS[@]})"
if [[ $fail -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
