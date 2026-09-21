# Adding a pool factory to bush-factories

This is the full walkthrough. Every factory in this repo was built this way, and the template
([`contracts/_template`](./contracts/_template), [`test/foundry/_template`](./test/foundry/_template),
[`maths/check/adapters/_template-pool-factory.ts`](./maths/check/adapters/_template-pool-factory.ts), the
`ConstantSum` pool in each maths package, [`docs/_template-pool-factory`](./docs/_template-pool-factory)) is a
small, complete, working example you can copy.

## The idea in one paragraph

A **factory** is the contract that deploys pools of one type and registers them with the Bush Vault. Integrators
(aggregators, routers, front-ends) need to price those pools off-chain, so every factory in this repo comes with
**exact maths** — code in TypeScript, Python and Rust that returns the same wei the contract would. To make sure
of that, the repo can deploy your factory on a local chain, create a pool through it, ask the real Router for
quotes, and replay those quotes through your maths (`npm run maths:check`). The maths lives directly in
[`maths/`](./maths), the library integrators install, so once everything matches there is nothing left to merge.

## What you will write

```
contracts/<family>/                          the factory, the pool, and anything they need
test/foundry/<family>/                       Foundry tests (and test/hardhat/<family>/ for Hardhat ones)
maths/check/adapters/<name>-pool-factory.ts  ~50 lines: how to create your pool, and which numbers the maths needs
maths/typescript/src/<pool>/                 your pool's maths, in at least one language …
maths/python/src/pools/<pool>/
maths/rust/src/pools/<pool>/
maths/check/runners/ts/pools.ts              … registered by pool type in that language's check registry
maths/check/runners/python/pools.py
maths/rust/src/pools/mod.rs
docs/<name>-pool-factory/PARAMETERS.md       every creation parameter, its range and default
docs/<name>-pool-factory/GAS_CHARACTERISTICS.md
docs/<name>-pool-factory/README.md
```

plus a row in the table in the root README. `<family>` groups pools that share code (`weighted` holds
both WeightedPoolFactory and WeightedPool8020Factory; `lbp` both LBP factories); a new pool type usually gets a
new family. There is a single Hardhat + Foundry project at the root, so there is no per-factory configuration.

## Step 0 — set up

```
npm install
npm run compile      # this repo's contracts + the @bush.fi/v3-* packages (artifacts and typechain types)
```

You need Node ≥ 20, Foundry, Python ≥ 3.10 and a Rust toolchain.

## Step 1 — copy the template

```
cp -r contracts/_template contracts/<family>
cp -r test/foundry/_template test/foundry/<family>
cp maths/check/adapters/_template-pool-factory.ts maths/check/adapters/<name>-pool-factory.ts
cp -r docs/_template-pool-factory docs/<name>-pool-factory
```

Then replace `ConstantSumPool` with your contracts and fix the relative imports. Everything else in the template
is generic.

## Step 2 — the contracts

Two contracts, minimum.

**The pool** implements `IBasePool`. The Vault calls it with balances already scaled to 18 decimals and expects:

| Function | What the Vault wants |
| --- | --- |
| `onSwap(PoolSwapParams)` | For `EXACT_IN`: the amount out. For `EXACT_OUT`: the amount in. |
| `computeInvariant(balances, rounding)` | The pool's invariant, rounded up or down as asked. |
| `computeBalance(balances, tokenIndex, invariantRatio)` | The balance of one token that makes the invariant change by `invariantRatio` (single-token add/remove). |
| `getMinimum/MaximumSwapFeePercentage()` | Fee bounds the Vault enforces when the fee is set. |
| `getMinimum/MaximumInvariantRatio()` | How far an unbalanced add/remove may move the invariant. |

Inherit `BushPoolToken` (the pool *is* its BPT token), `PoolInfo` (standard getters) and `Version`. Every
rounding choice must favour the Vault: amounts the user receives round down, amounts the user pays round up.
Look at `contracts/_template/ConstantSumPool.sol` for the shape, and at `contracts/weighted/WeightedPool.sol` /
`contracts/stable/StablePool.sol` for real ones.

**The factory** extends `BasePoolFactory`. Its `create(...)` function encodes the pool's constructor arguments,
calls `_create(args, salt)` (CREATE2), then `_registerPoolWithVault(...)` with the tokens, swap fee, role
accounts, hook contract and liquidity settings. `ConstantSumPoolFactory.sol` is the minimal version.

**If your pool has a hook** (like `contracts/stable-surge`), the hook contract lives next to the factory, which
passes it on registration. The maths for the hook is part of your maths contribution.

## Step 3 — tests

`test/foundry/<family>/*.t.sol`. Extend `BaseVaultTest` (from `@bush.fi/v3-vault`): it deploys a Vault, Router,
tokens and users. Override `createPoolFactory`, `createPool` and `initPool` for your factory, then test swaps,
adds, removes, and every revert your pool has. See `test/foundry/_template/ConstantSumPool.t.sol`. Deployer and
base-test contracts shared between tests go in `test/foundry/utils/`.

```
forge test --match-path 'test/foundry/<family>/*' -vvv
```

## Step 4 — the math-check adapter

`maths/check/adapters/<name>-pool-factory.ts` default-exports a `FactoryAdapter` (interface in
[`maths/check/src/types.ts`](./maths/check/src/types.ts)). The file name is the factory's name everywhere else:
its test-data files, `FACTORIES=…`, and `docs/<name>-pool-factory/`.

- **`variants`** — a few named parameter sets. One pool and one test-data file is generated per variant. Cover
  what changes a code path in your maths: token decimals (the Vault scales balances), token counts, and every
  pool parameter. Give each a `description` in plain words; it is printed when generating.
- **`createPool(ctx)`** — deploy your factory with `ctx.deploy('<Artifact>', [args])`, create the pool the way a
  user would, and return `{ pool, poolType, poolData }`:
  - `poolType` — a name for your pool type (`'CONSTANT_SUM'`, `'WEIGHTED'`, …). Your maths declares the same one.
  - `poolData()` — the pool-specific numbers the maths needs (a rate, weights, an amplification parameter…),
    **read back from the chain** via the pool's getters, as strings. These end up in the test-data file's
    `pool` block next to the generic state (balances, fees, scaling factors, …) that the tool reads itself.
  - optional: `hook` (contract, type and `dynamicData()`), `initialAmounts`, `queryTimestamp` (e.g. mid-sale for
    an LBP), `querySwap` for pools that only accept swaps from their own router.

The seven existing adapters are short and commented; `stable-pool-factory.ts` shows a parameter (amplification),
`lbpool-factory.ts` shows time-dependence, `stable-surge-pool-factory.ts` shows a hook, `cow-pool-factory.ts` a
custom swap path.

### About the numbers in the variants

Variants are just the inputs a pool is created with. Examples from the existing adapters:

- `decimals: [18, 6]` — the test tokens' decimals. The Vault scales every balance to 18 decimals, so mixing
  decimals exercises that scaling in your maths.
- `amplification: 200` (stable pools) — the "A" parameter, the one knob a StablePool has. It sets how flat the
  price curve is around 1:1: high A (1000+) behaves almost like a fixed 1:1 exchange until the pool gets very
  unbalanced; low A (10) curves more like a weighted pool. Like-kind assets (stablecoins, LSTs) use 100–2000.
  You write the human number; the contract stores it × 1000 (`AMP_PRECISION`), and *that* is what the maths
  receives as `amp`.
- `rate: 2` (fixed-price pools, the template) — the fixed price.
- `progress: 0.4` (LBPs) — how far through the sale to take the snapshot.

## Step 5 — the maths

The same pool class in at least one language, written straight into the maths package (the others can follow in
later PRs; `maths:check` reports each language separately):

| | Pool class goes in | Registered for `maths:check` in |
| --- | --- | --- |
| TypeScript | `maths/typescript/src/<pool>/` | `maths/check/runners/ts/pools.ts` — `pools[poolType] = (pool) => new MyPool(pool)` |
| Python | `maths/python/src/pools/<pool>/` | `maths/check/runners/python/pools.py` — `POOLS[pool_type] = MyPool` |
| Rust | `maths/rust/src/pools/<pool>/` (+ `pub mod` in `pools/mod.rs`) | `maths/check/rust/src/main.rs` — a `match` arm in `make_pool` |

The registry entry builds your pool from the `pool` block of the test-data file, numbers already converted to
`bigint` / `int` / `U256` (in Rust, `PoolJson` gives typed access). Your class implements the maths' `PoolBase` —
the same three functions as the contract (`onSwap`, `computeInvariant`, `computeBalance`) plus the two ratio
bounds (and in TypeScript the max-swap helpers). The `Vault` wraps it with everything that is the same for every
pool: scaling and rates, swap fees, hook calls, add/remove liquidity maths. You do not reimplement any of that.
A pool with a hook also registers the hook under its `type` (`hooks` / `HOOKS` / `make_hook`); see
`STABLE_SURGE` in each registry.

The rules that make it match to the wei:

1. **Integers only.** `bigint` / `int` / `U256`. No floats, no decimals.
2. **Same fixed-point primitives.** `MathSol` / `maths.py` / `common::maths` are ports of Solidity's
   `FixedPoint`; `LogExpMath` is ported too. Use them for every multiply and divide.
3. **Same rounding, same order.** Translate the Solidity call for call. Where the contract uses `mulUp`, use
   `mulUp`. Where it adds 1 wei before a call (Bush's `WeightedPool.onSwap` does), add 1 wei.
4. **Same reverts.** Throw / raise / `Err` where the contract reverts. The check counts "both fail" as a match.
5. **Reuse accepted library ports.** If your contract uses `WeightedMath.sol` or `StableMath.sol`, import the
   existing port of that library and write only your pool class — like `liquidityBootstrapping` does. Port what
   is new.

The template's `ConstantSum` pool (`maths/typescript/src/constantSum/`, `maths/python/src/pools/constant_sum/`,
`maths/rust/src/pools/constant_sum/`) is a full worked example in ~80 lines per language. Once the check passes,
also export the pool from the package (`maths/typescript/src/index.ts`) and add it to the `Vault`'s pool-type map
in each language, so the maths' own suites cover your test data. The test readers are generic: in TypeScript and
Python every field of the `pool` block reaches your pool class as a bigint / int under its JSON name (snake_case
in Python); in Rust, add a `PoolState` variant, a `from_json(pool: &PoolJson, base)` on your state struct and an
arm in `pools::state_from_json` — that one function feeds both `maths:check` and the test suite.

## Step 6 — run the check

```
npm run compile                                       # once, so your artifacts exist
FACTORIES=<name>-pool-factory npm run maths:generate  # local chain → maths/testData/31337-<name>-*.json
npm run maths:check -- <name>-pool-factory            # your maths vs. the deployed pool, per language (LANGS=typescript to limit)
```

You get a table per variant and language — `swaps 12/12  adds 9/9  removes 15/15` — and
`maths/check/out/report.md` listing any operation that differs (expected vs. got). Iterate until every number
matches. Commit the generated test-data files with your PR: reviewers run `maths:check` without a chain.

## Step 7 — docs

In `docs/<name>-pool-factory/`:

- `PARAMETERS.md`: every `create()` parameter — type, default, min, max, meaning, and the check in the contract
  that enforces it.
- `GAS_CHARACTERISTICS.md`: gas for creation, swap, add and remove, from a benchmark test if you have one
  (`test/hardhat/gas/`), otherwise say so and describe the cost drivers.
- `README.md`: what the pool is, when to use it, and the integration example (the maths `Vault`).

And a row in the table at the top of the root `README.md`.

## Step 8 — open the PR

Use the checklist in [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md); the review criteria
are in [`GOVERNANCE.md`](./GOVERNANCE.md).
