//! Runs this implementation against bush-maths test data: `cargo run --features math-check --bin math_check -- <file>`.

use bush_maths::pools::fixed_price_lbp::{FixedPriceLBPImmutable, FixedPriceLBPMutable, FixedPriceLBPState};
use bush_maths::PoolBase;
use fixed_price_lbpool_maths::FixedPriceLBPPool;
use math_check_support::{no_hook, PoolJson};

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    let state = FixedPriceLBPState {
        base: pool.base_state(None)?,
        mutable: FixedPriceLBPMutable {
            is_swap_enabled: pool.b("isSwapEnabled")?,
            current_timestamp: pool.u("currentTimestamp")?,
        },
        immutable: FixedPriceLBPImmutable {
            project_token_index: pool.n("projectTokenIndex")?,
            reserve_token_index: pool.n("reserveTokenIndex")?,
            project_token_rate: pool.u("projectTokenRate")?,
            start_time: pool.u("startTime")?,
            end_time: pool.u("endTime")?,
        },
    };
    Ok(Box::new(FixedPriceLBPPool::from(state)))
}

fn main() {
    math_check_support::run(make_pool, no_hook);
}
