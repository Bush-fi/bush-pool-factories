"""Maths implementation for weighted-8020-pool-factory. See pvt/math-check/README.md for the interface."""
from weighted_pool import Weighted

# The `poolType` written by pkg/weighted-8020-pool-factory/math-check/pool.ts.
POOL_TYPE = "WEIGHTED_8020"


def create_pool(pool):
    return Weighted(pool)
