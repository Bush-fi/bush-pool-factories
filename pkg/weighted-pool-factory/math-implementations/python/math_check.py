"""Maths implementation for weighted-pool-factory. See pvt/math-check/README.md for the interface."""
from weighted_pool import Weighted

# The `poolType` written by pkg/weighted-pool-factory/math-check/pool.ts.
POOL_TYPE = "WEIGHTED"


def create_pool(pool):
    return Weighted(pool)
