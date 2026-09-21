"""Maths implementation for fixed-price-lbpool-factory. See pvt/math-check/README.md for the interface."""
from fixed_price_lbp import FixedPriceLBP

# The `poolType` written by pkg/fixed-price-lbpool-factory/math-check/pool.ts.
POOL_TYPE = "FIXED_PRICE_LBP"


def create_pool(pool):
    return FixedPriceLBP(pool)
