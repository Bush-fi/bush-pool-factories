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
maths, so `poolState` is the only input.

## Building the pool state

`poolState` is the pool's state as read from the chain, with every number as a `bigint`. Every pool exposes its
state in two calls — `get<Pool>ImmutableData()` and `get<Pool>DynamicData()` — and the Vault's `getPoolConfig`
fills in the rest. A Weighted pool, with ethers v6:

```ts
import { Contract, JsonRpcProvider } from 'ethers';
import { Vault, SwapKind, type WeightedState } from '@bush.fi/maths';

const provider = new JsonRpcProvider(RPC_URL);
const vault = new Contract(VAULT_ADDRESS, ['function getPoolConfig(address) view returns (tuple(tuple(bool disableUnbalancedLiquidity, bool enableAddLiquidityCustom, bool enableRemoveLiquidityCustom, bool enableDonation) liquidityManagement, uint256 staticSwapFeePercentage, uint256 aggregateSwapFeePercentage, uint256 aggregateYieldFeePercentage, uint40 tokenDecimalDiffs, uint32 pauseWindowEndTime, bool isPoolRegistered, bool isPoolInitialized, bool isPoolPaused, bool isPoolInRecoveryMode))'], provider);
const pool = new Contract(POOL_ADDRESS, [
  'function getWeightedPoolImmutableData() view returns (tuple(address[] tokens, uint256[] decimalScalingFactors, uint256[] normalizedWeights, uint256[] minTokenBalances))',
  'function getWeightedPoolDynamicData() view returns (tuple(uint256[] balancesLiveScaled18, uint256[] tokenRates, uint256 staticSwapFeePercentage, uint256 totalSupply, bool isPoolInitialized, bool isPoolPaused, bool isPoolInRecoveryMode))',
], provider);

const [immutable, dynamic, config] = await Promise.all([
  pool.getWeightedPoolImmutableData(),
  pool.getWeightedPoolDynamicData(),
  vault.getPoolConfig(POOL_ADDRESS),
]);

const poolState: WeightedState = {
  poolType: 'WEIGHTED',
  poolAddress: POOL_ADDRESS,
  tokens: [...immutable.tokens],
  scalingFactors: [...immutable.decimalScalingFactors],
  weights: [...immutable.normalizedWeights],
  minTokenBalances: [...immutable.minTokenBalances],
  balancesLiveScaled18: [...dynamic.balancesLiveScaled18],
  tokenRates: [...dynamic.tokenRates],
  swapFee: dynamic.staticSwapFeePercentage,
  totalSupply: dynamic.totalSupply,
  aggregateSwapFee: config.aggregateSwapFeePercentage,
  supportsUnbalancedLiquidity: !config.liquidityManagement.disableUnbalancedLiquidity,
};

const amountOut = new Vault().swap(
  { amountRaw: 1_000_000n, tokenIn: poolState.tokens[0], tokenOut: poolState.tokens[1], swapKind: SwapKind.GivenIn },
  poolState,
);
```

(ethers returns `bigint`s already; spread the arrays to get plain `bigint[]`.) The same shape applies to every pool
type — the base fields above come from the same getters, and the pool-specific ones from that pool's data structs:

| `poolType` | State type | Pool-specific fields | From |
| --- | --- | --- | --- |
| `WEIGHTED`, `WEIGHTED_8020`, `COW` | `WeightedState` | `weights`, `minTokenBalances` | `getWeightedPoolImmutableData()` |
| `STABLE` | `StableState` | `amp` | `getAmplificationParameter()[0]` (raw, ×1000) |
| `LIQUIDITY_BOOTSTRAPPING` | `LiquidityBootstrappingState` | weights schedule, `projectTokenIndex`, `isSwapEnabled`, `currentTimestamp` | `getLBPoolImmutableData()` / `getLBPoolDynamicData()` |
| `FIXED_PRICE_LBP` | `FixedPriceLBPState` | `projectTokenRate`, indices, `startTime`/`endTime`, `currentTimestamp` | same |
| `RECLAMM` | `ReClammState` | `lastVirtualBalances`, `dailyPriceShiftBase`, `lastTimestamp`, `centerednessMargin`, the price-ratio update fields, `currentTimestamp` | `getReClammPoolDynamicData()` |

A pool with a hook (`STABLE` + StableSurge) also takes `hookType: 'StableSurge'` and a `hookState`
(`{ hookType: 'StableSurge', amp, surgeThresholdPercentage, maxSurgeFeePercentage }`, the last two from the
hook contract's `getSurgeThresholdPercentage(pool)` / `getMaxSurgeFeePercentage(pool)`), passed as the third argument of `swap` / `addLiquidity` / `removeLiquidity`.

Time-dependent pools (LBPs, ReClamm) take a `currentTimestamp`: use the timestamp of the block the transaction
will land in, not the block the state was read at.

The [`testData/`](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/testData) files in the source
repo show the exact JSON for every pool type, straight from a real pool: `pool` is the state, `swaps` / `adds` /
`removes` are the results the Vault returned for it.

## Pool types

| `poolType` | Class | Factory |
| --- | --- | --- |
| `WEIGHTED`, `WEIGHTED_8020`, `COW` | `Weighted` | WeightedPoolFactory, WeightedPool8020Factory, CowPoolFactory |
| `STABLE` (+ `StableSurge` hook) | `Stable`, `StableSurgeHook` | StablePoolFactory, StableSurgePoolFactory |
| `LIQUIDITY_BOOTSTRAPPING` | `LiquidityBootstrapping` | LBPoolFactory |
| `FIXED_PRICE_LBP` | `FixedPriceLBP` | FixedPriceLBPoolFactory |
| `RECLAMM` | `ReClamm` | ReClammPoolFactory |

## Notes

- Integers only, everywhere. Amounts are `bigint`; the fixed-point primitives (`MathSol`) are ports of the
  Solidity `FixedPoint` / `LogExpMath` libraries and round the same way the contracts do.
- Operations the pool would reject (over the max swap ratio, LBP sale restrictions, …) throw.
- Derived from [balancer-maths](https://github.com/balancer/balancer-maths) (MIT), trimmed and extended to the
  pool types Bush deploys.

## Contributing

Pool maths is added to this package together with its factory; the walkthrough is in the source repo's
[CONTRIBUTING.md](https://github.com/Bush-fi/bush-pool-factories/blob/main/CONTRIBUTING.md).
