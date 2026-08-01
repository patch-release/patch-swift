#!/usr/bin/env node
// Docs-freshness check.
//
// A page may declare what it documents:
//
//   ---
//   title: CLI reference
//   sources:
//     - cli/Sources/PatchCLI/Release.swift
//     - cli/Sources/CodeGenerator/BodyLowering.swift
//   ---
//
// (inline form `sources: [a, b]` works too). If any listed source has a git
// commit date NEWER than the page's own last commit, the code moved and the
// prose did not — the exact way docs go stale without anyone noticing.
//
//   node scripts/check-sources.mjs [--strict] [--json] [--content <dir>]
//
// Exit 0 by default (loud warning only), so this can land before any page
// carries `sources:`. --strict turns stale pages into a failure for CI.
// A `sources:` path that does not exist always exits 1: that is a broken
// declaration, not a stale page.
//
// Dates come from `git log -1` on each path. A file with no commit yet (a page
// being written right now) falls back to its working-tree mtime, marked (wt).

import { existsSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { relative, resolve } from 'node:path';
import { ROOT, CONTENT, readPages } from './lib/docs.mjs';

const argv = process.argv.slice(2);
const STRICT = argv.includes('--strict');
const JSON_OUT = argv.includes('--json');
const contentIdx = argv.indexOf('--content');
const CONTENT_DIR = contentIdx === -1 ? CONTENT : resolve(ROOT, argv[contentIdx + 1]);

// The docs live in a monorepo; `sources:` paths are repo-relative.
const REPO = (() => {
  const r = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: ROOT, encoding: 'utf8' });
  if (r.status !== 0) {
    console.error('!! not a git repository — check-sources needs git commit dates');
    process.exit(1);
  }
  return r.stdout.trim();
})();

// git commit date, falling back to the working-tree mtime for a path git has
// never seen (a page being written right now still has a real age).
const lastTouched = (absPath) => {
  const r = spawnSync('git', ['log', '-1', '--format=%ct%x09%h%x09%s', '--', absPath], {
    cwd: REPO,
    encoding: 'utf8',
  });
  const line = r.status === 0 ? r.stdout.trim() : '';
  if (line) {
    const [ts, hash, subject] = line.split('\t');
    return { ts: Number(ts) * 1000, hash, subject, wt: false };
  }
  return { ts: statSync(absPath).mtimeMs, hash: 'wt', subject: 'uncommitted working copy', wt: true };
};

// The same docs ship from two repo layouts. In the monorepo the SDK lives at
// `sdk/`; in the public `patch-swift` repo it IS the root package, so
// `sdk/Sources/X` is just `Sources/X` there (tools/sync-public.sh does that
// remap). The engine's `cli/` path is identical in both. Declare `sources:`
// against the monorepo layout and resolve the public one as a fallback, so a
// declaration is never "broken" merely because of which repo it is read from.
const LAYOUTS = [(p) => p, (p) => (p.startsWith('sdk/') ? p.slice(4) : null)];

const resolveSource = (src) => {
  for (const map of LAYOUTS) {
    const mapped = map(src);
    if (!mapped) continue;
    const abs = resolve(REPO, mapped);
    if (abs.startsWith(REPO) && existsSync(abs)) return { abs, ok: true };
  }
  const abs = resolve(REPO, src);
  return { abs, ok: false, escapes: !abs.startsWith(REPO) };
};

const fmt = (ms) => new Date(ms).toISOString().slice(0, 10);
const days = (a, b) => Math.round((a - b) / 86_400_000);

const pages = readPages(CONTENT_DIR);
const withSources = pages.filter((p) => p.sources.length);

const stale = [];
const broken = [];
let pairs = 0;

for (const page of withSources) {
  const pageCommit = lastTouched(page.file);
  for (const src of page.sources) {
    const { abs, ok, escapes } = resolveSource(src);
    if (escapes) {
      broken.push({ page: page.relFile, source: src, why: 'sources: path escapes the repo' });
      continue;
    }
    if (!ok) {
      broken.push({ page: page.relFile, source: src, why: 'sources: path does not exist' });
      continue;
    }
    const srcCommit = lastTouched(abs);
    pairs++;
    if (srcCommit.ts > pageCommit.ts) {
      stale.push({
        page: page.relFile,
        pageDate: fmt(pageCommit.ts) + (pageCommit.wt ? ' (wt)' : ''),
        source: relative(REPO, abs),
        sourceDate: fmt(srcCommit.ts) + (srcCommit.wt ? ' (wt)' : ''),
        behindDays: days(srcCommit.ts, pageCommit.ts),
        sourceCommit: `${srcCommit.hash} ${srcCommit.subject}`,
      });
    }
  }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ pagesWithSources: withSources.length, pairs, stale, broken }, null, 2));
} else {
  console.log(
    `Freshness: ${withSources.length}/${pages.length} pages declare \`sources:\` (${pairs} page↔source pairs checked).`,
  );
  if (withSources.length === 0) {
    console.log(
      '   No page declares `sources:` yet. Add it to a page\'s frontmatter to have this check watch it:\n' +
        '     sources:\n       - cli/Sources/PatchCLI/Release.swift',
    );
  }
  if (stale.length) {
    console.warn(`\n!  ${stale.length} page(s) may be STALE — the source moved after the page did:\n`);
    for (const s of stale) {
      console.warn(`   ${s.page}  (last touched ${s.pageDate})`);
      console.warn(`      ← ${s.source} changed ${s.sourceDate} (${s.behindDays}d newer)`);
      console.warn(`        ${s.sourceCommit}`);
    }
    console.warn('');
  } else if (pairs) {
    console.log('OK — every documented source is older than the page documenting it.');
  }
  if (broken.length) {
    console.error(`\n!! ${broken.length} bad \`sources:\` declaration(s):\n`);
    for (const b of broken) console.error(`   ${b.page}${b.source ? ` → ${b.source}` : ''}: ${b.why}`);
    console.error('');
  }
}

if (broken.length) process.exit(1);
if (stale.length && STRICT) process.exit(1);
