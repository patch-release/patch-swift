#!/usr/bin/env node
// Generate dist/llms.txt (+ dist/llms-full.txt) from the real page tree.
//
// These files were hand-maintained in two other places (web/, docs-site/) and
// drifted the moment a page was added or renamed. Here they are derived: the
// sidebar order comes from the built site (falling back to astro.config.mjs)
// and every title/description comes from the page's own frontmatter, so a page
// that exists is listed and a page that does not cannot be.
//
//   node scripts/gen-llms.mjs [--out dist] [--check]
//
// --check regenerates in memory and exits 1 if the on-disk files differ —
// useful in CI to prove nobody hand-edited the generated output.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { ROOT, DIST, readPages, sidebarGroups } from './lib/docs.mjs';

const argv = process.argv.slice(2);
const outIdx = argv.indexOf('--out');
const OUT = outIdx === -1 ? DIST : resolve(ROOT, argv[outIdx + 1]);
const CHECK = argv.includes('--check');

const SITE = 'https://docs.patchrelease.com';
const TITLE = 'Patch Docs';
const BLURB =
  'Over-the-air code updates for native Swift iOS apps. Compile changed Swift to WebAssembly and ship it without App Store review.';

const pages = readPages();
const byRoute = new Map(pages.map((p) => [p.route, p]));
const { source, groups } = sidebarGroups();
if (!groups.length) {
  console.error('!! could not read a sidebar from dist/ or astro.config.mjs — nothing to generate');
  process.exit(1);
}

const normRoute = (href) => {
  let r = href.split('#')[0].split('?')[0];
  if (!r.startsWith('/')) r = '/' + r;
  if (!r.endsWith('/')) r += '/';
  return r;
};

const url = (route) => SITE + (route === '/' ? '/' : route);

// ---------------------------------------------------------------- assemble

const seen = new Set();
const sections = [];
const problems = [];

for (const g of groups) {
  const entries = [];
  for (const link of g.links) {
    const route = normRoute(link.href);
    const page = byRoute.get(route);
    if (!page) {
      problems.push(`sidebar entry ${link.href} has no page in src/content/docs`);
      continue;
    }
    if (seen.has(route)) continue;
    seen.add(route);
    if (!page.description) problems.push(`${page.relFile} has no frontmatter description`);
    entries.push(page);
  }
  if (entries.length) sections.push({ label: g.label, entries });
}

// A page nobody put in the sidebar still exists on the web; list it rather
// than silently dropping it (that is exactly how the hand-written files rotted).
const orphans = pages.filter((p) => !seen.has(p.route));
if (orphans.length) sections.push({ label: 'Other pages', entries: orphans });

let llms = `# ${TITLE}\n\n> ${BLURB}\n\n`;
llms += `Generated from the docs page tree — do not edit by hand (scripts/gen-llms.mjs).\n\n`;
for (const s of sections) {
  llms += `## ${s.label}\n\n`;
  for (const p of s.entries) {
    llms += `- [${p.title}](${url(p.route)})${p.description ? `: ${p.description}` : ''}\n`;
  }
  llms += '\n';
}

// ---------------------------------------------------------------- full text

// llms-full.txt is the same tree with the page bodies inlined. The bodies are
// MDX; strip the machinery (imports/exports, JSX tags) but keep the prose and
// fenced code, which is what a model actually needs.
const demdx = (body) =>
  body
    .replace(/^\s*import\s+[^\n]*\n/gm, '')
    .replace(/^\s*export\s+(const|let|default)\s[^\n]*\n/gm, '')
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
    .replace(/^<[A-Z][^\n]*>\s*$/gm, '')
    .replace(/^<\/[A-Z][^\n]*>\s*$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

let full = `# ${TITLE} — full text\n\n> ${BLURB}\n\nGenerated from src/content/docs (scripts/gen-llms.mjs).\n\n`;
for (const s of sections) {
  for (const p of s.entries) {
    full += `\n---\n\n# ${p.title}\n\nURL: ${url(p.route)}\nSection: ${s.label}\n`;
    if (p.description) full += `Description: ${p.description}\n`;
    full += `\n${demdx(p.body)}\n`;
  }
}
full = full.replace(/\n{4,}/g, '\n\n\n') + '\n';

// ---------------------------------------------------------------- write

const targets = [
  [join(OUT, 'llms.txt'), llms],
  [join(OUT, 'llms-full.txt'), full],
];

if (CHECK) {
  let bad = 0;
  for (const [file, content] of targets) {
    const cur = existsSync(file) ? readFileSync(file, 'utf8') : null;
    if (cur !== content) {
      console.error(`!! ${relative(ROOT, file)} is ${cur === null ? 'missing' : 'stale'} — run \`npm run gen:llms\``);
      bad++;
    }
  }
  if (bad) process.exit(1);
  console.log('llms.txt / llms-full.txt are up to date.');
} else {
  mkdirSync(OUT, { recursive: true });
  for (const [file, content] of targets) writeFileSync(file, content);
  const pageCount = sections.reduce((n, s) => n + s.entries.length, 0);
  console.log(
    `llms.txt: ${pageCount} pages in ${sections.length} sections (order from ${source}) → ${relative(ROOT, OUT)}/llms.txt, llms-full.txt (${Math.round(full.length / 1024)} KB)`,
  );
}

if (problems.length) {
  console.warn(`\n!  ${problems.length} page-tree problem(s):`);
  for (const p of problems) console.warn(`   - ${p}`);
}
