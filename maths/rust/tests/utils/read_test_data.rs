//! Reads every test-data file in maths/testData into swaps / adds / removes plus the pool (and hook) state each
//! one was recorded against. Pool states are built by `bush_maths::pools::state_from_json`, so a new pool type
//! needs nothing here.

use alloy_primitives::U256;
use bush_maths::common::json::PoolJson;
use bush_maths::common::types::PoolState;
use bush_maths::hooks::types::HookState;
use bush_maths::pools::state_from_json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookData {
    pub address: String,
    #[serde(rename = "type")]
    pub hook_type: String,
    #[serde(rename = "dynamicData")]
    pub dynamic_data: serde_json::Value,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Swap {
    pub swap_kind: u8,
    pub amount_raw: U256,
    pub output_raw: U256,
    pub token_in: String,
    pub token_out: String,
    pub test: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Add {
    pub kind: u8,
    pub input_amounts_raw: Vec<U256>,
    pub bpt_out_raw: U256,
    pub test: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Remove {
    pub kind: u8,
    pub amounts_out_raw: Vec<U256>,
    pub bpt_in_raw: U256,
    pub test: String,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TestData {
    pub swaps: Vec<Swap>,
    pub adds: Vec<Add>,
    pub removes: Vec<Remove>,
    /// Keyed by file name.
    pub pools: HashMap<String, PoolState>,
    pub hook_states: HashMap<String, HookState>,
}

#[derive(Deserialize)]
struct RawTestFile {
    swaps: Option<Vec<RawSwap>>,
    adds: Option<Vec<RawAdd>>,
    removes: Option<Vec<RawRemove>>,
    pool: serde_json::Value,
}

#[derive(Deserialize)]
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

#[derive(Deserialize)]
struct RawAdd {
    kind: String,
    #[serde(rename = "inputAmountsRaw")]
    input_amounts_raw: Vec<String>,
    #[serde(rename = "bptOutRaw")]
    bpt_out_raw: String,
}

#[derive(Deserialize)]
struct RawRemove {
    kind: String,
    #[serde(rename = "amountsOutRaw")]
    amounts_out_raw: Vec<String>,
    #[serde(rename = "bptInRaw")]
    bpt_in_raw: String,
}

type BoxError = Box<dyn std::error::Error>;

fn parse_all(xs: &[String]) -> Result<Vec<U256>, BoxError> {
    xs.iter().map(|x| Ok(x.parse::<U256>()?)).collect()
}

pub fn read_test_data() -> Result<TestData, BoxError> {
    let mut data = TestData {
        swaps: Vec::new(),
        adds: Vec::new(),
        removes: Vec::new(),
        pools: HashMap::new(),
        hook_states: HashMap::new(),
    };

    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().join("testData");
    let mut files: Vec<_> = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    files.sort();

    for path in files {
        let test = path.file_name().unwrap().to_string_lossy().to_string();
        let file: RawTestFile = serde_json::from_str(&fs::read_to_string(&path)?)
            .map_err(|e| format!("{test}: {e}"))?;

        // A pool type this crate has no maths for yet (maths may land one language at a time).
        let pool = PoolJson(file.pool.clone());
        let pool_type = pool.s("poolType")?;
        if state_from_json(&pool, None).is_err_and(|e| e.starts_with("Unsupported pool type")) {
            eprintln!("{test}: pool type {pool_type} not implemented in Rust, skipped");
            continue;
        }

        for s in file.swaps.unwrap_or_default() {
            data.swaps.push(Swap {
                swap_kind: s.swap_kind,
                amount_raw: s.amount_raw.parse()?,
                output_raw: s.output_raw.parse()?,
                token_in: s.token_in,
                token_out: s.token_out,
                test: test.clone(),
            });
        }
        for a in file.adds.unwrap_or_default() {
            data.adds.push(Add {
                kind: if a.kind == "Unbalanced" { 0 } else { 1 },
                input_amounts_raw: parse_all(&a.input_amounts_raw)?,
                bpt_out_raw: a.bpt_out_raw.parse()?,
                test: test.clone(),
            });
        }
        for r in file.removes.unwrap_or_default() {
            data.removes.push(Remove {
                kind: map_remove_kind(&r.kind),
                amounts_out_raw: parse_all(&r.amounts_out_raw)?,
                bpt_in_raw: r.bpt_in_raw.parse()?,
                test: test.clone(),
            });
        }

        // The hook, if any, is mapped first: the pool state carries the hook type the Vault dispatches on.
        let hook_state = match file.pool.get("hook").filter(|h| !h.is_null()) {
            Some(hook) => {
                let hook_data: HookData = serde_json::from_value(hook.clone())?;
                let pool_data = crate::utils::PoolData {
                    tokens: pool.strings("tokens")?,
                    amp: pool.u("amp").ok(),
                    weights: pool.arr("weights").ok(),
                    swap_fee: pool.u("swapFee")?,
                };
                Some(crate::utils::map_hook_state(&hook_data, &pool_data)?)
            }
            None => None,
        };
        let hook_type = hook_state.as_ref().map(|h| match h {
            HookState::StableSurge(_) => "StableSurge".to_string(),
            HookState::Custom(state) => state.hook_type.clone(),
        });

        data.pools.insert(test.clone(), state_from_json(&pool, hook_type).map_err(|e| format!("{test}: {e}"))?);
        if let Some(h) = hook_state {
            data.hook_states.insert(test, h);
        }
    }

    Ok(data)
}

fn map_remove_kind(kind: &str) -> u8 {
    match kind {
        "Proportional" => 0,
        "SingleTokenExactIn" => 1,
        "SingleTokenExactOut" => 2,
        _ => panic!("Unsupported RemoveKind: {}", kind),
    }
}
