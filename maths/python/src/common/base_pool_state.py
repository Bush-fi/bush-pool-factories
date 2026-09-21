import re
from dataclasses import dataclass, fields
from typing import List, Optional


@dataclass
class BasePoolState:
    pool_address: str
    pool_type: str
    tokens: List[str]
    scaling_factors: List[int]
    token_rates: List[int]
    balances_live_scaled18: List[int]
    swap_fee: int
    aggregate_swap_fee: int
    total_supply: int
    supports_unbalanced_liquidity: bool
    hook_type: Optional[str]


def snake_case(name: str) -> str:
    """camelCase → snake_case, as the JSON keys of a test-data file map to dataclass fields."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def pool_state_from_json(pool: dict, hook_type: Optional[str] = None) -> BasePoolState:
    """
    The `pool` block of a test-data file (numeric strings already converted to int) → a BasePoolState with every
    pool-specific field attached as a snake_case attribute (`state.weights`, `state.amp`, `state.last_timestamp`,
    …) and the raw block under `state.raw`. Generic: a new pool type needs nothing here, its pool class simply reads
    the fields its adapter wrote.
    """
    state = BasePoolState(
        pool_address=pool["poolAddress"],
        pool_type=pool["poolType"],
        tokens=pool["tokens"],
        scaling_factors=pool["scalingFactors"],
        token_rates=pool["tokenRates"],
        balances_live_scaled18=pool["balancesLiveScaled18"],
        swap_fee=pool["swapFee"],
        aggregate_swap_fee=pool.get("aggregateSwapFee", 0),
        total_supply=pool["totalSupply"],
        supports_unbalanced_liquidity=pool.get("supportsUnbalancedLiquidity", True),
        hook_type=hook_type,
    )
    base = {f.name for f in fields(BasePoolState)}
    for key, value in pool.items():
        name = snake_case(key)
        if name not in base:
            setattr(state, name, value)
    state.raw = pool
    return state
