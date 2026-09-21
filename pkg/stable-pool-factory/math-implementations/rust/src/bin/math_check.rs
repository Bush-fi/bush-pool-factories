//! Runs this implementation against bush-maths test data: `cargo run --features math-check --bin math_check -- <file>`.

use bush_maths::pools::stable::StableMutable;
use bush_maths::PoolBase;
use math_check_support::{no_hook, PoolJson};
use stable_pool_maths::StablePool;

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    Ok(Box::new(StablePool::new(StableMutable { amp: pool.u("amp")? })))
}

fn main() {
    math_check_support::run(make_pool, no_hook);
}
