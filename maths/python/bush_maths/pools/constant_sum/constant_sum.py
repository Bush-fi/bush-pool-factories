"""TEMPLATE: exact fixed-point port of contracts/ConstantSumPool.sol, implementing the bush-maths `PoolBase`
interface so the bush-maths Vault flow (token scaling, rates, swap fees, hooks) can run it.

Rules for a port that matches the contract to the wei:
  - use Python ints and the bush-maths fixed-point helpers (mul_down_fixed etc.), never floats or Decimal;
  - mirror every rounding direction of the Solidity (mulDown/mulUp/divDown/divUp) call for call;
  - reproduce every revert as an exception (the check treats "both fail" as a match).
"""
from typing import List

from bush_maths.common.maths import Rounding, div_down_fixed, div_up_fixed, mul_down_fixed, mul_up_fixed
from bush_maths.common.pool_base import PoolBase
from bush_maths.common.swap_params import SwapParams
from bush_maths.common.types import SwapKind

# The Vault's invariant-ratio bounds for unbalanced liquidity operations (ConstantSumPool._MIN/_MAX_INVARIANT_RATIO).
_MIN_INVARIANT_RATIO = 500000000000000000  # 50%
_MAX_INVARIANT_RATIO = 2000000000000000000  # 200%


class ConstantSum(PoolBase):
    def __init__(self, pool_state):
        # How many token1 one token0 is worth, 18 decimals (ConstantSumPool._rate).
        self.rate = pool_state.rate

    def get_maximum_invariant_ratio(self) -> int:
        return _MAX_INVARIANT_RATIO

    def get_minimum_invariant_ratio(self) -> int:
        return _MIN_INVARIANT_RATIO

    # ConstantSumPool.onSwap
    def on_swap(self, swap_params: SwapParams) -> int:
        token0_in = swap_params.index_in == 0
        amount = swap_params.amount_given_scaled18
        if swap_params.swap_kind.value == SwapKind.GIVENIN.value:
            # The user receives the calculated amount: round down.
            return mul_down_fixed(amount, self.rate) if token0_in else div_down_fixed(amount, self.rate)
        # The user pays the calculated amount: round up.
        return div_up_fixed(amount, self.rate) if token0_in else mul_up_fixed(amount, self.rate)

    # ConstantSumPool.computeInvariant: balance0 * rate + balance1
    def compute_invariant(self, balances_live_scaled18: List[int], rounding: Rounding) -> int:
        if rounding.value == Rounding.ROUND_UP.value:
            token0_value = mul_up_fixed(balances_live_scaled18[0], self.rate)
        else:
            token0_value = mul_down_fixed(balances_live_scaled18[0], self.rate)
        return token0_value + balances_live_scaled18[1]

    # ConstantSumPool.computeBalance
    def compute_balance(self, balances_live_scaled18: List[int], token_in_index: int, invariant_ratio: int) -> int:
        new_invariant = mul_up_fixed(self.compute_invariant(balances_live_scaled18, Rounding.ROUND_UP), invariant_ratio)
        if token_in_index == 0:
            return div_up_fixed(new_invariant - balances_live_scaled18[1], self.rate)
        if token_in_index == 1:
            return new_invariant - mul_down_fixed(balances_live_scaled18[0], self.rate)
        raise ValueError("InvalidTokenIndex")
