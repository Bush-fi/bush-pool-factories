<p align="center">
  <img src="https://raw.githubusercontent.com/Bush-fi/bush-pool-factories/main/.github/BushTransparent.png" alt="Bush" width="120">
</p>

<h1 align="center">@bush.fi/maths</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/@bush.fi/maths"><img src="https://img.shields.io/npm/v/@bush.fi/maths?label=npm&color=2fb02d" alt="npm version"></a>
  <a href="https://www.npmjs.com/package/@bush.fi/maths"><img src="https://img.shields.io/npm/dm/@bush.fi/maths?color=2fb02d" alt="npm downloads"></a>
  <a href="https://github.com/Bush-fi/bush-pool-factories/blob/main/maths/typescript/LICENSE"><img src="https://img.shields.io/npm/l/@bush.fi/maths?color=2fb02d" alt="license"></a>
</p>

Exact fixed-point reference maths for Bush Protocol pools, in TypeScript (`bigint`). Given a pool's on-chain
state, it returns the same amounts the Bush Vault would — to the wei — for swaps, adds and removes. Built for
aggregators, routers and front-ends that need to quote without an RPC round-trip per query.

Every pool type here is verified bit-for-bit against a pool deployed through its factory on a local chain (see
[maths/check](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/check) in the source repo); the same
maths ships for [Python](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/python) and
[Rust](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/rust).

## Install

```
npm install @bush.fi/maths
```

## Usage

```ts
import { Vault, SwapKind } from '@bush.fi/maths';

const vault = new Vault();

// Raw token amounts in, raw token amounts out — exactly what the Router returns.
const amountOut = vault.swap(
  { amountRaw: 1_000_000n, tokenIn, tokenOut, swapKind: SwapKind.GivenIn },
  poolState,
);

const { bptAmountOutRaw, amountsInRaw } = vault.addLiquidity(
  { pool, maxAmountsInRaw, minBptAmountOutRaw: 0n, kind: AddKind.UNBALANCED },
  poolState,
);

const { amountsOutRaw, bptAmountInRaw } = vault.removeLiquidity(
  { pool, minAmountsOutRaw, maxBptAmountInRaw, kind: RemoveKind.PROPORTIONAL },
  poolState,
);
```

The `Vault` reproduces the whole on-chain flow — token scaling, rates, swap fees, hooks — on top of the pool
maths, so `poolState` is the only input. `poolState` is the pool's state as read from the Vault and the pool
contract, with every number as a `bigint`:

| Field | Source |
| --- | --- |
| `poolType`, `poolAddress`, `tokens` | pool registration |
| `scalingFactors`, `tokenRates`, `balancesLiveScaled18` | `Vault.getPoolTokenRates` / `getCurrentLiveBalances` |
| `swapFee`, `aggregateSwapFee`, `totalSupply`, `supportsUnbalancedLiquidity` | `Vault.getStaticSwapFeePercentage`, pool config, BPT supply |
| pool-specific fields (`weights`, `amp`, the LBP schedule, ReClamm virtual balances…) | the pool's `get<Pool>DynamicData()` / `ImmutableData()` getters |
| `currentTimestamp` (time-dependent pools) | the block the quote is for |

The `testData/` files in the source repo show the exact shape for every pool type, straight from a real pool.

## Pool types

| `poolType` | Class | Factory |
| --- | --- | --- |
| `WEIGHTED`, `WEIGHTED_8020`, `COW` | `Weighted` | WeightedPoolFactory, WeightedPool8020Factory, CowPoolFactory |
| `STABLE` (+ `StableSurge` hook) | `Stable`, `StableSurgeHook` | StablePoolFactory, StableSurgePoolFactory |
| `LIQUIDITY_BOOTSTRAPPING` | `LiquidityBootstrapping` | LBPoolFactory |
| `FIXED_PRICE_LBP` | `FixedPriceLBP` | FixedPriceLBPoolFactory |
| `RECLAMM` | `ReClamm` | ReClammPoolFactory |

Time-dependent pools (LBPs, ReClamm) take a `currentTimestamp`: quote for the block the transaction will land
in, not the block the state was read at.

## Notes

- Integers only, everywhere. Amounts are `bigint`; the fixed-point primitives (`MathSol`) are ports of the
  Solidity `FixedPoint` / `LogExpMath` libraries and round the same way the contracts do.
- Operations the pool would reject (over the max swap ratio, LBP sale restrictions, …) throw.
- Derived from [balancer-maths](https://github.com/balancer/balancer-maths) (MIT), trimmed and extended to the
  pool types Bush deploys.

## Contributing

Pool maths is added to this package together with its factory; the walkthrough is in the source repo's
[CONTRIBUTING.md](https://github.com/Bush-fi/bush-pool-factories/blob/main/CONTRIBUTING.md).
