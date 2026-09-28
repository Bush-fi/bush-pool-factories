// Scaffolds a new pool factory from the template (contracts/_template and friends):
//
//     npm run new-factory -- MyCurve                    # everything, family contracts/my-curve/
//     npm run new-factory -- MyCurve --family curves    # put the contracts in contracts/curves/
//     npm run new-factory -- MyCurve --langs ts         # maths in TypeScript only (ts, py, rs; default all three)
//     npm run new-factory -- MyCurve --blank            # skeletons with TODOs instead of the worked example
//     npm run new-factory -- MyCurve --dry-run          # print what would be written, write nothing
//
// By default the result is a copy of the working ConstantSum template under the new names, registered with
// maths/check in every chosen language, so it compiles, passes its tests and passes `maths:check` before you change
// a line. Then replace the constant-sum logic with your pool's, contract and maths side by side.
//
// With --blank, the pool, factory, test, adapter and maths are skeletons from scripts/templates/blank/ instead: every
// function the Vault and maths/check need, with comments on what goes in it and no curve maths. They compile, but
// the tests and `maths:check` fail with NotImplemented until you fill them in.
//
// Nothing is overwritten: the script stops if any file it would create already exists or the pool type is already
// registered.
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LANGS = ['ts', 'py', 'rs'];
const BLANK = 'scripts/templates/blank';

function usage(message) {
  if (message) console.error(`error: ${message}\n`);
  console.error('usage: npm run new-factory -- <PascalCaseName> [--family <dir>] [--langs ts,py,rs] [--blank] [--dry-run]');
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { family: undefined, langs: LANGS, blank: false, dryRun: false };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') opts.dryRun = true;
    else if (arg === '--blank') opts.blank = true;
    else if (arg === '--family') opts.family = argv[++i];
    else if (arg === '--langs') opts.langs = (argv[++i] || '').split(',').filter(Boolean);
    else if (arg.startsWith('-')) usage(`unknown option ${arg}`);
    else positional.push(arg);
  }
  if (positional.length !== 1) usage('give exactly one name');
  opts.name = positional[0];
  return opts;
}

function names(opts) {
  const { name } = opts;
  if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) usage(`name must be PascalCase letters and digits (e.g. MyCurve), got ${name}`);
  if (/Pool$|Factory$/.test(name)) usage(`leave off "Pool"/"Factory": ${name.replace(/(Pool)?(Factory)?$/, '')} gives ${name.replace(/(Pool)?(Factory)?$/, '')}Pool and ${name.replace(/(Pool)?(Factory)?$/, '')}PoolFactory`);
  const words = name.match(/[A-Z][a-z0-9]*|[a-z0-9]+/g);
  const kebab = words.map((w) => w.toLowerCase()).join('-');
  const family = opts.family ?? kebab;
  if (!/^[a-z0-9][a-z0-9-]*$/.test(family)) usage(`family must be lowercase letters, digits and dashes, got ${family}`);
  for (const lang of opts.langs) if (!LANGS.includes(lang)) usage(`unknown language ${lang} (ts, py, rs)`);
  if (opts.langs.length === 0) usage('--langs needs at least one of ts, py, rs');
  return {
    Pascal: name,
    camel: name[0].toLowerCase() + name.slice(1),
    snake: words.map((w) => w.toLowerCase()).join('_'),
    UPPER: words.map((w) => w.toUpperCase()).join('_'),
    title: words.join(' '),
    family,
    factory: `${kebab}-pool-factory`,
  };
}

// Template identifiers → new ones. Order matters: paths first, then the longest names.
function renamer(n) {
  const pairs = [
    ['contracts/_template', `contracts/${n.family}`],
    ['test/foundry/_template', `test/foundry/${n.family}`],
    ['_template-pool-factory', n.factory],
    ['ConstantSum', n.Pascal],
    ['constantSum', n.camel],
    ['constant_sum', n.snake],
    ['CONSTANT_SUM', n.UPPER],
    ['Constant Sum', n.title],
    ['constant sum', n.title.toLowerCase()],
    // Mark the copied starting point as something to replace.
    ['TEMPLATE:', 'TODO (scaffolded from the ConstantSum template, replace with your pool):'],
    ['TEMPLATE ', 'TODO (scaffolded from the ConstantSum template) '],
  ];
  return (text) => pairs.reduce((s, [from, to]) => s.split(from).join(to), text);
}

// Placeholders in the blank skeletons (scripts/templates/blank/*.tmpl) → new identifiers.
function filler(n) {
  const pairs = [
    ['__Pascal__', n.Pascal],
    ['__camel__', n.camel],
    ['__snake__', n.snake],
    ['__UPPER__', n.UPPER],
    ['__Title__', n.title],
    ['__title__', n.title.toLowerCase()],
    ['__family__', n.family],
  ];
  return (text) => pairs.reduce((s, [from, to]) => s.split(from).join(to), text);
}

function plan(n, langs, blank) {
  const rename = renamer(n);
  const fill = filler(n);
  // Each copy is [template source, blank skeleton source (or null: same source either way), destination].
  const copies = [
    ['contracts/_template/ConstantSumPool.sol', `${BLANK}/Pool.sol.tmpl`, `contracts/${n.family}/${n.Pascal}Pool.sol`],
    [
      'contracts/_template/ConstantSumPoolFactory.sol',
      `${BLANK}/PoolFactory.sol.tmpl`,
      `contracts/${n.family}/${n.Pascal}PoolFactory.sol`,
    ],
    ['test/foundry/_template/ConstantSumPool.t.sol', `${BLANK}/Pool.t.sol.tmpl`, `test/foundry/${n.family}/${n.Pascal}Pool.t.sol`],
    ['maths/check/adapters/_template-pool-factory.ts', `${BLANK}/adapter.ts.tmpl`, `maths/check/adapters/${n.factory}.ts`],
    ['docs/_template-pool-factory/PARAMETERS.md', null, `docs/${n.factory}/PARAMETERS.md`],
    ['docs/_template-pool-factory/GAS_CHARACTERISTICS.md', null, `docs/${n.factory}/GAS_CHARACTERISTICS.md`],
  ];
  const edits = [];

  if (langs.includes('ts')) {
    copies.push(
      ['maths/typescript/src/constantSum/constantSum.ts', `${BLANK}/pool.ts.tmpl`, `maths/typescript/src/${n.camel}/${n.camel}.ts`],
      ['maths/typescript/src/constantSum/index.ts', null, `maths/typescript/src/${n.camel}/index.ts`]
    );
    edits.push({
      file: 'maths/check/runners/ts/pools.ts',
      taken: [`new ${n.Pascal}(`, `    ${n.UPPER}:`],
      insert: {
        'scaffold:imports': `import { ${n.Pascal} } from '@bush.fi/maths/${n.camel}';`,
        'scaffold:pools': `    ${n.UPPER}: (pool) => new ${n.Pascal}(pool),`,
      },
    });
  }
  if (langs.includes('py')) {
    copies.push(
      ['maths/python/bush_maths/pools/constant_sum/__init__.py', null, `maths/python/bush_maths/pools/${n.snake}/__init__.py`],
      [
        'maths/python/bush_maths/pools/constant_sum/constant_sum.py',
        `${BLANK}/pool.py.tmpl`,
        `maths/python/bush_maths/pools/${n.snake}/${n.snake}.py`,
      ]
    );
    edits.push({
      file: 'maths/check/runners/python/pools.py',
      taken: [` import ${n.Pascal}\n`, `    "${n.UPPER}":`],
      insert: {
        'scaffold:imports': `from bush_maths.pools.${n.snake}.${n.snake} import ${n.Pascal}`,
        'scaffold:pools': `    "${n.UPPER}": ${n.Pascal},`,
      },
    });
  }
  if (langs.includes('rs')) {
    copies.push(['maths/rust/src/pools/constant_sum/mod.rs', `${BLANK}/mod.rs.tmpl`, `maths/rust/src/pools/${n.snake}/mod.rs`]);
    edits.push(
      {
        file: 'maths/rust/src/pools/mod.rs',
        taken: [`pub mod ${n.snake};`],
        insert: { 'scaffold:modules': `pub mod ${n.snake};` },
      },
      {
        file: 'maths/check/rust/src/main.rs',
        taken: [`::${n.Pascal}Pool;`, `"${n.UPPER}" =>`],
        insert: {
          'scaffold:imports': `use bush_maths::pools::${n.snake}::${n.Pascal}Pool;`,
          'scaffold:pools': blank
            ? `        "${n.UPPER}" => Box::new(${n.Pascal}Pool::new()),`
            : `        "${n.UPPER}" => Box::new(${n.Pascal}Pool::new(pool.u("rate")?)),`,
        },
      }
    );
  }

  const writes = copies.map(([template, skeleton, to]) => ({
    to,
    content: blank && skeleton ? fill(read(skeleton)) : rename(read(template)),
  }));
  writes.push({ to: `docs/${n.factory}/README.md`, content: readme(n) });
  return { writes, edits };
}

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

// Inserts `line` just above the line holding `marker`, at the marker's position in the file.
function insertAbove(text, marker, line, file) {
  const lines = text.split('\n');
  const at = lines.findIndex((l) => l.includes(marker));
  if (at < 0) throw new Error(`${file}: marker "${marker}" not found`);
  lines.splice(at, 0, line);
  return lines.join('\n');
}

function readme(n) {
  return `# ${n.title} Pool Factory

TODO: what the pool is and when to use it, in a paragraph an integrator can act on.

## Pool Type

${n.UPPER}

## Overview

TODO: how \`${n.Pascal}PoolFactory\` deploys \`${n.Pascal}Pool\`: token count, creation parameters (see
[PARAMETERS.md](./PARAMETERS.md)), roles, hooks, and any time- or state-dependent behavior.

## Key Files
- Contracts: [\`contracts/${n.family}/\`](../../contracts/${n.family})
- Tests: [\`test/foundry/${n.family}/\`](../../test/foundry/${n.family})
- Maths: [\`maths/\`](../../maths) (checked against the deployed pool by \`npm run maths:check -- ${n.factory}\`)
- Parameters: [PARAMETERS.md](./PARAMETERS.md)
- Gas costs: [GAS_CHARACTERISTICS.md](./GAS_CHARACTERISTICS.md)
- License: TODO (the SPDX identifier on the contracts)

## Integration (For Aggregators)

Use the [maths](../../maths) package for your language; its \`Vault\` reproduces the on-chain result
(scaling, rates, fees, hooks) for this pool type:

\`\`\`typescript
import { Vault, SwapKind } from '@bush.fi/maths';

const amountOut = new Vault().swap({ amountRaw, tokenIn, tokenOut, swapKind: SwapKind.GivenIn }, poolState);
\`\`\`

\`poolState\` is the pool's state as read from the Vault (see \`maths/testData/*${n.factory}*.json\` for the exact
shape).
`;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const n = names(opts);
  const { writes, edits } = plan(n, opts.langs, opts.blank);

  // Refuse before touching anything.
  const problems = [];
  for (const { to } of writes) if (fs.existsSync(path.join(ROOT, to))) problems.push(`${to} already exists`);
  const edited = edits.map((e) => {
    let text = read(e.file);
    for (const t of e.taken) if (text.includes(t)) problems.push(`${e.file} already registers ${t.trim()}`);
    for (const [marker, line] of Object.entries(e.insert)) text = insertAbove(text, marker, line, e.file);
    return { file: e.file, text };
  });
  if (problems.length) {
    console.error(`Nothing written:\n${problems.map((p) => `  - ${p}`).join('\n')}`);
    process.exit(1);
  }

  for (const { to, content } of writes) {
    console.log(`  create  ${to}`);
    if (!opts.dryRun) {
      fs.mkdirSync(path.dirname(path.join(ROOT, to)), { recursive: true });
      fs.writeFileSync(path.join(ROOT, to), content);
    }
  }
  for (const { file, text } of edited) {
    console.log(`  update  ${file}`);
    if (!opts.dryRun) fs.writeFileSync(path.join(ROOT, file), text);
  }
  if (opts.dryRun) {
    console.log('\n(dry run: nothing written)');
    return;
  }

  if (opts.blank) {
    console.log(`
Scaffolded ${n.Pascal}Pool / ${n.Pascal}PoolFactory (pool type ${n.UPPER}) as blank skeletons. They compile;
the tests and maths:check fail with NotImplemented until you fill them in:

  npm run compile

Then, following CONTRIBUTING.md (steps 2-7):
  - contracts/${n.family}/: NewPoolParams, onSwap, computeInvariant, computeBalance, the bounds, create()'s parameters
  - test/foundry/${n.family}/: test every operation and revert
  - maths/check/adapters/${n.factory}.ts: variants, create() args, poolData()
  - the maths (${opts.langs.join(', ')}): port the contract call for call, importing only from the pool kit${
    opts.langs.includes('rs') ? `\n    (Rust: also pass your parameters in the ${n.UPPER} arm in maths/check/rust/src/main.rs)` : ''
  }
  - docs/${n.factory}/: every file
  Search the new files for "TODO" to find everything still to write. For a worked example of each part, see the
  ConstantSum template (contracts/_template/, maths/*/constant_sum*).
`);
    return;
  }

  console.log(`
Scaffolded ${n.Pascal}Pool / ${n.Pascal}PoolFactory (pool type ${n.UPPER}). It is a renamed copy of the
constant-sum template, so it already passes. Check that, then make it yours:

  npm run compile
  forge test --match-path 'test/foundry/${n.family}/*'
  FACTORIES=${n.factory} npm run maths:generate
  npm run maths:check -- ${n.factory}

Then, following CONTRIBUTING.md (steps 2-7):
  - contracts/${n.family}/: replace the constant-sum logic and NewPoolParams with your pool's
  - test/foundry/${n.family}/: test every operation and revert
  - maths/check/adapters/${n.factory}.ts: variants, create() args, poolData()
  - the maths (${opts.langs.join(', ')}): port the contract call for call, importing only from the pool kit${
    opts.langs.includes('rs') ? `\n    (Rust: also point the ${n.UPPER} arm in maths/check/rust/src/main.rs at your constructor)` : ''
  }
  - docs/${n.factory}/: every file
  Search the repo for "TODO (scaffolded" to find everything still to replace.
`);
}

// Run as a script; `require`d (by new-hook.js), just share the helpers.
if (require.main === module) main();

module.exports = { ROOT, LANGS, read, insertAbove };
