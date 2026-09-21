//! Read and parse test data from JSON files

use alloy_primitives::U256;
use bush_maths::common::types::BasePoolState;
use bush_maths::hooks::types::HookState;
use bush_maths::pools::weighted::weighted_data::WeightedState;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// Stable pool state for test data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StableState {
    pub base: BasePoolState,
    pub mutable: StableMutable,
}

/// Stable pool mutable state for test data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StableMutable {
    pub amp: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidityBootstrappingMutable {
    #[serde(rename = "isSwapEnabled")]
    pub is_swap_enabled: bool,
    #[serde(rename = "currentTimestamp")]
    pub current_timestamp: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidityBootstrappingImmutable {
    #[serde(rename = "projectTokenIndex")]
    pub project_token_index: usize,
    #[serde(rename = "isProjectTokenSwapInBlocked")]
    pub is_project_token_swap_in_blocked: bool,
    #[serde(rename = "startWeights")]
    pub start_weights: Vec<U256>,
    #[serde(rename = "endWeights")]
    pub end_weights: Vec<U256>,
    #[serde(rename = "startTime")]
    pub start_time: U256,
    #[serde(rename = "endTime")]
    pub end_time: U256,
    #[serde(rename = "minTokenBalances")]
    pub min_token_balances: Option<Vec<U256>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidityBootstrappingState {
    pub base: BasePoolState,
    pub mutable: LiquidityBootstrappingMutable,
    pub immutable: LiquidityBootstrappingImmutable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixedPriceLBPMutable {
    #[serde(rename = "isSwapEnabled")]
    pub is_swap_enabled: bool,
    #[serde(rename = "currentTimestamp")]
    pub current_timestamp: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixedPriceLBPImmutable {
    #[serde(rename = "projectTokenIndex")]
    pub project_token_index: usize,
    #[serde(rename = "reserveTokenIndex")]
    pub reserve_token_index: usize,
    #[serde(rename = "projectTokenRate")]
    pub project_token_rate: U256,
    #[serde(rename = "startTime")]
    pub start_time: U256,
    #[serde(rename = "endTime")]
    pub end_time: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixedPriceLBPState {
    pub base: BasePoolState,
    pub mutable: FixedPriceLBPMutable,
    pub immutable: FixedPriceLBPImmutable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookData {
    pub address: String,
    #[serde(rename = "type")]
    pub hook_type: String,
    #[serde(rename = "dynamicData")]
    pub dynamic_data: serde_json::Value,
}

/// Base pool information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoolBase {
    pub chain_id: u64,
    pub block_number: u64,
    pub pool_address: String,
}

/// Weighted pool with base information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeightedPool {
    #[serde(flatten)]
    pub base: PoolBase,
    #[serde(flatten)]
    pub state: WeightedState,
}

/// Stable pool with base information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StablePool {
    #[serde(flatten)]
    pub base: PoolBase,
    #[serde(flatten)]
    pub state: StableState,
}



/// Liquidity Bootstrapping pool with base information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidityBootstrappingPool {
    #[serde(flatten)]
    pub base: PoolBase,
    #[serde(flatten)]
    pub state: LiquidityBootstrappingState,
}

/// FixedPriceLBP pool with base information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixedPriceLBPPool {
    #[serde(flatten)]
    pub base: PoolBase,
    #[serde(flatten)]
    pub state: FixedPriceLBPState,
}




/// Supported pool types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SupportedPool {
    Weighted(WeightedPool),
    Stable(StablePool),
    LiquidityBootstrapping(LiquidityBootstrappingPool),
    FixedPriceLBP(FixedPriceLBPPool),
    // Add other pool types as needed
}

/// Swap test data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Swap {
    pub swap_kind: u8,
    pub amount_raw: U256,
    pub output_raw: U256,
    pub token_in: String,
    pub token_out: String,
    pub test: String,
}

/// Add liquidity test data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Add {
    pub kind: u8,
    pub input_amounts_raw: Vec<U256>,
    pub bpt_out_raw: U256,
    pub test: String,
}

/// Remove liquidity test data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Remove {
    pub kind: u8,
    pub amounts_out_raw: Vec<U256>,
    pub bpt_in_raw: U256,
    pub test: String,
}

/// Complete test data structure
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TestData {
    pub swaps: Vec<Swap>,
    pub adds: Vec<Add>,
    pub removes: Vec<Remove>,
    pub pools: HashMap<String, SupportedPool>,
    /// Hook state per test file (keyed like `pools`), for pools that have a hook.
    pub hook_states: HashMap<String, HookState>,
}

/// Raw JSON structure for parsing
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RawTestFile {
    swaps: Option<Vec<RawSwap>>,
    adds: Option<Vec<RawAdd>>,
    removes: Option<Vec<RawRemove>>,
    pool: RawPool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RawSwap {
    #[serde(rename = "swapKind")]
    swap_kind: u8,
    #[serde(rename = "amountRaw")]
    amount_raw: String,
    #[serde(rename = "outputRaw")]
    output_raw: String,
    #[serde(rename = "tokenIn")]
    token_in: String,
    #[serde(rename = "tokenOut")]
    token_out: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RawAdd {
    kind: String,
    #[serde(rename = "inputAmountsRaw")]
    input_amounts_raw: Vec<String>,
    #[serde(rename = "bptOutRaw")]
    bpt_out_raw: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RawRemove {
    kind: String,
    #[serde(rename = "amountsOutRaw")]
    amounts_out_raw: Vec<String>,
    #[serde(rename = "bptInRaw")]
    bpt_in_raw: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RawPool {
    #[serde(rename = "poolType")]
    pub pool_type: String,
    #[serde(rename = "chainId")]
    pub chain_id: String,
    #[serde(rename = "blockNumber")]
    pub block_number: String,
    #[serde(rename = "poolAddress")]
    pub pool_address: String,
    pub tokens: Vec<String>,
    #[serde(rename = "scalingFactors", default = "default_scaling_factors")]
    pub scaling_factors: Vec<String>,
    #[serde(rename = "swapFee", default = "default_swap_fee")]
    pub swap_fee: String,
    #[serde(rename = "balancesLiveScaled18", default = "default_balances")]
    pub balances_live_scaled_18: Vec<String>,
    #[serde(rename = "tokenRates", default = "default_token_rates")]
    pub token_rates: Vec<String>,
    #[serde(rename = "totalSupply", default = "default_total_supply")]
    pub total_supply: String,
    #[serde(rename = "aggregateSwapFee")]
    pub aggregate_swap_fee: Option<String>,
    #[serde(rename = "supportsUnbalancedLiquidity")]
    pub supports_unbalanced_liquidity: Option<bool>,
    // Weighted pool specific fields
    pub weights: Option<Vec<String>>,
    #[serde(rename = "minTokenBalances")]
    pub min_token_balances: Option<Vec<String>>,
    // Stable pool specific fields
    pub amp: Option<String>,
    // Liquidity Bootstrapping specific fields
    #[serde(rename = "projectTokenIndex")]
    pub project_token_index: Option<serde_json::Value>,
    #[serde(rename = "isProjectTokenSwapInBlocked")]
    pub is_project_token_swap_in_blocked: Option<bool>,
    #[serde(rename = "startWeights")]
    pub start_weights: Option<Vec<String>>,
    #[serde(rename = "endWeights")]
    pub end_weights: Option<Vec<String>>,
    #[serde(rename = "startTime")]
    pub start_time: Option<String>,
    #[serde(rename = "endTime")]
    pub end_time: Option<String>,
    #[serde(rename = "isSwapEnabled")]
    pub is_swap_enabled: Option<bool>,
    #[serde(rename = "currentTimestamp")]
    pub current_timestamp: Option<String>,
    // FixedPriceLBP specific fields
    #[serde(rename = "reserveTokenIndex")]
    pub reserve_token_index: Option<serde_json::Value>,
    #[serde(rename = "projectTokenRate")]
    pub project_token_rate: Option<String>,
    // Hook data
    pub hook: Option<HookData>,
}

// Default functions for serde
fn default_scaling_factors() -> Vec<String> {
    vec!["1".to_string(), "1".to_string()]
}

fn default_swap_fee() -> String {
    "0".to_string()
}

fn default_balances() -> Vec<String> {
    vec!["0".to_string(), "0".to_string()]
}

fn default_token_rates() -> Vec<String> {
    vec![
        "1000000000000000000".to_string(),
        "1000000000000000000".to_string(),
    ]
}

fn default_total_supply() -> String {
    "0".to_string()
}

/// Read test data from JSON files in the testData directory
pub fn read_test_data() -> Result<TestData, Box<dyn std::error::Error>> {
    let mut pools: HashMap<String, SupportedPool> = HashMap::new();
    let mut swaps: Vec<Swap> = Vec::new();
    let mut adds: Vec<Add> = Vec::new();
    let mut removes: Vec<Remove> = Vec::new();
    let mut hook_states: HashMap<String, HookState> = HashMap::new();

    // Resolve the directory path relative to the current file's directory
    let absolute_directory_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("testData");

    // Read all files in the directory
    let entries = fs::read_dir(absolute_directory_path)?;

    // Iterate over each file
    for entry in entries {
        let entry = entry?;
        let file_path = entry.path();
        // Check if the file ends with .json
        if let Some(extension) = file_path.extension() {
            if extension == "json" {
                let filename = file_path.file_name().unwrap().to_string_lossy().to_string();
                // Read the file content
                let file_content = fs::read_to_string(&file_path)?;
                // Parse the JSON content
                match serde_json::from_str::<RawTestFile>(&file_content) {
                    Ok(json_data) => {
                        // Process swaps
                        if let Some(raw_swaps) = json_data.swaps {
                            for raw_swap in raw_swaps {
                                swaps.push(Swap {
                                    swap_kind: raw_swap.swap_kind,
                                    amount_raw: raw_swap.amount_raw.parse()?,
                                    output_raw: raw_swap.output_raw.parse()?,
                                    token_in: raw_swap.token_in,
                                    token_out: raw_swap.token_out,
                                    test: filename.clone(),
                                });
                            }
                        }
                        // Process adds
                        if let Some(raw_adds) = json_data.adds {
                            for raw_add in raw_adds {
                                adds.push(Add {
                                    kind: if raw_add.kind == "Unbalanced" { 0 } else { 1 },
                                    input_amounts_raw: raw_add
                                        .input_amounts_raw
                                        .into_iter()
                                        .map(|a| a.parse())
                                        .collect::<Result<Vec<U256>, _>>()?,
                                    bpt_out_raw: raw_add.bpt_out_raw.parse()?,
                                    test: filename.clone(),
                                });
                            }
                        }
                        // Process removes
                        if let Some(raw_removes) = json_data.removes {
                            for raw_remove in raw_removes {
                                removes.push(Remove {
                                    kind: map_remove_kind(&raw_remove.kind),
                                    amounts_out_raw: raw_remove
                                        .amounts_out_raw
                                        .into_iter()
                                        .map(|a| a.parse())
                                        .collect::<Result<Vec<U256>, _>>()?,
                                    bpt_in_raw: raw_remove.bpt_in_raw.parse()?,
                                    test: filename.clone(),
                                });
                            }
                        }
                        // Process pool
                        let pool = map_pool(json_data.pool.clone())?;
                        pools.insert(filename.clone(), pool);

                        // Parse hook state if present
                        {
                            if let Some(hook_data) = &json_data.pool.hook {
                                // Prepare pool data for hook state mapping
                                let amp = if json_data.pool.pool_type == "STABLE" {
                                    json_data
                                        .pool
                                        .amp
                                        .as_ref()
                                        .and_then(|a| a.parse::<U256>().ok())
                                } else {
                                    None
                                };

                                let weights = json_data
                                    .pool
                                    .weights
                                    .as_ref()
                                    .map(|w| {
                                        w.iter()
                                            .map(|w_str| w_str.parse::<U256>())
                                            .collect::<Result<Vec<U256>, _>>()
                                    })
                                    .transpose()?;

                                let swap_fee = json_data.pool.swap_fee.parse::<U256>()?;

                                let pool_data = crate::utils::PoolData {
                                    tokens: json_data.pool.tokens.clone(),
                                    amp,
                                    weights,
                                    swap_fee,
                                };

                                // Map hook state using helper function
                                let hook_state = crate::utils::map_hook_state(hook_data, &pool_data)?;

                                // Update the pool's hook_type field to match the hook
                                // This is needed for the vault to recognize the hook type
                                if let Some(pool) = pools.get_mut(&filename) {
                                    let hook_type_name = match &hook_state {
                                        HookState::StableSurge(_) => Some("StableSurge".to_string()),
                                        HookState::Custom(state) => Some(state.hook_type.clone()),
                                    };

                                    if let Some(hook_type) = hook_type_name {
                                        match pool {
                                            SupportedPool::Weighted(weighted_pool) => {
                                                weighted_pool.state.base.hook_type =
                                                    Some(hook_type);
                                            }
                                            SupportedPool::Stable(stable_pool) => {
                                                stable_pool.state.base.hook_type = Some(hook_type);
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                                hook_states.insert(filename.clone(), hook_state);
                            }
                        }
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
        }
    }

    Ok(TestData {
        swaps,
        adds,
        removes,
        pools,
        hook_states,
    })
}

/// Map remove liquidity kind string to enum value
fn parse_optional_list(list: &Option<Vec<String>>) -> Result<Option<Vec<U256>>, Box<dyn std::error::Error>> {
    list.as_ref()
        .map(|xs| xs.iter().map(|x| x.parse::<U256>()).collect::<Result<Vec<U256>, _>>())
        .transpose()
        .map_err(|e| e.into())
}

fn map_remove_kind(kind: &str) -> u8 {
    match kind {
        "Proportional" => 0,
        "SingleTokenExactIn" => 1,
        "SingleTokenExactOut" => 2,
        _ => panic!("Unsupported RemoveKind: {}", kind),
    }
}

/// Map raw pool data to supported pool type
fn map_pool(raw_pool: RawPool) -> Result<SupportedPool, Box<dyn std::error::Error>> {
    match raw_pool.pool_type.as_str() {
        "WEIGHTED" | "WEIGHTED_8020" | "COW" => {
            let weights = match raw_pool.weights {
                Some(w) => w
                    .into_iter()
                    .map(|w_str| w_str.parse::<U256>())
                    .collect::<Result<Vec<U256>, _>>()?,
                None => {
                    return Err("Weighted pool missing weights".into());
                }
            };
            let weighted_state = WeightedState {
                base: BasePoolState {
                    pool_address: raw_pool.pool_address.clone(),
                    pool_type: raw_pool.pool_type.clone(),
                    tokens: raw_pool.tokens.clone(),
                    scaling_factors: raw_pool
                        .scaling_factors
                        .into_iter()
                        .map(|sf| sf.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    swap_fee: raw_pool.swap_fee.parse::<U256>()?,
                    balances_live_scaled_18: raw_pool
                        .balances_live_scaled_18
                        .into_iter()
                        .map(|b| b.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    token_rates: raw_pool
                        .token_rates
                        .into_iter()
                        .map(|r| r.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    total_supply: raw_pool.total_supply.parse::<U256>()?,
                    aggregate_swap_fee: raw_pool
                        .aggregate_swap_fee
                        .unwrap_or_else(|| "0".to_string())
                        .parse::<U256>()?,
                    supports_unbalanced_liquidity: raw_pool
                        .supports_unbalanced_liquidity
                        .unwrap_or(true),
                    hook_type: None,
                },
                weights,
                min_token_balances: parse_optional_list(&raw_pool.min_token_balances)?,
            };
            Ok(SupportedPool::Weighted(WeightedPool {
                base: PoolBase {
                    chain_id: raw_pool.chain_id.parse()?,
                    block_number: raw_pool.block_number.parse()?,
                    pool_address: raw_pool.pool_address,
                },
                state: weighted_state,
            }))
        }
        "STABLE" => {
            let amp = match raw_pool.amp {
                Some(a) => a.parse::<U256>()?,
                None => {
                    return Err("Stable pool missing amp".into());
                }
            };
            let stable_state = StableState {
                base: BasePoolState {
                    pool_address: raw_pool.pool_address.clone(),
                    pool_type: raw_pool.pool_type.clone(),
                    tokens: raw_pool.tokens.clone(),
                    scaling_factors: raw_pool
                        .scaling_factors
                        .into_iter()
                        .map(|sf| sf.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    swap_fee: raw_pool.swap_fee.parse::<U256>()?,
                    balances_live_scaled_18: raw_pool
                        .balances_live_scaled_18
                        .into_iter()
                        .map(|b| b.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    token_rates: raw_pool
                        .token_rates
                        .into_iter()
                        .map(|r| r.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    total_supply: raw_pool.total_supply.parse::<U256>()?,
                    aggregate_swap_fee: raw_pool
                        .aggregate_swap_fee
                        .unwrap_or_else(|| "0".to_string())
                        .parse::<U256>()?,
                    supports_unbalanced_liquidity: raw_pool
                        .supports_unbalanced_liquidity
                        .unwrap_or(true),
                    hook_type: None,
                },
                mutable: StableMutable { amp },
            };
            Ok(SupportedPool::Stable(StablePool {
                base: PoolBase {
                    chain_id: raw_pool.chain_id.parse()?,
                    block_number: raw_pool.block_number.parse()?,
                    pool_address: raw_pool.pool_address,
                },
                state: stable_state,
            }))
        }
        "LIQUIDITY_BOOTSTRAPPING" => {
            // Parse Liquidity Bootstrapping parameters
            let project_token_index = raw_pool
                .project_token_index
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing projectTokenIndex")?
                .as_u64()
                .ok_or("projectTokenIndex must be a number")?
                as usize;

            let is_project_token_swap_in_blocked = raw_pool
                .is_project_token_swap_in_blocked
                .ok_or("Liquidity Bootstrapping pool missing isProjectTokenSwapInBlocked")?;

            let start_weights = raw_pool
                .start_weights
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing startWeights")?
                .iter()
                .map(|w| w.parse::<U256>())
                .collect::<Result<Vec<U256>, _>>()?;

            let end_weights = raw_pool
                .end_weights
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing endWeights")?
                .iter()
                .map(|w| w.parse::<U256>())
                .collect::<Result<Vec<U256>, _>>()?;

            let start_time = raw_pool
                .start_time
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing startTime")?
                .parse::<U256>()?;

            let end_time = raw_pool
                .end_time
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing endTime")?
                .parse::<U256>()?;

            let is_swap_enabled = raw_pool
                .is_swap_enabled
                .ok_or("Liquidity Bootstrapping pool missing isSwapEnabled")?;

            let current_timestamp = raw_pool
                .current_timestamp
                .as_ref()
                .ok_or("Liquidity Bootstrapping pool missing currentTimestamp")?
                .parse::<U256>()?;

            let liquidity_bootstrapping_state = LiquidityBootstrappingState {
                base: BasePoolState {
                    pool_address: raw_pool.pool_address.clone(),
                    pool_type: raw_pool.pool_type.clone(),
                    tokens: raw_pool.tokens.clone(),
                    scaling_factors: raw_pool
                        .scaling_factors
                        .into_iter()
                        .map(|sf| sf.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    swap_fee: raw_pool.swap_fee.parse::<U256>()?,
                    balances_live_scaled_18: raw_pool
                        .balances_live_scaled_18
                        .into_iter()
                        .map(|b| b.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    token_rates: raw_pool
                        .token_rates
                        .into_iter()
                        .map(|r| r.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    total_supply: raw_pool.total_supply.parse::<U256>()?,
                    aggregate_swap_fee: raw_pool
                        .aggregate_swap_fee
                        .unwrap_or_else(|| "0".to_string())
                        .parse::<U256>()?,
                    supports_unbalanced_liquidity: raw_pool
                        .supports_unbalanced_liquidity
                        .unwrap_or(true),
                    hook_type: None,
                },
                mutable: LiquidityBootstrappingMutable {
                    is_swap_enabled,
                    current_timestamp,
                },
                immutable: LiquidityBootstrappingImmutable {
                    project_token_index,
                    is_project_token_swap_in_blocked,
                    start_weights,
                    end_weights,
                    start_time,
                    end_time,
                    min_token_balances: parse_optional_list(&raw_pool.min_token_balances)?,
                },
            };
            Ok(SupportedPool::LiquidityBootstrapping(
                LiquidityBootstrappingPool {
                    base: PoolBase {
                        chain_id: raw_pool.chain_id.parse()?,
                        block_number: raw_pool.block_number.parse()?,
                        pool_address: raw_pool.pool_address,
                    },
                    state: liquidity_bootstrapping_state,
                },
            ))
        }
        "FIXED_PRICE_LBP" => {
            let project_token_index = raw_pool
                .project_token_index
                .as_ref()
                .ok_or("FixedPriceLBP pool missing projectTokenIndex")?
                .as_u64()
                .ok_or("projectTokenIndex must be a number")?
                as usize;

            let reserve_token_index = raw_pool
                .reserve_token_index
                .as_ref()
                .ok_or("FixedPriceLBP pool missing reserveTokenIndex")?
                .as_u64()
                .ok_or("reserveTokenIndex must be a number")?
                as usize;

            let project_token_rate = raw_pool
                .project_token_rate
                .as_ref()
                .ok_or("FixedPriceLBP pool missing projectTokenRate")?
                .parse::<U256>()?;

            let start_time = raw_pool
                .start_time
                .as_ref()
                .ok_or("FixedPriceLBP pool missing startTime")?
                .parse::<U256>()?;

            let end_time = raw_pool
                .end_time
                .as_ref()
                .ok_or("FixedPriceLBP pool missing endTime")?
                .parse::<U256>()?;

            let is_swap_enabled = raw_pool
                .is_swap_enabled
                .ok_or("FixedPriceLBP pool missing isSwapEnabled")?;

            let current_timestamp = raw_pool
                .current_timestamp
                .as_ref()
                .ok_or("FixedPriceLBP pool missing currentTimestamp")?
                .parse::<U256>()?;

            let fixed_price_lbp_state = FixedPriceLBPState {
                base: BasePoolState {
                    pool_address: raw_pool.pool_address.clone(),
                    pool_type: raw_pool.pool_type.clone(),
                    tokens: raw_pool.tokens.clone(),
                    scaling_factors: raw_pool
                        .scaling_factors
                        .into_iter()
                        .map(|sf| sf.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    swap_fee: raw_pool.swap_fee.parse::<U256>()?,
                    balances_live_scaled_18: raw_pool
                        .balances_live_scaled_18
                        .into_iter()
                        .map(|b| b.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    token_rates: raw_pool
                        .token_rates
                        .into_iter()
                        .map(|r| r.parse::<U256>())
                        .collect::<Result<Vec<U256>, _>>()?,
                    total_supply: raw_pool.total_supply.parse::<U256>()?,
                    aggregate_swap_fee: raw_pool
                        .aggregate_swap_fee
                        .unwrap_or_else(|| "0".to_string())
                        .parse::<U256>()?,
                    supports_unbalanced_liquidity: raw_pool
                        .supports_unbalanced_liquidity
                        .unwrap_or(false),
                    hook_type: None,
                },
                mutable: FixedPriceLBPMutable {
                    is_swap_enabled,
                    current_timestamp,
                },
                immutable: FixedPriceLBPImmutable {
                    project_token_index,
                    reserve_token_index,
                    project_token_rate,
                    start_time,
                    end_time,
                },
            };
            Ok(SupportedPool::FixedPriceLBP(FixedPriceLBPPool {
                base: PoolBase {
                    chain_id: raw_pool.chain_id.parse()?,
                    block_number: raw_pool.block_number.parse()?,
                    pool_address: raw_pool.pool_address,
                },
                state: fixed_price_lbp_state,
            }))
        }
        _ => Err(format!("Unsupported pool type: {}", raw_pool.pool_type).into()),
    }
}
