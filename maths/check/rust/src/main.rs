//! `math_check <test-data-file.json>`: runs the Rust maths against one test-data file through the Vault flow and
//! prints the outcomes as JSON (see lib.rs).
//!
//! Pool types the library knows are built through `bush_maths::pools::state_from_json` — that is where a new pool
//! is registered (a `PoolState` variant, a `from_json` on its state, one match arm). `make_pool` below only lists
//! pools that live outside the library, like the template example, so they can be checked before being merged.

use bush_maths::hooks::types::HookState;
use bush_maths::hooks::{StableSurgeHook, StableSurgeHookState};
use bush_maths::pools::constant_sum::ConstantSumPool;
use bush_maths::pools::state_from_json;
use bush_maths::{PoolBase, Vault};
use math_check::{Hook, PoolJson};

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    Ok(match pool.s("poolType")?.as_str() {
        // Template example.
        "CONSTANT_SUM" => Box::new(ConstantSumPool::new(pool.u("rate")?)),
        _ => Vault::get_pool(&state_from_json(pool, None)?).map_err(|e| format!("{e:?}"))?,
    })
}

/// Keyed by the hook `type` the adapter reports.
fn make_hook(pool: &PoolJson) -> Result<Option<Hook>, String> {
    let Some(hook) = pool.hook() else { return Ok(None) };
    match hook.s("type")?.as_str() {
        "STABLE_SURGE" => {
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
        other => Err(format!("no Rust maths registered for hook type {other} (maths/check/rust/src/main.rs)")),
    }
}

fn main() {
    math_check::run(make_pool, make_hook);
}
