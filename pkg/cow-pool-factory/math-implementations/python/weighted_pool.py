"""Exact fixed-point port of the pool deployed by cow-pool-factory: CowPoolFactory deploys CowPool, which is WeightedPool plus a trusted-router check.
The WeightedMath library port is reused from bush-maths (the same library as on-chain); this file is Bush's
WeightedPool.sol on top of it, implementing the bush-maths `PoolBase` interface. See pvt/math-check/README.md.
"""
from typing import List

from src.common.maths import Rounding
from src.common.pool_base import PoolBase
from src.common.swap_params import SwapParams
from src.common.types import SwapKind
from src.pools.weighted.weighted_math import (
    _MAX_INVARIANT_RATIO,
    _MIN_INVARIANT_RATIO,
    compute_balance_out_given_invariant,
    compute_in_given_exact_out,
    compute_invariant_down,
    compute_invariant_up,
    compute_out_given_exact_in,
)


# MinTokenBalanceLib.ABSOLUTE_MIN_TOKEN_BALANCE
ABSOLUTE_MIN_TOKEN_BALANCE = 1_000_000


def compute_min_token_balances(scaling_factors: List[int]) -> List[int]:
    """MinTokenBalanceLib.computeMinTokenBalances: max(1e6, 10^(18 - decimals)) per token."""
    return [max(ABSOLUTE_MIN_TOKEN_BALANCE, sf) for sf in scaling_factors]


class Weighted(PoolBase):
    def __init__(self, pool_state):
        self.normalized_weights = pool_state.weights
        self.min_token_balances = (
            pool_state.min_token_balances
            if getattr(pool_state, "min_token_balances", None) is not None
            else compute_min_token_balances(pool_state.scaling_factors)
        )

    def _ensure_minimum_balance(self, token_index: int, ending_balance_scaled18: int) -> None:
        """WeightedPool._ensureMinimumBalance"""
        if ending_balance_scaled18 < self.min_token_balances[token_index]:
            raise ValueError("TokenBalanceBelowMin")

    def _ensure_min_token_balances(self, balances_live_scaled18: List[int]) -> None:
        """WeightedPool._ensureMinTokenBalances"""
        for i, balance in enumerate(balances_live_scaled18):
            self._ensure_minimum_balance(i, balance)

    def get_maximum_invariant_ratio(self) -> int:
        return _MAX_INVARIANT_RATIO

    def get_minimum_invariant_ratio(self) -> int:
        return _MIN_INVARIANT_RATIO

    def on_swap(self, swap_params: SwapParams) -> int:
        index_in, index_out = swap_params.index_in, swap_params.index_out
        # WeightedPool.onSwap rounds the token-in balance up on both ExactIn and ExactOut swaps.
        balance_token_in_scaled18 = swap_params.balances_live_scaled18[index_in] + 1
        balance_token_out_scaled18 = swap_params.balances_live_scaled18[index_out]
        self._ensure_minimum_balance(index_in, balance_token_in_scaled18)

        if swap_params.swap_kind.value == SwapKind.GIVENIN.value:
            calculated_amount_scaled18 = compute_out_given_exact_in(
                balance_token_in_scaled18,
                self.normalized_weights[index_in],
                balance_token_out_scaled18,
                self.normalized_weights[index_out],
                swap_params.amount_given_scaled18,
            )
            amount_out_scaled18 = calculated_amount_scaled18
        else:
            calculated_amount_scaled18 = compute_in_given_exact_out(
                balance_token_in_scaled18,
                self.normalized_weights[index_in],
                balance_token_out_scaled18,
                self.normalized_weights[index_out],
                swap_params.amount_given_scaled18,
            )
            amount_out_scaled18 = swap_params.amount_given_scaled18

        # The swap must not drop the token-out balance below the minimum.
        self._ensure_minimum_balance(
            index_out, balance_token_out_scaled18 - amount_out_scaled18
        )
        return calculated_amount_scaled18

    def compute_invariant(
        self, balances_live_scaled18: List[int], rounding: Rounding
    ) -> int:
        self._ensure_min_token_balances(balances_live_scaled18)
        if rounding.value == Rounding.ROUND_UP.value:
            return compute_invariant_up(self.normalized_weights, balances_live_scaled18)

        return compute_invariant_down(self.normalized_weights, balances_live_scaled18)

    def compute_balance(
        self,
        balances_live_scaled18: List[int],
        token_in_index: int,
        invariant_ratio: int,
    ) -> int:
        original_balance = balances_live_scaled18[token_in_index]
        new_balance = compute_balance_out_given_invariant(
            original_balance,
            self.normalized_weights[token_in_index],
            invariant_ratio,
        )
        # WeightedPool.computeBalance: whichever of the two balances is lower must stay above the minimum.
        self._ensure_minimum_balance(token_in_index, min(original_balance, new_balance))
        return new_balance
