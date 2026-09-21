//! Runs this implementation against bush-maths test data: `cargo run --features math-check --bin math_check -- <file>`.

use bush_maths::pools::liquidity_bootstrapping::{
    LiquidityBootstrappingImmutable, LiquidityBootstrappingMutable, LiquidityBootstrappingState,
};
use bush_maths::PoolBase;
use lbpool_maths::LiquidityBootstrappingPool;
use math_check_support::{no_hook, PoolJson};

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    let state = LiquidityBootstrappingState {
        base: pool.base_state(None)?,
        mutable: LiquidityBootstrappingMutable {
            is_swap_enabled: pool.b("isSwapEnabled")?,
            current_timestamp: pool.u("currentTimestamp")?,
        },
        immutable: LiquidityBootstrappingImmutable {
            project_token_index: pool.n("projectTokenIndex")?,
            is_project_token_swap_in_blocked: pool.b("isProjectTokenSwapInBlocked")?,
            start_weights: pool.arr("startWeights")?,
            end_weights: pool.arr("endWeights")?,
            start_time: pool.u("startTime")?,
            end_time: pool.u("endTime")?,
            min_token_balances: pool.arr("minTokenBalances").ok(),
        },
    };
    Ok(Box::new(LiquidityBootstrappingPool::new(state).map_err(|e| format!("{e:?}"))?))
}

fn main() {
    math_check_support::run(make_pool, no_hook);
}
