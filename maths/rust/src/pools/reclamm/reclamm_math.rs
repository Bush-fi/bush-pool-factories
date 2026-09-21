//! Port of contracts/reclamm/lib/ReClammMath.sol. Every function mirrors its Solidity namesake call for call, with
//! the same fixed-point primitives and rounding, so the results match the contract to the wei.
//!
//! ReClamm pools are always 2-token pools; token `a` is index 0 and token `b` index 1 (registration order).

use crate::common::constants::{MAX_POW_RELATIVE_ERROR, WAD};
use crate::common::errors::PoolError;
use crate::common::log_exp_math;
use crate::common::maths::{div_down_fixed, div_up_fixed, mul_div_up_fixed, mul_down_fixed, mul_up_fixed};
use crate::common::oz_math::sqrt;
use crate::common::types::Rounding;
use crate::pools::reclamm::reclamm_data::PriceRatioState;
use alloy_primitives::{uint, U256};

pub const A: usize = 0;
pub const B: usize = 1;

/// ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT: scales the daily price shift exponent to the per-second tau.
pub const PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT: U256 = uint!(124649_U256);

const THIRTY_DAYS: U256 = uint!(2592000_U256);
const TWO: U256 = uint!(2_U256);
const FOUR: U256 = uint!(4_U256);

/// FixedPoint.powDown, ported exactly. `maths::pow_down_fixed` rounds the y == 2 / y == 4 shortcuts *up* (a
/// balancer-maths quirk), which is not what the contract does, so ReClamm keeps its own copy.
fn pow_down(x: &U256, y: &U256) -> Result<U256, PoolError> {
    if *y == WAD {
        return Ok(*x);
    }
    if *y == TWO * WAD {
        return mul_down_fixed(x, x);
    }
    if *y == FOUR * WAD {
        let square = mul_down_fixed(x, x)?;
        return mul_down_fixed(&square, &square);
    }
    let raw = log_exp_math::pow(x, y)?;
    let max_error = mul_up_fixed(&raw, &MAX_POW_RELATIVE_ERROR)? + U256::ONE;
    Ok(if raw < max_error { U256::ZERO } else { raw - max_error })
}

/// ReClammMath.computeInvariant (4-arg overload): (Ra + Va) * (Rb + Vb), without the square root.
pub fn compute_invariant(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    rounding: Rounding,
) -> Result<U256, PoolError> {
    let total_a = balances_scaled18[A] + virtual_balance_a;
    let total_b = balances_scaled18[B] + virtual_balance_b;
    match rounding {
        Rounding::RoundDown => mul_down_fixed(&total_a, &total_b),
        Rounding::RoundUp => mul_up_fixed(&total_a, &total_b),
    }
}

/// ReClammMath.computeOutGivenIn: Ao = (Bo + Vo) * Ai / (Bi + Vi + Ai).
pub fn compute_out_given_in(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    token_in_index: usize,
    token_out_index: usize,
    amount_in_scaled18: &U256,
) -> Result<U256, PoolError> {
    let (virtual_in, virtual_out) = if token_in_index == A {
        (virtual_balance_a, virtual_balance_b)
    } else {
        (virtual_balance_b, virtual_balance_a)
    };

    let amount_out_scaled18 = ((balances_scaled18[token_out_index] + virtual_out) * amount_in_scaled18)
        / (balances_scaled18[token_in_index] + virtual_in + amount_in_scaled18);

    // Amount out cannot be greater than the real balance of the token in the pool.
    if amount_out_scaled18 > balances_scaled18[token_out_index] {
        return Err(PoolError::Custom("AmountOutGreaterThanBalance".into()));
    }
    Ok(amount_out_scaled18)
}

/// ReClammMath.computeInGivenOut: Ai = (Bi + Vi) * Ao / (Bo + Vo - Ao), rounded up.
pub fn compute_in_given_out(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    token_in_index: usize,
    token_out_index: usize,
    amount_out_scaled18: &U256,
) -> Result<U256, PoolError> {
    // Amount out cannot be greater than the real balance of the token in the pool.
    if *amount_out_scaled18 > balances_scaled18[token_out_index] {
        return Err(PoolError::Custom("AmountOutGreaterThanBalance".into()));
    }

    let (virtual_in, virtual_out) = if token_in_index == A {
        (virtual_balance_a, virtual_balance_b)
    } else {
        (virtual_balance_b, virtual_balance_a)
    };

    // Round up to favor the vault (i.e. request larger amount in from the user).
    mul_div_up_fixed(
        &(balances_scaled18[token_in_index] + virtual_in),
        amount_out_scaled18,
        &(balances_scaled18[token_out_index] + virtual_out - amount_out_scaled18),
    )
}

/// ReClammMath.computeCurrentVirtualBalances: the virtual balances at `current_timestamp`, after applying any
/// in-progress price ratio update and, if the pool is outside the target range, the price range shift since
/// `last_timestamp`. Returns (virtual_balance_a, virtual_balance_b, changed); the stored balances unchanged when
/// queried in the block they were stored.
#[allow(clippy::too_many_arguments)]
pub fn compute_current_virtual_balances(
    balances_scaled18: &[U256],
    last_virtual_balance_a: &U256,
    last_virtual_balance_b: &U256,
    daily_price_shift_base: &U256,
    last_timestamp: &U256,
    centeredness_margin: &U256,
    price_ratio_state: &PriceRatioState,
    current_timestamp: &U256,
) -> Result<(U256, U256, bool), PoolError> {
    // Per-block VB freeze (see the contract for the rationale).
    if last_timestamp == current_timestamp {
        return Ok((*last_virtual_balance_a, *last_virtual_balance_b, false));
    }

    let mut virtual_balance_a = *last_virtual_balance_a;
    let mut virtual_balance_b = *last_virtual_balance_b;
    let mut changed = false;

    let current_fourth_root_price_ratio = compute_fourth_root_price_ratio(
        current_timestamp,
        &price_ratio_state.start_fourth_root_price_ratio,
        &price_ratio_state.end_fourth_root_price_ratio,
        &price_ratio_state.price_ratio_update_start_time,
        &price_ratio_state.price_ratio_update_end_time,
    )?;

    // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
    if *current_timestamp > price_ratio_state.price_ratio_update_start_time
        && *last_timestamp < price_ratio_state.price_ratio_update_end_time
    {
        (virtual_balance_a, virtual_balance_b) = compute_virtual_balances_updating_price_ratio(
            &current_fourth_root_price_ratio,
            balances_scaled18,
            last_virtual_balance_a,
            last_virtual_balance_b,
        )?;
        changed = true;
    }

    let (centeredness, is_pool_above_center) =
        compute_centeredness(balances_scaled18, &virtual_balance_a, &virtual_balance_b);

    // If the pool is outside the target range, track the market price by moving the price interval.
    if centeredness < *centeredness_margin {
        (virtual_balance_a, virtual_balance_b) = compute_virtual_balances_updating_price_range(
            balances_scaled18,
            &virtual_balance_a,
            &virtual_balance_b,
            is_pool_above_center,
            daily_price_shift_base,
            current_timestamp,
            last_timestamp,
        )?;
        changed = true;
    }

    Ok((virtual_balance_a, virtual_balance_b, changed))
}

/// ReClammMath.computeVirtualBalancesUpdatingPriceRatio: new virtual balances for a target fourth-root price ratio.
pub fn compute_virtual_balances_updating_price_ratio(
    current_fourth_root_price_ratio: &U256,
    balances_scaled18: &[U256],
    last_virtual_balance_a: &U256,
    last_virtual_balance_b: &U256,
) -> Result<(U256, U256), PoolError> {
    let (centeredness, is_pool_above_center) =
        compute_centeredness(balances_scaled18, last_virtual_balance_a, last_virtual_balance_b);

    let (balance_undervalued, last_virtual_undervalued, last_virtual_overvalued) = if is_pool_above_center {
        (balances_scaled18[A], *last_virtual_balance_a, *last_virtual_balance_b)
    } else {
        (balances_scaled18[B], *last_virtual_balance_b, *last_virtual_balance_a)
    };

    let sqrt_price_ratio = mul_down_fixed(current_fourth_root_price_ratio, current_fourth_root_price_ratio)?;

    // Vu = Ru * (1 + c + sqrt(c * (c + 4 * sqrtQ - 2) + 1)) / (2 * (sqrtQ - 1))
    let virtual_undervalued = (balance_undervalued
        * (WAD
            + centeredness
            + sqrt(&(centeredness * (centeredness + FOUR * sqrt_price_ratio - TWO * WAD) + WAD * WAD))))
        / (TWO * (sqrt_price_ratio - WAD));

    let virtual_overvalued = (virtual_undervalued * last_virtual_overvalued) / last_virtual_undervalued;

    Ok(if is_pool_above_center {
        (virtual_undervalued, virtual_overvalued)
    } else {
        (virtual_overvalued, virtual_undervalued)
    })
}

/// ReClammMath.computeVirtualBalancesUpdatingPriceRange: shifts the price range toward the market price by decaying
/// the overvalued virtual balance over the elapsed time (capped at 30 days), then re-deriving the other one.
#[allow(clippy::too_many_arguments)]
pub fn compute_virtual_balances_updating_price_range(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    is_pool_above_center: bool,
    daily_price_shift_base: &U256,
    current_timestamp: &U256,
    last_timestamp: &U256,
) -> Result<(U256, U256), PoolError> {
    let sqrt_price_ratio = sqrt_scaled18(&compute_price_ratio(balances_scaled18, virtual_balance_a, virtual_balance_b)?);

    let (balance_undervalued, balance_overvalued) = if is_pool_above_center {
        (balances_scaled18[A], balances_scaled18[B])
    } else {
        (balances_scaled18[B], balances_scaled18[A])
    };
    let (_, mut virtual_overvalued) = if is_pool_above_center {
        (*virtual_balance_a, *virtual_balance_b)
    } else {
        (*virtual_balance_b, *virtual_balance_a)
    };

    let duration = (*current_timestamp - last_timestamp).min(THIRTY_DAYS);

    // Vo = Vo * (1 - tau)^duration
    virtual_overvalued = mul_up_fixed(&virtual_overvalued, &pow_down(daily_price_shift_base, &(duration * WAD))?)?;

    // Never shrink Vo below what keeps the overvalued balance inside the price range.
    virtual_overvalued = virtual_overvalued.max(div_up_fixed(
        &balance_overvalued,
        &(sqrt_scaled18(&sqrt_price_ratio) - WAD),
    )?);

    // Vu = Ru * (Vo + Ro) / ((sqrtQ - 1) * Vo - Ro)
    let virtual_undervalued = (balance_undervalued * (virtual_overvalued + balance_overvalued))
        / (mul_up_fixed(&(sqrt_price_ratio - WAD), &virtual_overvalued)? - balance_overvalued);

    Ok(if is_pool_above_center {
        (virtual_undervalued, virtual_overvalued)
    } else {
        (virtual_overvalued, virtual_undervalued)
    })
}

/// ReClammMath.isPoolWithinTargetRange.
pub fn is_pool_within_target_range(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
    centeredness_margin: &U256,
) -> bool {
    compute_centeredness(balances_scaled18, virtual_balance_a, virtual_balance_b).0 >= *centeredness_margin
}

/// ReClammMath.computeCenteredness: (centeredness, is_pool_above_center). 1 = centered, 0 = at an edge.
pub fn compute_centeredness(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
) -> (U256, bool) {
    if balances_scaled18[A].is_zero() {
        return (U256::ZERO, false);
    }
    if balances_scaled18[B].is_zero() {
        return (U256::ZERO, true);
    }

    let numerator = balances_scaled18[A] * virtual_balance_b;
    let denominator = virtual_balance_a * balances_scaled18[B];

    let is_pool_above_center = numerator > denominator;

    // Math.mulDiv(x, ONE, y): exact, floored.
    let centeredness = if is_pool_above_center {
        (denominator * WAD) / numerator
    } else {
        (numerator * WAD) / denominator
    };
    (centeredness, is_pool_above_center)
}

/// ReClammMath.computeFourthRootPriceRatio: the fourth-root price ratio interpolated (geometrically) at `current_time`.
pub fn compute_fourth_root_price_ratio(
    current_time: &U256,
    start_fourth_root_price_ratio: &U256,
    end_fourth_root_price_ratio: &U256,
    price_ratio_update_start_time: &U256,
    price_ratio_update_end_time: &U256,
) -> Result<U256, PoolError> {
    if current_time >= price_ratio_update_end_time {
        return Ok(*end_fourth_root_price_ratio);
    }
    if current_time <= price_ratio_update_start_time {
        return Ok(*start_fourth_root_price_ratio);
    }

    let exponent = div_down_fixed(
        &(current_time - price_ratio_update_start_time),
        &(price_ratio_update_end_time - price_ratio_update_start_time),
    )?;

    let current_fourth_root_price_ratio = mul_down_fixed(
        start_fourth_root_price_ratio,
        &pow_down(
            &div_down_fixed(end_fourth_root_price_ratio, start_fourth_root_price_ratio)?,
            &exponent,
        )?,
    )?;

    // Since we're rounding current fourth root price ratio down, we only need to check the lower boundary.
    let minimum = (*start_fourth_root_price_ratio).min(*end_fourth_root_price_ratio);
    Ok(minimum.max(current_fourth_root_price_ratio))
}

/// ReClammMath.computePriceRatio: maxPrice / minPrice = ((1 + Ra/Va) * (1 + Rb/Vb))^2.
pub fn compute_price_ratio(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
) -> Result<U256, PoolError> {
    let sqrt_price_ratio = mul_down_fixed(
        &(WAD + div_down_fixed(&balances_scaled18[A], virtual_balance_a)?),
        &(WAD + div_down_fixed(&balances_scaled18[B], virtual_balance_b)?),
    )?;
    mul_down_fixed(&sqrt_price_ratio, &sqrt_price_ratio)
}

/// ReClammMath.computePriceRange: (min_price, max_price) of token A in terms of token B.
pub fn compute_price_range(
    balances_scaled18: &[U256],
    virtual_balance_a: &U256,
    virtual_balance_b: &U256,
) -> Result<(U256, U256), PoolError> {
    let invariant = compute_invariant(balances_scaled18, virtual_balance_a, virtual_balance_b, Rounding::RoundDown)?;
    // P_min(a) = Vb^2 / L
    let min_price = (virtual_balance_b * virtual_balance_b) / invariant;
    // P_max(a) = priceRatio * P_min(a)
    let max_price = mul_down_fixed(
        &compute_price_ratio(balances_scaled18, virtual_balance_a, virtual_balance_b)?,
        &min_price,
    )?;
    Ok((min_price, max_price))
}

/// ReClammMath.toDailyPriceShiftBase: 1 - tau, from the daily price shift exponent (percentage).
pub fn to_daily_price_shift_base(daily_price_shift_exponent: &U256) -> U256 {
    WAD - daily_price_shift_exponent / PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT
}

/// ReClammMath.toDailyPriceShiftExponent: the inverse of `to_daily_price_shift_base`.
pub fn to_daily_price_shift_exponent(daily_price_shift_base: &U256) -> U256 {
    (WAD - daily_price_shift_base) * PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT
}

/// ReClammMath.sqrtScaled18: square root of an 18-decimal fixed-point number (floored).
pub fn sqrt_scaled18(value_scaled18: &U256) -> U256 {
    sqrt(&(value_scaled18 * WAD))
}

/// ReClammMath.fourthRootScaled18.
pub fn fourth_root_scaled18(value_scaled18: &U256) -> U256 {
    sqrt(&(sqrt(&(value_scaled18 * WAD)) * WAD))
}
