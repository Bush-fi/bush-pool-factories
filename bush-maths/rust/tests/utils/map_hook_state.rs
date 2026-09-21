//! Maps hook data from JSON test files into typed HookState objects

use alloy_primitives::U256;
use bush_maths::hooks::types::HookState;
use bush_maths::hooks::StableSurgeHookState;

use super::read_test_data::HookData;

/// Pool data needed for hook state mapping
#[allow(dead_code)]
pub struct PoolData {
    pub tokens: Vec<String>,
    pub amp: Option<U256>,
    pub weights: Option<Vec<U256>>,
    pub swap_fee: U256,
}

/// Maps hook data from JSON test files into typed HookState objects
/// that can be used with hook implementations
pub fn map_hook_state(
    hook_data: &HookData,
    pool_data: &PoolData,
) -> Result<HookState, Box<dyn std::error::Error>> {
    match hook_data.hook_type.as_str() {
        "STABLE_SURGE" => map_stable_surge_hook_state(hook_data, pool_data),
        _ => Err(format!("Unsupported hook type: {}", hook_data.hook_type).into()),
    }
}


fn map_stable_surge_hook_state(
    hook_data: &HookData,
    pool_data: &PoolData,
) -> Result<HookState, Box<dyn std::error::Error>> {
    let dynamic_data = &hook_data.dynamic_data;

    let surge_threshold_percentage = dynamic_data["surgeThresholdPercentage"]
        .as_str()
        .ok_or("STABLE_SURGE hook requires surgeThresholdPercentage in dynamicData")?
        .parse::<U256>()?;

    let max_surge_fee_percentage = dynamic_data["maxSurgeFeePercentage"]
        .as_str()
        .ok_or("STABLE_SURGE hook requires maxSurgeFeePercentage in dynamicData")?
        .parse::<U256>()?;

    let amp = pool_data
        .amp
        .ok_or("STABLE_SURGE hook requires amp from pool data")?;

    Ok(HookState::StableSurge(StableSurgeHookState {
        hook_type: "StableSurge".to_string(),
        amp,
        surge_threshold_percentage,
        max_surge_fee_percentage,
    }))
}

