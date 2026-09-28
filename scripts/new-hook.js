// Scaffolds a new hook, and a factory that deploys an existing pool type with that hook as an immutable:
//
//     npm run new-hook -- MyFee                         # asks which pool type to put the hook on
//     npm run new-hook -- MyFee --pool weighted         # or say it: weighted, stable, constant-sum
//     npm run new-hook -- MyFee --restricted            # only pools from the factory may use the hook (see below)
//     npm run new-hook -- MyFee --family fees           # put the contracts in contracts/fees/
//     npm run new-hook -- MyFee --langs ts              # hook maths in TypeScript only (ts, py, rs; default all three)
//     npm run new-hook -- MyFee --dry-run               # print what would be written, write nothing
//
// For MyFee on weighted pools this writes MyFeeHook (every callback, commented, all switched off) and
// MyFeeWeightedPoolFactory (deploys a standard WeightedPool, registered with the hook), a Forge test inheriting
// PoolPropertiesTest, a maths/check adapter, and the hook's maths in each language, registered with maths/check. The
// pool itself is unchanged, so its maths already exists: only the hook is new. Everything compiles and passes before
// you change a line (the hook does nothing yet).
//
// Registration is open by default, like StableSurgeHook: any pool from any factory may register with the hook, which
// is safe while everything it stores is per pool. --restricted is for hooks that hold funds or state shared between
// pools: the deployer binds the hook to its factory once (`setFactory`), and it refuses every other pool.
//
// Nothing is overwritten: the script stops if any file it would create
// already exists or the hook type is already registered.
const fs = require('fs');
const path = require('path');
const readline = require('readline/promises');

const { ROOT, LANGS, read, insertAbove } = require('./new-factory');

const TEMPLATES = 'scripts/templates/hook';

// The pool types a hook can go on. Each knows how to create its pool (in the factory, the test and the adapter) and
// which fields its maths reads. Not offered: LBPs are their own hooks, CoW pools route through CowRouter, and ReClamm
// pools keep state the Vault can't see; hooking those needs a hand-written factory.
const POOLS = {
  weighted: {
    label: 'Weighted (WeightedPool: any weights, full price range, uncorrelated assets)',
    pool: 'WeightedPool',
    poolPath: 'weighted/WeightedPool.sol',
    poolType: 'WEIGHTED',
    prefix: 'Weighted',
    testImports: 'import { MinTokenBalanceLib } from "@bush.fi/v3-vault/contracts/lib/MinTokenBalanceLib.sol";',
    testRanges: `        // Other defaults suit a WeightedPool (it refuses swaps above 30% of a balance, the default maxSwapRatio).
        // WeightedMath's invariant is a product of approximated powers: it drifts by up to ~1e-18 relative.
        invariantRelDecreaseTolerance = 1e3; // 1e-15`,
    testCreate: `        uint256[] memory weights = [uint256(50e16), uint256(50e16)].toMemoryArray();
        newPool = __Factory__(poolFactory).create(
            "__Title__ Pool",
            "POOL",
            tokenConfigs,
            weights,
            roleAccounts,
            SWAP_FEE,
            false, // enableDonation
            false, // disableUnbalancedLiquidity
            bytes32(0)
        );
        poolArgs = abi.encode(
            WeightedPool.NewPoolParams({
                name: "__Title__ Pool",
                symbol: "POOL",
                numTokens: 2,
                normalizedWeights: weights,
                version: POOL_VERSION,
                minTokenBalances: MinTokenBalanceLib.computeMinTokenBalances(tokenConfigs)
            }),
            vault
        );`,
    variants: `    '2-tokens': { description: '2 tokens (18 and 6 decimals), equal weights', decimals: [18, 6] },
    '3-tokens': { description: '3 tokens (18, 8, 6 decimals), equal weights', decimals: [18, 8, 6] },`,
    adapterCreate: `    // Equal weights, summing exactly to 1e18 (the factory enforces the sum).
    const ONE = 10n ** 18n;
    const weights = tokens.map(() => ONE / BigInt(tokens.length));
    weights[0] += ONE - weights.reduce((a, b) => a + b, 0n);
    const tx = await factory.create(
      '__Title__ Pool',
      'POOL',
      ctx.tokenConfig(tokens),
      weights,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01),
      false, // enableDonation
      false, // disableUnbalancedLiquidity
      ctx.ZERO_BYTES32
    );`,
    poolData: `async () => ({
        weights: [...(await pool.getNormalizedWeights())].map(String),
        minTokenBalances: [...(await pool.getMinTokenBalances())].map(String),
      })`,
  },
  stable: {
    label: 'Stable (StablePool: amplified curve for like-kind assets, e.g. stablecoins, LSTs)',
    pool: 'StablePool',
    poolPath: 'stable/StablePool.sol',
    poolType: 'STABLE',
    prefix: 'Stable',
    testImports: '',
    testRanges: `        // StableMath's invariant is iterative and stops converging on extremely unbalanced pools: keep the random
        // balances within a factor of 1000 of each other.
        minBalance = 1e21;
        maxBalance = 1e24;
        // StableMath's invariant is found by Newton iteration: it drifts by up to ~1e-22 relative.
        invariantRelDecreaseTolerance = 1e2; // 1e-16`,
    testCreate: `        newPool = __Factory__(poolFactory).create(
            "__Title__ Pool",
            "POOL",
            tokenConfigs,
            AMPLIFICATION,
            roleAccounts,
            SWAP_FEE,
            false, // enableDonation
            false, // disableUnbalancedLiquidity
            bytes32(0)
        );
        poolArgs = abi.encode(
            StablePool.NewPoolParams({
                name: "__Title__ Pool",
                symbol: "POOL",
                amplificationParameter: AMPLIFICATION,
                version: POOL_VERSION
            }),
            vault
        );`,
    testConstants: '    uint256 private constant AMPLIFICATION = 200;',
    variants: `    '2-tokens-A200': { description: '2 tokens (18 and 6 decimals), amplification 200', decimals: [18, 6], amplification: 200 },
    '3-tokens-A1000': { description: '3 tokens (18, 18, 6 decimals), amplification 1000', decimals: [18, 18, 6], amplification: 1000 },`,
    adapterCreate: `    const tx = await factory.create(
      '__Title__ Pool',
      'POOL',
      ctx.tokenConfig(tokens),
      ctx.variant.amplification as number,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.001),
      false, // enableDonation
      false, // disableUnbalancedLiquidity
      ctx.ZERO_BYTES32
    );`,
    poolData: `async () => ({ amp: (await pool.getAmplificationParameter())[0].toString() })`,
  },
  'constant-sum': {
    label: 'Constant sum (the template ConstantSumPool: fixed price, 2 tokens; handy for trying a hook out)',
    pool: 'ConstantSumPool',
    poolPath: '_template/ConstantSumPool.sol',
    poolType: 'CONSTANT_SUM',
    prefix: 'ConstantSum',
    testImports: '',
    testRanges: '        // The defaults suit a ConstantSumPool.',
    testCreate: `        newPool = __Factory__(poolFactory).create("__Title__ Pool", "POOL", tokenConfigs, RATE, roleAccounts, SWAP_FEE, bytes32(0));
        poolArgs = abi.encode(
            ConstantSumPool.NewPoolParams({ name: "__Title__ Pool", symbol: "POOL", version: POOL_VERSION, rate: RATE }),
            vault
        );`,
    testConstants: '    uint256 private constant RATE = 2e18; // 1 token0 = 2 token1',
    variants: `    'rate-2-decimals-18-6': { description: '1 token0 = 2 token1; tokens with 18 and 6 decimals', decimals: [18, 6], rate: 2 },`,
    adapterCreate: `    const tx = await factory.create(
      '__Title__ Pool',
      'POOL',
      ctx.tokenConfig(tokens),
      ctx.fp(ctx.variant.rate as number),
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01),
      ctx.ZERO_BYTES32
    );`,
    poolData: `async () => ({ rate: (await pool.getConstantSumRate()).toString() })`,
  },
};

function usage(message) {
  if (message) console.error(`error: ${message}\n`);
  console.error(
    `usage: npm run new-hook -- <PascalCaseName> [--pool ${Object.keys(POOLS).join('|')}] [--restricted] [--family <dir>] [--langs ts,py,rs] [--dry-run]`
  );
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { pool: undefined, restricted: false, family: undefined, langs: LANGS, dryRun: false };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') opts.dryRun = true;
    else if (arg === '--pool') opts.pool = argv[++i];
    else if (arg === '--restricted') opts.restricted = true;
    else if (arg === '--family') opts.family = argv[++i];
    else if (arg === '--langs') opts.langs = (argv[++i] || '').split(',').filter(Boolean);
    else if (arg.startsWith('-')) usage(`unknown option ${arg}`);
    else positional.push(arg);
  }
  if (positional.length !== 1) usage('give exactly one name');
  opts.name = positional[0];
  return opts;
}

/** Asks for the pool type when --pool wasn't given (and there's someone to ask). */
async function choosePool(opts) {
  if (opts.pool) {
    if (!POOLS[opts.pool]) usage(`unknown pool ${opts.pool}; choose one of ${Object.keys(POOLS).join(', ')}`);
    return opts.pool;
  }
  if (!process.stdin.isTTY) usage(`--pool is required when not run interactively (${Object.keys(POOLS).join(', ')})`);

  const keys = Object.keys(POOLS);
  console.log(`Which pool type should ${opts.name} hook into?\n`);
  keys.forEach((k, i) => console.log(`  ${i + 1}. ${POOLS[k].label}`));
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    for (;;) {
      const answer = (await rl.question(`\nPool type [1-${keys.length}]: `)).trim();
      const byNumber = keys[Number(answer) - 1];
      const choice = byNumber ?? (POOLS[answer] ? answer : undefined);
      if (choice) return choice;
      console.log(`  Enter a number from 1 to ${keys.length}, or one of: ${keys.join(', ')}.`);
    }
  } finally {
    rl.close();
  }
}

function names(opts, poolKey) {
  const { name } = opts;
  if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) usage(`name must be PascalCase letters and digits (e.g. MyFee), got ${name}`);
  if (/(Hook|Pool|Factory)$/.test(name)) {
    usage(`leave off "Hook"/"Pool"/"Factory": the script adds them (MyFee gives MyFeeHook and MyFee<Pool>PoolFactory)`);
  }
  const words = name.match(/[A-Z][a-z0-9]*|[a-z0-9]+/g);
  const kebab = words.map((w) => w.toLowerCase()).join('-');
  const family = opts.family ?? kebab;
  if (!/^[a-z0-9][a-z0-9-]*$/.test(family)) usage(`family must be lowercase letters, digits and dashes, got ${family}`);
  for (const lang of opts.langs) if (!LANGS.includes(lang)) usage(`unknown language ${lang} (ts, py, rs)`);
  if (opts.langs.length === 0) usage('--langs needs at least one of ts, py, rs');

  const base = POOLS[poolKey];
  const prefixKebab = base.prefix.match(/[A-Z][a-z0-9]*/g).map((w) => w.toLowerCase()).join('-');
  return {
    Pascal: name,
    camel: name[0].toLowerCase() + name.slice(1),
    snake: words.map((w) => w.toLowerCase()).join('_'),
    UPPER: words.map((w) => w.toUpperCase()).join('_'),
    title: words.join(' '),
    family,
    Factory: `${name}${base.prefix}PoolFactory`,
    factory: `${kebab}-${prefixKebab}-pool-factory`,
  };
}

function filler(n, base) {
  // Pool snippets first: they contain placeholders of their own.
  const pairs = [
    ['__EXTRA_IMPORTS__\n', base.testImports ? `${base.testImports}\n` : ''],
    ['__RANGES__', base.testRanges],
    ['__CREATE__', null], // filled per file (test or adapter)
    ['__VARIANTS__', base.variants],
    ['__POOL_DATA__', base.poolData],
    ['__POOL_TYPE__', base.poolType],
    ['__POOL_PATH__', base.poolPath],
    ['__POOL__', base.pool],
    ['__Factory__', n.Factory],
    ['__factory__', n.factory],
    ['__Pascal__', n.Pascal],
    ['__camel__', n.camel],
    ['__snake__', n.snake],
    ['__UPPER__', n.UPPER],
    ['__Title__', n.title],
    ['__title__', n.title.toLowerCase()],
    ['__family__', n.family],
  ];
  return (text, create) =>
    pairs.reduce((s, [from, to]) => s.split(from).join(to ?? create ?? from), text);
}

/**
 * Keeps the template lines for the chosen registration mode: `// @open {` ... `// @open }` blocks only for open
 * hooks, `// @restricted {` ... `// @restricted }` only for restricted ones. The marker lines themselves go.
 */
function variant(text, restricted) {
  const drop = restricted ? 'open' : 'restricted';
  const out = [];
  let skipping = false;
  for (const line of text.split('\n')) {
    const marker = line.match(/^\s*\/\/\s*@(open|restricted)\s*([{}])\s*$/);
    if (marker) {
      if (marker[1] === drop) skipping = marker[2] === '{';
      continue;
    }
    if (!skipping) out.push(line);
  }
  return out.join('\n');
}

function plan(n, poolKey, langs, restricted) {
  const base = POOLS[poolKey];
  const fill = filler(n, base);
  const t = (f) => variant(read(`${TEMPLATES}/${f}`), restricted);

  // The test's pool-specific constants go right after SWAP_FEE.
  let test = t('HookPool.t.sol.tmpl');
  if (base.testConstants) {
    test = test.replace(
      '    uint256 private constant SWAP_FEE = 1e16; // 1%\n',
      `    uint256 private constant SWAP_FEE = 1e16; // 1%\n${base.testConstants}\n`
    );
  }

  const writes = [
    { to: `contracts/${n.family}/${n.Pascal}Hook.sol`, content: fill(t('Hook.sol.tmpl')) },
    { to: `contracts/${n.family}/${n.Factory}.sol`, content: fill(t(`factories/${poolKey}.sol.tmpl`)) },
    { to: `test/foundry/${n.family}/${n.Pascal}Hook.t.sol`, content: fill(test, fill(base.testCreate)) },
    { to: `maths/check/adapters/${n.factory}.ts`, content: fill(t('adapter.ts.tmpl'), fill(base.adapterCreate)) },
    { to: `docs/${n.factory}/README.md`, content: readme(n, base, restricted) },
  ];
  const edits = [];

  if (langs.includes('ts')) {
    writes.push({ to: `maths/typescript/src/hooks/${n.camel}Hook.ts`, content: fill(t('hook.ts.tmpl')) });
    edits.push({
      file: 'maths/check/runners/ts/pools.ts',
      taken: [`    ${n.UPPER}: (pool) =>`, `/hooks/${n.camel}Hook'`],
      insert: {
        'scaffold:imports': `import { ${n.Pascal}Hook, type HookState${n.Pascal} } from '@bush.fi/maths/hooks/${n.camel}Hook';`,
        'scaffold:hooks': [
          `    ${n.UPPER}: (pool) => {`,
          `        // TODO: fill the hook state from pool.hook.dynamicData (the adapter's hook.dynamicData()).`,
          `        const hookState: HookState${n.Pascal} = { hookType: '${n.Pascal}' };`,
          `        return { hook: new ${n.Pascal}Hook(), hookState };`,
          `    },`,
        ].join('\n'),
      },
    });
  }
  if (langs.includes('py')) {
    writes.push(
      { to: `maths/python/bush_maths/hooks/${n.snake}/__init__.py`, content: '' },
      { to: `maths/python/bush_maths/hooks/${n.snake}/${n.snake}_hook.py`, content: fill(t('hook.py.tmpl')) }
    );
    edits.push({
      file: 'maths/check/runners/python/pools.py',
      taken: [`    "${n.UPPER}":`, `hooks.${n.snake}.`],
      insert: {
        'scaffold:imports': `from bush_maths.hooks.${n.snake}.${n.snake}_hook import ${n.Pascal}Hook, ${n.Pascal}HookState`,
        // TODO in the entry: fill the state from pool.hook["dynamicData"].
        'scaffold:hooks': `    "${n.UPPER}": lambda pool: (${n.Pascal}Hook(), ${n.Pascal}HookState()),  # TODO: state from pool.hook["dynamicData"]`,
      },
    });
  }
  if (langs.includes('rs')) {
    writes.push({ to: `maths/rust/src/hooks/${n.snake}/mod.rs`, content: fill(t('hook_mod.rs.tmpl')) });
    edits.push(
      {
        file: 'maths/rust/src/hooks/mod.rs',
        taken: [`pub mod ${n.snake};`],
        insert: { 'scaffold:modules': `pub mod ${n.snake};` },
      },
      {
        file: 'maths/check/rust/src/main.rs',
        taken: [`"${n.UPPER}" =>`, `::${n.Pascal}Hook;`],
        insert: {
          'scaffold:imports': `use bush_maths::hooks::${n.snake}::${n.Pascal}Hook;`,
          'scaffold:hooks': [
            `        "${n.UPPER}" => Ok(Some(Hook {`,
            `            hook_type: "${n.Pascal}".to_string(),`,
            `            hook: Box::new(${n.Pascal}Hook::new()),`,
            `            // The hook reads its parameters from the adapter's hook.dynamicData() JSON.`,
            `            state: HookState::Custom(bush_maths::hooks::types::CustomHookState {`,
            `                hook_type: "${n.Pascal}".to_string(),`,
            `                data: hook.0["dynamicData"].clone(),`,
            `            }),`,
            `        })),`,
          ].join('\n'),
        },
      }
    );
  }
  return { writes, edits };
}

function readme(n, base, restricted) {
  const deployment = restricted
    ? `Deployment, in this order:

1. deploy \`${n.Pascal}Hook(vault, version)\`;
2. deploy \`${n.Factory}(vault, hook, pauseWindowDuration, factoryVersion, poolVersion)\`;
3. from the hook's deployer, call \`hook.setFactory(factory)\` (once). Until then the hook accepts no pools; after
   it, only pools from that factory.`
    : `Deployment: deploy \`${n.Pascal}Hook(vault, version)\`, then
\`${n.Factory}(vault, hook, pauseWindowDuration, factoryVersion, poolVersion)\`.

Registration is open, like StableSurgeHook: pools from other factories may use the hook too. That's safe as long as
everything the hook stores is per pool. TODO: confirm it is, or re-scaffold with \`--restricted\`.`;
  return `# ${n.title} Hook on ${base.pool}s

TODO: what the hook does and why, in a paragraph an integrator can act on.

## Hook Type

${n.UPPER} (on pool type ${base.poolType})

## Overview

\`${n.Factory}\` deploys standard \`${base.pool}\`s, each registered with the same \`${n.Pascal}Hook\`, which the
factory holds as an immutable. The pool maths is unchanged; the hook adds: TODO (which callbacks it uses, and what
each does).

${deployment}

## Key Files
- Contracts: [\`contracts/${n.family}/\`](../../contracts/${n.family})
- Tests: [\`test/foundry/${n.family}/\`](../../test/foundry/${n.family})
- Maths: the hook in [\`maths/\`](../../maths) (checked against the deployed contracts by \`npm run maths:check -- ${n.factory}\`)
- License: TODO (the SPDX identifier on the contracts)
`;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const poolKey = await choosePool(opts);
  const n = names(opts, poolKey);
  const { writes, edits } = plan(n, poolKey, opts.langs, opts.restricted);

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

  const mode = opts.restricted ? 'restricted to its factory' : 'open registration';
  console.log(`\n${n.Pascal}Hook on ${POOLS[poolKey].pool}s (hook type ${n.UPPER}, ${mode}):\n`);
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

  console.log(`
Every callback is switched off, so it already passes. Check that, then make it yours:

  npm run compile
  forge test --match-path 'test/foundry/${n.family}/*'
  FACTORIES=${n.factory} npm run maths:generate
  npm run maths:check -- ${n.factory}

Then:
  - contracts/${n.family}/${n.Pascal}Hook.sol: switch on the callbacks you need in getHookFlags and implement them
  - test/foundry/${n.family}/: test each callback (the property tests keep checking the pool stays sound)
  - maths/check/adapters/${n.factory}.ts: the hook's parameters in dynamicData(), variants that exercise them
  - the hook maths (${opts.langs.join(', ')}): mirror the flags and port each callback, importing only from the pool kit;
    fill the hook state in each maths/check registry entry
  - docs/${n.factory}/README.md
  Search the new files for "TODO" to find everything still to write.
`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
