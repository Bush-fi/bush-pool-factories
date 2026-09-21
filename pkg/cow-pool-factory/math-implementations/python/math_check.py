"""Maths implementation for cow-pool-factory. See pvt/math-check/README.md for the interface."""
from weighted_pool import Weighted

# The `poolType` written by pkg/cow-pool-factory/math-check/pool.ts.
POOL_TYPE = "COW"


def create_pool(pool):
    return Weighted(pool)
