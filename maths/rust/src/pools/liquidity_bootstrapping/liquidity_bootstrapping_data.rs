use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

/// Liquidity Bootstrapping mutable state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiquidityBootstrappingMutable {
    pub is_swap_enabled: bool,
    pub current_timestamp: U256,
}

/// Liquidity Bootstrapping immutable state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiquidityBootstrappingImmutable {
    pub project_token_index: usize,
    pub is_project_token_swap_in_blocked: bool,
    pub start_weights: Vec<U256>,
    pub end_weights: Vec<U256>,
    pub start_time: U256,
    pub end_time: U256,
    /// See `WeightedState::min_token_balances`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_token_balances: Option<Vec<U256>>,
}

/// Liquidity Bootstrapping pool state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiquidityBootstrappingState {
    pub base: BasePoolState,
    pub mutable: LiquidityBootstrappingMutable,
    pub immutable: LiquidityBootstrappingImmutable,
}

impl From<LiquidityBootstrappingState> for crate::common::types::PoolState {
    fn from(state: LiquidityBootstrappingState) -> Self {
        crate::common::types::PoolState::LiquidityBootstrapping(state)
    }
}

impl LiquidityBootstrappingState {
    /// From the `pool` block of a test-data file (see `crate::common::json`).
    pub fn from_json(pool: &crate::common::json::PoolJson, base: BasePoolState) -> Result<Self, String> {
        Ok(LiquidityBootstrappingState {
            base,
            mutable: LiquidityBootstrappingMutable {
                is_swap_enabled: pool.b("isSwapEnabled")?,
                current_timestamp: pool.u("currentTimestamp")?,
            },
            immutable: LiquidityBootstrappingImmutable {
                project_token_index: pool.n("projectTokenIndex")?,
                is_project_token_swap_in_blocked: pool.b("isProjectTokenSwapInBlocked")?,
                start_weights: pool.arr("startWeights")?,
                end_weights: pool.arr("endWeights")?,
                start_time: pool.u("startTime")?,
                end_time: pool.u("endTime")?,
                min_token_balances: pool.arr("minTokenBalances").ok(),
            },
        })
    }
}
