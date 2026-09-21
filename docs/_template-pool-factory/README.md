# Template pool factory

A minimal, **complete and working** factory: a two-token constant-sum pool with a fixed price
(`1 token0 = rate token1`). Copy it to start a new factory — every file a factory needs is here, and every one of
them is exercised by the repo's tooling (compile, Forge tests, `maths:generate`, `maths:check` in three
languages).

This is an example, not an approved factory: it is not in `registry.json`, and its generated test data goes to
`maths/check/out/` instead of `maths/testData/`. Anything whose name starts with `_` is treated this way.

Read [CONTRIBUTING.md](../../CONTRIBUTING.md) for the full walkthrough. What each file is for:

| File | What it is | What you change |
| --- | --- | --- |
| `contracts/_template/ConstantSumPool.sol` | The pool: `onSwap`, `computeInvariant`, `computeBalance`, fee and ratio bounds. Heavily commented. | Replace with your pool. Keep the rounding discipline. |
| `contracts/_template/ConstantSumPoolFactory.sol` | The factory: `create()` → `_create` + `_registerPoolWithVault`. | Your `create()` parameters and constructor args. |
| `test/foundry/_template/ConstantSumPool.t.sol` | Forge tests on top of `BaseVaultTest`: factory registration, invariant, a swap through the Vault, rounding. | Test your pool's behaviour and every revert. |
| `maths/check/adapters/_template-pool-factory.ts` | How the maths tooling creates your pool (variants, `createPool`, `poolType`, `poolData`). | Your factory's `create()` call and the numbers your maths needs. |
| `maths/typescript/src/constantSum/` | The maths, on the `PoolBase` interface. | Port your pool. |
| `maths/python/src/pools/constant_sum/` | Same, in Python. | |
| `maths/rust/src/pools/constant_sum/` | Same, in Rust (declared in `pools/mod.rs`). | |
| `CONSTANT_SUM` in `maths/check/runners/ts/pools.ts`, `runners/python/pools.py`, `rust/src/main.rs` | The registry entries that build the pool from a test-data file for `maths:check`. | Register your `poolType`. |
| `docs/_template-pool-factory/PARAMETERS.md` | Creation parameters with ranges and defaults. | Yours. |
| `docs/_template-pool-factory/GAS_CHARACTERISTICS.md` | Gas costs (or, as here, why there are none measured). | Yours. |

## Try it

```
npm run compile                                            # at the repo root
npm run test:template                                      # 4 Forge tests
FACTORIES=_template-pool-factory npm run maths:generate    # 2 variants → maths/check/out/testData/
npm run maths:check -- _template-pool-factory              # TypeScript, Python, Rust vs. the deployed pool
```

## The pool, in short

```
invariant     = balance0 * rate + balance1                     (value in token1)
swap in  →    token0 in: out = in * rate     token1 in: out = in / rate     (rounded down)
swap out →    token0 in: in  = out / rate    token1 in: in  = out * rate    (rounded up)
```

Creation parameters: two tokens, `rate` (18-decimal), swap fee (0–10%), role accounts.
