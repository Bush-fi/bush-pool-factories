# Parameters

This document describes every pool-creation parameter accepted by `WeightedPoolFactory.create(...)`, plus the
additional validation performed by the `WeightedPool` constructor itself. Values and bounds are read directly from
`contracts/WeightedPoolFactory.sol`, `contracts/WeightedPool.sol`, and `@bush.fi/v3-solidity-utils/contracts/math/WeightedMath.sol`.

## `WeightedPoolFactory.create(...)` parameters

| Name | Type | Default | Min | Max | Description | Validation |
|---|---|---|---|---|---|---|
| `name` | `string` | none | — | — | Pool (BPT) token name. | None on-chain beyond being a valid string. |
| `symbol` | `string` | none | — | — | Pool (BPT) token symbol. | None on-chain beyond being a valid string. |
| `tokens` | `TokenConfig[]` | none | 2 tokens | 8 tokens | Descriptors (address, token type, rate provider, etc.) for the tokens the pool will manage. Must be supplied in ascending address order (the Vault requires sorted tokens for registration). | Vault enforces `_MIN_TOKENS = 2` and `_MAX_TOKENS = 8` (`VaultStorage.sol`) on registration; reverts `MinTokens`/`MaxTokens` otherwise. Vault also rejects duplicate or unsorted tokens. |
| `normalizedWeights` | `uint256[]` | none | `1e16` (1%) per weight | `~0.99e18` per weight (since all weights must sum to `1e18` and every other weight must be ≥ 1%) | Weight assigned to each token, 18-decimal fixed point, in the same order as `tokens`. | `WeightedPool` constructor: each weight must be `>= _MIN_WEIGHT = 1e16` (reverts `MinWeight()`), array length must equal `tokens.length` (reverts via `InputHelpers.ensureInputLengthMatch`), and the weights must sum to exactly `FixedPoint.ONE = 1e18` (reverts `NormalizedWeightInvariant()`). |
| `roleAccounts` | `PoolRoleAccounts` | zero addresses | — | — | Addresses allowed to pause the pool, manage the swap fee, and receive pool-creator fees. | No factory-level validation; zero addresses disable the corresponding permissioned role. |
| `swapFeePercentage` | `uint256` | none | `0.05e16` (0.05%) | `10e16` (10%) | Initial static swap fee, 18-decimal fixed point. | Bounds are defined in `WeightedPool` (`_MIN_SWAP_FEE_PERCENTAGE`, `_MAX_SWAP_FEE_PERCENTAGE`) and enforced by the Vault at registration via `getMinimumSwapFeePercentage()` / `getMaximumSwapFeePercentage()`. |
| `poolHooksContract` | `address` | `address(0)` | — | — | Optional contract implementing pool hooks (e.g. custom fee logic). `address(0)` means no hooks. | Vault validates any non-zero hooks contract implements the expected hook interface at registration. |
| `enableDonation` | `bool` | `false` | — | — | If `true`, the pool accepts the "donation" add-liquidity mechanism (tokens sent in without minting BPT). | None beyond being a bool flag passed into `LiquidityManagement`. |
| `disableUnbalancedLiquidity` | `bool` | `false` | — | — | If `true`, only proportional add/remove liquidity is accepted (must be `true` if `poolHooksContract` sets `enableHookAdjustedAmounts = true`). | Enforced indirectly: the Vault reverts unbalanced add/remove calls against a pool with this flag set. |
| `salt` | `bytes32` | none | — | — | Deployment salt for deterministic `CREATE2`/`CREATE3` pool addresses. | Combined with `msg.sender` and `block.chainid` by `BasePoolFactory` unless overridden. |

## Derived / implicit parameters (computed by the factory, not passed directly)

| Name | Description | Rule |
|---|---|---|
| `minTokenBalances[i]` | Minimum live balance (18-decimal scaled) the Vault will allow for token `i`. | Computed by `MinTokenBalanceLib.computeMinTokenBalances`: `max(ABSOLUTE_MIN_TOKEN_BALANCE = 1e6, 10^(18 - tokenDecimals))`. The `WeightedPool` constructor also requires each value to be `>= ABSOLUTE_MIN_TOKEN_BALANCE` (reverts `InvalidMinTokenBalance()` if a pool were deployed outside the factory with a smaller value). |

## Swap-time / math-level bounds (`WeightedMath.sol`, enforced on every swap and liquidity operation)

| Constant | Value | Applies to | Effect |
|---|---|---|---|
| `_MAX_IN_RATIO` | 30% | Exact-in swaps | `amountIn` cannot exceed 30% of `balanceIn`; reverts `MaxInRatio()`. |
| `_MAX_OUT_RATIO` | 30% | Exact-out swaps | `amountOut` cannot exceed 30% of `balanceOut`; reverts `MaxOutRatio()`. |
| `_MAX_INVARIANT_RATIO` | 300% | Unbalanced add liquidity | The invariant cannot grow by more than 3x in a single non-proportional add. |
| `_MIN_INVARIANT_RATIO` | 70% | Unbalanced remove liquidity | The invariant cannot shrink by more than 30% in a single non-proportional remove. |

## Constructor-only fields (`WeightedPool.NewPoolParams`, built internally by the factory)

These are assembled by `WeightedPoolFactory.create()` from the parameters above and are not directly settable by the
caller: `numTokens` (= `tokens.length`), `version` (the factory's configured pool version string), and
`minTokenBalances` (see above).
