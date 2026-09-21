//! Liquidity Bootstrapping pool implementation

use crate::common::errors::PoolError;
use crate::common::pool_base::PoolBase;
use crate::common::types::{Rounding, SwapParams};
use crate::pools::liquidity_bootstrapping::liquidity_bootstrapping_data::LiquidityBootstrappingState;
use crate::pools::liquidity_bootstrapping::liquidity_bootstrapping_math::get_normalized_weights;
use crate::pools::weighted::weighted_pool::{compute_min_token_balances, WeightedPool};
use crate::pools::weighted::weighted_math::{MAX_INVARIANT_RATIO, MIN_INVARIANT_RATIO};
use alloy_primitives::U256;

/// Liquidity Bootstrapping pool implementation
pub struct LiquidityBootstrappingPool {
    /// Current normalized weights (scaled 18) based on time interpolation
    normalized_weights: Vec<U256>,
    /// The underlying WeightedPool maths (LBPool inherits WeightedPool)
    weighted: WeightedPool,
    /// Pool state
    state: LiquidityBootstrappingState,
}

impl LiquidityBootstrappingPool {
    /// Create a new Liquidity Bootstrapping pool
    pub fn new(state: LiquidityBootstrappingState) -> Result<Self, PoolError> {
        if state.immutable.start_weights.len() != 2 || state.immutable.end_weights.len() != 2 {
            return Err(PoolError::InvalidSwapParameters);
        }

        // Calculate current normalized weights based on time interpolation
        let normalized_weights = get_normalized_weights(
            state.immutable.project_token_index,
            &state.mutable.current_timestamp,
            &state.immutable.start_time,
            &state.immutable.end_time,
            &state.immutable.start_weights[state.immutable.project_token_index],
            &state.immutable.end_weights[state.immutable.project_token_index],
        )?;

        let min_token_balances = state
            .immutable
            .min_token_balances
            .clone()
            .unwrap_or_else(|| compute_min_token_balances(&state.base.scaling_factors));
        let weighted =
            WeightedPool::with_min_token_balances(normalized_weights.clone(), min_token_balances);
        Ok(Self {
            normalized_weights,
            weighted,
            state,
        })
    }

    /// Check if swaps are enabled
    fn is_swap_enabled(&self) -> bool {
        self.state.mutable.is_swap_enabled
    }

    /// Check if project token swap in is blocked
    fn is_project_token_swap_in_blocked(&self) -> bool {
        self.state.immutable.is_project_token_swap_in_blocked
    }

    /// Validate swap parameters
    fn validate_swap(&self, token_in_index: usize) -> Result<(), PoolError> {
        if !self.is_swap_enabled() {
            return Err(PoolError::InvalidSwapParameters);
        }

        // Check if project token swap in is blocked
        if self.is_project_token_swap_in_blocked()
            && token_in_index == self.state.immutable.project_token_index
        {
            return Err(PoolError::InvalidSwapParameters);
        }

        Ok(())
    }
}

impl PoolBase for LiquidityBootstrappingPool {
    fn on_swap(&self, swap_params: &SwapParams) -> Result<U256, PoolError> {
        let token_in_index = swap_params.token_in_index;
        let token_out_index = swap_params.token_out_index;

        if token_in_index >= self.normalized_weights.len()
            || token_out_index >= self.normalized_weights.len()
        {
            return Err(PoolError::InvalidTokenIndex);
        }

        // Validate swap parameters
        self.validate_swap(token_in_index)?;

        self.weighted.on_swap(swap_params)
    }

    fn compute_invariant(
        &self,
        balances_live_scaled_18: &[U256],
        rounding: Rounding,
    ) -> Result<U256, PoolError> {
        self.weighted.compute_invariant(balances_live_scaled_18, rounding)
    }

    fn compute_balance(
        &self,
        balances_live_scaled_18: &[U256],
        token_in_index: usize,
        invariant_ratio: &U256,
    ) -> Result<U256, PoolError> {
        self.weighted
            .compute_balance(balances_live_scaled_18, token_in_index, invariant_ratio)
    }

    fn get_maximum_invariant_ratio(&self) -> U256 {
        MAX_INVARIANT_RATIO
    }

    fn get_minimum_invariant_ratio(&self) -> U256 {
        MIN_INVARIANT_RATIO
    }
}

impl From<LiquidityBootstrappingState> for LiquidityBootstrappingPool {
    fn from(liquidity_bootstrapping_state: LiquidityBootstrappingState) -> Self {
        Self::new(liquidity_bootstrapping_state)
            .expect("Failed to create LiquidityBootstrappingPool from state")
    }
}
