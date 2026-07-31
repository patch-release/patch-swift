# Patch docs

Astro + Starlight. Replaces the single 1,872-line `docs-site/index.html`.

```bash
npm install
npm run dev      # local dev server
npm run gen      # regenerate src/data/coverage.json from the census artifact
npm run build    # static output in dist/
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

## Migration

`scripts/extract.py` performed the one-time port from `docs-site/index.html`,
splitting on `<h2>` into one page per section. The MDX files are now the source
of truth; the script is kept for reference, not re-run.

## Still to do

* CI-compiled Swift snippets (needs the WASM CI fixed first — see
  `OPEN-SOURCE-MIGRATION.md` T1.7)
* Generated CLI `--help` output
* Link checker in CI
* `llms.txt` generated from the page tree instead of hand-maintained
* DocC for SDK API reference
