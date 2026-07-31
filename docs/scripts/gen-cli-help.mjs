#!/usr/bin/env node
// Capture the REAL `patchcli --help` output into src/data/cli-help.json so the
// CLI reference page can be rendered from the binary instead of from memory.
//
// The docs' command list is the single easiest thing to get plausibly wrong —
// a flag renamed in Swift does not touch the MDX. This makes the CLI the
// source of truth: regenerate, and a changed help text shows up as a diff.
//
//   node scripts/gen-cli-help.mjs [--no-build] [--cli <path>] [--check]
//
// Walks subcommands recursively (patchcli fingerprint diff, etc.).
// If the CLI cannot be built or run, this exits NON-ZERO with a clear message
// and writes nothing. It never invents help text.

import { existsSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve, relative } from 'node:path';
import { ROOT } from './lib/docs.mjs';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => {
  const i = argv.indexOf(n);
  return i === -1 ? d : argv[i + 1];
};

const CLI_DIR = resolve(ROOT, '..', 'cli');
const BIN = resolve(ROOT, opt('--cli', join(CLI_DIR, '.build/debug/patchcli')));
const OUT = join(ROOT, 'src/data/cli-help.json');
const CHECK = flag('--check');

const die = (msg) => {
  console.error(`!! ${msg}`);
  console.error('   cli-help.json was NOT written — the docs keep the last known-good capture.');
  process.exit(1);
};

// ---------------------------------------------------------------- build

function build() {
  if (!existsSync(join(CLI_DIR, 'Package.swift'))) {
    die(`no Swift package at ${CLI_DIR} — cannot build patchcli in this environment`);
  }
  console.log(`building patchcli (swift build in ${relative(ROOT, CLI_DIR)}) …`);
  const r = spawnSync('swift', ['build', '--product', 'patchcli'], {
    cwd: CLI_DIR,
    stdio: 'inherit',
    // The host (Apple/Xcode) toolchain builds the CLI; a swiftly-first PATH
    // would select the swift.org toolchain, which is for WASM targets only.
    env: { ...process.env, PATH: '/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin' },
    timeout: 20 * 60 * 1000,
  });
  if (r.error && r.error.code === 'ENOENT') {
    die('`swift` is not on PATH — cannot build patchcli in this environment');
  }
  if (r.status !== 0) die(`swift build failed (exit ${r.status})`);
}

if (!existsSync(BIN)) {
  if (flag('--no-build')) die(`no patchcli binary at ${BIN} and --no-build was passed`);
  build();
  if (!existsSync(BIN)) die(`swift build succeeded but no binary at ${BIN}`);
} else if (!flag('--no-build')) {
  // Rebuild by default so a stale binary cannot freeze the docs. Incremental
  // builds are cheap; --no-build skips it for fast local runs / CI without Swift.
  build();
}

// ---------------------------------------------------------------- capture

function run(args) {
  const r = spawnSync(BIN, args, { encoding: 'utf8', timeout: 60_000 });
  if (r.error) die(`could not run ${BIN}: ${r.error.message}`);
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`.trimEnd();
  if (!out) die(`\`patchcli ${args.join(' ')}\` produced no output`);
  return out;
}

// swift-argument-parser prints a SUBCOMMANDS block; names may carry
// "(default)". Descriptions wrap onto continuation lines.
function subcommandsOf(help) {
  const i = help.indexOf('SUBCOMMANDS:');
  if (i === -1) return [];
  const block = help.slice(i + 'SUBCOMMANDS:'.length).split(/\n\s*\n/)[0];
  const names = [];
  for (const line of block.split('\n')) {
    const m = line.match(/^\s{2}([a-z][a-z0-9-]*)(\s+\(default\))?\s{2,}\S/);
    if (m) names.push(m[1]);
  }
  return names;
}

const version = run(['--version']).trim();
const commands = [];

function capture(path) {
  const help = run([...path, '--help']);
  const overview = (help.match(/^OVERVIEW:\s*([\s\S]*?)\n\s*\n/) ?? [, ''])[1]
    .split('\n')
    .map((s) => s.trim())
    .join(' ')
    .trim();
  const usage = (help.match(/^USAGE:\s*(.+)$/m) ?? [, ''])[1].trim();
  const subs = subcommandsOf(help);
  commands.push({
    name: path.length ? path.join(' ') : 'patchcli',
    path,
    overview,
    usage,
    subcommands: subs.map((s) => [...path, s].join(' ')),
    help,
  });
  for (const s of subs) capture([...path, s]);
}

capture([]);

const payload = {
  generatedBy: 'scripts/gen-cli-help.mjs',
  cli: 'patchcli',
  version,
  commandCount: commands.length,
  commands,
};
const json = JSON.stringify(payload, null, 2) + '\n';

if (CHECK) {
  const cur = existsSync(OUT) ? readFileSync(OUT, 'utf8') : null;
  if (cur !== json) {
    console.error(
      `!! ${relative(ROOT, OUT)} is ${cur === null ? 'missing' : 'stale'} vs patchcli ${version} — run \`npm run gen:cli-help\``,
    );
    process.exit(1);
  }
  console.log(`cli-help.json matches patchcli ${version} (${commands.length} commands).`);
} else {
  mkdirSync(join(ROOT, 'src/data'), { recursive: true });
  writeFileSync(OUT, json);
  console.log(
    `cli-help.json: patchcli ${version}, ${commands.length} commands (${commands
      .filter((c) => c.path.length === 1)
      .map((c) => c.name.split(' ').pop())
      .join(', ')})`,
  );
}
