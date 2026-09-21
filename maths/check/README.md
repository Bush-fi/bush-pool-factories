# maths/check

Checks that the off-chain maths in [maths/](..) reproduces, bit for bit, what a pool contract deployed through its
factory actually returns.

```
npm run maths:generate     # deploy every factory on a local chain, query the pools, write maths/testData/
npm run maths:check        # run maths/{typescript,python,rust} against that data through the Vault flow
npm run maths:test         # run the three maths packages' own test suites (they read the same data)
npm run maths:all          # all of the above
```

Add `-- <factory>` to `maths:check` (or `FACTORIES=a,b` to either) to limit it to one factory;
`LANGS=typescript,python` to limit the languages. Run `npm run compile` first: the generator deploys from the
Hardhat artifacts.

## How it works

1. **Generate** ([src/run.ts](src/run.ts)). For each adapter in [adapters/](adapters) and each *variant* it
   declares, the generator deploys a Vault, Router and tokens on a local Hardhat chain, asks the adapter to
   create a pool through the real factory, initializes it through the Router, then queries a spread of swaps
   (every token pair, both kinds, several sizes), adds and removes through the Router — the same calls an
   integrator makes. The results and the pool state go into `maths/testData/31337-<factory>-<variant>.json`, in
   the format the maths test suites read. Operations the pool rejects (max swap ratio, LBP sale restrictions, …)
   are simply not recorded.
2. **Check** ([src/check.ts](src/check.ts)). For each language, a small runner looks the pool type (and hook
   type) up in a registry, plugs the maths into the `Vault` — the part that is the same for every pool (token
   scaling, rates, swap fees, hook calls) — and runs every recorded operation. Every result has to match
   exactly. (BPT amounts in add/remove may differ by one unit: the Router's query reads live balances rounded
   down, the Vault rounds them up inside the operation; the maths' own suites allow the same.)

   | Language | Runner | Registry |
   | --- | --- | --- |
   | TypeScript | [runners/ts/runner.ts](runners/ts/runner.ts) | [runners/ts/pools.ts](runners/ts/pools.ts) |
   | Python | [runners/python/runner.py](runners/python/runner.py) | [runners/python/pools.py](runners/python/pools.py) |
   | Rust | [rust/src/lib.rs](rust/src/lib.rs) | `bush_maths::pools::state_from_json` (library); [rust/src/main.rs](rust/src/main.rs) only for pools outside it, e.g. the template |

3. **Test** — the TypeScript, Python and Rust suites read the same files, so `maths:test` shows the packages
   agree with the contracts through their own public API too.

Test data files are committed, so reviewers can run `maths:check` and `maths:test` without a chain.

## Adding a pool type

The full walkthrough is [CONTRIBUTING.md](../../CONTRIBUTING.md). The parts that concern this directory:

### `adapters/<factory>.ts`

Default-exports a `FactoryAdapter` (see [src/types.ts](src/types.ts)):

- `variants`: named parameter sets; one test-data file is generated per variant. Cover the token counts,
  decimals and parameters that change code paths (e.g. `{ decimals: [18, 6], amplification: 200 }`).
- `createPool(ctx)`: deploy the factory (`ctx.deploy('MyPoolFactory', [...])`), create the pool, and return
  `{ pool, poolType, poolData }` where `poolData()` reads back the pool-specific fields the maths need
  (`weights`, `amp`, the LBP schedule…). Read them from the chain, not from the create() arguments. Optional:
  `hook` (contract, type, `dynamicData()`), `initialAmounts`, `queryTimestamp` (e.g. mid-sale), and
  `querySwap` for pools that only accept swaps from their own router (see `cow-pool-factory.ts`).

The existing adapters are the reference; each is ~50 lines. Adapters whose name starts with `_` are examples
(the template): they are skipped unless asked for by name, and their test data goes to `out/testData/` instead
of `maths/testData/`.

### The registries

The maths itself goes into the packages (`maths/typescript/src/<pool>/`, `maths/python/src/pools/<pool>/`,
`maths/rust/src/pools/<pool>/`). Each registry then maps the adapter's `poolType` to a constructor that builds
the pool from the `pool` block of a test-data file (numeric strings already converted to `bigint` / `int` /
`U256`; in Rust, `PoolJson` gives typed access: `pool.u("amp")`, `pool.arr("weights")`,
`pool.base_state(hook_type)`). A pool with a hook also registers the hook under the `type` the adapter reports,
returning the hook maths and the state the Vault hands it on every call — see `STABLE_SURGE`.

## Regenerating

`maths:generate` is deterministic for a given `SEED` (default 1); pool parameters and amounts come from the
seed. Regenerate whenever a factory's contracts, adapter or variants change. `SIZES=0.001,0.01,0.1` sets the
operation sizes as a fraction of the pool balance.
