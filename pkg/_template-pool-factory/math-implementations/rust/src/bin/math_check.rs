//! TEMPLATE: runs this implementation against bush-maths test data.
//! `cargo run --features math-check --bin math_check -- <test-data-file.json>` (pvt/math-check does this for you).

use bush_maths::PoolBase;
use constant_sum_pool_maths::ConstantSumPool;
use math_check_support::{no_hook, PoolJson};

/// Build the pool maths from the `pool` block of a test-data file. `PoolJson` gives typed access to its fields.
fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    Ok(Box::new(ConstantSumPool::new(pool.u("rate")?)))
}

fn main() {
    // For a pool with a hook, pass a `make_hook` returning `Some(Hook { hook_type, hook, state })` instead of `no_hook`.
    math_check_support::run(make_pool, no_hook);
}
