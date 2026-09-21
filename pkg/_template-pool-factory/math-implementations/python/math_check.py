"""TEMPLATE: the entry point pvt/math-check loads. See pvt/math-check/README.md."""
from constant_sum_pool import ConstantSum

# Must equal the `poolType` returned by math-check/pool.ts.
POOL_TYPE = "CONSTANT_SUM"


def create_pool(pool):
    """`pool` is a BasePoolState with the pool-specific fields attached as snake_case attributes (here: pool.rate)."""
    return ConstantSum(pool)


# For a pool with a hook, also define:
#   HOOK_TYPE = "MyHook"
#   def create_hook(pool): return MyHook(), MyHookState(...)
