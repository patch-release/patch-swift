import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import sitemap from '@astrojs/sitemap';

const SITE = 'https://docs.patchrelease.com';
const CONTENT = fileURLToPath(new URL('./src/content/docs/', import.meta.url));

// ------------------------------------------------------------ code theme
//
// One theme for BOTH site themes: the code panel stays Xcode-dark on the light
// page, the same way the marketing site's demo panel does. It is a real
// TextMate theme (Xcode's own Default (Dark) values), so Expressive Code and
// Shiki highlight with it directly rather than us re-colouring tokens in CSS.
const xcodeDark = JSON.parse(
  readFileSync(new URL('./src/styles/xcode-dark.json', import.meta.url), 'utf8')
);

const MONO = "'JetBrains Mono', ui-monospace, SFMono-Regular, 'SF Mono', Menlo, monospace";

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
        // Typefaces, matched to the marketing site: Figtree for display/UI,
        // JetBrains Mono for code. Loaded as <link> (not a CSS @import) so the
        // font request starts with the document rather than after the
        // stylesheet has been fetched and parsed.
        {
          tag: 'link',
          attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        },
        {
          tag: 'link',
          attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true },
        },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href: 'https://fonts.googleapis.com/css2?family=Figtree:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap',
          },
        },
      ],
      // The code panel: Xcode Default (Dark), in both site themes.
      expressiveCode: {
        themes: [xcodeDark],
        useDarkModeMediaQuery: false,
        styleOverrides: {
          borderRadius: '12px',
          borderWidth: '1px',
          borderColor: 'rgba(255, 255, 255, 0.09)',
          codeFontFamily: MONO,
          codeFontSize: '13px',
          codeLineHeight: '1.66',
          codePaddingInline: '1.15rem',
          codePaddingBlock: '0.95rem',
          uiFontFamily: "'Figtree', -apple-system, BlinkMacSystemFont, sans-serif",
          uiFontSize: '12.5px',
          focusBorder: '#0a7aff',
          scrollbarThumbColor: 'rgba(255, 255, 255, 0.18)',
          scrollbarThumbHoverColor: 'rgba(255, 255, 255, 0.3)',
          frames: {
            frameBoxShadowCssValue:
              '0 1px 2px rgba(11, 13, 19, 0.06), 0 14px 32px -18px rgba(11, 13, 19, 0.34)',
            editorTabBarBackground: '#252529',
            editorTabBarBorderBottomColor: 'rgba(0, 0, 0, 0.45)',
            editorActiveTabBackground: '#1f1f24',
            editorActiveTabForeground: '#dfdfe0',
            editorActiveTabBorderColor: 'transparent',
            editorActiveTabIndicatorTopColor: '#f05138',
            editorActiveTabIndicatorBottomColor: 'transparent',
            editorActiveTabIndicatorHeight: '2px',
            editorTabBorderRadius: '0',
            inactiveTabBackground: '#252529',
            inactiveTabForeground: 'rgba(255, 255, 255, 0.45)',
            editorBackground: '#1f1f24',
            terminalBackground: '#1f1f24',
            terminalTitlebarBackground: '#2c2c31',
            terminalTitlebarForeground: 'rgba(255, 255, 255, 0.62)',
            terminalTitlebarBorderBottomColor: 'rgba(0, 0, 0, 0.45)',
            terminalTitlebarDotsForeground: 'rgba(255, 255, 255, 0.26)',
            terminalTitlebarDotsOpacity: '1',
            tooltipSuccessBackground: '#12a05b',
            inlineButtonForeground: '#dfdfe0',
            inlineButtonBorder: 'rgba(255, 255, 255, 0.22)',
          },
          textMarkers: {
            markBackground: 'rgba(10, 122, 255, 0.16)',
            markBorderColor: '#0a7aff',
            insBackground: 'rgba(65, 182, 69, 0.14)',
            insBorderColor: '#41b645',
            delBackground: 'rgba(252, 106, 93, 0.14)',
            delBorderColor: '#fc6a5d',
          },
        },
      },
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
