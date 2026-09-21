// Entry point: `npm run check` / `npm run check -- <factory>` (ts-node).
//
// For each factory with an adapter, runs the TypeScript, Python and Rust maths (maths/<lang>) through the Vault flow
// against that factory's generated test data (maths/testData/31337-<factory>-*.json) and reports, per language and
// operation, how many results match the deployed contracts exactly. Each language looks the pool up by type in its
// registry: runners/ts/pools.ts, runners/python/pools.py, rust/src/main.rs.
//
//   FACTORIES=weighted-pool-factory,...   subset (default: every approved factory)
//   LANGS=typescript,python,rust          subset of languages

import { execFileSync, spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { discoverFactories, REPO, ROOT, testDataDirFor } from './paths';

type Lang = 'typescript' | 'python' | 'rust';
const LANGS: Lang[] = ['typescript', 'python', 'rust'];

interface Outcome {
  kind: 'swap' | 'add' | 'remove';
  index: number;
  expected: string[];
  actual?: string[];
  error?: string;
}

type Verdict = 'exact' | 'one-wei' | 'mismatch' | 'error';

function verdict(o: Outcome): Verdict {
  if (o.error !== undefined || !o.actual) return 'error';
  if (o.actual.length !== o.expected.length) return 'mismatch';
  let worst: Verdict = 'exact';
  for (let i = 0; i < o.expected.length; i++) {
    const d = BigInt(o.expected[i]) - BigInt(o.actual[i]);
    const abs = d < 0n ? -d : d;
    if (abs === 0n) continue;
    // The Router's query reads live balances rounded down, while the Vault rounds them up inside add/remove
    // liquidity, so BPT amounts can legitimately differ by one unit (the maths' own suites allow the same).
    if (abs === 1n && o.kind !== 'swap') worst = worst === 'exact' ? 'one-wei' : worst;
    else return 'mismatch';
  }
  return worst;
}

function which(cmd: string): boolean {
  return spawnSync('which', [cmd]).status === 0;
}

const RUST = path.join(ROOT, 'rust');
let rustBuilt = false;

function runMaths(lang: Lang, dataFile: string): Outcome[] {
  let cmd: [string, string[]];
  if (lang === 'typescript') {
    cmd = ['npx', ['ts-node', '--transpile-only', '-r', 'tsconfig-paths/register', '-P', path.join(REPO, 'tsconfig.json'), path.join(ROOT, 'runners/ts/runner.ts'), dataFile]];
  } else if (lang === 'python') {
    cmd = ['python3', [path.join(ROOT, 'runners/python/runner.py'), dataFile]];
  } else {
    if (!rustBuilt) {
      execFileSync('cargo', ['build', '--release', '--quiet', '--manifest-path', path.join(RUST, 'Cargo.toml')], { stdio: ['ignore', 'ignore', 'inherit'] });
      rustBuilt = true;
    }
    cmd = [path.join(RUST, 'target/release/math_check'), [dataFile]];
  }
  const r = spawnSync(cmd[0], cmd[1], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, cwd: REPO, env: { ...process.env, TS_NODE_PROJECT: path.join(REPO, 'tsconfig.json') } });
  if (r.status !== 0) throw new Error(`${lang} runner failed:\n${r.stderr}`);
  return JSON.parse(r.stdout);
}

interface Row {
  factory: string;
  file: string;
  lang: Lang;
  counts: Record<Outcome['kind'], Record<Verdict, number>>;
  problems: (Outcome & { verdict: Verdict })[];
}

function main() {
  const wanted = process.env.FACTORIES?.split(',') ?? (process.argv[2] ? [process.argv[2]] : undefined);
  const factories = discoverFactories(wanted !== undefined).filter((f) => !wanted || wanted.includes(f.name));
  if (factories.length === 0) throw new Error('no factory adapter matched');
  const langs = ((process.env.LANGS?.split(',') as Lang[] | undefined) ?? LANGS).filter((l) => {
    const ok = l === 'typescript' || (l === 'python' ? which('python3') : which('cargo'));
    if (!ok) console.log(`⚠️  ${l}: toolchain not found, skipped`);
    return ok;
  });

  const rows: Row[] = [];
  let failed = false;
  for (const factory of factories) {
    const dataDir = testDataDirFor(factory.name);
    const files = fs.existsSync(dataDir) ? fs.readdirSync(dataDir).filter((f) => f.startsWith(`31337-${factory.name}-`)).sort() : [];
    if (files.length === 0) {
      console.log(`\n${factory.name}: no test data — run \`npm run generate\` first`);
      failed = true;
      continue;
    }
    console.log(`\n${factory.name}`);
    for (const lang of langs) {
      for (const file of files) {
        const row: Row = { factory: factory.name, file, lang, counts: { swap: zero(), add: zero(), remove: zero() }, problems: [] };
        try {
          for (const o of runMaths(lang, path.join(dataDir, file))) {
            const v = verdict(o);
            row.counts[o.kind][v]++;
            if (v === 'mismatch' || v === 'error') row.problems.push({ ...o, verdict: v });
          }
        } catch (e: any) {
          console.log(`  ${lang.padEnd(10)} ${file}: ${e.message.split('\n').slice(0, 3).join(' | ')}`);
          failed = true;
          continue;
        }
        rows.push(row);
        const cell = (k: Outcome['kind']) => {
          const c = row.counts[k];
          const n = c.exact + c['one-wei'] + c.mismatch + c.error;
          return n === 0 ? '   —   ' : `${String(c.exact + c['one-wei']).padStart(3)}/${String(n).padEnd(3)}`;
        };
        const bad = row.problems.length;
        console.log(`  ${bad ? '❌' : '✅'} ${lang.padEnd(10)} ${file.replace(`31337-${factory.name}-`, '').replace('.json', '').padEnd(26)} swaps ${cell('swap')} adds ${cell('add')} removes ${cell('remove')}`);
        if (bad) failed = true;
      }
    }
  }

  // Detailed report
  const out = path.join(ROOT, 'out');
  fs.mkdirSync(out, { recursive: true });
  const lines: string[] = ['# Math check report', ''];
  for (const row of rows) {
    if (row.problems.length === 0) continue;
    lines.push(`## ${row.factory} / ${row.file} / ${row.lang}`, '');
    for (const p of row.problems.slice(0, 50)) {
      lines.push(`- ${p.kind} #${p.index}: expected \`${p.expected.join(', ')}\`, ${p.error !== undefined ? `error \`${p.error}\`` : `got \`${p.actual!.join(', ')}\``}`);
    }
    lines.push('');
  }
  if (lines.length === 2) lines.push('All results match the deployed contracts.');
  fs.writeFileSync(path.join(out, 'report.md'), lines.join('\n'));
  fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(rows, null, 2));
  console.log(`\nDetails: ${path.relative(REPO, path.join(out, 'report.md'))}`);
  console.log(failed ? '❌ some results do not match the deployed contracts' : '✅ every result matches the deployed contracts');
  process.exitCode = failed ? 1 : 0;
}

function zero(): Record<Verdict, number> {
  return { exact: 0, 'one-wei': 0, mismatch: 0, error: 0 };
}

main();
