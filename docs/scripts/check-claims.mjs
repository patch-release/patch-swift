#!/usr/bin/env node
// Claim consistency check for the docs content.
//
// Two classes of error have already shipped on this site and are easy to
// reintroduce, so they are now build failures rather than review items:
//
//   1. The Apple Developer Program License Agreement's interpreted-code clause
//      cited as a bare "§3.3.2". The number moved between DPLA revisions; the
//      site cites it as "§3.3.1(B) (formerly §3.3.2)" everywhere so a reader
//      checking the current agreement finds the clause. A page that says
//      "3.3.2" without also saying "3.3.1(B)" contradicts the rest of the site.
//
//   2. Unsourced scale claims — "tens of thousands of App Store apps" appeared
//      in several files with no source behind it. If a number cannot be traced
//      to a primary source it does not belong on the page.
//
//   node scripts/check-claims.mjs [--content <dir>]
//
// Exit 1 on any violation.

import { resolve } from 'node:path';
import { ROOT, CONTENT, readPages } from './lib/docs.mjs';

const argv = process.argv.slice(2);
const contentIdx = argv.indexOf('--content');
const CONTENT_DIR = contentIdx === -1 ? CONTENT : resolve(ROOT, argv[contentIdx + 1]);

const RULES = [
  {
    id: 'dpla-clause-number',
    // A file may mention 3.3.2 only if it also carries the current number.
    test(page) {
      const text = page.raw;
      if (!/3\.3\.2/.test(text)) return null;
      if (/3\.3\.1\(B\)/.test(text)) return null;
      return 'cites the DPLA clause as 3.3.2 without the current number — write "§3.3.1(B) (formerly §3.3.2)"';
    },
  },
  {
    id: 'dpla-bare-section-sign',
    // "§3.3.2" on its own reads as the current number. It must be introduced.
    test(page) {
      const bad = [];
      for (const m of page.raw.matchAll(/§\s*3\.3\.2/g)) {
        const before = page.raw.slice(Math.max(0, m.index - 32), m.index);
        if (!/formerly/.test(before)) bad.push(m[0]);
      }
      return bad.length
        ? `writes "${bad[0]}" without "formerly" in front of it — the current number is §3.3.1(B)`
        : null;
    },
  },
  {
    id: 'unsourced-scale-claim',
    test(page) {
      return /tens of thousands/i.test(page.raw)
        ? 'contains the unsourced scale claim "tens of thousands" — cite a source or drop the number'
        : null;
    },
  },
];

const pages = readPages(CONTENT_DIR).map((p) => ({
  ...p,
  // The rules read the whole file, frontmatter included.
  raw: `${JSON.stringify(p.data)}\n${p.body}`,
}));

const failures = [];
for (const page of pages) {
  for (const rule of RULES) {
    const why = rule.test(page);
    if (why) failures.push({ page: page.relFile, rule: rule.id, why });
  }
}

console.log(`Claims: ${pages.length} pages checked against ${RULES.length} rules.`);

if (failures.length) {
  console.error(`\n!! ${failures.length} claim violation(s):\n`);
  for (const f of failures) console.error(`   ${f.page}  [${f.rule}]\n      ${f.why}`);
  console.error('');
  process.exit(1);
}

console.log('OK — DPLA clause cited consistently, no unsourced scale claims.');
