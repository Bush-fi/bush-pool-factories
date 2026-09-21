from src.hooks.stable_surge.types import (
    StableSurgeHookState,
    map_stable_surge_hook_state,
)
from src.hooks.types import HookState


def map_hook_state(hook_data: dict, pool_data: dict) -> HookState:
    """
    Maps hook data from JSON to typed HookState objects.

    This function serves as a central dispatcher that converts raw hook data
    from test JSON files into strongly-typed HookState objects based on the
    hook type.

    Args:
        hook_data: Raw hook dict from JSON with fields:
            - type: Hook type identifier (e.g., "STABLE_SURGE")
            - dynamicData: Hook-specific parameters (varies by type)
            - address: Hook contract address
            - Configuration flags (shouldCallAfterSwap, etc.)
        pool_data: Pool dict with fields needed by hooks:
            - tokens: List of token addresses
            - amp: Amplification parameter (for stable pools with STABLE_SURGE)

    Returns:
        Typed HookState object (StableSurgeHookState)

    Raises:
        ValueError: If hook type is unsupported or required fields are missing
    """
    hook_type = hook_data.get("type")

    if hook_type == "STABLE_SURGE":
        return _map_stable_surge_hook(hook_data, pool_data)
    else:
        raise ValueError(f"Unsupported hook type: {hook_type}")


def _map_stable_surge_hook(hook_data: dict, pool_data: dict) -> StableSurgeHookState:
    """Maps STABLE_SURGE hook data to StableSurgeHookState."""
    if "dynamicData" not in hook_data:
        raise ValueError("STABLE_SURGE hook requires dynamicData")

    dynamic_data = hook_data["dynamicData"]

    if "surgeThresholdPercentage" not in dynamic_data:
        raise ValueError(
            "STABLE_SURGE hook requires surgeThresholdPercentage in dynamicData"
        )
    if "maxSurgeFeePercentage" not in dynamic_data:
        raise ValueError(
            "STABLE_SURGE hook requires maxSurgeFeePercentage in dynamicData"
        )
    if "amp" not in pool_data:
        raise ValueError("STABLE_SURGE hook requires amp from pool data")

    return map_stable_surge_hook_state(
        {
            "surgeThresholdPercentage": dynamic_data["surgeThresholdPercentage"],
            "maxSurgeFeePercentage": dynamic_data["maxSurgeFeePercentage"],
            "amp": pool_data["amp"],
        }
    )

