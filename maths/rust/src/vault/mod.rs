//! Vault operations for Bush pools

pub mod add_liquidity;
pub mod base_pool_math;
pub mod remove_liquidity;
pub mod swap;

use crate::common::errors::PoolError;
use crate::common::pool_base::PoolBase;
use crate::common::types::*;
use crate::hooks::types::HookState;
use crate::hooks::{DefaultHook, HookBase, StableSurgeHook};
use crate::vault::add_liquidity::add_liquidity;
use crate::vault::remove_liquidity::remove_liquidity;
use crate::vault::swap::swap;
use alloy_primitives::U256;

/// Main vault interface for pool operations
pub struct Vault;

impl Vault {
    /// Create a new vault instance
    pub fn new() -> Self {
        Vault
    }

    /// Get hook instance based on hook type
    fn get_hook(
        &self,
        hook_type: &Option<String>,
        hook_state: Option<&HookState>,
    ) -> Box<dyn HookBase> {
        match hook_type {
            Some(hook_type) => match hook_type.as_str() {
                "StableSurge" => {
                    if let Some(HookState::StableSurge(_)) = hook_state {
                        Box::new(StableSurgeHook::new())
                    } else {
                        Box::new(DefaultHook::new())
                    }
                }
                // Hooks implemented outside this crate go through the lower-level `vault::swap` etc. with an
                // explicit `&dyn HookBase`; `Vault` itself only knows the built-in ones.
                _ => Box::new(DefaultHook::new()),
            },
            None => Box::new(DefaultHook::new()),
        }
    }

    /// Instantiate the maths for a pool from its state.
    pub fn get_pool(pool_state: &PoolState) -> Result<Box<dyn PoolBase>, PoolError> {
        Ok(match pool_state {
            // WeightedPool8020Factory and CowPoolFactory deploy WeightedPool too; both use WeightedState.
            PoolState::Weighted(weighted_state) => Box::new(
                crate::pools::weighted::WeightedPool::from(weighted_state.clone()),
            ),
            PoolState::Stable(stable_state) => Box::new(crate::pools::stable::StablePool::new(
                stable_state.mutable.clone(),
            )),
            PoolState::LiquidityBootstrapping(liquidity_bootstrapping_state) => Box::new(
                crate::pools::liquidity_bootstrapping::LiquidityBootstrappingPool::from(
                    liquidity_bootstrapping_state.clone(),
                ),
            ),
            PoolState::FixedPriceLBP(fixed_price_lbp_state) => {
                Box::new(crate::pools::fixed_price_lbp::FixedPriceLBPPool::from(
                    fixed_price_lbp_state.clone(),
                ))
            }
            PoolState::ReClamm(reclamm_state) => Box::new(
                crate::pools::reclamm::ReClammPool::from(reclamm_state.clone()),
            ),
            PoolState::Base(base) => {
                return Err(PoolError::UnsupportedPoolType(base.pool_type.clone()))
            }
        })
    }

    /// Perform a swap operation
    pub fn swap(
        &self,
        swap_input: &SwapInput,
        pool_state: &PoolState,
        hook_state: Option<&HookState>,
    ) -> Result<U256, PoolError> {
        let pool = Self::get_pool(pool_state)?;
        let hook: Box<dyn HookBase> = self.get_hook(&pool_state.base().hook_type, hook_state);
        swap(
            swap_input,
            pool_state,
            pool.as_ref(),
            hook.as_ref(),
            hook_state,
        )
    }

    /// Add liquidity to a pool
    pub fn add_liquidity(
        &self,
        add_liquidity_input: &AddLiquidityInput,
        pool_state: &PoolState,
        hook_state: Option<&HookState>,
    ) -> Result<AddLiquidityResult, PoolError> {
        let base_state = pool_state.base();
        let pool = Self::get_pool(pool_state)?;

        let hook: Box<dyn HookBase> = self.get_hook(&base_state.hook_type, hook_state);

        add_liquidity(
            add_liquidity_input,
            pool_state,
            pool.as_ref(),
            hook.as_ref(),
            hook_state,
        )
    }

    /// Remove liquidity from a pool
    pub fn remove_liquidity(
        &self,
        remove_liquidity_input: &RemoveLiquidityInput,
        pool_state: &PoolState,
        hook_state: Option<&HookState>,
    ) -> Result<RemoveLiquidityResult, PoolError> {
        let base_state = pool_state.base();
        let pool = Self::get_pool(pool_state)?;

        let hook: Box<dyn HookBase> = self.get_hook(&base_state.hook_type, hook_state);

        remove_liquidity(
            remove_liquidity_input,
            pool_state,
            pool.as_ref(),
            hook.as_ref(),
            hook_state,
        )
    }
}

impl Default for Vault {
    fn default() -> Self {
        Vault::new()
    }
}
