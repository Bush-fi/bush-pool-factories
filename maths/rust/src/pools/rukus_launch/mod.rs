//! Port of contracts/bonding-reclamm/BondingReClammPool.sol (and the graduation solve from
//! lib/BondingReClammMath.sol), implementing the bush-maths `PoolBase` trait.
//!
//! A BondingReClamm pool sells its launch token along a bonding curve (pump.fun's virtual-reserve curve) and then
//! graduates, in place, into a (practically) full-range pool. The swap maths is ReClamm's (constant product on real +
//! virtual balances) in both phases; what changes is the virtual balances it runs with:
//!   - BONDING:   the bonding curve's, which never move (and the buy completing the curve may go at most 0.1%
//!     past the graduation balance);
//!   - COMPLETED: the curve sold out. In the block it did, every operation reverts (GraduationPending). In a later
//!     block, the first operation graduates the pool: the virtual balances are re-solved at the current price for
//!     the graduated width (1e12x), and that operation runs on the result;
//!   - GRADUATED: the graduated ones, which never move with time (only proportional adds and removes scale them).

use crate::pool_kit::*;

mod bonding_reclamm_data;
pub use bonding_reclamm_data::*;

/// BondingReClammPool._MIN_SWAP_FEE_PERCENTAGE / _MAX_SWAP_FEE_PERCENTAGE (the same as ReClammPool's).
pub const MIN_SWAP_FEE_PERCENTAGE: U256 = uint!(1_000_000_000_000_U256); // 0.001%
pub const MAX_SWAP_FEE_PERCENTAGE: U256 = uint!(100_000_000_000_000_000_U256); // 10%

/// BondingReClammPool.MAX_GRADUATION_OVERSHOOT: 0.1% of the graduation balance.
pub const MAX_GRADUATION_OVERSHOOT: U256 = uint!(1_000_000_000_000_000_U256);

pub struct BondingReClammPool {
    pub state: BondingReClammMutable,
}

impl BondingReClammPool {
    pub fn new(state: BondingReClammMutable) -> Self {
        Self { state }
    }

    /// BondingReClammPool._minLaunchBalance: the graduation balance less the overshoot allowed.
    pub fn min_launch_balance(&self) -> Result<U256, PoolError> {
        let g = self.state.graduation_launch_balance;
        Ok(g - mul_down_fixed(&g, &MAX_GRADUATION_OVERSHOOT)?)
    }

    /// The virtual balances `on_swap` runs with: the stored ones (they never change with time), except that a
    /// COMPLETED pool queried in a later block graduates first, as the contract does.
    pub fn swap_virtual_balances(&self, balances_live_scaled18: &[U256]) -> Result<(U256, U256), PoolError> {
        let s = &self.state;
        if s.phase == BondingPhase::Completed {
            // BondingReClammPool._graduate.
            if s.current_timestamp <= s.bonding_completed_at {
                return Err(PoolError::Custom("GraduationPending".into()));
            }
            return compute_graduation_virtual_balances(
                balances_live_scaled18,
                &s.virtual_balance_a,
                &s.virtual_balance_b,
                &reclamm_math::sqrt_scaled18(&s.graduated_price_ratio),
            );
        }
        Ok((s.virtual_balance_a, s.virtual_balance_b))
    }
}

impl From<BondingReClammState> for BondingReClammPool {
    fn from(state: BondingReClammState) -> Self {
        Self::new(state.mutable)
    }
}

impl PoolBase for BondingReClammPool {
    /// BondingReClammPool.onSwap.
    fn on_swap(&self, swap_params: &SwapParams) -> Result<U256, PoolError> {
        let balances = &swap_params.balances_live_scaled_18;
        let (virtual_a, virtual_b) = self.swap_virtual_balances(balances)?;
        let amount_calculated = match swap_params.swap_kind {
            SwapKind::GivenIn => reclamm_math::compute_out_given_in(
                balances,
                &virtual_a,
                &virtual_b,
                swap_params.token_in_index,
                swap_params.token_out_index,
                &swap_params.amount_scaled_18,
            )?,
            SwapKind::GivenOut => reclamm_math::compute_in_given_out(
                balances,
                &virtual_a,
                &virtual_b,
                swap_params.token_in_index,
                swap_params.token_out_index,
                &swap_params.amount_scaled_18,
            )?,
        };

        // While bonding, the buy that completes the curve may go at most MAX_GRADUATION_OVERSHOOT past it.
        let s = &self.state;
        if s.phase == BondingPhase::Bonding && swap_params.token_out_index == s.launch_token_index {
            let launch_out = match swap_params.swap_kind {
                SwapKind::GivenIn => amount_calculated,
                SwapKind::GivenOut => swap_params.amount_scaled_18,
            };
            let launch_balance_after = balances[swap_params.token_out_index] - launch_out;
            if launch_balance_after <= s.graduation_launch_balance && launch_balance_after < self.min_launch_balance()? {
                return Err(PoolError::Custom("GraduationBuyTooLarge".into()));
            }
        }
        Ok(amount_calculated)
    }

    /// BondingReClammPool.computeInvariant: a view, so a completed pool still uses the bonding virtual balances.
    fn compute_invariant(&self, balances: &[U256], rounding: Rounding) -> Result<U256, PoolError> {
        reclamm_math::compute_invariant(balances, &self.state.virtual_balance_a, &self.state.virtual_balance_b, rounding)
    }

    /// BondingReClammPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced liquidity.
    fn compute_balance(&self, _balances: &[U256], _token_in_index: usize, _invariant_ratio: &U256) -> Result<U256, PoolError> {
        Err(PoolError::Custom("NotImplemented".into()))
    }

    // The invariant ratio bounds are required by the trait but unused: liquidity is proportional only.
    fn get_maximum_invariant_ratio(&self) -> U256 {
        U256::ZERO
    }

    fn get_minimum_invariant_ratio(&self) -> U256 {
        U256::ZERO
    }
}

/// BondingReClammMath.computeGraduationVirtualBalances: new virtual balances for the ReClamm range at the current
/// price, for the given sqrt(price ratio). See the contract for the derivation.
pub fn compute_graduation_virtual_balances(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    sqrt_price_ratio: &U256,
) -> Result<(U256, U256), PoolError> {
    let total_a = balances_scaled18[reclamm_math::A] + virtual_balance_a;
    let total_b = balances_scaled18[reclamm_math::B] + virtual_balance_b;

    let alpha = div_down_fixed(&balances_scaled18[reclamm_math::A], &total_a)?;
    let beta = div_down_fixed(&balances_scaled18[reclamm_math::B], &total_b)?;

    let linear_term = mul_down_fixed(sqrt_price_ratio, &(alpha + beta))?;
    let product_term = uint!(4_U256)
        * (*sqrt_price_ratio - WAD)
        * mul_down_fixed(&mul_down_fixed(sqrt_price_ratio, &alpha)?, &beta)?;
    let squared_linear_term = linear_term * linear_term;
    let discriminant = if squared_linear_term > product_term { squared_linear_term - product_term } else { U256::ZERO };

    let u = div_down_fixed(&(linear_term + sqrt(&discriminant)), &(uint!(2_U256) * (*sqrt_price_ratio - WAD)))?;

    if u <= alpha || u <= beta {
        return Err(PoolError::Custom("ZeroVirtualBalance".into()));
    }

    let new_virtual_balance_a = mul_down_fixed(&total_a, &(u - alpha))?;
    let new_virtual_balance_b = mul_down_fixed(&total_b, &(u - beta))?;

    if new_virtual_balance_a.is_zero() || new_virtual_balance_b.is_zero() {
        return Err(PoolError::Custom("ZeroVirtualBalance".into()));
    }

    Ok((new_virtual_balance_a, new_virtual_balance_b))
}
