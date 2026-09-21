//! Shared test helpers.

use bush_maths::common::types::PoolState;

/// The pool address a liquidity operation targets.
#[allow(dead_code)]
pub fn get_pool_address(pool: &PoolState) -> String {
    pool.base().pool_address.clone()
}
