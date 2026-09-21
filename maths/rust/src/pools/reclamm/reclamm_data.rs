use crate::common::json::PoolJson;
use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

/// ReClammMath.PriceRatioState (fourth roots are 18-decimal fixed point, times are unix seconds).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PriceRatioState {
    pub start_fourth_root_price_ratio: U256,
    pub end_fourth_root_price_ratio: U256,
    pub price_ratio_update_start_time: U256,
    pub price_ratio_update_end_time: U256,
}

/// ReClammPoolDynamicData, minus the fields BasePoolState already carries, plus the timestamp the state is
/// evaluated at (the virtual balances are time-dependent).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReClammMutable {
    pub last_virtual_balance_a: U256,
    pub last_virtual_balance_b: U256,
    /// 1 - tau: the per-second decay applied to the overvalued virtual balance while out of range.
    pub daily_price_shift_base: U256,
    pub last_timestamp: U256,
    /// The pool is in its target range while centeredness >= this margin.
    pub centeredness_margin: U256,
    pub price_ratio_state: PriceRatioState,
    pub current_timestamp: U256,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReClammState {
    pub base: BasePoolState,
    pub mutable: ReClammMutable,
}

impl From<ReClammState> for crate::common::types::PoolState {
    fn from(state: ReClammState) -> Self {
        crate::common::types::PoolState::ReClamm(state)
    }
}

impl ReClammState {
    /// From the `pool` block of a test-data file (see `crate::common::json`).
    pub fn from_json(pool: &PoolJson, base: BasePoolState) -> Result<Self, String> {
        let last_virtual_balances = pool.arr("lastVirtualBalances")?;
        if last_virtual_balances.len() != 2 {
            return Err("`lastVirtualBalances` must have 2 entries".into());
        }
        Ok(ReClammState {
            base,
            mutable: ReClammMutable {
                last_virtual_balance_a: last_virtual_balances[0],
                last_virtual_balance_b: last_virtual_balances[1],
                daily_price_shift_base: pool.u("dailyPriceShiftBase")?,
                last_timestamp: pool.u("lastTimestamp")?,
                centeredness_margin: pool.u("centerednessMargin")?,
                price_ratio_state: PriceRatioState {
                    start_fourth_root_price_ratio: pool.u("startFourthRootPriceRatio")?,
                    end_fourth_root_price_ratio: pool.u("endFourthRootPriceRatio")?,
                    price_ratio_update_start_time: pool.u("priceRatioUpdateStartTime")?,
                    price_ratio_update_end_time: pool.u("priceRatioUpdateEndTime")?,
                },
                current_timestamp: pool.u("currentTimestamp")?,
            },
        })
    }
}
