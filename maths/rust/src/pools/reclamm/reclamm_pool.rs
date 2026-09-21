//! Port of contracts/reclamm/ReClammPool.sol: the pool-level maths on top of reclamm_math.
//!
//! A ReClamm pool is a 2-token constant-product pool with virtual balances that bound the price to a range, and
//! that move over time to re-center the range on the market price. Liquidity can only be added or removed
//! proportionally (the Vault handles that without the pool), so the pool's job is swaps and the invariant.

use crate::common::errors::PoolError;
use crate::common::pool_base::PoolBase;
use crate::common::types::{Rounding, SwapKind, SwapParams};
use crate::pools::reclamm::reclamm_data::{ReClammMutable, ReClammState};
use crate::pools::reclamm::reclamm_math::{
    compute_current_virtual_balances, compute_in_given_out, compute_invariant, compute_out_given_in,
};
use alloy_primitives::{uint, U256};

/// ReClammPool._MIN_SWAP_FEE_PERCENTAGE / _MAX_SWAP_FEE_PERCENTAGE.
pub const MIN_SWAP_FEE_PERCENTAGE: U256 = uint!(1_000_000_000_000_U256); // 0.001%
pub const MAX_SWAP_FEE_PERCENTAGE: U256 = uint!(100_000_000_000_000_000_U256); // 10%

pub struct ReClammPool {
    pub state: ReClammMutable,
}

impl ReClammPool {
    pub fn new(state: ReClammMutable) -> Self {
        Self { state }
    }

    /// ReClammPool._computeCurrentVirtualBalances: (virtual_balance_a, virtual_balance_b, changed) as of
    /// `current_timestamp`.
    pub fn current_virtual_balances(&self, balances_live_scaled18: &[U256]) -> Result<(U256, U256, bool), PoolError> {
        let s = &self.state;
        compute_current_virtual_balances(
            balances_live_scaled18,
            &s.last_virtual_balance_a,
            &s.last_virtual_balance_b,
            &s.daily_price_shift_base,
            &s.last_timestamp,
            &s.centeredness_margin,
            &s.price_ratio_state,
            &s.current_timestamp,
        )
    }
}

impl From<ReClammState> for ReClammPool {
    fn from(state: ReClammState) -> Self {
        Self::new(state.mutable)
    }
}

impl PoolBase for ReClammPool {
    // The invariant ratio bounds are required by the trait but unused: liquidity is proportional only.
    fn get_maximum_invariant_ratio(&self) -> U256 {
        U256::ZERO
    }

    fn get_minimum_invariant_ratio(&self) -> U256 {
        U256::ZERO
    }

    /// ReClammPool.onSwap.
    fn on_swap(&self, swap_params: &SwapParams) -> Result<U256, PoolError> {
        let balances = &swap_params.balances_live_scaled_18;
        let (virtual_a, virtual_b, _) = self.current_virtual_balances(balances)?;
        match swap_params.swap_kind {
            SwapKind::GivenIn => compute_out_given_in(
                balances,
                &virtual_a,
                &virtual_b,
                swap_params.token_in_index,
                swap_params.token_out_index,
                &swap_params.amount_scaled_18,
            ),
            SwapKind::GivenOut => compute_in_given_out(
                balances,
                &virtual_a,
                &virtual_b,
                swap_params.token_in_index,
                swap_params.token_out_index,
                &swap_params.amount_scaled_18,
            ),
        }
    }

    /// ReClammPool.computeInvariant.
    fn compute_invariant(&self, balances_live_scaled18: &[U256], rounding: Rounding) -> Result<U256, PoolError> {
        let (virtual_a, virtual_b, _) = self.current_virtual_balances(balances_live_scaled18)?;
        compute_invariant(balances_live_scaled18, &virtual_a, &virtual_b, rounding)
    }

    /// ReClammPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced adds and removes.
    fn compute_balance(
        &self,
        _balances_live_scaled18: &[U256],
        _token_in_index: usize,
        _invariant_ratio: &U256,
    ) -> Result<U256, PoolError> {
        Err(PoolError::Custom("NotImplemented".into()))
    }
}
