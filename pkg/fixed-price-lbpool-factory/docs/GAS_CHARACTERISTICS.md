# Gas Characteristics

No gas snapshot suite exists for `FixedPriceLBPoolFactory` or `FixedPriceLBPool` in this package
(`weighted-pool-factory`'s benchmark covers the base `WeightedPool` contract). No
numbers are fabricated here; this document describes gas characteristics qualitatively, based on reading
`contracts/lbp/FixedPriceLBPoolFactory.sol`, `contracts/lbp/BaseLBPFactory.sol`, `contracts/lbp/LBPCommon.sol`, and
`contracts/lbp/FixedPriceLBPool.sol`, in comparison to `weighted-pool-factory` and `lbpool-factory`.

## Pool creation

`FixedPriceLBPoolFactory.create()` should be **cheaper to create** than `lbpool-factory`'s `LBPoolFactory.create()`,
and likely comparable to or cheaper than `WeightedPoolFactory.create()`, for concrete reasons visible in the
source:

- Its constructor arguments are simpler: `lbpCommonParams`, a single `projectTokenRate` scalar, `swapFeePercentage`,
  `salt`, `poolCreator` -- no weight-schedule struct (`LBPParams`) to validate.
- `FixedPriceLBPool` does **not** inherit `WeightedPool`, so it skips the per-token weight/min-balance validation
  loop and the 8-slot immutable weight/min-balance storage assignment that both `WeightedPool` and `LBPool` perform
  in their constructors.
- It does not call `MinTokenBalanceLib.computeMinTokenBalances` (no `decimals()` calls per token for that purpose).
- Its only extra validation versus a bare `LBPCommon` deployment is a single nonzero check on `projectTokenRate`
  and a single boolean check on `blockProjectTokenSwapsIn` -- both O(1), versus `LBPoolLib.verifyWeightUpdateParameters`'s
  four comparisons and two sum checks in `lbpool-factory`.
- Like `LBPoolFactory`, it still inherits `ReentrancyGuardTransient` (`nonReentrant` on `create()`) and still
  registers the pool as its own hooks contract (extra `onRegister` callback versus a hookless `WeightedPoolFactory`
  pool).

Net effect: expect `FixedPriceLBPoolFactory.create()` gas to be lower than `LBPoolFactory.create()` (no weight
schedule validation, no `WeightedPool` constructor loop) and in a similar ballpark to `WeightedPoolFactory.create()`
for a 2-token pool, modulo the reentrancy guard and self-hooks registration overhead shared with all LBP factories.
No specific number is available without benchmarking against the deployed bytecode.

## Swap

`FixedPriceLBPool.onSwap` is the cheapest swap path of the four factories in this family: after the sale-window and
swap-direction checks (shared with `LBPool`), it does a single `divDown` (EXACT_IN) or `mulUp` (EXACT_OUT) against
the immutable `_projectTokenRate` -- no weight lookups, no `GradualValueChange` interpolation, no `powUp`/`powDown`
exponentiation (unlike both `WeightedPool` and `LBPool`, which call into `WeightedMath`'s power function on every
swap). Expect gas per swap to be meaningfully lower than the "Standard" `WeightedPool` swap numbers in
`weighted-pool-factory/docs/GAS_CHARACTERISTICS.md` (~151.0k–168.1k for a single exact-in swap with fees), since
this pool eliminates the most expensive part of `WeightedMath` (fixed-point exponentiation) entirely. No measured
number is available.

## Add liquidity

Only proportional add liquidity is permitted (`disableUnbalancedLiquidity = true` always), and only the `owner`,
only before `startTime`, only via the `trustedRouter`. Initialization additionally requires `reserveAmount == 0` and
`projectAmount > 0` (`onBeforeInitialize`), so a fixed-price LBP is always seeded with project tokens only --
cheaper than seeding a two-sided pool, since only one token transfer occurs on initialization.

## Remove liquidity

Only proportional remove is permitted, and only outside the `[startTime, endTime]` window. No single-token remove
gas applies (`computeBalance` reverts `UnsupportedOperation`).

## Summary

No real snapshot numbers are available for `fixed-price-lbpool-factory`. Qualitatively: pool creation gas should be
lower than `lbpool-factory` (no weight-schedule validation, no `WeightedPool` constructor overhead) and comparable
to or lower than `weighted-pool-factory`; swap gas should be the lowest of all four factories in this family, since
the swap math is a single multiply/divide with no fixed-point exponentiation; liquidity operations are restricted
to the cheaper proportional-only, single-sided-initialization code path.
