use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

/// FixedPriceLBP mutable state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FixedPriceLBPMutable {
    pub is_swap_enabled: bool,
    pub current_timestamp: U256,
}

/// FixedPriceLBP immutable state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FixedPriceLBPImmutable {
    pub project_token_index: usize,
    pub reserve_token_index: usize,
    pub project_token_rate: U256,
    pub start_time: U256,
    pub end_time: U256,
}

/// FixedPriceLBP pool state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FixedPriceLBPState {
    pub base: BasePoolState,
    pub mutable: FixedPriceLBPMutable,
    pub immutable: FixedPriceLBPImmutable,
}

impl From<FixedPriceLBPState> for crate::common::types::PoolState {
    fn from(state: FixedPriceLBPState) -> Self {
        crate::common::types::PoolState::FixedPriceLBP(state)
    }
}

impl FixedPriceLBPState {
    /// From the `pool` block of a test-data file (see `crate::common::json`).
    pub fn from_json(pool: &crate::common::json::PoolJson, base: BasePoolState) -> Result<Self, String> {
        Ok(FixedPriceLBPState {
            base,
            mutable: FixedPriceLBPMutable {
                is_swap_enabled: pool.b("isSwapEnabled")?,
                current_timestamp: pool.u("currentTimestamp")?,
            },
            immutable: FixedPriceLBPImmutable {
                project_token_index: pool.n("projectTokenIndex")?,
                reserve_token_index: pool.n("reserveTokenIndex")?,
                project_token_rate: pool.u("projectTokenRate")?,
                start_time: pool.u("startTime")?,
                end_time: pool.u("endTime")?,
            },
        })
    }
}
