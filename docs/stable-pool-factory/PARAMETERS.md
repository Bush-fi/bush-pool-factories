# StablePoolFactory — Pool Creation Parameters

Parameters below are read directly from `contracts/StablePoolFactory.sol::create()` and the
`contracts/StablePool.sol` constructor / lifecycle functions they feed into (particularly
the amplification-factor bounds enforced in `StablePool`'s constructor, which come from
`@bush.fi/v3-solidity-utils/contracts/math/StableMath.sol`).

## `StablePoolFactory.create(...)` parameters

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `name` | `string` | — (required) | — | — | ERC20 name of the pool token. | No on-chain length/format validation in the copied contracts. |
| `symbol` | `string` | — (required) | — | — | ERC20 symbol of the pool token. | No on-chain length/format validation in the copied contracts. |
| `tokens` | `TokenConfig[]` | — (required) | 2 (Vault-level minimum; not enforced in these contracts) | 5 | Token descriptors (address, rate provider, token type, exemption flag) for the pool's tokens. | `StablePoolFactory.create()`: `if (tokens.length > StableMath.MAX_STABLE_TOKENS) revert IVaultErrors.MaxTokens();` — `MAX_STABLE_TOKENS = 5` in `StableMath.sol`. This is stricter than the Vault's general 8-token ceiling, enforced here because `StablePool` itself doesn't know how many tokens it has. |
| `amplificationParameter` | `uint256` | — (required) | `1` | `50000` | The "raw"/human-readable amplification factor `A`. Internally multiplied by `StableMath.AMP_PRECISION` (1000) and stored. Higher = flatter curve / lower slippage near parity; lower = closer to a weighted-pool curve. | `StablePool` constructor: `if (params.amplificationParameter < StableMath.MIN_AMP) revert AmplificationFactorTooLow();` and `if (params.amplificationParameter > StableMath.MAX_AMP) revert AmplificationFactorTooHigh();` (`MIN_AMP = 1`, `MAX_AMP = 50000` in `StableMath.sol`). |
| `roleAccounts` | `PoolRoleAccounts` | — (required) | — | — | Addresses granted permission to change pause, swap-fee, and pool-creator settings (`pauseManager`, `swapFeeManager`, `poolCreator`). Zero addresses delegate to governance. | No explicit validation in the copied contracts; passed through to `_registerPoolWithVault`. |
| `swapFeePercentage` | `uint256` | — (required) | `1e12` (0.0001%) | `10e16` (10%) | Initial static swap fee, 18-decimal FP (`1e18` = 100%). | Bounds exposed by `StablePool.getMinimumSwapFeePercentage()` / `getMaximumSwapFeePercentage()` (`_MIN_SWAP_FEE_PERCENTAGE = 1e12`, `_MAX_SWAP_FEE_PERCENTAGE = 10e16`); enforced by the Vault at registration time via `ISwapFeePercentageBounds`. |
| `poolHooksContract` | `address` | — (required, may be `address(0)`) | — | — | Optional external hooks contract for custom lifecycle behavior. | No validation in `StablePoolFactory`; passed to `_registerPoolWithVault`. |
| `enableDonation` | `bool` | — (required) | — | — | If `true`, enables the donation add-liquidity mechanism (direct balance top-ups without minting BPT). | Sets `liquidityManagement.enableDonation` before registration. |
| `disableUnbalancedLiquidity` | `bool` | — (required) | — | — | If `true`, only proportional add/remove liquidity is permitted (no single-sided or unbalanced operations). | Sets `liquidityManagement.disableUnbalancedLiquidity` before registration. |
| `salt` | `bytes32` | — (required) | — | — | Deployment salt for deterministic pool address (CREATE3 via `BasePoolFactory._create`). | No validation; a reused salt for the same factory/params will revert on redeploy (deterministic address collision). |

## Amplification parameter lifecycle constraints

These are not creation-time parameters, but bound how `amplificationParameter` can be changed
after deployment via `StablePool.startAmplificationParameterUpdate(...)`:

| Constraint | Value | Source |
|---|---|---|
| Minimum update duration | `1 days` | `_MIN_UPDATE_TIME = 1 days`; reverts `AmpUpdateDurationTooShort` if shorter. |
| Maximum daily rate of change | `2x` (double or halve per day) | `_MAX_AMP_UPDATE_DAILY_RATE = 2`; reverts `AmpUpdateRateTooFast` if exceeded. |
| Concurrent updates | Not allowed | Reverts `AmpUpdateAlreadyStarted` if an update is already in progress. |
| End value bounds | `[1, 50000]` | Same `StableMath.MIN_AMP` / `MAX_AMP` bounds as creation, reverting `AmplificationFactorTooLow` / `AmplificationFactorTooHigh`. |

## Other StableMath-derived invariants (not creation parameters, but relevant limits)

| Constant | Value | Purpose |
|---|---|---|
| `MAX_IMBALANCE_RATIO` | `10,000` | Max allowed ratio between the highest and lowest token balances (`maxBalance / minBalance`); enforced in `computeInvariant`, reverts `MaxImbalanceRatioExceeded`. |
| `MIN_INVARIANT_RATIO` | `60%` | Minimum invariant ratio allowed for a non-proportional remove (invariant cannot shrink below 60% of its pre-operation value in one op). |
| `MAX_INVARIANT_RATIO` | `500%` | Maximum invariant ratio allowed for a non-proportional add (invariant cannot grow above 500% of its pre-operation value in one op). |
