# Parameters

This document describes every pool-creation parameter accepted by `WeightedPool8020Factory.create(...)`, plus the
additional validation performed by the underlying `WeightedPool` constructor. Values and bounds are read directly
from `contracts/WeightedPool8020Factory.sol` and `contracts/WeightedPool.sol`.

`WeightedPool8020Factory` is a specialized factory: it always deploys a 2-token `WeightedPool` with hardcoded
weights of 80% and 20% (`_EIGHTY = 80e16`, `_TWENTY = 20e16` in `WeightedPool8020Factory.sol`). It exposes far fewer
parameters than the general `WeightedPoolFactory` because token count, weights, hooks, and liquidity-management
flags are all fixed by the factory rather than caller-supplied.

## `WeightedPool8020Factory.create(...)` parameters

| Name | Type | Default | Min | Max | Description | Validation |
|---|---|---|---|---|---|---|
| `highWeightTokenConfig` | `TokenConfig` | none | — | — | Descriptor for the token that will receive the 80% weight. Must implement `IERC20Metadata.symbol()` (used to auto-generate the pool name/symbol). | Token address must be nonzero and distinct from the low-weight token (enforced indirectly by sort logic and the Vault's duplicate-token check on registration). |
| `lowWeightTokenConfig` | `TokenConfig` | none | — | — | Descriptor for the token that will receive the 20% weight. Must implement `IERC20Metadata.symbol()`. | Same as above. |
| `roleAccounts` | `PoolRoleAccounts` | zero addresses | — | — | Addresses allowed to pause the pool, manage the swap fee, and receive pool-creator fees. | No factory-level validation. |
| `swapFeePercentage` | `uint256` | none | `0.05e16` (0.05%) | `10e16` (10%) | Initial static swap fee, 18-decimal fixed point. | Bounds defined in `WeightedPool` (`_MIN_SWAP_FEE_PERCENTAGE`, `_MAX_SWAP_FEE_PERCENTAGE`) and enforced by the Vault at registration. |

Note: unlike `WeightedPoolFactory`, this factory does **not** accept `poolHooksContract`, `enableDonation`, or
`disableUnbalancedLiquidity` parameters -- it always registers with `getDefaultPoolHooksContract()` (no hooks) and
`getDefaultLiquidityManagement()` (standard, non-donation liquidity management).

## Fixed / hardcoded values (not caller-configurable)

| Name | Value | Description |
|---|---|---|
| `numTokens` | `2` | Always exactly two tokens. |
| High token weight | `80e16` (80%) | Weight assigned to `highWeightTokenConfig`'s token (`_EIGHTY`). |
| Low token weight | `20e16` (20%) | Weight assigned to `lowWeightTokenConfig`'s token (`_TWENTY`). |
| `name` | `"Bush 80 <symbol> 20 <symbol>"` | Auto-generated from token symbols via `string.concat`. |
| `symbol` | `"B-80<symbol>-20<symbol>"` | Auto-generated from token symbols via `string.concat`. |
| Salt | `keccak256(abi.encode(block.chainid, highWeightToken, lowWeightToken))` | The factory overrides `_computeFinalSalt` so the salt does **not** depend on `msg.sender`, allowing anyone to predict/derive the deterministic pool address for a given token pair (see `getPool()`). |
| Pool hooks | `address(0)` (none) | Always deployed via `getDefaultPoolHooksContract()`. |
| Liquidity management | Default (donation disabled, unbalanced liquidity allowed) | Always `getDefaultLiquidityManagement()`; not caller-configurable. |
| Protocol fee exemption | `false` | Pool is never exempt from protocol fees. |

## Constructor-level validation (inherited from `WeightedPool`)

| Rule | Value | Effect |
|---|---|---|
| Minimum weight | `_MIN_WEIGHT = 1e16` (1%) | Both 80% and 20% comfortably satisfy this; included for completeness since the constructor still checks it. |
| Weights must sum to `ONE` | `1e18` | `80e16 + 20e16 = 100e16 = 1e18` -- always satisfied by construction. |
| Minimum token balances | `max(1e6, 10^(18 - tokenDecimals))` per token | Computed via `MinTokenBalanceLib.computeMinTokenBalances`, same as the general Weighted Pool. |

## Swap-time / math-level bounds (`WeightedMath.sol`, shared with weighted-pool-factory)

| Constant | Value | Applies to | Effect |
|---|---|---|---|
| `_MAX_IN_RATIO` | 30% | Exact-in swaps | `amountIn` cannot exceed 30% of `balanceIn`; reverts `MaxInRatio()`. |
| `_MAX_OUT_RATIO` | 30% | Exact-out swaps | `amountOut` cannot exceed 30% of `balanceOut`; reverts `MaxOutRatio()`. |
| `_MAX_INVARIANT_RATIO` | 300% | Unbalanced add liquidity | The invariant cannot grow by more than 3x in a single non-proportional add. |
| `_MIN_INVARIANT_RATIO` | 70% | Unbalanced remove liquidity | The invariant cannot shrink by more than 30% in a single non-proportional remove. |
