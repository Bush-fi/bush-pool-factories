# Stable Surge Pool Factory

A factory for deploying standard `StablePool` instances pre-wired with a
`StableSurgeHook` — a dynamic fee hook that raises the effective swap fee as a trade (or
unbalanced liquidity operation) pushes the pool further past a configurable imbalance
threshold, and blocks unbalanced liquidity operations outright while the pool is already
surging.

## Pool Type

STABLE (with SURGE dynamic-fee hook)

## Overview

`StableSurgePoolFactory` deploys the exact same `StablePool` contract used by
`stable-pool-factory`, but always registers it with a single shared `StableSurgeHook`
instance instead of an arbitrary hooks contract. The hook computes each pool's
"imbalance" as the total absolute deviation of token balances from their median,
normalized by total balance (`StableSurgeMedianMath.calculateImbalance`). If a swap or
unbalanced liquidity operation would push that imbalance up and past a per-pool
threshold, the hook linearly ramps the swap fee from the static fee (at the threshold)
toward a per-pool maximum surge fee (as imbalance approaches 100%), and rejects
unbalanced add/remove liquidity operations outright while surging. This discourages
trades that would otherwise be able to drain a StableSwap pool's flat region cheaply.

## Key Files
- Contracts: `contracts/`
- Maths: `math-implementations/` (exact fixed-point; checked against the deployed pool by `npm run maths:check`)
- Tests: `test/`
- Parameters: `docs/PARAMETERS.md`
- Gas costs: `docs/GAS_CHARACTERISTICS.md`

## Integration (For Aggregators)

Use the [bush-maths](../../bush-maths) package for your language; its `Vault` reproduces the on-chain result
(scaling, rates, fees, hooks) for this pool type:

```typescript
import { Vault, SwapKind } from '@bush.fi/maths';

const amountOut = new Vault().swap({ amountRaw, tokenIn, tokenOut, swapKind: SwapKind.GivenIn }, poolState);
```

`poolState` is the pool's state as read from the Vault (see `bush-maths/testData/*.json` for the exact shape).
The maths is verified bit-for-bit against pools deployed through this factory (`npm run maths:check`).
