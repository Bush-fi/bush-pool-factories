# StableSurgePoolFactory — Pool Creation Parameters

`StableSurgePoolFactory` deploys a standard `StablePool` (same contract as
`stable-pool-factory`) but always registers it with a fixed `StableSurgeHook` instance
(deployed once and passed into the factory's constructor), rather than an
arbitrary/pluggable hooks contract. Parameters below come from
`contracts/StableSurgePoolFactory.sol::create()`, the `StablePool` constructor
(`contracts/StablePool.sol`, using bounds from `@bush.fi/v3-solidity-utils/contracts/math/StableMath.sol`), and the
surge-hook constructor / setters in `contracts/StableSurgeHook.sol` and
`contracts/SurgeHookCommon.sol`.

## `StableSurgePoolFactory.create(...)` parameters

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `name` | `string` | — (required) | — | — | ERC20 name of the pool token. | No on-chain validation. |
| `symbol` | `string` | — (required) | — | — | ERC20 symbol of the pool token. | No on-chain validation. |
| `tokens` | `TokenConfig[]` | — (required) | 2 (Vault-level, not enforced here) | 5 | Token descriptors for the pool. | `if (tokens.length > StableMath.MAX_STABLE_TOKENS) revert IVaultErrors.MaxTokens();` (`MAX_STABLE_TOKENS = 5`). |
| `amplificationParameter` | `uint256` | — (required) | `1` | `50000` | Initial StableSwap amplification factor, passed straight through to the underlying `StablePool`. | Enforced in the `StablePool` constructor: `AmplificationFactorTooLow` / `AmplificationFactorTooHigh` against `StableMath.MIN_AMP` (1) / `MAX_AMP` (50000). |
| `roleAccounts` | `PoolRoleAccounts` | — (required) | — | — | `pauseManager` / `swapFeeManager` / `poolCreator` addresses. | No explicit validation; `swapFeeManager` (or governance if zero) is the account authorized to later call `setMaxSurgeFeePercentage` / `setSurgeThresholdPercentage`. |
| `swapFeePercentage` | `uint256` | — (required) | `1e12` (0.0001%) | `10e16` (10%) | Initial static swap fee (the surge fee is layered dynamically on top of this). | Same bounds as `StablePool` (`_MIN_SWAP_FEE_PERCENTAGE` / `_MAX_SWAP_FEE_PERCENTAGE`), enforced by the Vault at registration. |
| `enableDonation` | `bool` | — (required) | — | — | If `true`, enables the donation add-liquidity mechanism. | Sets `liquidityManagement.enableDonation`. |
| `salt` | `bytes32` | — (required) | — | — | CREATE3 deployment salt. | No validation; reused salt collides deterministically. |

Note: unlike `StablePoolFactory`, `create()` here takes **no** `poolHooksContract` parameter
(the factory's own `StableSurgeHook` is always used) and **no**
`disableUnbalancedLiquidity` parameter (it is left at the default, i.e. unbalanced
liquidity operations are permitted, subject to the surge hook's `onAfterAddLiquidity` /
`onAfterRemoveLiquidity` checks below).

## Surge hook parameters (`StableSurgeHook` / `SurgeHookCommon`)

These are not part of `create()` — they're set once at `StableSurgeHook`'s own
deployment (shared by every pool the factory creates) and can subsequently be
overridden **per pool**.

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `defaultMaxSurgeFeePercentage` | `uint256` | — (hook constructor arg) | `0` | `1e18` (100%) | Default ceiling for the dynamic surge fee, applied to every pool at registration (`onRegister`). | `SurgeHookCommon` constructor calls `_ensureValidPercentage`, reverting `InvalidPercentage` if `> FixedPoint.ONE` (1e18). |
| `defaultSurgeThresholdPercentage` | `uint256` | — (hook constructor arg) | `0` | `1e18` (100%) | Default imbalance threshold above which the surge fee begins to apply, applied to every pool at registration. | Same `_ensureValidPercentage` check as above. |

## Per-pool surge parameter setters (post-creation)

| Name | Type | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|
| `setMaxSurgeFeePercentage(pool, newMaxSurgeFeePercentage)` | `uint256` | `0` | `1e18` (100%) | Overrides the max surge fee for a specific pool. | `withValidPercentage` modifier (`InvalidPercentage` if `> 1e18`); caller must be `onlySwapFeeManagerOrGovernance(pool)`. |
| `setSurgeThresholdPercentage(pool, newSurgeThresholdPercentage)` | `uint256` | `0` | `1e18` (100%) | Overrides the imbalance threshold for a specific pool. | Same modifier/authorization as above. |

Note: if a pool's `maxSurgeFeePercentage` is ever set below its static swap fee
percentage, the hook effectively disables surging for that pool — `StableSurgeHook`'s
internal `_isSurgingSwap` short-circuits to "not surging" whenever
`maxSurgeFeePercentage < staticSwapFeePercentage`, since the surge fee can never be
lower than the static fee.

## Surge fee formula (for reference; not a creation parameter)

```
surgeFee = staticFee + (maxFee - staticFee) * (imbalance - threshold) / (1 - threshold)
```

applied only when `isSurging` is true (imbalance increased by the operation **and** the
new imbalance exceeds `threshold`). See `math-implementations/` for a full port, and
`contracts/StableSurgeHook.sol` / `contracts/SurgeHookCommon.sol` for the source.

## Inherited StableMath invariants (same as `stable-pool-factory`)

| Constant | Value | Purpose |
|---|---|---|
| `MAX_IMBALANCE_RATIO` | `10,000` | Max allowed ratio between highest/lowest token balances. |
| `MIN_INVARIANT_RATIO` | `60%` | Minimum invariant ratio for a non-proportional remove. |
| `MAX_INVARIANT_RATIO` | `500%` | Maximum invariant ratio for a non-proportional add. |
