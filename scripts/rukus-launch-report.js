#!/usr/bin/env node
// Runs every RukusLaunch test and writes an audit-style report: npm run test:rukus-launch:report
//
// What it runs:
//   1. Foundry: every suite in test/foundry/rukus-launch (unit, fuzz, invariant, attacks, extreme moves, the
//      volatility simulation), as JSON, so each test's result, fuzz/invariant runs and logged numbers are captured.
//   2. With FORK_URL set: the same Foundry suites again on a fork of the live chain (pinned to its latest block), so
//      the tests run against the live Vault, Router, Permit2, WETH and protocol fee controller. Tests that need a
//      local-mock control skip there and say why.
//   3. Hardhat: the end-to-end Router + ETH test, with its gas table.
//   4. The maths check: the TypeScript, Python and Rust maths against the deployed pool.
//
// Writes docs/rukus-launch-pool-factory/TEST_REPORT.md. Each test is described by the NatSpec comment above it in
// the test source, so the report says what was tested, not just its name.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const TEST_DIR = 'test/foundry/rukus-launch';
const OUT = path.join(ROOT, 'docs/rukus-launch-pool-factory/TEST_REPORT.md');

function run(cmd, args, env = {}) {
  const started = Date.now();
  const result = spawnSync(cmd, args, {
    cwd: ROOT,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 1024,
  });
  return {
    status: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    seconds: ((Date.now() - started) / 1000).toFixed(1),
  };
}

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');
const firstLine = (s) => (s || '').trim().split('\n')[0];

/***************************************************************************
                         Test descriptions (NatSpec)
***************************************************************************/

/** Maps `Contract.function` to the doc comment above it in the test sources. */
function readDescriptions() {
  const descriptions = {};
  for (const file of fs.readdirSync(path.join(ROOT, TEST_DIR))) {
    if (!file.endsWith('.sol')) continue;
    const lines = fs.readFileSync(path.join(ROOT, TEST_DIR, file), 'utf8').split('\n');
    let contract = '';
    let doc = [];
    let inBlock = false;
    let inBanner = false;
    for (const raw of lines) {
      const line = raw.trim();
      const contractMatch = line.match(/^contract (\w+)/);
      if (contractMatch) contract = contractMatch[1];

      // Section banners (/*** ... ***/) are not test comments.
      if (line.startsWith('/***')) {
        inBanner = !line.endsWith('*/') || line === '/***';
        doc = [];
        continue;
      }
      if (inBanner) {
        if (line.endsWith('*/')) {
          inBanner = false;
          doc = [];
        }
        continue;
      }
      if (line.startsWith('/**')) {
        inBlock = true;
        doc = [];
        const rest = line.replace(/^\/\*\*/, '').replace(/\*\/$/, '').trim();
        if (rest) doc.push(rest);
        if (line.endsWith('*/')) inBlock = false;
        continue;
      }
      if (inBlock) {
        if (line.startsWith('*/') || line.endsWith('*/')) {
          inBlock = false;
          const rest = line.replace(/\*\/$/, '').replace(/^\*/, '').trim();
          if (rest) doc.push(rest);
          continue;
        }
        doc.push(line.replace(/^\*\s?/, ''));
        continue;
      }
      if (line.startsWith('///')) {
        doc.push(line.replace(/^\/\/\/\s?/, ''));
        continue;
      }
      const fn = line.match(/^function ((?:test|invariant)\w*)\(/);
      if (fn) {
        descriptions[`${contract}.${fn[1]}`] = doc
          .join(' ')
          .replace(/@dev\s*/g, '')
          .replace(/@notice\s*/g, '')
          .replace(/forge-config:[^ ]+ = \d+\s*/g, '')
          .replace(/\s+/g, ' ')
          .trim();
      }
      if (line && !line.startsWith('//') && !line.startsWith('*')) doc = [];
    }
  }
  return descriptions;
}

/** Maps a test function's name to the reason it gives `_skipOnFork("...")` in the test sources. */
function readForkSkipReasons() {
  const reasons = {};
  for (const file of fs.readdirSync(path.join(ROOT, TEST_DIR))) {
    if (!file.endsWith('.sol')) continue;
    let current = '';
    for (const line of fs.readFileSync(path.join(ROOT, TEST_DIR, file), 'utf8').split('\n')) {
      const fn = line.match(/function ((?:test|invariant)\w*)\(/);
      if (fn) current = fn[1];
      const skip = line.match(/_skipOnFork\("([^"]+)"\)/);
      if (skip && current) reasons[current] = skip[1];
      if (/RUN_SIM/.test(line) && current) reasons[current] = reasons[current] || 'the volatility simulation runs locally only';
    }
  }
  return reasons;
}

/** `testBuyFollowsVirtualReserveCurve__Fuzz` -> "Buy follows virtual reserve curve", for tests without a comment. */
function humanize(name) {
  const words = name
    .replace(/^(test|invariant_)/, '')
    .replace(/__Fuzz$/, '')
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .trim()
    .toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1) + '.';
}

/** The comment for a test: by contract, else by name (inherited tests), else its name in words. */
function describe(descriptions, contract, name) {
  if (descriptions[`${contract}.${name}`]) return descriptions[`${contract}.${name}`];
  const inherited = Object.keys(descriptions).find((key) => key.endsWith(`.${name}`) && descriptions[key]);
  return inherited ? descriptions[inherited] : humanize(name);
}

/***************************************************************************
                                  Foundry
***************************************************************************/

function parseForgeJson(stdout) {
  const start = stdout.indexOf('{');
  if (start < 0) return {};
  try {
    return JSON.parse(stdout.slice(start));
  } catch {
    return {};
  }
}

function describeKind(kind) {
  if (!kind) return '';
  if (kind.Unit) return 'unit';
  if (kind.Fuzz) return `fuzz, ${Number(kind.Fuzz.runs).toLocaleString('en-US')} runs`;
  if (kind.Invariant) {
    const k = kind.Invariant;
    return `invariant, ${k.runs} runs × ${Math.round(k.calls / Math.max(k.runs, 1))} calls, ${k.reverts} reverts`;
  }
  return Object.keys(kind)[0].toLowerCase();
}

function gasOf(kind) {
  if (!kind) return '';
  if (kind.Unit) return Number(kind.Unit.gas).toLocaleString('en-US');
  if (kind.Fuzz) return `μ ${Number(kind.Fuzz.mean_gas).toLocaleString('en-US')}`;
  return '';
}

/***************************************************************************
                                  Report
***************************************************************************/

function main() {
  const descriptions = readDescriptions();
  const skipReasons = readForkSkipReasons();
  const commit = run('git', ['rev-parse', '--short', 'HEAD']).stdout.trim();
  const branch = run('git', ['rev-parse', '--abbrev-ref', 'HEAD']).stdout.trim();
  const dirty = run('git', ['status', '--porcelain', '--', 'contracts/rukus-launch', TEST_DIR]).stdout.trim() !== '';
  const forgeVersion = firstLine(run('forge', ['--version']).stdout);

  console.log('Running the Foundry suites locally (with the volatility simulation)...');
  const forkUrl = process.env.FORK_URL || '';
  // -vv: without it, forge leaves the tests' console output (the logged numbers) out of the JSON.
  const forge = run('forge', ['test', '--match-path', `${TEST_DIR}/*`, '--json', '-vv'], {
    RUN_SIM: 'true',
    FOUNDRY_GAS_LIMIT: '9000000000',
    FORK_URL: '',
  });
  const suites = parseForgeJson(forge.stdout);

  // The same suites on a fork of the live chain, pinned to one block (so every test sees the same state).
  let fork = null;
  let forkSuites = {};
  let forkBlock = '';
  if (forkUrl) {
    forkBlock = process.env.FORK_BLOCK || String(parseInt(JSON.parse(
      run('curl', ['-s', '-X', 'POST', '-H', 'content-type: application/json', '--data',
        '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}', forkUrl]).stdout
    ).result, 16));
    console.log(`Running the Foundry suites on a fork of ${forkUrl} at block ${forkBlock}...`);
    // Light fuzzing on the fork: the full 10,000-run fuzzing is the local run's job; here every path just has to
    // behave the same against the live contracts.
    fork = run('forge', ['test', '--match-path', `${TEST_DIR}/*`, '--json', '-vv'], {
      FORK_URL: forkUrl,
      FORK_BLOCK: forkBlock,
      FOUNDRY_FUZZ_RUNS: '256',
      FOUNDRY_INVARIANT_RUNS: '16',
      FOUNDRY_INVARIANT_DEPTH: '32',
    });
    forkSuites = parseForgeJson(fork.stdout);
  }

  console.log('Running the Hardhat end-to-end test...');
  const hardhat = run('npx', ['hardhat', 'test', 'test/hardhat/rukus-launch/rukusLaunchPool.test.ts']);
  const hardhatOut = stripAnsi(hardhat.stdout);

  console.log('Running the maths check...');
  const maths = run('npm', ['run', 'maths:check', '--', 'rukus-launch-pool-factory']);
  const mathsOut = stripAnsi(maths.stdout);

  // Sizes from the Hardhat build (the deployment settings).
  const sizes = [];
  for (const name of ['RukusLaunchPool', 'RukusLaunchPoolFactory', 'RukusLaunchToken']) {
    const file = path.join(ROOT, `artifacts/contracts/rukus-launch/${name}.sol/${name}.json`);
    if (fs.existsSync(file)) {
      const bytes = (JSON.parse(fs.readFileSync(file, 'utf8')).deployedBytecode.length - 2) / 2;
      sizes.push(`| \`${name}\` | ${bytes.toLocaleString('en-US')} bytes (${(bytes / 1024).toFixed(1)} KB) |`);
    }
  }

  // Tally.
  let passed = 0;
  let failed = 0;
  let skipped = 0;
  const suiteRows = [];
  const sections = [];
  const failures = [];
  for (const [suiteKey, suite] of Object.entries(suites).sort()) {
    const contract = suiteKey.split(':').pop();
    const file = suiteKey.split(':')[0].replace(`${TEST_DIR}/`, '');
    const results = Object.entries(suite.test_results || {}).sort();
    let p = 0;
    let f = 0;
    let s = 0;
    const rows = [];
    const logs = [];
    for (const [signature, result] of results) {
      const name = signature.split('(')[0];
      const status = result.status === 'Success' ? 'PASS' : result.status === 'Skipped' ? 'SKIP' : 'FAIL';
      if (status === 'PASS') p++;
      else if (status === 'SKIP') s++;
      else {
        f++;
        failures.push(`- \`${contract}.${name}\`: ${result.reason || 'failed'}`);
      }
      const description = describe(descriptions, contract, name);
      rows.push(`| \`${name}\` | ${status} | ${describeKind(result.kind)} | ${gasOf(result.kind)} | ${description.replace(/\|/g, '\\|')} |`);
      const decoded = (result.decoded_logs || []).filter((l) => l.trim() !== '');
      if (decoded.length) logs.push(`**\`${name}\`**\n\n\`\`\`\n${decoded.join('\n')}\n\`\`\``);
    }
    passed += p;
    failed += f;
    skipped += s;
    suiteRows.push(`| ${contract} | \`${file}\` | ${p} | ${f} | ${s} |`);
    sections.push(
      `### ${contract}\n\n\`${TEST_DIR}/${file}\`\n\n| Test | Result | Kind | Gas | What it checks |\n| --- | --- | --- | --- | --- |\n${rows.join('\n')}` +
        (logs.length ? `\n\n#### Logged data\n\n${logs.join('\n\n')}` : '')
    );
  }

  // Fork run: per suite, and what skipped there and why.
  let forkPassed = 0;
  let forkFailed = 0;
  let forkSkipped = 0;
  const forkRows = [];
  const forkSkips = [];
  for (const [suiteKey, suite] of Object.entries(forkSuites).sort()) {
    const contract = suiteKey.split(':').pop();
    let p = 0;
    let f = 0;
    let k = 0;
    for (const [signature, result] of Object.entries(suite.test_results || {})) {
      const name = signature.split('(')[0];
      if (result.status === 'Success') p++;
      else if (result.status === 'Skipped') {
        k++;
        forkSkips.push(`- \`${contract}.${name}\`: ${skipReasons[name] || 'skipped'}`);
      } else {
        f++;
        failures.push(`- (fork) \`${contract}.${name}\`: ${result.reason || 'failed'}`);
      }
    }
    forkPassed += p;
    forkFailed += f;
    forkSkipped += k;
    forkRows.push(`| ${contract} | ${p} | ${f} | ${k} |`);
  }

  const hardhatPassing = (hardhatOut.match(/(\d+) passing/) || [])[1] || '0';
  const hardhatFailing = (hardhatOut.match(/(\d+) failing/) || [])[1] || '0';
  const hardhatBody = hardhatOut
    .split('\n')
    .filter((l) => /✔|✗|\d+\) |Gas \(|^\s{8}\S.*\d$|passing|failing/.test(l))
    .join('\n');
  const mathsTable = mathsOut
    .split('\n')
    .filter((l) => /✅|❌|every result|mismatch/.test(l))
    .join('\n');
  const mathsOk = /every result matches/.test(mathsOut);

  const overall =
    failed === 0 &&
    forkFailed === 0 &&
    (!forkUrl || forkPassed > 0) &&
    hardhatFailing === '0' &&
    hardhat.status === 0 &&
    mathsOk &&
    forge.stdout.trim() !== '';

  const report = `# RukusLaunch: Test Report

Generated by \`npm run test:rukus-launch:report\` on ${new Date().toISOString().replace('T', ' ').slice(0, 19)} UTC.
Do not edit by hand: re-run the script.

## Summary

| | Result |
| --- | --- |
| **Overall** | **${overall ? 'PASS' : 'FAIL'}** |
| Foundry tests | ${passed} passed, ${failed} failed, ${skipped} skipped (${forge.seconds}s) |
| Hardhat end-to-end (Router, ETH) | ${hardhatPassing} passed, ${hardhatFailing} failed (${hardhat.seconds}s) |
| Maths check (TypeScript, Python, Rust vs the contract) | ${mathsOk ? 'all match' : 'MISMATCH or error'} (${maths.seconds}s) |
| Foundry tests on a live-chain fork | ${forkUrl ? `${forkPassed} passed, ${forkFailed} failed, ${forkSkipped} skipped, at block ${forkBlock} (${fork.seconds}s)` : 'not run (set FORK_URL)'} |
${failures.length ? `\n**Failures**\n\n${failures.join('\n')}\n` : ''}
## Scope

| | |
| --- | --- |
| Commit | \`${commit}\` on \`${branch}\`${dirty ? ' (**uncommitted changes** in the contracts or tests)' : ''} |
| Contracts | \`contracts/rukus-launch/\`: \`RukusLaunchPool\`, \`RukusLaunchPoolFactory\`, \`RukusLaunchToken\`, \`lib/RukusLaunchMath\`, \`lib/RukusLaunchPoolFactoryLib\`; swap maths from \`contracts/reclamm/lib/ReClammMath\` |
| Toolchain | ${forgeVersion} |

Runtime sizes (Hardhat build, the deployment settings; limit 24,576 bytes):

| Contract | Size |
| --- | --- |
${sizes.join('\n')}

Design and trust assumptions: [README.md](./README.md). Parameters: [PARAMETERS.md](./PARAMETERS.md).

## Method

- **Unit tests** check each behaviour directly (phases, graduation, fees, roles, limits, errors).
- **Fuzz tests** repeat a property over thousands of random inputs (\`[fuzz] runs\` in \`foundry.toml\`).
- **Invariant tests** run random sequences of buys, sells, waits, graduation, liquidity adds and removes, and fee
  withdrawals, and check the invariants after every step.
- **Attack scenarios** try specific exploits (recovery-mode exits, premines, flash buyouts, push-and-hold, JIT
  liquidity, overshoot) and assert they fail or lose money.
- **Extreme moves and the volatility simulation** push the graduated pool through 5,000x runs, crashes and 45-day
  price paths.
- **End to end** through the real Router paying in ETH (Hardhat).
- **Live-chain fork**: every Foundry suite again against the live chain's Vault, Router, WETH and fee controller.
- **Maths check**: the off-chain maths (for aggregators) replays the pool's results in three languages.

## Foundry suites

| Suite | File | Passed | Failed | Skipped |
| --- | --- | --- | --- | --- |
${suiteRows.join('\n')}

${sections.join('\n\n')}

${forkUrl ? `## On a live-chain fork

The same suites on a fork of \`${forkUrl}\` at block ${forkBlock}: the live Vault, Router, Permit2, WETH and protocol
fee controller, with the chain's real protocol fee. Lighter fuzzing than locally (256 fuzz runs, 16 invariant
sequences of 32 steps): the point here is the live contracts, not more random inputs. The volatility simulation runs
locally only.

| Suite | Passed | Failed | Skipped |
| --- | --- | --- | --- |
${forkRows.join('\n')}

${forkSkips.length ? `Skipped on the fork, and why:\n\n${forkSkips.join('\n')}\n` : ''}
` : ''}## Hardhat end to end (Router, ETH)

\`test/hardhat/rukus-launch/rukusLaunchPool.test.ts\`

\`\`\`
${hardhatBody}
\`\`\`

## Maths check

\`\`\`
${mathsTable}
\`\`\`
`;

  fs.writeFileSync(OUT, report);
  console.log(`\n${overall ? 'PASS' : 'FAIL'}: wrote ${path.relative(ROOT, OUT)}`);
  if (forge.stdout.trim() === '') console.error(forge.stderr.slice(-4000));
  process.exitCode = overall ? 0 : 1;
}

main();
