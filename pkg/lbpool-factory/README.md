# LBPool Factory

A Liquidity Bootstrapping Pool (LBP) factory: a two-token Weighted Pool whose token weights change gradually
between a start and end weight over a configured time window, letting a project distribute (sell) tokens at a
price that starts high and drifts toward a target as the sale progresses.

## Pool Type

WEIGHTED (LBP: dynamic weights over time, 2 tokens)

## Overview

`LBPoolFactory` deploys `LBPool` contracts -- two-token `WeightedPool`s where weights are interpolated linearly
between `projectTokenStartWeight`/`reserveTokenStartWeight` and `projectTokenEndWeight`/`reserveTokenEndWeight`
over `[startTime, endTime]`. Swaps are only enabled during that window; liquidity can only be added beforehand (by
the pool owner, via a trusted router) and removed only afterward. LBPs optionally support a "seedless" mode
(`reserveTokenVirtualBalance > 0`) that lets the sale be initialized with project tokens only, using a virtual
reserve balance offset to set the initial price, and can optionally block project tokens from being sold back into
the pool during the sale (`blockProjectTokenSwapsIn`).

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
