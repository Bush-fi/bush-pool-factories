"""The pool types (and hook types) `maths:check` knows how to build from the `pool` block of a test-data file.

Add your pool here after porting its maths into maths/python/bush_maths/pools/<pool>/: the key is the `poolType` your
adapter (maths/check/adapters/<factory>.ts) reports, the value builds the maths from the recorded pool state
(a BasePoolState with the pool-specific fields attached as snake_case attributes, and the raw JSON under `.raw`).
"""
from bush_maths.hooks.stable_surge.stable_surge_hook import StableSurgeHook
from bush_maths.hooks.stable_surge.types import StableSurgeHookState
from bush_maths.pools.constant_sum.constant_sum import ConstantSum
from bush_maths.pools.fixed_price_lbp.fixed_price_lbp import FixedPriceLBP
from bush_maths.pools.liquidity_bootstrapping.liquidity_bootstrapping import LiquidityBootstrapping
from bush_maths.pools.reclamm.reclamm import ReClamm
from bush_maths.pools.stable.stable import Stable
from bush_maths.pools.weighted.weighted import Weighted

POOLS = {
    "WEIGHTED": Weighted,
    "WEIGHTED_8020": Weighted,
    # The CoW-specific arithmetic lives in CowRouter, not the pool.
    "COW": Weighted,
    "STABLE": Stable,
    "LIQUIDITY_BOOTSTRAPPING": LiquidityBootstrapping,
    "FIXED_PRICE_LBP": FixedPriceLBP,
    "RECLAMM": ReClamm,
    # Template example.
    "CONSTANT_SUM": ConstantSum,
}


def _stable_surge(pool):
    dynamic = pool.hook["dynamicData"]
    state = StableSurgeHookState(
        surge_threshold_percentage=dynamic["surgeThresholdPercentage"],
        max_surge_fee_percentage=dynamic["maxSurgeFeePercentage"],
        amp=pool.amp,
    )
    return StableSurgeHook(), state


# Keyed by the hook `type` the adapter reports. Returns (hook, hook_state); the hook is registered with the Vault
# under `hook_state.hook_type`.
HOOKS = {
    "STABLE_SURGE": _stable_surge,
}
