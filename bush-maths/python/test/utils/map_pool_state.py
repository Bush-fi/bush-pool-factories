from test.utils.map_hook_state import map_hook_state

from src.common.types import PoolState
from src.hooks.types import HookState
from src.pools.fixed_price_lbp.fixed_price_lbp_data import map_fixed_price_lbp_state
from src.pools.liquidity_bootstrapping.liquidity_bootstrapping_data import (
    map_liquidity_bootstrapping_state,
)
from src.pools.stable.stable_data import map_stable_state
from src.pools.weighted.weighted_data import map_weighted_state


def map_pool_state(pool_state: dict) -> PoolState:
    if pool_state["poolType"] == "LIQUIDITY_BOOTSTRAPPING":
        return map_liquidity_bootstrapping_state(pool_state)
    elif pool_state["poolType"] == "STABLE":
        return map_stable_state(pool_state)
    elif pool_state["poolType"] in ("WEIGHTED", "WEIGHTED_8020", "COW"):
        return map_weighted_state(pool_state)
    elif pool_state["poolType"] == "FIXED_PRICE_LBP":
        return map_fixed_price_lbp_state(pool_state)
    else:
        raise ValueError(f"Unsupported pool type: {pool_state['poolType']}")


def transform_strings_to_ints(pool_with_strings):
    pool_with_ints = {}
    for key, value in pool_with_strings.items():
        if isinstance(value, dict):
            # Recursively transform nested dictionaries (e.g., hook object)
            pool_with_ints[key] = transform_strings_to_ints(value)
        elif isinstance(value, list):
            # Convert each element in the list to an integer, handling exceptions
            int_list = []
            for item in value:
                try:
                    int_list.append(int(item))
                except ValueError:
                    int_list = value
                    break
            pool_with_ints[key] = int_list
        else:
            try:
                pool_with_ints[key] = int(value)
            except (ValueError, TypeError):
                pool_with_ints[key] = value
    return pool_with_ints


def map_pool_and_hook_state(
    pool: dict,
) -> tuple[PoolState, HookState | None]:
    """
    Maps pool data to pool state and hook state (if present).

    This function maps both the pool state and any associated hook state from
    the raw pool dictionary. Hook data is extracted and mapped only for pool
    types that support hooks (STABLE and WEIGHTED).

    Args:
        pool: Pool dict from JSON (already converted to ints via transform_strings_to_ints)

    Returns:
        Tuple of (pool_state, hook_state or None)
        - pool_state: Mapped PoolState or BufferState
        - hook_state: Mapped HookState if hook exists and pool supports it, None otherwise
    """
    # First, map the pool state
    pool_state = map_pool_state(pool)

    # Check if pool has hook data
    hook_data = pool.get("hook")
    if not hook_data:
        return (pool_state, None)

    # Map the hook state using the centralized mapper
    try:
        hook_state = map_hook_state(hook_data, pool)
        # Update pool state's hook_type so the vault can instantiate the correct hook
        pool_state.hook_type = hook_state.hook_type
        return (pool_state, hook_state)
    except (KeyError, ValueError) as e:
        # If hook mapping fails, raise with context about which pool failed
        raise ValueError(
            f"Failed to map hook state for pool {pool.get('poolAddress', 'unknown')}: {e}"
        ) from e
