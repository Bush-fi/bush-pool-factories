//! Exact fixed-point port of Bush's WeightedPool.sol on top of the WeightedMath port in weighted_math.rs.
//! Implements the bush-maths `PoolBase` trait so the bush-maths Vault flow can run it: see pvt/math-check/README.md.
//!
//! Differences from a plain WeightedMath wrapper that matter for bit-exactness with the deployed contract:
//!   - on_swap rounds the token-in balance up by 1 wei before calling the maths;
//!   - every operation enforces the per-token minimum balance (MinTokenBalanceLib).

//! Weighted pool implementation

use bush_maths::common::errors::PoolError;
use bush_maths::common::pool_base::PoolBase;
use bush_maths::common::types::{Rounding, SwapParams};
use bush_maths::pools::weighted::weighted_data::WeightedState;
use crate::weighted_math::{MAX_INVARIANT_RATIO, MIN_INVARIANT_RATIO, *};
use alloy_primitives::U256;

/// MinTokenBalanceLib.ABSOLUTE_MIN_TOKEN_BALANCE
pub const ABSOLUTE_MIN_TOKEN_BALANCE: u64 = 1_000_000;

/// MinTokenBalanceLib.computeMinTokenBalances: max(1e6, 10^(18 - decimals)) per token.
pub fn compute_min_token_balances(scaling_factors: &[U256]) -> Vec<U256> {
    scaling_factors
        .iter()
        .map(|sf| std::cmp::max(U256::from(ABSOLUTE_MIN_TOKEN_BALANCE), *sf))
        .collect()
}

/// Weighted pool implementation
pub struct WeightedPool {
    /// Normalized weights (scaled 18)
    normalized_weights: Vec<U256>,
    /// Per-token minimum live balance (scaled 18), see `compute_min_token_balances`
    min_token_balances: Vec<U256>,
}

impl WeightedPool {
    /// Create a new weighted pool with the absolute minimum token balance for every token
    pub fn new(weights: Vec<U256>) -> Result<Self, PoolError> {
        if weights.is_empty() {
            return Err(PoolError::InvalidSwapParameters);
        }
        let min_token_balances = vec![U256::from(ABSOLUTE_MIN_TOKEN_BALANCE); weights.len()];
        Ok(Self {
            normalized_weights: weights,
            min_token_balances,
        })
    }

    /// Create a new weighted pool with explicit per-token minimum balances
    pub fn with_min_token_balances(weights: Vec<U256>, min_token_balances: Vec<U256>) -> Self {
        Self {
            normalized_weights: weights,
            min_token_balances,
        }
    }

    /// WeightedPool._ensureMinimumBalance
    fn ensure_minimum_balance(
        &self,
        token_index: usize,
        ending_balance_scaled_18: U256,
    ) -> Result<(), PoolError> {
        let minimum = self
            .min_token_balances
            .get(token_index)
            .copied()
            .unwrap_or(U256::ZERO);
        if ending_balance_scaled_18 < minimum {
            return Err(PoolError::Custom("TokenBalanceBelowMin".to_string()));
        }
        Ok(())
    }

    /// WeightedPool._ensureMinTokenBalances
    fn ensure_min_token_balances(&self, balances_live_scaled_18: &[U256]) -> Result<(), PoolError> {
        for (i, balance) in balances_live_scaled_18.iter().enumerate() {
            self.ensure_minimum_balance(i, *balance)?;
        }
        Ok(())
    }

    /// Get the normalized weights
    pub fn normalized_weights(&self) -> &[U256] {
        &self.normalized_weights
    }
}

impl PoolBase for WeightedPool {
    fn on_swap(&self, swap_params: &SwapParams) -> Result<U256, PoolError> {
        let token_in_index = swap_params.token_in_index;
        let token_out_index = swap_params.token_out_index;

        if token_in_index >= self.normalized_weights.len()
            || token_out_index >= self.normalized_weights.len()
        {
            return Err(PoolError::InvalidTokenIndex);
        }

        // WeightedPool.onSwap rounds the token-in balance up on both ExactIn and ExactOut swaps.
        let balance_in = swap_params.balances_live_scaled_18[token_in_index] + U256::from(1);
        let weight_in = &self.normalized_weights[token_in_index];
        let balance_out = swap_params.balances_live_scaled_18[token_out_index];
        let weight_out = &self.normalized_weights[token_out_index];
        let amount_scaled_18 = &swap_params.amount_scaled_18;
        self.ensure_minimum_balance(token_in_index, balance_in)?;

        let (calculated, amount_out) = match swap_params.swap_kind {
            bush_maths::common::types::SwapKind::GivenIn => {
                let out = compute_out_given_exact_in(
                    &balance_in,
                    weight_in,
                    &balance_out,
                    weight_out,
                    amount_scaled_18,
                )?;
                (out, out)
            }
            bush_maths::common::types::SwapKind::GivenOut => {
                let inp = compute_in_given_exact_out(
                    &balance_in,
                    weight_in,
                    &balance_out,
                    weight_out,
                    amount_scaled_18,
                )?;
                (inp, *amount_scaled_18)
            }
        };
        // The swap must not drop the token-out balance below the minimum.
        if amount_out > balance_out {
            return Err(PoolError::Custom("TokenBalanceBelowMin".to_string()));
        }
        self.ensure_minimum_balance(token_out_index, balance_out - amount_out)?;
        Ok(calculated)
    }

    fn compute_invariant(
        &self,
        balances_live_scaled_18: &[U256],
        rounding: Rounding,
    ) -> Result<U256, PoolError> {
        self.ensure_min_token_balances(balances_live_scaled_18)?;
        match rounding {
            Rounding::RoundDown => {
                compute_invariant_down(&self.normalized_weights, balances_live_scaled_18)
            }
            Rounding::RoundUp => {
                compute_invariant_up(&self.normalized_weights, balances_live_scaled_18)
            }
        }
    }

    fn compute_balance(
        &self,
        balances_live_scaled_18: &[U256],
        token_in_index: usize,
        invariant_ratio: &U256,
    ) -> Result<U256, PoolError> {
        if token_in_index >= balances_live_scaled_18.len()
            || token_in_index >= self.normalized_weights.len()
        {
            return Err(PoolError::InvalidTokenIndex);
        }

        let current_balance = &balances_live_scaled_18[token_in_index];
        let weight = &self.normalized_weights[token_in_index];

        // Calculate the new balance based on the invariant ratio
        let new_balance = compute_balance_out_given_invariant(current_balance, weight, invariant_ratio)?;
        // WeightedPool.computeBalance: whichever of the two balances is lower must stay above the minimum.
        self.ensure_minimum_balance(token_in_index, std::cmp::min(*current_balance, new_balance))?;
        Ok(new_balance)
    }

    fn get_maximum_invariant_ratio(&self) -> U256 {
        MAX_INVARIANT_RATIO
    }

    fn get_minimum_invariant_ratio(&self) -> U256 {
        MIN_INVARIANT_RATIO
    }
}

impl From<WeightedState> for WeightedPool {
    fn from(weighted_state: WeightedState) -> Self {
        let min_token_balances = weighted_state
            .min_token_balances
            .unwrap_or_else(|| compute_min_token_balances(&weighted_state.base.scaling_factors));
        Self {
            normalized_weights: weighted_state.weights,
            min_token_balances,
        }
    }
}
