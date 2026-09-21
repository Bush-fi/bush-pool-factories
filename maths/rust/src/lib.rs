//! Exact fixed-point reference maths for Bush Protocol pools.
//!
//! Ported from balancer-maths (MIT). Covers swaps, add/remove liquidity and pool-specific maths for the pool types
//! deployed by the factories in this repository: Weighted (incl. 80/20 and CoW), Stable (incl. StableSurge hook),
//! LBP and fixed-price LBP.

pub mod common;
pub mod cow;
pub mod hooks;
pub mod pools;
pub mod vault;

// Re-export commonly used types for convenience
pub use common::errors::PoolError;
pub use common::pool_base::PoolBase;
pub use common::types::{AddLiquidityKind, PoolState, RemoveLiquidityKind, SwapKind};

// Re-export hook types and traits
pub use hooks::types::HookState;
pub use hooks::{DefaultHook, HookBase};

// Re-export pool implementations
pub use pools::weighted::{WeightedPool, WeightedState};

pub use vault::Vault;
