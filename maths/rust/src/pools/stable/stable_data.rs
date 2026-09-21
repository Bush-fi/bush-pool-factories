use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

/// Stable pool mutable state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StableMutable {
    pub amp: U256,
}

/// Stable pool state
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StableState {
    #[serde(flatten)]
    pub base: BasePoolState,
    #[serde(flatten)]
    pub mutable: StableMutable,
}

impl From<StableState> for crate::common::types::PoolState {
    fn from(state: StableState) -> Self {
        crate::common::types::PoolState::Stable(state)
    }
}

impl StableState {
    /// From the `pool` block of a test-data file (see `crate::common::json`). `amp` is the raw, AMP_PRECISION-scaled
    /// amplification parameter, as `getAmplificationParameter()` returns it.
    pub fn from_json(pool: &crate::common::json::PoolJson, base: BasePoolState) -> Result<Self, String> {
        Ok(StableState {
            base,
            mutable: StableMutable { amp: pool.u("amp")? },
        })
    }
}
