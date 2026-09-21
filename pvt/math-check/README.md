# math-check

Checks that the off-chain maths for a pool type reproduces, bit for bit, what the pool contract deployed through
its factory actually returns.

```
npm run maths:generate     # deploy every factory on a local chain, query the pools, write bush-maths/testData/
npm run maths:check        # run every pkg/*/math-implementations against that data (TypeScript, Python, Rust)
npm run maths:test         # run bush-maths' own test suites against the same data
npm run maths:all          # all of the above
```

Add `-- <factory>` to `maths:check` (or `FACTORIES=a,b`) to check one factory; `LANGS=typescript,python` to
limit the languages.

## How it works

1. **Generate.** For each factory package with a `math-check/pool.ts` adapter, and each *variant* the adapter
   declares, the generator deploys a Vault, Router and tokens on a local Hardhat chain, asks the adapter to
   create a pool through the real factory, initializes it through the Router, then queries a spread of swaps
   (every token pair, both kinds, several sizes), adds and removes through the Router — the same calls an
   integrator makes. The results and the pool state go into
   `bush-maths/testData/31337-<factory>-<variant>.json`, in the format bush-maths test suites already read.
   Operations the pool rejects (max swap ratio, LBP sale restrictions, …) are simply not recorded.
2. **Check.** For each language, the contributor's implementation is plugged into the bush-maths `Vault` — the
   part of the maths that is the same for every pool (token scaling, rates, swap fees, hook calls) — and run
   against every recorded operation. Every result has to match exactly. (BPT amounts in add/remove may differ by
   one unit: the Router's query reads live balances rounded down, the Vault rounds them up inside the
   operation; bush-maths' own suites allow the same.)
3. **bush-maths.** Its TypeScript, Python and Rust suites read the same files, so `maths:test` shows that the
   accepted maths agrees with the contracts too — and therefore with a contribution that passes `maths:check`.
   For a source-level comparison, `pvt/math-check/diff-bush-maths.sh <factory>` diffs each file against its
   bush-maths counterpart, ignoring imports.

Test data files are committed, so reviewers can run `maths:check` and `maths:test` without a chain.

## Adding a pool type: what a contributor ships

```
pkg/<name>-pool-factory/
├─ math-check/pool.ts                        how to create the pool, and the fields the maths need
└─ math-implementations/
   ├─ typescript/index.ts  (+ your modules)  poolType, createPool(pool) [, hookType, createHook(pool)]
   ├─ python/math_check.py (+ your modules)  POOL_TYPE, create_pool(pool) [, HOOK_TYPE, create_hook(pool)]
   └─ rust/                                  a crate with src/bin/math_check.rs calling math_check_support::run
```

### `math-check/pool.ts`

Default-exports a `FactoryAdapter` (see [src/types.ts](src/types.ts)):

- `variants`: named parameter sets; one test-data file is generated per variant. Cover the token counts,
  decimals and parameters that change code paths (e.g. `{ decimals: [18, 6], amplification: 200 }`).
- `createPool(ctx)`: deploy the factory (`ctx.deploy('MyPoolFactory', [...])`), create the pool, and return
  `{ pool, poolType, poolData }` where `poolData()` reads back the pool-specific fields the maths need
  (`weights`, `amp`, the LBP schedule…). Read them from the chain, not from the create() arguments. Optional:
  `hook` (contract, type, `dynamicData()`), `initialAmounts`, `queryTimestamp` (e.g. mid-sale), and
  `querySwap` for pools that only accept swaps from their own router (see cow-pool-factory).

The seven existing adapters are the reference; each is ~50 lines.

### `math-implementations`

Exact integer fixed-point only (`bigint` / `int` / `U256`): the maths must produce the same wei as the
contract, so it has to use the same fixed-point primitives and rounding directions as the Solidity. bush-maths
provides those (`MathSol` / `maths.py` / `common::maths`, `LogExpMath`, `BasePoolMath`) and the `PoolBase`
interface your pool class implements (`onSwap`, `computeInvariant`, `computeBalance`, the invariant-ratio
limits and max-swap helpers). Reuse an existing library port from bush-maths when the contract does the same
(LBPool reuses WeightedMath on-chain, so `lbpool-factory` reuses bush-maths' WeightedMath port); port what is
new.

- **TypeScript** – `index.ts` exports `poolType`, `createPool(pool)` and, for a hooked pool, `hookType` and
  `createHook(pool)` returning `{ hook, hookState }`. `pool` is the `pool` block of the test-data file with
  numeric strings converted to `bigint`. Import bush-maths as `@bush.fi/maths` / `@bush.fi/maths/<module>`.
- **Python** – `math_check.py` exports `POOL_TYPE`, `create_pool(pool)` and optionally `HOOK_TYPE`,
  `create_hook(pool)` returning `(hook, hook_state)`. `pool` is a `BasePoolState` with the pool-specific
  fields attached as snake_case attributes (`pool.weights`, `pool.min_token_balances`, …) and the raw JSON
  under `pool.raw`. bush-maths is importable as `src.…` (`bush-maths/python` is put on `sys.path`).
- **Rust** – a crate depending on `bush-maths` (path dependency) with an optional `math-check` feature that
  enables a `math_check` binary: `math_check_support::run(make_pool, make_hook)`. `PoolJson` gives typed
  access to the `pool` block (`pool.u("amp")`, `pool.arr("weights")`, `pool.base_state(hook_type)`). Copy the
  `[features]` / `[[bin]]` stanza from any existing crate.

If the pool comes with a hook, the hook is part of the contribution: the check runs the full fee/hook flow.

### Then

```
npm run compile                       # once, builds the factory's artifacts
npm run maths:check -- <factory>      # generate is run by maths:all; or FACTORIES=<factory> npm run maths:generate
```

and commit the generated `bush-maths/testData/31337-<factory>-*.json` files with the PR. When the
contribution is accepted, the pool type is merged into `bush-maths` proper (its `Vault` learns the new
`poolType`, the suites cover the new files) — that is the version integrators consume.

## Regenerating

`maths:generate` is deterministic for a given `SEED` (default 1); pool parameters and amounts come from the
seed. Regenerate whenever a factory's contracts, adapter or variants change. `SIZES=0.001,0.01,0.1` sets the
operation sizes as a fraction of the pool balance.
