# Adding a pool factory to bush-factories

This is the full walkthrough. Every factory in `pkg/` was built this way, and
[`pkg/_template-pool-factory`](./pkg/_template-pool-factory) is a small, complete, working example you can copy.

## The idea in one paragraph

A **factory** is the contract that deploys pools of one type and registers them with the Bush Vault. Integrators
(aggregators, routers, front-ends) need to price those pools off-chain, so every factory in this repo comes with
**exact maths** — code in TypeScript, Python and Rust that returns the same wei the contract would. To make sure
of that, the repo can deploy your factory on a local chain, create a pool through it, ask the real Router for
quotes, and replay those quotes through your maths (`npm run maths:check`). When everything matches, the maths
is merged into [`bush-maths`](./bush-maths), the library integrators install.

## What you will write

```
pkg/<name>-pool-factory/
├─ contracts/                 the factory, the pool, and anything they need
├─ test/                      Foundry (and/or Hardhat) tests
├─ math-check/pool.ts         ~50 lines: how to create your pool, and which numbers the maths needs
├─ math-implementations/      your pool's maths in TypeScript, Python and Rust
├─ docs/PARAMETERS.md         every creation parameter, its range and default
├─ docs/GAS_CHARACTERISTICS.md
├─ README.md
├─ package.json, hardhat.config.ts, foundry.toml, tsconfig.json   (copy from the template)
```

plus one entry in [`registry.json`](./registry.json).

## Step 0 — set up

```
npm install          # all workspaces
npm run compile      # builds every package, including pvt/deps (the shared @bush.fi/v3-* artifacts)
```

You need Node ≥ 20, Foundry, Python ≥ 3.10 and a Rust toolchain.

## Step 1 — copy the template

```
cp -r pkg/_template-pool-factory pkg/<name>-pool-factory
```

Then, in the copy: rename the package in `package.json` (`@bush.fi/factory-<name>`) and in `hardhat.config.ts`
(`overrides('@bush.fi/factory-<name>')`), and replace `ConstantSumPool` with your contracts. Everything else in the
template is generic.

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
Look at `ConstantSumPool.sol` in the template for the shape, and at `WeightedPool.sol` / `StablePool.sol` for
real ones.

**The factory** extends `BasePoolFactory`. Its `create(...)` function encodes the pool's constructor arguments,
calls `_create(args, salt)` (CREATE2), then `_registerPoolWithVault(...)` with the tokens, swap fee, role
accounts, hook contract and liquidity settings. `ConstantSumPoolFactory.sol` is the minimal version.

**If your pool has a hook** (like `stable-surge-pool-factory`), the hook contract is part of the package and the
factory passes it on registration. The maths for the hook is part of your maths contribution.

## Step 3 — tests

`test/foundry/*.t.sol`. Extend `BaseVaultTest` (from `@bush.fi/v3-vault`): it deploys a Vault, Router, tokens
and users. Override `createPoolFactory`, `createPool` and `initPool` for your factory, then test swaps, adds,
removes, and every revert your pool has. See `test/foundry/ConstantSumPool.t.sol` in the template.

```
cd pkg/<name>-pool-factory && forge test -vvv
```

## Step 4 — the math-check adapter

`math-check/pool.ts` default-exports a `FactoryAdapter` (interface in
[`pvt/math-check/src/types.ts`](./pvt/math-check/src/types.ts)):

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

The seven existing adapters are short and commented; `stable-pool-factory` shows a parameter (amplification),
`lbpool-factory` shows time-dependence, `stable-surge-pool-factory` shows a hook, `cow-pool-factory` a custom
swap path.

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

Three implementations of the same pool class, one per language, each on top of bush-maths:

| | File | Exports |
| --- | --- | --- |
| TypeScript | `math-implementations/typescript/index.ts` | `poolType`, `createPool(pool)` [, `hookType`, `createHook(pool)`] |
| Python | `math-implementations/python/math_check.py` | `POOL_TYPE`, `create_pool(pool)` [, `HOOK_TYPE`, `create_hook(pool)`] |
| Rust | `math-implementations/rust/` (a crate) | `src/bin/math_check.rs` calling `math_check_support::run(make_pool, make_hook)` |

`pool` is the `pool` block of the test-data file, numbers already converted to `bigint` / `int` / `U256`. Your
class implements bush-maths' `PoolBase` — the same three functions as the contract (`onSwap`,
`computeInvariant`, `computeBalance`) plus the two ratio bounds (and in TypeScript the max-swap helpers). The
bush-maths `Vault` wraps it with everything that is the same for every pool: scaling and rates, swap fees, hook
calls, add/remove liquidity maths. You do not reimplement any of that.

The rules that make it match to the wei:

1. **Integers only.** `bigint` / `int` / `U256`. No floats, no decimals.
2. **Same fixed-point primitives.** `MathSol` / `maths.py` / `common::maths` are ports of Solidity's
   `FixedPoint`; `LogExpMath` is ported too. Use them for every multiply and divide.
3. **Same rounding, same order.** Translate the Solidity call for call. Where the contract uses `mulUp`, use
   `mulUp`. Where it adds 1 wei before a call (Bush's `WeightedPool.onSwap` does), add 1 wei.
4. **Same reverts.** Throw / raise / `Err` where the contract reverts. The check counts "both fail" as a match.
5. **Reuse accepted library ports.** If your contract uses `WeightedMath.sol` or `StableMath.sol`, import the
   bush-maths port of that library and write only your pool class — like `lbpool-factory` does. Port what is new.

The template's `constantSumPool.ts` / `constant_sum_pool.py` / `constant_sum_pool.rs` are a full worked example
in ~80 lines each.

## Step 6 — run the check

```
npm run compile                                       # once, so your artifacts exist
FACTORIES=<name>-pool-factory npm run maths:generate  # local chain → bush-maths/testData/31337-<name>-*.json
npm run maths:check -- <name>-pool-factory            # your maths vs. the deployed pool, all three languages
```

You get a table per variant and language — `swaps 12/12  adds 9/9  removes 15/15` — and
`pvt/math-check/out/report.md` listing any operation that differs (expected vs. got). Iterate until every
number matches. Commit the generated test-data files with your PR: reviewers run `maths:check` without a chain.

`pvt/math-check/diff-bush-maths.sh <name>-pool-factory` shows how your files differ from their bush-maths
counterparts, if you started from one.

## Step 7 — docs and registry

- `docs/PARAMETERS.md`: every `create()` parameter — type, default, min, max, meaning, and the check in the
  contract that enforces it.
- `docs/GAS_CHARACTERISTICS.md`: gas for creation, swap, add and remove, from a benchmark test if you have one,
  otherwise say so and describe the cost drivers.
- `README.md`: what the pool is, when to use it, and the integration example (bush-maths `Vault`).
- `registry.json`: add an entry with `address` left as `0x0…0`; it is filled in on deployment.

## Step 8 — open the PR

Use the checklist in [`.github/PULL_REQUEST_TEMPLATE.md`](./.github/PULL_REQUEST_TEMPLATE.md) and pick a review
tier from [`GOVERNANCE.md`](./GOVERNANCE.md). When the factory is accepted, maintainers merge the pool type into
`bush-maths` (its `Vault` learns the `poolType`, the suites cover your test-data files), which is what
integrators install.
