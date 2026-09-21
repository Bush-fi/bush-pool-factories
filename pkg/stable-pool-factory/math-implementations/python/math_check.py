"""Maths implementation for stable-pool-factory. See pvt/math-check/README.md for the interface."""
from stable_pool import Stable

# The `poolType` written by pkg/stable-pool-factory/math-check/pool.ts.
POOL_TYPE = "STABLE"


def create_pool(pool):
    return Stable(pool)
