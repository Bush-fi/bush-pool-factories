# Parameters

This document describes every pool-creation parameter accepted by `FixedPriceLBPoolFactory.create(...)`, plus the
additional validation performed by `LBPCommon`, `LBPValidation`, and the `FixedPriceLBPool` constructor. Values and
bounds are read directly from `contracts/lbp/FixedPriceLBPoolFactory.sol`, `contracts/lbp/BaseLBPFactory.sol`,
`contracts/lbp/LBPCommon.sol`, `contracts/lbp/LBPValidation.sol`, and `contracts/lbp/FixedPriceLBPool.sol`.

## `FixedPriceLBPoolFactory.create(...)` arguments

| Name | Type | Default | Min | Max | Description | Validation |
|---|---|---|---|---|---|---|
| `lbpCommonParams` | `LBPCommonParams` struct | none | — | — | Common LBP configuration (name, symbol, owner, tokens, timing, swap direction restriction). See table below. | Validated by `LBPValidation.validateCommonParams` (called in the factory, then again in the pool constructor via `LBPCommon`). |
| `projectTokenRate` | `uint256` | none | `1` (must be nonzero) | — (`type(uint256).max` in practice) | The fixed exchange rate: how many reserve tokens equal one project token, 18-decimal fixed point (e.g. `4e18` means 1 project token = 4 reserve tokens). | Must be nonzero; reverts `IFixedPriceLBPool.InvalidProjectTokenRate()` in both the factory's `create()` and the pool's constructor otherwise. |
| `swapFeePercentage` | `uint256` | none | `0` (0%) | `10e16` (10%) | Initial static swap fee, 18-decimal fixed point. | Bounds are `FixedPriceLBPool._MIN_SWAP_FEE_PERCENTAGE = 0` and `_MAX_SWAP_FEE_PERCENTAGE = 10e16`, enforced by the Vault at registration. Unlike the weight-curve `LBPool`/`WeightedPool`, there is **no** minimum fee floor, since this pool's constant-sum math doesn't depend on the fee to stay well-behaved. |
| `salt` | `bytes32` | none | — | — | Deployment salt passed to `CREATE3` deployment. | Combined with `msg.sender`/`chainid` per `BasePoolFactory` defaults. |
| `poolCreator` | `address` | `address(0)` | — | — | Address registered as the pool creator, entitled to a cut of protocol fees. | No factory-level validation. |

## `LBPCommonParams` fields (shared with `lbpool-factory`)

| Name | Type | Description | Validation |
|---|---|---|---|
| `name` | `string` | Pool (BPT) token name. | None beyond being a valid string. |
| `symbol` | `string` | Pool (BPT) token symbol. | None beyond being a valid string. |
| `owner` | `address` | Sole LP and pool owner. | Must be nonzero -- reverts `InvalidOwner()` otherwise. |
| `projectToken` | `IERC20` | The token being sold. | Must be nonzero (`InvalidProjectToken()`) and different from `reserveToken` (`TokensMustBeDifferent()`). |
| `reserveToken` | `IERC20` | The token used to buy the project token. | Must be nonzero (`InvalidReserveToken()`) and different from `projectToken`. |
| `startTime` | `uint256` | Unix timestamp when the sale begins. | Must be `>= block.timestamp + INITIALIZATION_PERIOD` (**1 hour**) and `<= endTime`; otherwise reverts `GradualValueChange.InvalidStartTime(startTime, endTime)`. |
| `endTime` | `uint256` | Unix timestamp when the sale ends. | Must be `>= startTime` (see above). |
| `blockProjectTokenSwapsIn` | `bool` | Must be `true` for a fixed-price LBP -- selling the project token back into the pool is never supported. | `FixedPriceLBPoolFactory.create()` explicitly checks this and reverts `IFixedPriceLBPool.TokenSwapsInUnsupported()` if `false`; the pool constructor repeats the check. |

## Fixed / structural constraints (not directly settable, but relevant to integrators)

| Constraint | Value | Source |
|---|---|---|
| Token count | Always exactly 2 (`_TWO_TOKENS`) | `BaseLBPFactory._TWO_TOKENS`, `LBPCommon._TWO_TOKENS` |
| Pricing model | Constant rate throughout the sale -- **no** weight schedule, `GradualValueChange` is not used | `FixedPriceLBPool.onSwap` always divides/multiplies by the same immutable `_projectTokenRate`. |
| Liquidity management | `disableUnbalancedLiquidity = true` always | `BaseLBPFactory._registerLBP` always sets this; only proportional add/remove is possible. |
| Initialization | Must supply project tokens only (`projectAmount > 0`, `reserveAmount == 0`) | `FixedPriceLBPool.onBeforeInitialize` reverts `InvalidInitializationAmount()` otherwise -- the pool is always effectively "seedless" (no reserve tokens needed to seed liquidity, unlike a non-seedless `LBPool`). |
| Swap direction | Buy-only: project token can never be `tokenIn` | `blockProjectTokenSwapsIn` is required to be `true`; `LBPCommon`/`LBPool` swap-direction checks apply via inherited hooks. |
| Pool hooks | The pool itself (`FixedPriceLBPool`/`LBPCommon` implements `BaseHooks`) | `_registerLBP` registers `pool` as its own hooks contract. |
| Trusted router | Set once at factory deployment (`trustedRouter` constructor arg) | `BaseLBPFactory` constructor reverts `InvalidTrustedRouter()` if `address(0)` is passed. |
| Swap availability window | Swaps enabled only when `startTime <= block.timestamp <= endTime` | `LBPCommon._isSwapEnabled`; reverts `SwapsDisabled()` otherwise. |
| Remove-liquidity window | Blocked while `startTime <= block.timestamp <= endTime` | `LBPCommon.onBeforeRemoveLiquidity`; reverts `RemovingLiquidityNotAllowed()` during the sale. |
| Add-liquidity window | Only allowed while `block.timestamp < startTime`, and only by `owner` via the `trustedRouter` | `LBPCommon.onlyBeforeSale` modifier / `onBeforeAddLiquidity`. |
| Invariant ratio bounds | `getMinimumInvariantRatio() = 0`, `getMaximumInvariantRatio() = type(uint256).max` | `FixedPriceLBPool` returns unconstrained bounds since unbalanced operations are blocked entirely by hooks anyway (`disableUnbalancedLiquidity = true`). |
| Single-token liquidity ops | Unsupported | `FixedPriceLBPool.computeBalance` always reverts `UnsupportedOperation()`. |

Note: `FixedPriceLBPool` does not use `MinTokenBalanceLib`-style per-token minimum balance validation in the same
way as `WeightedPool`/`LBPool` (it does not inherit `WeightedPool`), since its invariant is a simple linear
constant-sum formula rather than a weighted power-product.
