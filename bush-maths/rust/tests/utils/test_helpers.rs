//! Shared test helper functions for pool state conversion and utilities

use crate::utils::read_test_data::SupportedPool;
use bush_maths::common::types::PoolState;
use bush_maths::pools::fixed_price_lbp::{
    FixedPriceLBPImmutable, FixedPriceLBPMutable, FixedPriceLBPState,
};
use bush_maths::pools::liquidity_bootstrapping::{
    LiquidityBootstrappingImmutable, LiquidityBootstrappingMutable, LiquidityBootstrappingState,
};
use bush_maths::pools::stable::{StableMutable, StableState};
use bush_maths::pools::weighted::WeightedState;

/// Convert a SupportedPool from test data to a PoolState for the vault
pub fn convert_to_pool_state(pool: &SupportedPool) -> PoolState {
    match pool {
        SupportedPool::Weighted(weighted_pool) => PoolState::Weighted(WeightedState {
            base: weighted_pool.state.base.clone(),
            weights: weighted_pool.state.weights.clone(),
            min_token_balances: weighted_pool.state.min_token_balances.clone(),
        }),
        SupportedPool::Stable(stable_pool) => PoolState::Stable(StableState {
            base: stable_pool.state.base.clone(),
            mutable: StableMutable {
                amp: stable_pool.state.mutable.amp,
            },
        }),
        SupportedPool::LiquidityBootstrapping(lbp) => {
            PoolState::LiquidityBootstrapping(LiquidityBootstrappingState {
                base: lbp.state.base.clone(),
                mutable: LiquidityBootstrappingMutable {
                    is_swap_enabled: lbp.state.mutable.is_swap_enabled,
                    current_timestamp: lbp.state.mutable.current_timestamp,
                },
                immutable: LiquidityBootstrappingImmutable {
                    project_token_index: lbp.state.immutable.project_token_index,
                    is_project_token_swap_in_blocked: lbp
                        .state
                        .immutable
                        .is_project_token_swap_in_blocked,
                    start_weights: lbp.state.immutable.start_weights.clone(),
                    end_weights: lbp.state.immutable.end_weights.clone(),
                    start_time: lbp.state.immutable.start_time,
                    end_time: lbp.state.immutable.end_time,
                    min_token_balances: lbp.state.immutable.min_token_balances.clone(),
                },
            })
        }
        SupportedPool::FixedPriceLBP(lbp) => PoolState::FixedPriceLBP(FixedPriceLBPState {
            base: lbp.state.base.clone(),
            mutable: FixedPriceLBPMutable {
                is_swap_enabled: lbp.state.mutable.is_swap_enabled,
                current_timestamp: lbp.state.mutable.current_timestamp,
            },
            immutable: FixedPriceLBPImmutable {
                project_token_index: lbp.state.immutable.project_token_index,
                reserve_token_index: lbp.state.immutable.reserve_token_index,
                project_token_rate: lbp.state.immutable.project_token_rate,
                start_time: lbp.state.immutable.start_time,
                end_time: lbp.state.immutable.end_time,
            },
        }),
    }
}

/// Get the pool address from a SupportedPool
#[allow(dead_code)]
pub fn get_pool_address(pool: &SupportedPool) -> String {
    match pool {
        SupportedPool::Weighted(pool) => pool.base.pool_address.clone(),
        SupportedPool::Stable(pool) => pool.base.pool_address.clone(),
        SupportedPool::LiquidityBootstrapping(pool) => pool.base.pool_address.clone(),
        SupportedPool::FixedPriceLBP(pool) => pool.base.pool_address.clone(),
    }
}
