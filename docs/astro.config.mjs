import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import sitemap from '@astrojs/sitemap';

const SITE = 'https://docs.patchrelease.com';
const CONTENT = fileURLToPath(new URL('./src/content/docs/', import.meta.url));

// ---------------------------------------------------------------- lastmod
//
// Google only trusts a sitemap `lastmod` it can verify against the page, so the
// value here comes from the same source the page's visible "Last updated" line
// and its JSON-LD `dateModified` come from: the page's `lastUpdated:`
// frontmatter, falling back to the file's newest git commit date. Never a
// bulk stamp — a URL whose date cannot be established is left without one
// rather than given a made-up one.

const lastmodCache = new Map();

function fileForRoute(pathname) {
  const slug = pathname.replace(/^\//, '').replace(/\/$/, '') || 'index';
  for (const ext of ['.mdx', '.md']) {
    const p = resolve(CONTENT, slug + ext);
    if (existsSync(p)) return p;
  }
  return null;
}

function frontmatterLastUpdated(file) {
  const raw = readFileSync(file, 'utf8');
  if (!raw.startsWith('---')) return null;
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return null;
  const head = raw.slice(0, end);
  const m = head.match(/^lastUpdated:\s*(.+)$/m);
  if (!m) return null;
  const d = new Date(m[1].trim().replace(/^['"]|['"]$/g, ''));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function gitLastUpdated(file) {
  const r = spawnSync('git', ['log', '-1', '--format=%cI', '--', file], { encoding: 'utf8' });
  const out = r.status === 0 ? r.stdout.trim() : '';
  if (!out) return null;
  const d = new Date(out);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function lastmodFor(url) {
  if (lastmodCache.has(url)) return lastmodCache.get(url);
  let value = null;
  try {
    const pathname = new URL(url).pathname;
    const file = fileForRoute(pathname);
    if (file) value = frontmatterLastUpdated(file) ?? gitLastUpdated(file);
  } catch {
    value = null;
  }
  lastmodCache.set(url, value);
  return value;
}

export default defineConfig({
  site: SITE,
  integrations: [
    // Configured explicitly (Starlight only adds its own sitemap integration
    // when none is present) so every URL can carry a real `lastmod`.
    sitemap({
      serialize(item) {
        const lastmod = lastmodFor(item.url);
        if (lastmod) item.lastmod = lastmod;
        return item;
      },
    }),
    starlight({
      title: 'Patch Docs',
      description:
        'Over-the-air code updates for native Swift iOS apps. Compile changed Swift to WebAssembly and ship it without App Store review.',
      logo: { src: './src/assets/patch-icon.png', replacesTitle: false },
      // Visible, dated "Last updated" line on every page. Pages set an explicit
      // `lastUpdated:` in frontmatter; this is the git-derived fallback.
      lastUpdated: true,
      head: [
        {
          tag: 'meta',
          attrs: { property: 'og:image', content: `${SITE}/og-image.png` },
        },
        {
          tag: 'link',
          attrs: { rel: 'describedby', href: `${SITE}/llms.txt` },
        },
      ],
      // Array form since Starlight 0.33 — the old object shape is a build error.
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/patch-release/patch-swift',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/patch-release/patch-swift/edit/main/docs/',
      },
      customCss: ['./src/styles/patch.css'],
      components: {
        // Extends Starlight's own <Head> — adds one JSON-LD @graph per page.
        Head: './src/components/Head.astro',
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { slug: '' },
            { slug: 'quickstart' },
            { slug: 'how-it-works' },
            { slug: 'ai-setup' },
            { slug: 'faq' },
          ],
        },
        {
          label: 'What Patch can change',
          items: [
            { slug: 'coverage' },
            { slug: 'fingerprint' },
            { slug: 'glossary' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { slug: 'cli' },
            { slug: 'sdk' },
          ],
        },
        {
          label: 'Shipping',
          items: [
            { slug: 'channels' },
            { slug: 'rollouts' },
            { slug: 'targeting' },
            { slug: 'force-updates' },
            { slug: 'cicd' },
          ],
        },
        {
          label: 'Open source & self-hosting',
          items: [
            { slug: 'open-source' },
            { slug: 'self-hosting' },
            { slug: 'compare' },
            { slug: 'apple-compliance' },
          ],
        },
        {
          label: 'Account',
          items: [
            { slug: 'team' },
            { slug: 'billing' },
            { slug: 'usage' },
            { slug: 'audit' },
            { slug: 'webhooks' },
          ],
        },
        {
          label: 'Help',
          items: [{ slug: 'troubleshooting' }],
        },
      ],
    }),
  ],
});
