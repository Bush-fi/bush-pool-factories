# Stable Pool Factory

A factory for deploying `StablePool` instances — AMM pools using a StableSwap-style
invariant (based on Curve's StableSwap) that is tuned for assets expected to trade near
parity or at a known exchange rate (e.g. stablecoins, or liquid-staking-token / underlying
pairs via a rate provider). The invariant's "flatness," controlled by the amplification
parameter, allows large swaps between correlated assets with very low slippage, while
still degrading gracefully (toward constant-product behavior) if the pool becomes
significantly imbalanced.

## Pool Type

STABLE

## Overview

`StablePoolFactory` deploys `StablePool` contracts (up to 5 tokens, a Vault-enforced
sub-limit of the general 8-token maximum) parameterized by an initial amplification factor,
swap fee, role accounts, hooks contract, and liquidity-management flags. The pool's core
math — `computeInvariant`, `computeBalance`, and the exact-in/exact-out swap formulas — lives
in `StableMath.sol`, a Newton-Raphson iterative solver with no closed-form solution. The
amplification parameter can be ramped up or down post-deployment (bounded to at most 2x per
day, over a minimum one-day window) to adjust the pool's risk/slippage profile over time.

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
