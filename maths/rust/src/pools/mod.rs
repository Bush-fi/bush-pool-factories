//! Pool implementations for the Bush pool types

/// Example pool for contributors (the template factory's ConstantSumPool); not a Bush pool type.
pub mod constant_sum;
pub mod fixed_price_lbp;
pub mod liquidity_bootstrapping;
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
pub use stable::{StableMutable, StablePool, StableState};
pub use weighted::{WeightedPool, WeightedState};
