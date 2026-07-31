// Shared helpers: read the real page tree + the real sidebar order.
// No dependencies — the frontmatter here is flat enough that a YAML parser
// would be a dependency bought for nothing.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { resolve, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(fileURLToPath(new URL('../..', import.meta.url)));
export const CONTENT = join(ROOT, 'src/content/docs');
export const DIST = join(ROOT, 'dist');

// -- frontmatter ------------------------------------------------------------

const unquote = (v) => {
  const s = v.trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
};

// Handles: `key: value`, `key: [a, b]`, one level of `key:` + `  sub: value`,
// and `key:` + `  - item` lists. That is the whole shape Starlight frontmatter
// uses here; anything more exotic is returned raw so callers can notice.
export function parseFrontmatter(raw) {
  if (!raw.startsWith('---')) return { data: {}, body: raw };
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return { data: {}, body: raw };
  const head = raw.slice(raw.indexOf('\n') + 1, end);
  const body = raw.slice(raw.indexOf('\n', end + 1) + 1);

  const data = {};
  let currentKey = null;
  for (const line of head.split('\n')) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const indented = /^\s+/.test(line);
    if (!indented) {
      const m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
      if (!m) continue;
      const [, key, rest] = m;
      currentKey = key;
      if (rest === '') {
        data[key] = undefined; // filled by the indented block below
      } else if (rest.startsWith('[')) {
        data[key] = rest
          .replace(/^\[|\]$/g, '')
          .split(',')
          .map((s) => unquote(s))
          .filter(Boolean);
      } else {
        data[key] = unquote(rest);
      }
    } else if (currentKey) {
      const item = line.match(/^\s+-\s*(.+)$/);
      if (item) {
        if (!Array.isArray(data[currentKey])) data[currentKey] = [];
        data[currentKey].push(unquote(item[1]));
        continue;
      }
      const sub = line.match(/^\s+([A-Za-z0-9_-]+):\s*(.*)$/);
      if (sub) {
        if (typeof data[currentKey] !== 'object' || data[currentKey] === null || Array.isArray(data[currentKey])) {
          data[currentKey] = {};
        }
        const v = unquote(sub[2]);
        data[currentKey][sub[1]] = /^-?\d+(\.\d+)?$/.test(v) ? Number(v) : v;
      }
    }
  }
  return { data, body };
}

// -- pages ------------------------------------------------------------------

export const slugToRoute = (slug) => (slug === 'index' ? '/' : `/${slug}/`);

export function readPages(dir = CONTENT) {
  if (!existsSync(dir)) throw new Error(`no content collection at ${dir}`);
  const files = readdirSync(dir)
    .filter((f) => f.endsWith('.mdx') || f.endsWith('.md'))
    .sort();
  return files.map((f) => {
    const file = join(dir, f);
    const raw = readFileSync(file, 'utf8');
    const { data, body } = parseFrontmatter(raw);
    const slug = f.replace(/\.mdx?$/, '');
    return {
      slug,
      route: slugToRoute(slug),
      file,
      relFile: relative(ROOT, file),
      title: data.title ?? slug,
      description: typeof data.description === 'string' ? data.description : '',
      sources: Array.isArray(data.sources) ? data.sources : [],
      data,
      body,
    };
  });
}

// -- sidebar ----------------------------------------------------------------

// The built site is the most honest source of order/grouping (it is what a
// reader sees). Fall back to the config when dist is not there yet.
function sidebarFromDist() {
  const idx = join(DIST, 'index.html');
  if (!existsSync(idx)) return null;
  const html = readFileSync(idx, 'utf8');
  const start = html.indexOf('id="starlight__sidebar"');
  if (start === -1) return null;
  // Bound the slice at the end of the nav list — past it live the social /
  // preference links, which are chrome, not pages.
  let pane = html.slice(start);
  const end = pane.indexOf('</sl-sidebar-state-persist>');
  if (end !== -1) pane = pane.slice(0, end);
  const groups = [];
  const re =
    /<span class="large[^"]*"[^>]*>([^<]+)<\/span>|<a href="([^"]+)"[^>]*>\s*<span[^>]*>([^<]*)<\/span>/g;
  let m;
  while ((m = re.exec(pane))) {
    if (m[1]) groups.push({ label: m[1].trim(), links: [] });
    else if (groups.length && m[2].startsWith('/')) {
      groups[groups.length - 1].links.push({ href: m[2], label: m[3].trim() });
    }
  }
  return groups.length ? groups : null;
}

function sidebarFromConfig() {
  const cfg = join(ROOT, 'astro.config.mjs');
  if (!existsSync(cfg)) return null;
  const src = readFileSync(cfg, 'utf8');
  const start = src.indexOf('sidebar:');
  if (start === -1) return null;
  const groups = [];
  const re = /label:\s*['"]([^'"]+)['"]|slug:\s*['"]([^'"]*)['"]/g;
  let m;
  while ((m = re.exec(src.slice(start)))) {
    if (m[1] !== undefined) groups.push({ label: m[1], links: [] });
    else if (groups.length) {
      const slug = m[2] === '' ? 'index' : m[2];
      groups[groups.length - 1].links.push({ href: slugToRoute(slug), label: null });
    }
  }
  return groups.length ? groups : null;
}

/** Ordered [{ label, links: [{ href, label }] }] — from dist, else the config. */
export function sidebarGroups() {
  const fromDist = sidebarFromDist();
  if (fromDist) return { source: 'dist/index.html', groups: fromDist };
  const fromConfig = sidebarFromConfig();
  if (fromConfig) return { source: 'astro.config.mjs', groups: fromConfig };
  return { source: null, groups: [] };
}

export const isFile = (p) => existsSync(p) && statSync(p).isFile();
