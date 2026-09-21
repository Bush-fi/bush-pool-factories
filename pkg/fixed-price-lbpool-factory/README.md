# Fixed Price LBPool Factory

A Liquidity Bootstrapping Pool variant that sells a project token at a single, constant exchange rate for the
entire sale, instead of a weighted price curve that drifts over time. Simpler math, no weight schedule, always
buy-only and always seedless.

## Pool Type

WEIGHTED family / LBP (fixed constant-sum price, 2 tokens)

## Overview

`FixedPriceLBPoolFactory` deploys `FixedPriceLBPool` contracts -- two-token pools that swap reserve tokens for
project tokens (and only in that direction) at a fixed, immutable rate (`projectTokenRate`: how many reserve
tokens equal one project token). Unlike the standard `LBPool`, there is no gradual weight change: the invariant is
a simple constant-sum formula (`projectBalance * projectTokenRate + reserveBalance`), and the pool is always
"seedless" -- it must be initialized with project tokens only, with zero reserve tokens. Swaps are only enabled
during `[startTime, endTime]`; liquidity can only be added beforehand (by the owner, via a trusted router) and
removed only afterward.

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
