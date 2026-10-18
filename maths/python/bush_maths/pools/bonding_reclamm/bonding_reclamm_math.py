"""Port of contracts/bonding-reclamm/lib/BondingReClammMath.sol: the graduation solve (the bonding curve setup only
runs at initialization, so the maths never needs it). Call for call, with the same fixed-point primitives."""

from typing import List, Tuple

from bush_maths.pool_kit import WAD, div_down_fixed, mul_down_fixed, reclamm_math, sqrt


def compute_graduation_virtual_balances(
    balances_scaled18: List[int], virtual_balance_a: int, virtual_balance_b: int, sqrt_price_ratio: int
) -> Tuple[int, int]:
    """BondingReClammMath.computeGraduationVirtualBalances: new virtual balances for the ReClamm range at the current
    price, for the given sqrt(price ratio). See the contract for the derivation."""
    total_a = balances_scaled18[reclamm_math.A] + virtual_balance_a
    total_b = balances_scaled18[reclamm_math.B] + virtual_balance_b

    alpha = div_down_fixed(balances_scaled18[reclamm_math.A], total_a)
    beta = div_down_fixed(balances_scaled18[reclamm_math.B], total_b)

    linear_term = mul_down_fixed(sqrt_price_ratio, alpha + beta)
    product_term = 4 * (sqrt_price_ratio - WAD) * mul_down_fixed(mul_down_fixed(sqrt_price_ratio, alpha), beta)
    squared_linear_term = linear_term * linear_term
    discriminant = squared_linear_term - product_term if squared_linear_term > product_term else 0

    u = div_down_fixed(linear_term + sqrt(discriminant), 2 * (sqrt_price_ratio - WAD))

    if u <= alpha or u <= beta:
        raise ValueError("ZeroVirtualBalance")

    new_virtual_balance_a = mul_down_fixed(total_a, u - alpha)
    new_virtual_balance_b = mul_down_fixed(total_b, u - beta)

    if new_virtual_balance_a == 0 or new_virtual_balance_b == 0:
        raise ValueError("ZeroVirtualBalance")

    return new_virtual_balance_a, new_virtual_balance_b
