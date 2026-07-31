#!/usr/bin/env node
// Link + anchor checker for the built Starlight site.
//
// AI-written docs fail by looking plausible, so a link to a page that was
// renamed (or an anchor to a heading that was reworded) reads fine and is
// still broken. This turns that class of rot into a build failure.
//
// Crawls dist/*.html and fails on:
//   - internal links to pages/assets that do not exist
//   - in-page anchors that do not resolve to an id on the TARGET page
//   - empty href="" / href="#"
// External http(s) links are listed, never fetched (no network in CI).
//
//   node scripts/check-links.mjs [--dist dist] [--quiet]
//
// Exit 1 if any error was found.

import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs';
import { resolve, join, relative, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(name);
  return i === -1 ? dflt : argv[i + 1];
};
const QUIET = argv.includes('--quiet');

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const DIST = resolve(ROOT, arg('--dist', 'dist'));
const CONTENT = resolve(ROOT, 'src/content/docs');

if (!existsSync(DIST)) {
  console.error(`!! no build output at ${relative(ROOT, DIST)} — run \`npm run build\` first`);
  process.exit(1);
}

// ---------------------------------------------------------------- collect

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'pagefind' || e.name === '_astro') continue; // generated assets
      walk(p, out);
    } else if (e.name.endsWith('.html')) {
      out.push(p);
    }
  }
  return out;
}

const pages = walk(DIST).sort();
if (pages.length === 0) {
  console.error(`!! ${relative(ROOT, DIST)} contains no HTML — is the build complete?`);
  process.exit(1);
}

// dist/foo/index.html -> /foo/ ; dist/index.html -> /
const routeOf = (file) => {
  let r = '/' + relative(DIST, file).split(/[\\/]/).join('/');
  if (r.endsWith('/index.html')) r = r.slice(0, -'index.html'.length);
  return r;
};

// Best-effort map back to the authored file, so the report names something a
// human can open. Route /cli/ -> src/content/docs/cli.mdx
const sourceOf = (route) => {
  const slug = route.replace(/^\/|\/$/g, '') || 'index';
  for (const ext of ['.mdx', '.md']) {
    const p = join(CONTENT, slug + ext);
    if (existsSync(p)) return relative(ROOT, p);
  }
  return null;
};

const stripped = (html) =>
  html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '');

const idsOf = (html) => {
  const ids = new Set();
  for (const m of html.matchAll(/\sid=["']([^"']+)["']/g)) ids.add(m[1]);
  // <a name="..."> still resolves as an anchor target in browsers.
  for (const m of html.matchAll(/<a\b[^>]*\sname=["']([^"']+)["']/g)) ids.add(m[1]);
  return ids;
};

const idsByRoute = new Map();
const htmlByFile = new Map();
for (const file of pages) {
  const raw = readFileSync(file, 'utf8');
  htmlByFile.set(file, raw);
  idsByRoute.set(routeOf(file), idsOf(raw));
}

// ---------------------------------------------------------------- resolve

// A route resolves if dist has index.html for it, a sibling .html, or a real
// file (assets like /favicon.svg).
function resolveRoute(pathname) {
  const clean = decodeURIComponent(pathname);
  const rel = clean.replace(/^\//, '');
  const candidates = [
    join(DIST, rel, 'index.html'),
    join(DIST, rel + '.html'),
    join(DIST, rel),
  ];
  for (const c of candidates) {
    if (existsSync(c) && statSync(c).isFile()) {
      return { file: c, route: c.endsWith('.html') ? routeOf(c) : null };
    }
  }
  return null;
}

const errors = [];
const external = new Map(); // url -> Set(source route)
let internalChecked = 0;
let anchorsChecked = 0;

const SITE_ORIGINS = ['https://docs.patchrelease.com'];

for (const file of pages) {
  const route = routeOf(file);
  const src = sourceOf(route) ?? relative(ROOT, file);
  const html = stripped(htmlByFile.get(file));

  for (const m of html.matchAll(/<a\b[^>]*?\shref=(["'])(.*?)\1/gis)) {
    const raw = m[2].trim();

    if (raw === '' || raw === '#') {
      errors.push({ src, link: raw === '' ? 'href=""' : 'href="#"', why: 'empty link' });
      continue;
    }
    if (/^(mailto:|tel:|javascript:|data:)/i.test(raw)) continue;

    let url = raw;
    // A self-origin absolute URL is an internal link wearing a costume.
    for (const origin of SITE_ORIGINS) {
      if (url.startsWith(origin)) url = url.slice(origin.length) || '/';
    }
    if (/^https?:\/\//i.test(url) || url.startsWith('//')) {
      if (!external.has(raw)) external.set(raw, new Set());
      external.get(raw).add(src);
      continue;
    }

    const hashAt = url.indexOf('#');
    let pathPart = hashAt === -1 ? url : url.slice(0, hashAt);
    const hash = hashAt === -1 ? '' : url.slice(hashAt + 1);
    pathPart = pathPart.split('?')[0];

    // Resolve the target route.
    let targetRoute;
    if (pathPart === '') {
      targetRoute = route; // same-page anchor
    } else if (pathPart.startsWith('/')) {
      targetRoute = pathPart;
    } else {
      const base = route.endsWith('/') ? route : posix.dirname(route) + '/';
      targetRoute = posix.normalize(posix.join(base, pathPart));
    }

    if (pathPart !== '') {
      internalChecked++;
      const hit = resolveRoute(targetRoute);
      if (!hit) {
        errors.push({ src, link: raw, why: `target page does not exist (${targetRoute})` });
        continue;
      }
      if (hit.route) targetRoute = hit.route;
      else if (hash) {
        // anchor into a non-HTML asset — nothing to check
        continue;
      } else continue;
    }

    if (!hash) continue;
    anchorsChecked++;
    const ids = idsByRoute.get(targetRoute) ?? idsByRoute.get(targetRoute.replace(/\/$/, '') + '/');
    if (!ids) {
      errors.push({ src, link: raw, why: `cannot check anchor — no built page for ${targetRoute}` });
      continue;
    }
    if (!ids.has(decodeURIComponent(hash))) {
      const id = decodeURIComponent(hash);
      const where = pathPart === '' ? 'this page' : targetRoute;
      // The common shape here is a leftover from a single-page docs site:
      // `#quickstart` used to be a section, and is now its own page. Say so.
      let hint = '';
      if (pathPart === '' && resolveRoute('/' + id + '/')) {
        hint = ` — did you mean /${id}/ (that page exists)?`;
      } else {
        const near = [...ids].filter((x) => x.startsWith(id) || id.startsWith(x.split('-')[0]));
        if (near.length === 1) hint = ` — nearest id on that page: #${near[0]}`;
      }
      errors.push({ src, link: raw, why: `no element with id="${id}" on ${where}${hint}` });
    }
  }
}

// ---------------------------------------------------------------- report

const plural = (n, s) => `${n} ${s}${n === 1 ? '' : 's'}`;

if (!QUIET && external.size) {
  console.log(`External links (listed, not fetched) — ${plural(external.size, 'unique URL')}:`);
  for (const [url, srcs] of [...external].sort()) {
    console.log(`  ${url}\n      ← ${[...srcs].sort().join(', ')}`);
  }
  console.log('');
}

console.log(
  `Checked ${plural(pages.length, 'page')}: ${internalChecked} internal links, ${anchorsChecked} anchors, ${external.size} external.`,
);

if (errors.length) {
  console.error(`\n!! ${plural(errors.length, 'broken link')}:\n`);
  const bySrc = new Map();
  for (const e of errors) {
    if (!bySrc.has(e.src)) bySrc.set(e.src, []);
    bySrc.get(e.src).push(e);
  }
  for (const [src, list] of [...bySrc].sort()) {
    console.error(`  ${src}`);
    for (const e of list) console.error(`      ${e.link}  →  ${e.why}`);
  }
  console.error('');
  process.exit(1);
}

console.log('OK — no broken internal links or anchors.');
