# Gas Characteristics

No gas snapshot suite (`test/gas/*Benchmark.test.ts` + `.hardhat-snapshots`) exists for `LBPoolFactory` or `LBPool`
in this package -- `weighted-pool-factory`'s benchmark covers the base `WeightedPool` contract, not `LBPool`. No numbers are fabricated here; this document describes gas
characteristics qualitatively, based on reading `contracts/lbp/LBPoolFactory.sol`, `contracts/lbp/BaseLBPFactory.sol`,
`contracts/lbp/LBPCommon.sol`, `contracts/lbp/LBPool.sol`, and `contracts/lib/GradualValueChange.sol`, in comparison
to the equivalent operations in `weighted-pool-factory` (which does have real snapshot numbers, in
`weighted-pool-factory/docs/GAS_CHARACTERISTICS.md`).

## Pool creation

`LBPoolFactory.create()` is more expensive than `WeightedPoolFactory.create()` for an equivalent 2-token pool, for
several concrete reasons visible in the source:

- It runs an extra weight-schedule validation pass up front: `LBPValidation.validateCommonParams` (owner/token/time
  checks) and `LBPoolLib.verifyWeightUpdateParameters` (four `MIN_WEIGHT` comparisons plus two sum-to-`ONE` checks)
  are both called explicitly in the factory *and* redundantly again inside the `LBPool` constructor (via
  `LBPCommon`'s constructor and `LBPool`'s own call to `LBPoolLib.verifyWeightUpdateParameters`), so the weight and
  timing validation logic executes twice per deployment.
- `LBPoolFactory` inherits `ReentrancyGuardTransient` (`nonReentrant` on `create()`), adding transient-storage
  guard overhead that `WeightedPoolFactory.create()` does not have.
- The `LBPool` constructor does everything the base `WeightedPool` constructor does (weight/min-balance validation
  loop over its 2 tokens) *plus* additional work: computing `_reserveTokenScalingFactor` (an external `decimals()`
  call), computing `_reserveTokenVirtualBalanceScaled18`, and building/emitting the extra
  `GradualWeightUpdateScheduled` event with two `uint256[]` arrays.
- `_registerLBP` always sets `disableUnbalancedLiquidity = true` and registers the pool itself as its own hooks
  contract, which the Vault must additionally validate (`onRegister` hook callback) -- `WeightedPoolFactory` deploys
  with no hooks in the common case, skipping that callback.

Net effect: expect `LBPoolFactory.create()` gas to be noticeably higher than a comparable 2-token
`WeightedPoolFactory.create()` call (which itself has no directly measured number either -- see that factory's own
gas doc) due to the duplicated validation, the hook registration callback, and the extra constructor state/events.
No specific number is available without benchmarking against the deployed bytecode.

## Swap

Once past the sale-window checks (`_isSwapEnabled`, project-token-direction check), `LBPool.onSwap` delegates to
the same `WeightedMath.computeOutGivenExactIn` / `computeInGivenExactOut` as the base `WeightedPool`, but with two
differences that add gas relative to a static-weight `WeightedPool` swap:

1. Computing the *current* weight requires reading `GradualValueChange.calculateValueChangeProgress` and
   `interpolateValue` on every swap (extra `SLOAD`s for `_startTime`/`_endTime`/weight immutables, plus the
   division/multiplication for the interpolation), instead of reading a single stored weight.
2. For seedless LBPs (`_reserveTokenVirtualBalanceScaled18 > 0`), the reserve balance is mutated (add virtual
   balance, run the swap, restore original, plus an `InsufficientRealReserveBalance` check when reserve is the
   token out) -- extra memory writes and a comparison that a non-seedless pool or a base `WeightedPool` does not do.

Directionally, expect LBP swap gas to be somewhat higher than the "Standard" 2-token `WeightedPool` swap numbers in
`weighted-pool-factory/docs/GAS_CHARACTERISTICS.md` (~151.0k–168.1k for a single exact-in swap with fees), but no
measured LBP-specific number is available.

## Add liquidity

Only proportional add liquidity is permitted (`disableUnbalancedLiquidity = true` is always set), and only the
`owner`, only before `startTime`, and only via the `trustedRouter` (`LBPCommon.onBeforeAddLiquidity`). Every add
call additionally runs the `onlyBeforeSale` timestamp check and a sender/router equality check. No unbalanced-add
or single-token-add gas applies (those paths are blocked/`computeBalance` reverts `UnsupportedOperation`).

## Remove liquidity

Only proportional remove is permitted, and only outside the `[startTime, endTime]` window
(`LBPCommon.onBeforeRemoveLiquidity` reverts `RemovingLiquidityNotAllowed()` during the sale). No single-token
remove gas applies for the same reason as above.

## Summary

No real snapshot numbers are available for `lbpool-factory`. Qualitatively: pool creation gas is higher than
`weighted-pool-factory`'s equivalent (extra validation pass, hook registration, extra constructor state); swap gas
is modestly higher (weight interpolation on every swap, optional virtual-balance bookkeeping for seedless pools);
add/remove liquidity is restricted to the cheaper proportional-only code path (no unbalanced or single-token
variants are reachable at all).
