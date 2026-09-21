//! `math_check <test-data-file.json>`: runs the Rust maths against one test-data file through the Vault flow and
//! prints the outcomes as JSON (see lib.rs). The pool and hook types it knows are registered below.
//!
//! Add your pool here after porting its maths into maths/rust/src/pools/<pool>/: match on the `poolType` your
//! adapter (maths/check/adapters/<factory>.ts) reports and build the maths from the recorded pool fields
//! (`PoolJson` gives typed access to them).

use bush_maths::hooks::types::HookState;
use bush_maths::hooks::{StableSurgeHook, StableSurgeHookState};
use bush_maths::pools::constant_sum::ConstantSumPool;
use bush_maths::pools::fixed_price_lbp::{
    FixedPriceLBPImmutable, FixedPriceLBPMutable, FixedPriceLBPPool, FixedPriceLBPState,
};
use bush_maths::pools::liquidity_bootstrapping::{
    LiquidityBootstrappingImmutable, LiquidityBootstrappingMutable, LiquidityBootstrappingPool,
    LiquidityBootstrappingState,
};
use bush_maths::pools::stable::{StableMutable, StablePool};
use bush_maths::pools::weighted::{WeightedPool, WeightedState};
use bush_maths::PoolBase;
use math_check::{Hook, PoolJson};

fn make_pool(pool: &PoolJson) -> Result<Box<dyn PoolBase>, String> {
    let pool_type = pool.s("poolType")?;
    Ok(match pool_type.as_str() {
        // The CoW-specific arithmetic lives in CowRouter, not the pool.
        "WEIGHTED" | "WEIGHTED_8020" | "COW" => Box::new(WeightedPool::from(WeightedState {
            base: pool.base_state(None)?,
            weights: pool.arr("weights")?,
            min_token_balances: pool.arr("minTokenBalances").ok(),
        })),
        // `amp` is the raw, AMP_PRECISION-scaled amplification parameter, as `getAmplificationParameter()` returns it.
        "STABLE" => Box::new(StablePool::new(StableMutable { amp: pool.u("amp")? })),
        "LIQUIDITY_BOOTSTRAPPING" => Box::new(
            LiquidityBootstrappingPool::new(LiquidityBootstrappingState {
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
            })
            .map_err(|e| format!("{e:?}"))?,
        ),
        "FIXED_PRICE_LBP" => Box::new(FixedPriceLBPPool::from(FixedPriceLBPState {
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
        })),
        // Template example.
        "CONSTANT_SUM" => Box::new(ConstantSumPool::new(pool.u("rate")?)),
        other => return Err(format!("no Rust maths registered for poolType {other} (maths/check/rust/src/main.rs)")),
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
