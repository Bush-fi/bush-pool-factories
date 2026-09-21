//! Pool implementations for the Bush pool types

/// Example pool for contributors (the template factory's ConstantSumPool); not a Bush pool type.
pub mod constant_sum;
pub mod fixed_price_lbp;
pub mod liquidity_bootstrapping;
pub mod reclamm;
pub mod stable;
pub mod weighted;

// Re-export pool traits and types
pub use fixed_price_lbp::{
    FixedPriceLBPImmutable, FixedPriceLBPMutable, FixedPriceLBPPool, FixedPriceLBPState,
};
pub use liquidity_bootstrapping::{
    LiquidityBootstrappingImmutable, LiquidityBootstrappingMutable, LiquidityBootstrappingPool,
    LiquidityBootstrappingState,
};
pub use reclamm::{ReClammMutable, ReClammPool, ReClammState};
pub use stable::{StableMutable, StablePool, StableState};
pub use weighted::{WeightedPool, WeightedState};

use crate::common::json::PoolJson;
use crate::common::types::PoolState;

/// The `pool` block of a test-data file → the state of the pool type it names. This is the one place that maps a
/// `poolType` string to a state type: a new pool adds a `PoolState` variant, a `from_json` on its state, and an arm
/// here. Both `maths/check` and this crate's test suite build their pools through it.
pub fn state_from_json(pool: &PoolJson, hook_type: Option<String>) -> Result<PoolState, String> {
    let base = pool.base_state(hook_type)?;
    Ok(match base.pool_type.as_str() {
        // WeightedPool8020Factory and CowPoolFactory deploy WeightedPool; the CoW-specific arithmetic lives in
        // CowRouter, not the pool.
        "WEIGHTED" | "WEIGHTED_8020" | "COW" => PoolState::Weighted(WeightedState::from_json(pool, base)?),
        "STABLE" => PoolState::Stable(StableState::from_json(pool, base)?),
        "LIQUIDITY_BOOTSTRAPPING" => {
            PoolState::LiquidityBootstrapping(LiquidityBootstrappingState::from_json(pool, base)?)
        }
        "FIXED_PRICE_LBP" => PoolState::FixedPriceLBP(FixedPriceLBPState::from_json(pool, base)?),
        "RECLAMM" => PoolState::ReClamm(ReClammState::from_json(pool, base)?),
        other => return Err(format!("Unsupported pool type: {other}")),
    })
}
