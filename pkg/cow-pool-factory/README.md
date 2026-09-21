# CoW Pool Factory

A factory for deploying `CowPool` instances — weighted AMM pools that restrict swaps and
donations to a single trusted router, so that all trading flows through CoW Protocol's
batch-auction settlement instead of the open, permissionless AMM interface.

## Pool Type

WEIGHTED (CoW Protocol-restricted)

## Overview

`CowPoolFactory` deploys `CowPool` contracts — `WeightedPool`s that additionally
implement `IHooks` on themselves, using `onBeforeSwap` to reject any swap not
originating from the pool's `trustedCowRouter`, and `onBeforeAddLiquidity` to restrict
donation-type liquidity additions the same way. This lets CoW Protocol solvers settle
batch auctions directly against the pool's liquidity (via `CowRouter`, which also splits
settlement surplus into an LP donation and a protocol fee) while preventing MEV bots or
arbitrary callers from swapping against the pool through the normal Vault swap path.
Pools are always created with donations enabled and unbalanced liquidity disabled, so
all value transfer into/out of the pool goes through the controlled swap/donation paths.

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

Note: `CowPool` is a `WeightedPool` that only accepts swaps from its trusted `CowRouter`. The pool maths in
`math-implementations/` is therefore the WeightedPool port (pool type `COW`), plus the CoW-specific
protocol-fee split from `CowRouter._donateToPool` (`splitDonationAndProtocolFee`). Settlement accounting
(`computeSenderCredit`) is not pricing maths and is not ported.
