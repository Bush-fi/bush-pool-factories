# Weighted 80/20 Pool Factory

A specialized Bush Weighted Pool factory that deploys two-token pools with weights permanently fixed at 80% and
20%. It reuses the same `WeightedPool` contract and Weighted Math as the general weighted-pool-factory, but greatly
simplifies configuration by removing token-count, weight, and hooks parameters.

## Pool Type

WEIGHTED (fixed 80/20, 2 tokens)

## Overview

`WeightedPool8020Factory` deploys `WeightedPool` contracts constrained to exactly two tokens with hardcoded 80%/20%
weights -- a common configuration for pairing a governance/protocol token (80%) against a reserve asset like a
stablecoin or ETH (20%), popularized by the "80/20 pools" pattern. It auto-derives the pool name and symbol from
the underlying token symbols, uses a deployer-independent salt (so pool addresses are predictable per token pair),
and always deploys with no custom hooks and default (non-donation) liquidity management.

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
