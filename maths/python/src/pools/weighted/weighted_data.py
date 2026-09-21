from dataclasses import dataclass, fields
from typing import List, Optional

from src.common.base_pool_state import BasePoolState


@dataclass
class WeightedState(BasePoolState):
    weights: List[int]
    # Per-token minimum live balance (scaled 18) enforced by WeightedPool: max(1e6, 10^(18 - decimals)).
    # Read from `getMinTokenBalances()`; defaults from the scaling factors when omitted.
    min_token_balances: Optional[List[int]] = None

    def __init__(self, **kwargs):
        # Set pool_type before initializing BasePoolState
        kwargs["pool_type"] = "WEIGHTED"

        # Get BasePoolState fields
        base_fields = {f.name for f in fields(BasePoolState)}
        base_kwargs = {k: v for k, v in kwargs.items() if k in base_fields}

        # Initialize BasePoolState with its fields
        super().__init__(**base_kwargs)

        # Get WeightedState fields
        custom_fields = {f.name for f in fields(WeightedState)}

        # Set WeightedState fields
        for field in custom_fields:
            if field in kwargs:
                setattr(self, field, kwargs[field])


def map_weighted_state(pool_state: dict) -> WeightedState:
    return WeightedState(
        # BasePoolState fields
        pool_address=pool_state["poolAddress"],
        tokens=pool_state["tokens"],
        scaling_factors=pool_state["scalingFactors"],
        token_rates=pool_state["tokenRates"],
        balances_live_scaled18=pool_state["balancesLiveScaled18"],
        swap_fee=pool_state["swapFee"],
        aggregate_swap_fee=pool_state["aggregateSwapFee"],
        total_supply=pool_state["totalSupply"],
        supports_unbalanced_liquidity=pool_state.get(
            "supportsUnbalancedLiquidity", True
        ),
        hook_type=pool_state.get("hookType", None),
        # WeightedState fields
        weights=pool_state["weights"],
        min_token_balances=pool_state.get("minTokenBalances"),
    )
