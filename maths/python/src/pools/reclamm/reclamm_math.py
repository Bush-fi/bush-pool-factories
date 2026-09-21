"""Port of contracts/reclamm/lib/ReClammMath.sol. Every function mirrors its Solidity namesake call for call, with
the same fixed-point primitives and rounding, so the results match the contract to the wei.

ReClamm pools are always 2-token pools; token `a` is index 0 and token `b` index 1 (registration order).
"""

from dataclasses import dataclass
from typing import List, Tuple

from src.common.constants import MAX_POW_RELATIVE_ERROR, WAD
from src.common.log_exp_math import LogExpMath
from src.common.maths import (
    Rounding,
    div_down_fixed,
    div_up_fixed,
    mul_div_up_fixed,
    mul_down_fixed,
    mul_up_fixed,
)
from src.common.oz_math import sqrt

A = 0
B = 1

# ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT: scales the daily price shift exponent to the per-second tau.
PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT = 124649

_THIRTY_DAYS = 30 * 24 * 60 * 60


@dataclass
class PriceRatioState:
    """ReClammMath.PriceRatioState (fourth roots are 18-decimal fixed point, times are unix seconds)."""

    start_fourth_root_price_ratio: int
    end_fourth_root_price_ratio: int
    price_ratio_update_start_time: int
    price_ratio_update_end_time: int


def _pow_down(x: int, y: int) -> int:
    """FixedPoint.powDown, ported exactly. `maths.pow_down_fixed` rounds the y == 2 / y == 4 shortcuts *up* (a
    balancer-maths quirk), which is not what the contract does, so ReClamm keeps its own copy."""
    if y == WAD:
        return x
    if y == 2 * WAD:
        return mul_down_fixed(x, x)
    if y == 4 * WAD:
        square = mul_down_fixed(x, x)
        return mul_down_fixed(square, square)
    raw = LogExpMath.pow(x, y)
    max_error = mul_up_fixed(raw, MAX_POW_RELATIVE_ERROR) + 1
    return 0 if raw < max_error else raw - max_error


def compute_invariant(
    balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int, rounding: Rounding
) -> int:
    """ReClammMath.computeInvariant (4-arg overload): (Ra + Va) * (Rb + Vb), without the square root."""
    mul = mul_down_fixed if rounding == Rounding.ROUND_DOWN else mul_up_fixed
    return mul(balances_scaled18[A] + virtual_balance_a, balances_scaled18[B] + virtual_balance_b)


def compute_out_given_in(
    balances_scaled18: List[int],
    virtual_balance_a: int,
    virtual_balance_b: int,
    token_in_index: int,
    token_out_index: int,
    amount_in_scaled18: int,
) -> int:
    """ReClammMath.computeOutGivenIn: Ao = (Bo + Vo) * Ai / (Bi + Vi + Ai)."""
    virtual_in, virtual_out = (
        (virtual_balance_a, virtual_balance_b) if token_in_index == A else (virtual_balance_b, virtual_balance_a)
    )
    amount_out_scaled18 = ((balances_scaled18[token_out_index] + virtual_out) * amount_in_scaled18) // (
        balances_scaled18[token_in_index] + virtual_in + amount_in_scaled18
    )
    # Amount out cannot be greater than the real balance of the token in the pool.
    if amount_out_scaled18 > balances_scaled18[token_out_index]:
        raise ValueError("AmountOutGreaterThanBalance")
    return amount_out_scaled18


def compute_in_given_out(
    balances_scaled18: List[int],
    virtual_balance_a: int,
    virtual_balance_b: int,
    token_in_index: int,
    token_out_index: int,
    amount_out_scaled18: int,
) -> int:
    """ReClammMath.computeInGivenOut: Ai = (Bi + Vi) * Ao / (Bo + Vo - Ao), rounded up."""
    # Amount out cannot be greater than the real balance of the token in the pool.
    if amount_out_scaled18 > balances_scaled18[token_out_index]:
        raise ValueError("AmountOutGreaterThanBalance")
    virtual_in, virtual_out = (
        (virtual_balance_a, virtual_balance_b) if token_in_index == A else (virtual_balance_b, virtual_balance_a)
    )
    # Round up to favor the vault (i.e. request larger amount in from the user).
    return mul_div_up_fixed(
        balances_scaled18[token_in_index] + virtual_in,
        amount_out_scaled18,
        balances_scaled18[token_out_index] + virtual_out - amount_out_scaled18,
    )


def compute_current_virtual_balances(
    balances_scaled18: List[int],
    last_virtual_balance_a: int,
    last_virtual_balance_b: int,
    daily_price_shift_base: int,
    last_timestamp: int,
    centeredness_margin: int,
    price_ratio_state: PriceRatioState,
    current_timestamp: int,
) -> Tuple[int, int, bool]:
    """ReClammMath.computeCurrentVirtualBalances: the virtual balances at `current_timestamp`, after applying any
    in-progress price ratio update and, if the pool is outside the target range, the price range shift since
    `last_timestamp`. Returns (virtual_balance_a, virtual_balance_b, changed); the stored balances unchanged when
    queried in the block they were stored."""
    # Per-block VB freeze (see the contract for the rationale).
    if last_timestamp == current_timestamp:
        return last_virtual_balance_a, last_virtual_balance_b, False

    virtual_balance_a = last_virtual_balance_a
    virtual_balance_b = last_virtual_balance_b
    changed = False

    current_fourth_root_price_ratio = compute_fourth_root_price_ratio(
        current_timestamp,
        price_ratio_state.start_fourth_root_price_ratio,
        price_ratio_state.end_fourth_root_price_ratio,
        price_ratio_state.price_ratio_update_start_time,
        price_ratio_state.price_ratio_update_end_time,
    )

    # If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
    if (
        current_timestamp > price_ratio_state.price_ratio_update_start_time
        and last_timestamp < price_ratio_state.price_ratio_update_end_time
    ):
        virtual_balance_a, virtual_balance_b = compute_virtual_balances_updating_price_ratio(
            current_fourth_root_price_ratio, balances_scaled18, last_virtual_balance_a, last_virtual_balance_b
        )
        changed = True

    centeredness, is_pool_above_center = compute_centeredness(balances_scaled18, virtual_balance_a, virtual_balance_b)

    # If the pool is outside the target range, track the market price by moving the price interval.
    if centeredness < centeredness_margin:
        virtual_balance_a, virtual_balance_b = compute_virtual_balances_updating_price_range(
            balances_scaled18,
            virtual_balance_a,
            virtual_balance_b,
            is_pool_above_center,
            daily_price_shift_base,
            current_timestamp,
            last_timestamp,
        )
        changed = True

    return virtual_balance_a, virtual_balance_b, changed


def compute_virtual_balances_updating_price_ratio(
    current_fourth_root_price_ratio: int,
    balances_scaled18: List[int],
    last_virtual_balance_a: int,
    last_virtual_balance_b: int,
) -> Tuple[int, int]:
    """ReClammMath.computeVirtualBalancesUpdatingPriceRatio: new virtual balances for a target fourth-root price
    ratio."""
    centeredness, is_pool_above_center = compute_centeredness(
        balances_scaled18, last_virtual_balance_a, last_virtual_balance_b
    )
    balance_undervalued, last_virtual_undervalued, last_virtual_overvalued = (
        (balances_scaled18[A], last_virtual_balance_a, last_virtual_balance_b)
        if is_pool_above_center
        else (balances_scaled18[B], last_virtual_balance_b, last_virtual_balance_a)
    )

    sqrt_price_ratio = mul_down_fixed(current_fourth_root_price_ratio, current_fourth_root_price_ratio)

    # Vu = Ru * (1 + c + sqrt(c * (c + 4 * sqrtQ - 2) + 1)) / (2 * (sqrtQ - 1))
    virtual_undervalued = (
        balance_undervalued
        * (WAD + centeredness + sqrt(centeredness * (centeredness + 4 * sqrt_price_ratio - 2 * WAD) + WAD * WAD))
    ) // (2 * (sqrt_price_ratio - WAD))

    virtual_overvalued = (virtual_undervalued * last_virtual_overvalued) // last_virtual_undervalued

    return (
        (virtual_undervalued, virtual_overvalued)
        if is_pool_above_center
        else (virtual_overvalued, virtual_undervalued)
    )


def compute_virtual_balances_updating_price_range(
    balances_scaled18: List[int],
    virtual_balance_a: int,
    virtual_balance_b: int,
    is_pool_above_center: bool,
    daily_price_shift_base: int,
    current_timestamp: int,
    last_timestamp: int,
) -> Tuple[int, int]:
    """ReClammMath.computeVirtualBalancesUpdatingPriceRange: shifts the price range toward the market price by
    decaying the overvalued virtual balance over the elapsed time (capped at 30 days), then re-deriving the other."""
    sqrt_price_ratio = sqrt_scaled18(compute_price_ratio(balances_scaled18, virtual_balance_a, virtual_balance_b))

    balance_undervalued, balance_overvalued = (
        (balances_scaled18[A], balances_scaled18[B]) if is_pool_above_center else (balances_scaled18[B], balances_scaled18[A])
    )
    virtual_undervalued, virtual_overvalued = (
        (virtual_balance_a, virtual_balance_b) if is_pool_above_center else (virtual_balance_b, virtual_balance_a)
    )

    duration = min(current_timestamp - last_timestamp, _THIRTY_DAYS)

    # Vo = Vo * (1 - tau)^duration
    virtual_overvalued = mul_up_fixed(virtual_overvalued, _pow_down(daily_price_shift_base, duration * WAD))

    # Never shrink Vo below what keeps the overvalued balance inside the price range.
    virtual_overvalued = max(virtual_overvalued, div_up_fixed(balance_overvalued, sqrt_scaled18(sqrt_price_ratio) - WAD))

    # Vu = Ru * (Vo + Ro) / ((sqrtQ - 1) * Vo - Ro)
    virtual_undervalued = (balance_undervalued * (virtual_overvalued + balance_overvalued)) // (
        mul_up_fixed(sqrt_price_ratio - WAD, virtual_overvalued) - balance_overvalued
    )

    return (
        (virtual_undervalued, virtual_overvalued)
        if is_pool_above_center
        else (virtual_overvalued, virtual_undervalued)
    )


def is_pool_within_target_range(
    balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int, centeredness_margin: int
) -> bool:
    """ReClammMath.isPoolWithinTargetRange."""
    centeredness, _ = compute_centeredness(balances_scaled18, virtual_balance_a, virtual_balance_b)
    return centeredness >= centeredness_margin


def compute_centeredness(
    balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int
) -> Tuple[int, bool]:
    """ReClammMath.computeCenteredness: (centeredness, is_pool_above_center). 1 = centered, 0 = at an edge."""
    if balances_scaled18[A] == 0:
        return 0, False
    if balances_scaled18[B] == 0:
        return 0, True

    numerator = balances_scaled18[A] * virtual_balance_b
    denominator = virtual_balance_a * balances_scaled18[B]

    is_pool_above_center = numerator > denominator

    # Math.mulDiv(x, ONE, y): exact, floored.
    centeredness = (denominator * WAD) // numerator if is_pool_above_center else (numerator * WAD) // denominator
    return centeredness, is_pool_above_center


def compute_fourth_root_price_ratio(
    current_time: int,
    start_fourth_root_price_ratio: int,
    end_fourth_root_price_ratio: int,
    price_ratio_update_start_time: int,
    price_ratio_update_end_time: int,
) -> int:
    """ReClammMath.computeFourthRootPriceRatio: the fourth-root price ratio interpolated (geometrically) at
    `current_time`."""
    if current_time >= price_ratio_update_end_time:
        return end_fourth_root_price_ratio
    if current_time <= price_ratio_update_start_time:
        return start_fourth_root_price_ratio

    exponent = div_down_fixed(
        current_time - price_ratio_update_start_time, price_ratio_update_end_time - price_ratio_update_start_time
    )
    current_fourth_root_price_ratio = mul_down_fixed(
        start_fourth_root_price_ratio,
        _pow_down(div_down_fixed(end_fourth_root_price_ratio, start_fourth_root_price_ratio), exponent),
    )

    # Since we're rounding current fourth root price ratio down, we only need to check the lower boundary.
    minimum = min(start_fourth_root_price_ratio, end_fourth_root_price_ratio)
    return max(minimum, current_fourth_root_price_ratio)


def compute_price_ratio(balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int) -> int:
    """ReClammMath.computePriceRatio: maxPrice / minPrice = ((1 + Ra/Va) * (1 + Rb/Vb))^2."""
    sqrt_price_ratio = mul_down_fixed(
        WAD + div_down_fixed(balances_scaled18[A], virtual_balance_a),
        WAD + div_down_fixed(balances_scaled18[B], virtual_balance_b),
    )
    return mul_down_fixed(sqrt_price_ratio, sqrt_price_ratio)


def compute_price_range(
    balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int
) -> Tuple[int, int]:
    """ReClammMath.computePriceRange: (min_price, max_price) of token A in terms of token B."""
    invariant = compute_invariant(balances_scaled18, virtual_balance_a, virtual_balance_b, Rounding.ROUND_DOWN)
    # P_min(a) = Vb^2 / L
    min_price = (virtual_balance_b * virtual_balance_b) // invariant
    # P_max(a) = priceRatio * P_min(a)
    max_price = mul_down_fixed(compute_price_ratio(balances_scaled18, virtual_balance_a, virtual_balance_b), min_price)
    return min_price, max_price


def to_daily_price_shift_base(daily_price_shift_exponent: int) -> int:
    """ReClammMath.toDailyPriceShiftBase: 1 - tau, from the daily price shift exponent (percentage)."""
    return WAD - daily_price_shift_exponent // PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT


def to_daily_price_shift_exponent(daily_price_shift_base: int) -> int:
    """ReClammMath.toDailyPriceShiftExponent: the inverse of `to_daily_price_shift_base`."""
    return (WAD - daily_price_shift_base) * PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT


def sqrt_scaled18(value_scaled18: int) -> int:
    """ReClammMath.sqrtScaled18: square root of an 18-decimal fixed-point number (floored)."""
    return sqrt(value_scaled18 * WAD)


def fourth_root_scaled18(value_scaled18: int) -> int:
    """ReClammMath.fourthRootScaled18."""
    return sqrt(sqrt(value_scaled18 * WAD) * WAD)
