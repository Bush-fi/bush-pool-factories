//! TEMPLATE: exact fixed-point port of contracts/ConstantSumPool.sol, implementing the bush-maths `PoolBase` trait
//! so the bush-maths Vault flow (token scaling, rates, swap fees, hooks) can run it.
//!
//! Rules for a port that matches the contract to the wei:
//!   - use `U256` and the bush-maths fixed-point helpers (`mul_down_fixed` etc.), never floats;
//!   - mirror every rounding direction of the Solidity (mulDown/mulUp/divDown/divUp) call for call;
//!   - reproduce every revert as an `Err` (the check treats "both fail" as a match).

use alloy_primitives::{uint, U256};
use bush_maths::common::errors::PoolError;
use bush_maths::common::maths::{div_down_fixed, div_up_fixed, mul_down_fixed, mul_up_fixed};
use bush_maths::common::pool_base::PoolBase;
use bush_maths::common::types::{Rounding, SwapKind, SwapParams};

/// The Vault's invariant-ratio bounds for unbalanced liquidity operations (ConstantSumPool._MIN/_MAX_INVARIANT_RATIO).
pub const MIN_INVARIANT_RATIO: U256 = uint!(500000000000000000_U256); // 50%
pub const MAX_INVARIANT_RATIO: U256 = uint!(2000000000000000000_U256); // 200%

pub struct ConstantSumPool {
    /// How many token1 one token0 is worth, 18 decimals (ConstantSumPool._rate).
    rate: U256,
}

impl ConstantSumPool {
    pub fn new(rate: U256) -> Self {
        Self { rate }
    }
}

impl PoolBase for ConstantSumPool {
    // ConstantSumPool.onSwap
    fn on_swap(&self, swap_params: &SwapParams) -> Result<U256, PoolError> {
        let token0_in = swap_params.token_in_index == 0;
        let amount = &swap_params.amount_scaled_18;
        match swap_params.swap_kind {
            // The user receives the calculated amount: round down.
            SwapKind::GivenIn => {
                if token0_in {
                    mul_down_fixed(amount, &self.rate)
                } else {
                    div_down_fixed(amount, &self.rate)
                }
            }
            // The user pays the calculated amount: round up.
            SwapKind::GivenOut => {
                if token0_in {
                    div_up_fixed(amount, &self.rate)
                } else {
                    mul_up_fixed(amount, &self.rate)
                }
            }
        }
    }

    // ConstantSumPool.computeInvariant: balance0 * rate + balance1
    fn compute_invariant(&self, balances: &[U256], rounding: Rounding) -> Result<U256, PoolError> {
        let token0_value = match rounding {
            Rounding::RoundUp => mul_up_fixed(&balances[0], &self.rate)?,
            Rounding::RoundDown => mul_down_fixed(&balances[0], &self.rate)?,
        };
        Ok(token0_value + balances[1])
    }

    // ConstantSumPool.computeBalance
    fn compute_balance(&self, balances: &[U256], token_in_index: usize, invariant_ratio: &U256) -> Result<U256, PoolError> {
        let new_invariant = mul_up_fixed(&self.compute_invariant(balances, Rounding::RoundUp)?, invariant_ratio)?;
        match token_in_index {
            0 => div_up_fixed(&(new_invariant - balances[1]), &self.rate),
            1 => Ok(new_invariant - mul_down_fixed(&balances[0], &self.rate)?),
            _ => Err(PoolError::InvalidTokenIndex),
        }
    }

    fn get_maximum_invariant_ratio(&self) -> U256 {
        MAX_INVARIANT_RATIO
    }

    fn get_minimum_invariant_ratio(&self) -> U256 {
        MIN_INVARIANT_RATIO
    }
}
