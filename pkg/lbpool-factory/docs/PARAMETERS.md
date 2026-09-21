# Parameters

This document describes every pool-creation parameter accepted by `LBPoolFactory.create(...)`, plus the additional
validation performed by `LBPCommon`, `LBPValidation`, `LBPoolLib`, and the `LBPool` / `WeightedPool` constructors.
Values and bounds are read directly from `contracts/lbp/LBPoolFactory.sol`, `contracts/lbp/BaseLBPFactory.sol`,
`contracts/lbp/LBPCommon.sol`, `contracts/lbp/LBPValidation.sol`, `contracts/lib/LBPoolLib.sol`, and
`contracts/lbp/LBPool.sol`.

## `LBPoolFactory.create(...)` top-level arguments

| Name | Type | Default | Min | Max | Description | Validation |
|---|---|---|---|---|---|---|
| `lbpCommonParams` | `LBPCommonParams` struct | none | — | — | Common LBP configuration (name, symbol, owner, tokens, timing, swap direction restriction). See table below. | Validated by `LBPValidation.validateCommonParams` (called both in the factory, for a clean error, and again in the pool constructor). |
| `lbpParams` | `LBPParams` struct | none | — | — | Weight-schedule and seedless-virtual-balance configuration. See table below. | Validated by `LBPoolLib.verifyWeightUpdateParameters` (called in the factory and again in the pool constructor). |
| `swapFeePercentage` | `uint256` | none | `0.05e16` (0.05%) | `10e16` (10%) | Initial static swap fee, 18-decimal fixed point (LBPool inherits `WeightedPool`'s bounds). | Enforced by the Vault at registration via `WeightedPool.getMinimumSwapFeePercentage()` / `getMaximumSwapFeePercentage()`. |
| `salt` | `bytes32` | none | — | — | Deployment salt passed to `CREATE3` deployment. | Combined with `msg.sender`/`chainid` per `BasePoolFactory` defaults (not overridden by this factory). |
| `poolCreator` | `address` | `address(0)` | — | — | Address registered as the pool creator, entitled to a cut of protocol fees. | No factory-level validation. |

## `LBPCommonParams` fields (shared by both LBP factories)

| Name | Type | Description | Validation |
|---|---|---|---|
| `name` | `string` | Pool (BPT) token name. | None beyond being a valid string. |
| `symbol` | `string` | Pool (BPT) token symbol. | None beyond being a valid string. |
| `owner` | `address` | Sole LP and pool owner; the only address allowed to add liquidity before the sale and (implicitly, via `swapFeeManager`) manage the swap fee. | Must be nonzero -- reverts `InvalidOwner()` otherwise. |
| `projectToken` | `IERC20` | The token being sold. | Must be nonzero (`InvalidProjectToken()`) and different from `reserveToken` (`TokensMustBeDifferent()`). |
| `reserveToken` | `IERC20` | The token used to buy the project token (e.g. USDC, WETH). | Must be nonzero (`InvalidReserveToken()`) and different from `projectToken`. |
| `startTime` | `uint256` | Unix timestamp when the sale begins; liquidity can only be added before this time. | Must be `>= block.timestamp + INITIALIZATION_PERIOD` (**1 hour**) and `<= endTime`; otherwise reverts `GradualValueChange.InvalidStartTime(startTime, endTime)`. |
| `endTime` | `uint256` | Unix timestamp when the sale ends; liquidity can only be removed after this time. | Must be `>= startTime` (see above). |
| `blockProjectTokenSwapsIn` | `bool` | If `true`, the pool only supports "buy-only" swaps: the project token can never be `tokenIn`. | No explicit bound; combined with per-swap checks in `LBPool.onSwap` / `LBPCommon`. |

## `LBPParams` fields (`LBPoolFactory`-specific; the fixed-price factory has a different, simpler parameter set)

| Name | Type | Default | Min | Max | Description | Validation |
|---|---|---|---|---|---|---|
| `projectTokenStartWeight` | `uint256` | none | `1e16` (1%) | — | Project token's normalized weight at `startTime`. | `LBPoolLib.verifyWeightUpdateParameters`: must be `>= MIN_WEIGHT (1e16)`, reverts `IWeightedPool.MinWeight()` otherwise. |
| `reserveTokenStartWeight` | `uint256` | none | `1e16` (1%) | — | Reserve token's normalized weight at `startTime`. | Same `MIN_WEIGHT` check; additionally `projectTokenStartWeight + reserveTokenStartWeight` must equal exactly `1e18` (`ONE`), reverts `IWeightedPool.NormalizedWeightInvariant()` otherwise. |
| `projectTokenEndWeight` | `uint256` | none | `1e16` (1%) | — | Project token's normalized weight at `endTime`. | Same `MIN_WEIGHT` check as above. |
| `reserveTokenEndWeight` | `uint256` | none | `1e16` (1%) | — | Reserve token's normalized weight at `endTime`. | Same `MIN_WEIGHT` check; `projectTokenEndWeight + reserveTokenEndWeight` must equal exactly `1e18`. |
| `reserveTokenVirtualBalance` | `uint256` | `0` | `0` | — | If nonzero, marks the LBP as "seedless": this virtual balance (in native reserve-token decimals) is added to the reserve balance for pricing purposes, so the pool can be initialized with 0 real reserve tokens. `0` means a normal (non-seedless) LBP that must be seeded with real reserve tokens. | If nonzero, `LBPool.onBeforeInitialize` requires the actual reserve amount supplied at initialization to be exactly `0` (reverts `SeedlessLBPInitializationWithNonZeroReserve()` otherwise). |

## Fixed / structural constraints (not directly settable, but relevant to integrators)

| Constraint | Value | Source |
|---|---|---|
| Token count | Always exactly 2 (`_TWO_TOKENS`) | `BaseLBPFactory._TWO_TOKENS`, `LBPCommon._TWO_TOKENS` |
| Liquidity management | `disableUnbalancedLiquidity = true` always | `BaseLBPFactory._registerLBP` always sets this; only proportional add/remove is possible. |
| Pool hooks | The pool itself (`LBPool`/`LBPCommon` implements `BaseHooks`) | `_registerLBP` registers `pool` as its own hooks contract. |
| Trusted router | Set once at factory deployment (`trustedRouter` constructor arg) | `BaseLBPFactory` constructor reverts `InvalidTrustedRouter()` if `address(0)` is passed. Required so the pool can reliably identify the true sender for owner-only add-liquidity/initialize checks. |
| Swap availability window | Swaps enabled only when `startTime <= block.timestamp <= endTime` | `LBPCommon._isSwapEnabled`; reverts `SwapsDisabled()` otherwise. |
| Remove-liquidity window | Blocked while `startTime <= block.timestamp <= endTime` | `LBPCommon.onBeforeRemoveLiquidity`; reverts `RemovingLiquidityNotAllowed()` during the sale. |
| Add-liquidity window | Only allowed while `block.timestamp < startTime`, and only by `owner` via the `trustedRouter` | `LBPCommon.onlyBeforeSale` modifier / `onBeforeAddLiquidity`; reverts `AddingLiquidityNotAllowed()` otherwise. |
| Minimum token balances | `max(1e6, 10^(18 - tokenDecimals))` per token | `MinTokenBalanceLib.computeMinTokenBalances`, same mechanism as the base weighted-pool-factory. |

## Swap-time / math-level bounds (`WeightedMath.sol`, applies to swaps using the pool's *current* interpolated weights)

| Constant | Value | Applies to | Effect |
|---|---|---|---|
| `_MAX_IN_RATIO` | 30% | Exact-in swaps | `amountIn` cannot exceed 30% of `balanceIn`; reverts `MaxInRatio()`. |
| `_MAX_OUT_RATIO` | 30% | Exact-out swaps | `amountOut` cannot exceed 30% of `balanceOut`; reverts `MaxOutRatio()`. |

Note: `LBPool.computeBalance` (single-token add/remove) always reverts `UnsupportedOperation()` -- only proportional
liquidity operations are supported (`disableUnbalancedLiquidity` is always `true`), so `MAX_INVARIANT_RATIO` /
`MIN_INVARIANT_RATIO` bounds are not reachable in practice.
