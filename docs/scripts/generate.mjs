// Derive docs data from the committed census artifact.
// Nothing about coverage is hand-written in MDX — it is imported from here, so a
// stale number is impossible without a stale artifact.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const LOG = '../tools/swiftui-corpus-coverage/artifacts/census-2026-07-30.log';
if (!existsSync(LOG)) {
  console.error(`!! missing census artifact ${LOG} — run tools/swiftui-corpus-coverage/run.sh`);
  process.exit(1);
}
const txt = readFileSync(LOG, 'utf8');

const view = txt.match(/HEADLINE \(view-level, OTA auto-route\): (\d+)\/(\d+) = ([\d.]+)%/);
const elem = txt.match(/Element-level coverage:\s+(\d+)\/(\d+) = ([\d.]+)%/);
if (!view || !elem) { console.error('!! could not parse headline from census'); process.exit(1); }

const apps = [...txt.matchAll(/^\s{2}([A-Za-z0-9._-]+)\s+(\d+)\/(\d+)\s+\((\d+)%\)/gm)]
  .map(([, name, low, total, pct]) => ({ name, lowered: +low, total: +total, pct: +pct }))
  .sort((a, b) => b.pct - a.pct);

// Best/worst must come from apps with a meaningful sample — an app with one
// view scoring 100% is noise, not a result.
const MIN_VIEWS = 10;
const ranked = apps.filter((a) => a.total >= MIN_VIEWS);

const data = {
  generatedFrom: LOG,
  minViewsForRanking: MIN_VIEWS,
  viewLevel:    { lowered: +view[1], total: +view[2], pct: parseFloat(view[3]) },
  elementLevel: { lowered: +elem[1], total: +elem[2], pct: parseFloat(elem[3]) },
  appCount: apps.length,
  best: ranked[0],
  worst: ranked[ranked.length - 1],
  apps,
};
writeFileSync('src/data/coverage.json', JSON.stringify(data, null, 2) + '\n');
console.log(`coverage.json: ${data.viewLevel.pct}% view-level, ${data.elementLevel.pct}% element-level, ${data.appCount} apps`);
