//! Pool kit: everything a new pool or hook needs, in one import.
//!
//! ```ignore
//! use crate::pool_kit::*;
//! ```
//!
//! A pool under `src/pools/<pool>/` uses this module and its own module, nothing else (not even `alloy_primitives`
//! directly: `U256`, `I256` and `uint!` are re-exported here). If a pool needs something that is not here, add it here
//! (in a PR a maintainer reviews) rather than importing it from elsewhere.

// Integer types. Integers only: no floats anywhere in a pool.
pub use alloy_primitives::{uint, I256, U256};

// Fixed-point arithmetic: ports of Solidity's FixedPoint / LogExpMath / OpenZeppelin Math.
pub use crate::common::constants::{FOUR_WAD, MAX_POW_RELATIVE_ERROR, RAY, TWO_WAD, WAD};
pub use crate::common::log_exp_math;
pub use crate::common::maths::{
    complement_fixed, div_down_fixed, div_up, div_up_fixed, mul_div_up_fixed, mul_down_fixed, mul_up_fixed,
    pow_down_fixed, pow_down_fixed_with_version, pow_up_fixed, pow_up_fixed_with_version,
};
pub use crate::common::oz_math::sqrt;

// The trait a pool implements, its error type, and the types the Vault passes to it.
pub use crate::common::errors::PoolError;
pub use crate::common::pool_base::PoolBase;
pub use crate::common::types::{AddLiquidityKind, RemoveLiquidityKind, Rounding, SwapKind, SwapParams};

// Raw <-> scaled18 conversions (token decimals and rates).
pub use crate::common::utils::{
    to_raw_undo_rate_round_down, to_raw_undo_rate_round_up, to_scaled_18_apply_rate_round_down,
    to_scaled_18_apply_rate_round_up,
};

// Ports of the existing pools' maths libraries, to reuse instead of re-porting (CONTRIBUTING.md, Step 5, rule 5).
// Used as modules because they share constant names: `weighted_math::compute_invariant_down(...)`.
pub use crate::pools::liquidity_bootstrapping::liquidity_bootstrapping_math;
pub use crate::pools::reclamm::reclamm_math;
pub use crate::pools::stable::stable_math;
pub use crate::pools::weighted::weighted_math;

// Hooks: the trait, its config and result types, and a no-op hook to copy from.
pub use crate::hooks::types::{
    AfterAddLiquidityResult, AfterRemoveLiquidityResult, AfterSwapParams, AfterSwapResult, BeforeAddLiquidityResult,
    BeforeRemoveLiquidityResult, BeforeSwapResult, DynamicSwapFeeResult, HookState,
};
pub use crate::hooks::{DefaultHook, HookBase, HookConfig};
