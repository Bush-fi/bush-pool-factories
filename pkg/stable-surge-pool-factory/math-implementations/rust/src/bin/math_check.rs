//! Runs this implementation against bush-maths test data: `cargo run --features math-check --bin math_check -- <file>`.

use bush_maths::hooks::types::HookState;
use bush_maths::hooks::StableSurgeHookState;
use bush_maths::pools::stable::{StableMutable, StablePool};
use bush_maths::PoolBase;
use math_check_support::{Hook, PoolJson};
use stable_surge_pool_maths::StableSurgeHook;

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    Ok(Box::new(StablePool::new(StableMutable { amp: pool.u("amp")? })))
}

fn make_hook(pool: &PoolJson) -> Result<Option<Hook>, String> {
    let Some(hook) = pool.hook() else { return Ok(None) };
    let dynamic = PoolJson(hook.0["dynamicData"].clone());
    let state = StableSurgeHookState {
        hook_type: "StableSurge".to_string(),
        amp: pool.u("amp")?,
        surge_threshold_percentage: dynamic.u("surgeThresholdPercentage")?,
        max_surge_fee_percentage: dynamic.u("maxSurgeFeePercentage")?,
    };
    Ok(Some(Hook {
        hook_type: "StableSurge".to_string(),
        hook: Box::new(StableSurgeHook::new()),
        state: HookState::StableSurge(state),
    }))
}

fn main() {
    math_check_support::run(make_pool, make_hook);
}
