# CowPoolFactory — Pool Creation Parameters

`CowPoolFactory` deploys `CowPool` instances, which are `WeightedPool`s (from the
`pool-weighted` package — not copied into this factory directory, see note below) that
add CoW Protocol-specific hooks restricting swaps/donations to a single trusted router.
Parameters below are read directly from `contracts/CowPoolFactory.sol::create()`, the
`CowPoolFactory`/`CowPool` constructors, and `contracts/CowRouter.sol`'s constructor and
setters.

## `CowPoolFactory.create(...)` parameters

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `name` | `string` | — (required) | — | — | ERC20 name of the pool token. | No on-chain validation in the copied contracts. |
| `symbol` | `string` | — (required) | — | — | ERC20 symbol of the pool token. | No on-chain validation. |
| `tokens` | `TokenConfig[]` | — (required) | 2 (Vault-level, not enforced here) | 8 (Vault-level general max; `CowPoolFactory` adds no extra cap) | Token descriptors for the pool. | No explicit length check in `CowPoolFactory.create()` (unlike `StablePoolFactory`, which caps at 5). `MinTokenBalanceLib.computeMinTokenBalances(tokens)` is computed and passed to the underlying `WeightedPool`, which enforces a minimum live balance per token to prevent full-drain manipulation (see `WeightedPool.sol`, not copied into this directory). |
| `normalizedWeights` | `uint256[]` | — (required) | `1e16` (1%) per weight (enforced by the underlying `WeightedPool`, not by `CowPoolFactory`/`CowPool` themselves) | — (implicitly ≤ 100% given the sum constraint) | Per-token weights, 18-decimal FP, must sum to `1e18` (100%). | **Not validated in the copied `CowPoolFactory.sol`/`CowPool.sol`** — validation (`MinWeight`/`NormalizedWeightInvariant` reverts, `_MIN_WEIGHT = 1e16`) lives in `WeightedPool.sol`'s constructor, which `CowPool` inherits but which was intentionally not copied into this factory directory (out of scope per the source task). Documented here for accuracy, but treat it as inherited/reference information, not something enforced by the contracts in `contracts/`. |
| `roleAccounts` | `PoolRoleAccounts` | — (required) | — | — | `pauseManager` / `swapFeeManager` / `poolCreator` addresses. | No explicit validation in `CowPoolFactory`. |
| `swapFeePercentage` | `uint256` | — (required) | `0.05e16` (0.05%, inherited `WeightedPool` bound, not enforced in copied contracts) | `10e16` (10%, inherited `WeightedPool` bound) | Initial static swap fee. | Bounds are `WeightedPool._MIN_SWAP_FEE_PERCENTAGE` / `_MAX_SWAP_FEE_PERCENTAGE`, enforced by the Vault at registration using the pool's `ISwapFeePercentageBounds` implementation (inherited, not in the copied `CowPool.sol`). |
| `salt` | `bytes32` | — (required) | — | — | CREATE3 deployment salt. | No validation; reused salt collides deterministically. |

`CowPoolFactory.create()` unconditionally sets, and does not expose as caller-configurable:
- `liquidityManagement.enableDonation = true` — required so CoW solvers can donate
  settlement surplus back to the pool.
- `liquidityManagement.disableUnbalancedLiquidity = true` — required so LPs cannot
  bypass CoW-specific swap/donation restrictions via unbalanced add/remove.
- The pool's hooks contract is always the pool itself (`pool` passed as
  `poolHooksContract` to `_registerPoolWithVault`), since `CowPool` implements `IHooks`
  directly.

## `CowPoolFactory` constructor / admin parameters

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `trustedCowRouter` (constructor arg, and `setTrustedCowRouter`) | `address` | — (required) | non-zero | — | The only router address `CowPool.onBeforeSwap` will accept swaps from. | `_setTrustedCowRouter` reverts `InvalidTrustedCowRouter` if `address(0)`. `setTrustedCowRouter` is additionally gated by `authenticate` (governance-permissioned). |

Individual pools do not automatically track factory-level router changes; each pool
must call `refreshTrustedCowRouter()` (permissionless) to pull the current value from
`CowPoolFactory.getTrustedCowRouter()`.

## `CowRouter` constructor / admin parameters

| Name | Type | Default | Min | Max | Description | Validation / Source |
|---|---|---|---|---|---|---|
| `protocolFeePercentage` (constructor arg, and `setProtocolFeePercentage`) | `uint256` | — (required) | `0` | `50e16` (50%) | Share of each donation taken as a protocol fee, 18-decimal FP. | `_setProtocolFeePercentage` reverts `ProtocolFeePercentageAboveLimit(newProtocolFeePercentage, _MAX_PROTOCOL_FEE_PERCENTAGE)` if `> _MAX_PROTOCOL_FEE_PERCENTAGE` (`50e16`). `setProtocolFeePercentage` is gated by `authenticate`. |
| `feeSweeper` (constructor arg, and `setFeeSweeper`) | `address` | — (required) | non-zero | — | Address that receives withdrawn protocol fees. | `_setFeeSweeper` reverts `InvalidFeeSweeper` if `address(0)`. `setFeeSweeper` is gated by `authenticate`. |

## Per-call parameters (not pool-creation, but the only other numeric inputs in scope)

| Name | Type | Description | Validation / Source |
|---|---|---|---|
| `swapDeadline` | `uint256` | Timestamp after which `swapExactInAndDonateSurplus` / `swapExactOutAndDonateSurplus` revert. | `swapAndDonateSurplusHook` reverts `SwapDeadline` if `block.timestamp > swapDeadline`. |
| `donationAmounts` / `transferAmountHints` | `uint256[]` | Per-token donation and upfront-transfer amounts for a swap+donate or donate-only call. | Checked via the credit/debt accounting in `_settleSwapAndDonation`, reverting `InsufficientFunds(token, credits, debts)` if the upfront transfer under-covers the operation. The `computeSenderCredit` check is not part of the maths port (it is settlement accounting, not pricing). |
