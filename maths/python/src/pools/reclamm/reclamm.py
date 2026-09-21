"""Port of contracts/reclamm/ReClammPool.sol: the pool-level maths on top of reclamm_math.

A ReClamm pool is a 2-token constant-product pool with virtual balances that bound the price to a range, and that
move over time to re-center the range on the market price. Liquidity can only be added or removed proportionally
(the Vault handles that without the pool), so the pool's job is swaps and the invariant.
"""

from typing import List, Tuple

from src.common.maths import Rounding
from src.common.pool_base import PoolBase
from src.common.swap_params import SwapParams
from src.common.types import SwapKind
from src.pools.reclamm.reclamm_math import (
    PriceRatioState,
    compute_current_virtual_balances,
    compute_in_given_out,
    compute_invariant,
    compute_out_given_in,
)

# ReClammPool._MIN_SWAP_FEE_PERCENTAGE / _MAX_SWAP_FEE_PERCENTAGE
MIN_SWAP_FEE_PERCENTAGE = 1_000_000_000_000  # 0.001%
MAX_SWAP_FEE_PERCENTAGE = 100_000_000_000_000_000  # 10%


class ReClamm(PoolBase):
    def __init__(self, pool_state):
        """`pool_state` carries the ReClammMutable fields (a ReClammState, or any state with those attributes)."""
        self.last_virtual_balance_a, self.last_virtual_balance_b = pool_state.last_virtual_balances
        self.daily_price_shift_base = pool_state.daily_price_shift_base
        self.last_timestamp = pool_state.last_timestamp
        self.centeredness_margin = pool_state.centeredness_margin
        self.price_ratio_state = PriceRatioState(
            start_fourth_root_price_ratio=pool_state.start_fourth_root_price_ratio,
            end_fourth_root_price_ratio=pool_state.end_fourth_root_price_ratio,
            price_ratio_update_start_time=pool_state.price_ratio_update_start_time,
            price_ratio_update_end_time=pool_state.price_ratio_update_end_time,
        )
        self.current_timestamp = pool_state.current_timestamp

    # The invariant ratio bounds are required by the interface but unused: liquidity is proportional only.
    def get_maximum_invariant_ratio(self) -> int:
        return 0

    def get_minimum_invariant_ratio(self) -> int:
        return 0

    def on_swap(self, swap_params: SwapParams) -> int:
        """ReClammPool.onSwap."""
        balances = swap_params.balances_live_scaled18
        virtual_a, virtual_b, _ = self.current_virtual_balances(balances)
        if swap_params.swap_kind.value == SwapKind.GIVENIN.value:
            return compute_out_given_in(
                balances, virtual_a, virtual_b, swap_params.index_in, swap_params.index_out, swap_params.amount_given_scaled18
            )
        return compute_in_given_out(
            balances, virtual_a, virtual_b, swap_params.index_in, swap_params.index_out, swap_params.amount_given_scaled18
        )

    def compute_invariant(self, balances_live_scaled18: List[int], rounding: Rounding) -> int:
        """ReClammPool.computeInvariant."""
        virtual_a, virtual_b, _ = self.current_virtual_balances(balances_live_scaled18)
        return compute_invariant(balances_live_scaled18, virtual_a, virtual_b, rounding)

    def compute_balance(self, balances_live_scaled18: List[int], token_in_index: int, invariant_ratio: int) -> int:
        """ReClammPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced adds and removes."""
        raise NotImplementedError("NotImplemented")

    def current_virtual_balances(self, balances_live_scaled18: List[int]) -> Tuple[int, int, bool]:
        """ReClammPool._computeCurrentVirtualBalances: the virtual balances as of `current_timestamp`."""
        return compute_current_virtual_balances(
            balances_live_scaled18,
            self.last_virtual_balance_a,
            self.last_virtual_balance_b,
            self.daily_price_shift_base,
            self.last_timestamp,
            self.centeredness_margin,
            self.price_ratio_state,
            self.current_timestamp,
        )
