# Weighted Pool Factory

The general-purpose Bush Weighted Pool: a constant-product AMM generalized to support more than two tokens and
arbitrary (non-50/50) weights, based on Bush Weighted Math (essentially unchanged since Balancer v1/v2). Designed
for uncorrelated assets, it supports up to 8 tokens per pool with weights that must sum to 100%.

## Pool Type

WEIGHTED

## Overview

`WeightedPoolFactory` deploys `WeightedPool` contracts with 2–8 tokens and caller-specified normalized weights
(each ≥ 1%, summing to 100%). Weights are fixed at deployment and cannot be changed afterward. The pool supports
optional donation-based liquidity, optional restriction to proportional-only liquidity operations, custom pool
hooks, and a configurable static swap fee (bounded between 0.05% and 10%).

## Key Files

- Contracts: `contracts/`
- Maths: [`maths/`](../../maths) (exact fixed-point; checked against the deployed pool by `npm run maths:check`)
- Tests: `test/`
- Parameters: `docs/PARAMETERS.md`
- Gas costs: `docs/GAS_CHARACTERISTICS.md`

## Integration (For Aggregators)

Use the [maths](../../maths) package for your language; its `Vault` reproduces the on-chain result
(scaling, rates, fees, hooks) for this pool type:

```typescript
import { Vault, SwapKind } from '@bush.fi/maths';

const amountOut = new Vault().swap({ amountRaw, tokenIn, tokenOut, swapKind: SwapKind.GivenIn }, poolState);
```

`poolState` is the pool's state as read from the Vault (see `maths/testData/*.json` for the exact shape).
The maths is verified bit-for-bit against pools deployed through this factory (`npm run maths:check`).
