# Patch docs

Astro + Starlight. Replaces the single 1,872-line `docs-site/index.html`.
Requires Node ≥ 22.12 (Astro 7 hard-fails on 20).

```bash
npm install
npm run dev      # local dev server
npm run gen      # regenerate src/data/coverage.json from the census artifact
npm run build    # static output in dist/ (postbuild regenerates llms.txt)
npm run check    # links + anchors, source freshness, claims, llms freshness
```

## Accuracy machinery

The point of this rebuild is that **wrong docs should fail the build**, not sit
there looking plausible.

* **No coverage number is written by hand.** `npm run gen` parses the committed
  census artifact at `tools/swiftui-corpus-coverage/artifacts/` into
  `src/data/coverage.json`; `coverage.mdx` imports it. To change a number you
  re-run the census, not the prose. Best/worst ranking ignores apps with fewer
  than 10 views so a 1/1 app cannot top the table.
* **The census is reproducible by anyone** — `corpus/fetch.sh` clones the 20
  open-source corpus apps at pinned commits.
* **No CLI flag is written by hand.** `npm run gen:cli-help` captures real
  `patchcli --help` into `src/data/cli-help.json`; `cli.mdx` imports it.
* **`check:links`** crawls `dist/` and fails on a dead internal link or an
  anchor that does not resolve to an id on the target page.
* **`check:sources`** compares each page's own git commit date against the
  `sources:` paths it declares, and warns when the code moved after the prose
  did. A `sources:` path that does not exist is a hard failure.
* **`check:claims`** fails the build on two mistakes that have already shipped
  here: the Apple DPLA clause cited as a bare `§3.3.2` (the site cites it as
  `§3.3.1(B)` with `(formerly §3.3.2)` — the number moved between revisions),
  and the unsourced scale claim "tens of thousands".
* **`check:llms`** regenerates `llms.txt` / `llms-full.txt` in memory and fails
  if the on-disk files differ, or if either one contains an HTML entity
  (`&amp;`) or raw JSX (`<LinkCard`, `<Aside`). Those files are read as plain
  text by coding agents, so markup in them is a defect.

## Page conventions

Every page follows the same shape, because answer engines cite passages rather
than pages and take them from the top:

* **Definition first.** The first paragraph — before any `<Aside>` or
  `<CardGrid>` — is a standalone 2–3 sentence definition naming the entity
  ("A staged rollout is …", "The native-shell fingerprint is …"). No "as we saw
  above", no leading "this".
* **Question headings** where the section answers a question a reader would
  type, with the answer's first sentence answering outright.
* **`description:`** is a 120–160-character answer-first sentence. It becomes
  the `<meta name="description">`, the `og:description` and the page's line in
  `llms.txt`, so a five-word description ("The activity trail.") wastes all
  three. Quote it in YAML if it contains `": "`.
* **`lastUpdated:`** is set explicitly in frontmatter. Starlight's git-derived
  fallback (`lastUpdated: true` in the config) is unreliable on a shallow CI
  clone, and the same value has to feed the visible "Last updated" line, the
  JSON-LD `dateModified` and the sitemap `<lastmod>`. Bump it when the page
  genuinely changes — never as a routine.
* **`sources:`** lists the repo-relative implementation paths the page
  documents, so `check:sources` can watch them.
* **A `## Related` list** at the end, linking sibling docs pages and the
  matching marketing/blog URLs.

## Structured data and dates

* `src/components/Head.astro` overrides Starlight's `<Head>` and injects one
  JSON-LD `@graph` per page: a `TechArticle`, a `BreadcrumbList`, and the
  shared `Organization` (`https://patchrelease.com/#org`). Every field is read
  from the page — the frontmatter title and description, and the same
  `lastUpdated` Date the visible date renders — so structured data cannot claim
  something the page does not say. There is deliberately no `aggregateRating`
  or review markup.
* The sitemap is configured explicitly in `astro.config.mjs` (Starlight only
  adds its own when none is present) with a `serialize` hook that sets
  `<lastmod>` per URL from the page's `lastUpdated:` frontmatter, falling back
  to `git log -1 --format=%cI`. Output: **`dist/sitemap-index.xml`** plus
  `dist/sitemap-0.xml`.
* `public/og-image.png` is the shared social card, copied from
  `web/assets/og-image.png`.

## Migration

`scripts/extract.py` performed the one-time port from `docs-site/index.html`,
splitting on `<h2>` into one page per section. The MDX files are now the source
of truth; the script is kept for reference, not re-run.

## Still to do

* CI-compiled Swift snippets (needs the WASM CI fixed first — see
  `OPEN-SOURCE-MIGRATION.md` T1.7)
* DocC for SDK API reference
* `npm run check` wired into CI as a required job
