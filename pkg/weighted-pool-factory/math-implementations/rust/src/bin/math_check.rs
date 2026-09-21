//! Runs this implementation against bush-maths test data: `cargo run --features math-check --bin math_check -- <file>`.

use bush_maths::pools::weighted::WeightedState;
use bush_maths::PoolBase;
use math_check_support::{no_hook, PoolJson};
use weighted_pool_maths::WeightedPool;

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    let state = WeightedState {
        base: pool.base_state(None)?,
        weights: pool.arr("weights")?,
        min_token_balances: pool.arr("minTokenBalances").ok(),
    };
    Ok(Box::new(WeightedPool::from(state)))
}

fn main() {
    math_check_support::run(make_pool, no_hook);
}
