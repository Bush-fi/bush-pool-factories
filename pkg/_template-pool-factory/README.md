# Template pool factory

A minimal, **complete and working** factory package: a two-token constant-sum pool with a fixed price
(`1 token0 = rate token1`). Copy it to start a new factory — every file a factory needs is here, and every one of
them is exercised by the repo's tooling (compile, Forge tests, `maths:generate`, `maths:check` in three
languages).

This is an example, not an approved factory: it is not in `registry.json`, and its generated test data goes to
`pvt/math-check/out/` instead of `bush-maths/testData/`. Packages whose name starts with `_` are treated this way.

Read [CONTRIBUTING.md](../../CONTRIBUTING.md) for the full walkthrough. What each file here is for:

| File | What it is | What you change |
| --- | --- | --- |
| `contracts/ConstantSumPool.sol` | The pool: `onSwap`, `computeInvariant`, `computeBalance`, fee and ratio bounds. Heavily commented. | Replace with your pool. Keep the rounding discipline. |
| `contracts/ConstantSumPoolFactory.sol` | The factory: `create()` → `_create` + `_registerPoolWithVault`. | Your `create()` parameters and constructor args. |
| `test/foundry/ConstantSumPool.t.sol` | Forge tests on top of `BaseVaultTest`: factory registration, invariant, a swap through the Vault, rounding. | Test your pool's behaviour and every revert. |
| `math-check/pool.ts` | How the maths tooling creates your pool (variants, `createPool`, `poolType`, `poolData`). | Your factory's `create()` call and the numbers your maths needs. |
| `math-implementations/typescript/` | `constantSumPool.ts` (the maths, on bush-maths `PoolBase`) + `index.ts` (entry point). | Port your pool. |
| `math-implementations/python/` | `constant_sum_pool.py` + `math_check.py`. | Same, in Python. |
| `math-implementations/rust/` | A crate: `src/constant_sum_pool.rs`, `src/lib.rs`, `src/bin/math_check.rs`. | Same, in Rust. Rename the crate in `Cargo.toml`. |
| `docs/PARAMETERS.md` | Creation parameters with ranges and defaults. | Yours. |
| `docs/GAS_CHARACTERISTICS.md` | Gas costs (or, as here, why there are none measured). | Yours. |
| `package.json`, `hardhat.config.ts`, `foundry.toml`, `tsconfig.json` | Build config, identical across factories. | Package name only. |

## Try it

```
npm run compile                                            # at the repo root
cd pkg/_template-pool-factory && forge test -vvv           # 4 tests
FACTORIES=_template-pool-factory npm run maths:generate    # 2 variants → pvt/math-check/out/testData/
npm run maths:check -- _template-pool-factory              # TypeScript, Python, Rust vs. the deployed pool
```

## The pool, in short

```
invariant     = balance0 * rate + balance1                     (value in token1)
swap in  →    token0 in: out = in * rate     token1 in: out = in / rate     (rounded down)
swap out →    token0 in: in  = out / rate    token1 in: in  = out * rate    (rounded up)
```

Creation parameters: two tokens, `rate` (18-decimal), swap fee (0–10%), role accounts.
