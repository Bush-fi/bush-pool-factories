use crate::common::json::PoolJson;
use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde::{Deserialize, Serialize};

/// IRukusLaunchPool.BondingPhase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BondingPhase {
    Bonding,
    Completed,
    Graduated,
}

impl TryFrom<U256> for BondingPhase {
    type Error = String;

    fn try_from(value: U256) -> Result<Self, String> {
        match value.to::<u8>() {
            0 => Ok(BondingPhase::Bonding),
            1 => Ok(BondingPhase::Completed),
            2 => Ok(BondingPhase::Graduated),
            other => Err(format!("unknown bonding phase {other}")),
        }
    }
}

/// `getRukusLaunchPoolDynamicData()` (minus what BasePoolState carries), the graduated width, and the timestamp
/// the state is evaluated at (a completed pool graduates on the first operation in a later block).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RukusLaunchMutable {
    pub phase: BondingPhase,
    /// The launch token's index in the pool's (sorted) tokens.
    pub launch_token_index: usize,
    /// The launch token balance (scaled18) at which the curve completes.
    pub graduation_launch_balance: U256,
    /// Timestamp of the buy that completed the curve (0 while bonding).
    pub bonding_completed_at: U256,
    /// The width the graduated virtual balances are solved for (RukusLaunchPool.GRADUATED_PRICE_RATIO).
    pub graduated_price_ratio: U256,
    /// The bonding curve's until graduation, the graduated ones after (fixed in time).
    pub virtual_balance_a: U256,
    pub virtual_balance_b: U256,
    pub current_timestamp: U256,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RukusLaunchState {
    pub base: BasePoolState,
    pub mutable: RukusLaunchMutable,
}

impl From<RukusLaunchState> for crate::common::types::PoolState {
    fn from(state: RukusLaunchState) -> Self {
        crate::common::types::PoolState::RukusLaunch(state)
    }
}

impl RukusLaunchState {
    /// From the `pool` block of a test-data file (see `crate::common::json`).
    pub fn from_json(pool: &PoolJson, base: BasePoolState) -> Result<Self, String> {
        let virtual_balances = pool.arr("virtualBalances")?;
        if virtual_balances.len() != 2 {
            return Err("`virtualBalances` must have 2 entries".into());
        }
        Ok(RukusLaunchState {
            base,
            mutable: RukusLaunchMutable {
                phase: pool.u("phase")?.try_into()?,
                launch_token_index: pool.u("launchTokenIndex")?.to::<usize>(),
                graduation_launch_balance: pool.u("graduationLaunchBalance")?,
                bonding_completed_at: pool.u("bondingCompletedAt")?,
                graduated_price_ratio: pool.u("graduatedPriceRatio")?,
                virtual_balance_a: virtual_balances[0],
                virtual_balance_b: virtual_balances[1],
                current_timestamp: pool.u("currentTimestamp")?,
            },
        })
    }
}
