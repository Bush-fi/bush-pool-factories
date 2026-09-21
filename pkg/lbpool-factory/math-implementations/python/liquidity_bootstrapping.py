"""Exact fixed-point port of Bush's LBPool.sol (pool-weighted/contracts/lbp/LBPool.sol): a two-token WeightedPool
whose weights move linearly between a start and an end weight during the sale (GradualValueChange), with swaps only
enabled during the sale and optionally blocked for selling the project token back in. The weighted maths is reused
from bush-maths; the weight schedule is ported in liquidity_bootstrapping_math.py. Only seeded LBPs (no reserve
virtual balance) are modelled. See pvt/math-check/README.md.
"""
from src.common.swap_params import SwapParams
from liquidity_bootstrapping_math import (
    get_normalized_weights,
)
from src.pools.weighted.weighted import Weighted, compute_min_token_balances


class LiquidityBootstrapping(Weighted):
    def __init__(self, pool_state):  # pylint: disable=super-init-not-called
        project_token_start_weight = pool_state.start_weights[
            pool_state.project_token_index
        ]
        project_token_end_weight = pool_state.end_weights[
            pool_state.project_token_index
        ]
        current_time = pool_state.current_timestamp
        weights = get_normalized_weights(
            pool_state.project_token_index,
            current_time,
            pool_state.start_time,
            pool_state.end_time,
            project_token_start_weight,
            project_token_end_weight,
        )
        self.normalized_weights = weights
        self.min_token_balances = (
            pool_state.min_token_balances
            if getattr(pool_state, "min_token_balances", None) is not None
            else compute_min_token_balances(pool_state.scaling_factors)
        )
        self.lbp_state = pool_state

    def on_swap(self, swap_params: SwapParams) -> int:
        if not self.lbp_state.is_swap_enabled:
            raise ValueError("Swap is not enabled")
        if (
            self.lbp_state.is_project_token_swap_in_blocked
            and swap_params.index_in == self.lbp_state.project_token_index
        ):
            raise ValueError("Project token swap in is blocked")
        return super().on_swap(swap_params)
