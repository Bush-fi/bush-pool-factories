"""Maths implementation for lbpool-factory. See pvt/math-check/README.md for the interface."""
from liquidity_bootstrapping import LiquidityBootstrapping

# The `poolType` written by pkg/lbpool-factory/math-check/pool.ts.
POOL_TYPE = "LIQUIDITY_BOOTSTRAPPING"


def create_pool(pool):
    return LiquidityBootstrapping(pool)
