"""Maths implementation for stable-surge-pool-factory. See pvt/math-check/README.md for the interface."""
from src.pools.stable.stable import Stable
from stable_surge_hook import StableSurgeHook
from stable_surge_types import StableSurgeHookState

# The `poolType` / hook written by pkg/stable-surge-pool-factory/math-check/pool.ts.
POOL_TYPE = "STABLE"
HOOK_TYPE = "StableSurge"


def create_pool(pool):
    return Stable(pool)


def create_hook(pool):
    dynamic = pool.hook["dynamicData"]
    state = StableSurgeHookState(
        surge_threshold_percentage=dynamic["surgeThresholdPercentage"],
        max_surge_fee_percentage=dynamic["maxSurgeFeePercentage"],
        amp=pool.amp,
    )
    return StableSurgeHook(), state
