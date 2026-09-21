//! Support for a factory package's `src/bin/math_check.rs`.
//!
//! The binary hands over two constructors and this crate does the rest: it reads a bush-maths test-data file, runs
//! every swap / add / remove through the bush-maths Vault flow with the contributor's `PoolBase` (and optional
//! `HookBase`) implementation, and prints the outcomes as JSON for `pvt/math-check` to report.
//!
//! ```ignore
//! use math_check_support::{PoolJson, U256};
//! fn make_pool(pool: &PoolJson) -> Result<Box<dyn bush_maths::PoolBase>, String> { ... }
//! fn main() { math_check_support::run(make_pool, math_check_support::no_hook) }
//! ```

pub use alloy_primitives::U256;
pub use bush_maths;
use bush_maths::common::types::{
    AddLiquidityInput, AddLiquidityKind, BasePoolState, PoolState, RemoveLiquidityInput, RemoveLiquidityKind,
    SwapInput, SwapKind,
};
use bush_maths::hooks::types::HookState;
use bush_maths::hooks::{DefaultHook, HookBase};
use bush_maths::PoolBase;
use serde::Serialize;
use serde_json::Value;

/// The `pool` block of a test-data file (see bush-maths/testData). Numbers are decimal strings.
pub struct PoolJson(pub Value);

impl PoolJson {
    pub fn u(&self, key: &str) -> Result<U256, String> {
        let v = self.0.get(key).ok_or_else(|| format!("pool is missing `{key}`"))?;
        match v {
            Value::String(s) => U256::from_str_radix(s, 10).map_err(|e| format!("`{key}`: {e}")),
            Value::Number(n) => Ok(U256::from(n.as_u64().ok_or_else(|| format!("`{key}` is not an integer"))?)),
            _ => Err(format!("`{key}` is not a number")),
        }
    }
    pub fn arr(&self, key: &str) -> Result<Vec<U256>, String> {
        self.0
            .get(key)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("pool is missing array `{key}`"))?
            .iter()
            .map(|v| match v {
                Value::String(s) => U256::from_str_radix(s, 10).map_err(|e| format!("`{key}`: {e}")),
                Value::Number(n) => Ok(U256::from(n.as_u64().unwrap_or(0))),
                _ => Err(format!("`{key}` has a non-numeric element")),
            })
            .collect()
    }
    pub fn n(&self, key: &str) -> Result<usize, String> {
        let v = self.0.get(key).ok_or_else(|| format!("pool is missing `{key}`"))?;
        match v {
            Value::Number(n) => n.as_u64().map(|n| n as usize).ok_or_else(|| format!("`{key}` is not an integer")),
            Value::String(s) => s.parse().map_err(|_| format!("`{key}` is not an integer")),
            _ => Err(format!("`{key}` is not an integer")),
        }
    }
    pub fn b(&self, key: &str) -> Result<bool, String> {
        self.0.get(key).and_then(Value::as_bool).ok_or_else(|| format!("pool is missing bool `{key}`"))
    }
    pub fn s(&self, key: &str) -> Result<String, String> {
        self.0.get(key).and_then(Value::as_str).map(String::from).ok_or_else(|| format!("pool is missing `{key}`"))
    }
    pub fn strings(&self, key: &str) -> Result<Vec<String>, String> {
        self.0
            .get(key)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("pool is missing array `{key}`"))?
            .iter()
            .map(|v| v.as_str().map(String::from).ok_or_else(|| format!("`{key}` has a non-string element")))
            .collect()
    }
    /// The `hook` block, if the pool has one.
    pub fn hook(&self) -> Option<PoolJson> {
        self.0.get("hook").filter(|h| !h.is_null()).map(|h| PoolJson(h.clone()))
    }
    /// The pool-agnostic state the Vault flow needs, read from the standard fields.
    pub fn base_state(&self, hook_type: Option<String>) -> Result<BasePoolState, String> {
        Ok(BasePoolState {
            pool_address: self.s("poolAddress")?,
            pool_type: self.s("poolType")?,
            tokens: self.strings("tokens")?,
            scaling_factors: self.arr("scalingFactors")?,
            token_rates: self.arr("tokenRates")?,
            balances_live_scaled_18: self.arr("balancesLiveScaled18")?,
            swap_fee: self.u("swapFee")?,
            aggregate_swap_fee: self.u("aggregateSwapFee").unwrap_or(U256::ZERO),
            total_supply: self.u("totalSupply")?,
            supports_unbalanced_liquidity: self.b("supportsUnbalancedLiquidity").unwrap_or(true),
            hook_type,
        })
    }
}

/// A hook implementation plus the state the Vault should hand it on every call.
pub struct Hook {
    pub hook_type: String,
    pub hook: Box<dyn HookBase>,
    pub state: HookState,
}

pub type MakePool = fn(&PoolJson) -> Result<Box<dyn PoolBase>, String>;
pub type MakeHook = fn(&PoolJson) -> Result<Option<Hook>, String>;

/// For pools without a hook.
pub fn no_hook(_pool: &PoolJson) -> Result<Option<Hook>, String> {
    Ok(None)
}

#[derive(Serialize)]
struct Outcome {
    kind: &'static str,
    index: usize,
    expected: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    actual: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn u(v: &Value) -> U256 {
    U256::from_str_radix(v.as_str().unwrap_or("0"), 10).unwrap_or(U256::ZERO)
}

fn strs(xs: &[U256]) -> Vec<String> {
    xs.iter().map(|x| x.to_string()).collect()
}

/// Entry point for a factory's `math_check` binary: `math_check <test-data-file.json>`.
pub fn run(make_pool: MakePool, make_hook: MakeHook) {
    std::panic::set_hook(Box::new(|info| eprintln!("{info}")));
    let path = std::env::args().nth(1).expect("usage: math_check <test-data-file.json>");
    let file: Value = serde_json::from_str(&std::fs::read_to_string(path).expect("read test data")).expect("parse test data");
    let pool_json = PoolJson(file["pool"].clone());

    let hook = make_hook(&pool_json).unwrap_or_else(|e| panic!("make_hook: {e}"));
    let base = pool_json
        .base_state(hook.as_ref().map(|h| h.hook_type.clone()))
        .unwrap_or_else(|e| panic!("{e}"));
    let pool_state = PoolState::Base(base.clone());
    let pool = make_pool(&pool_json).unwrap_or_else(|e| panic!("make_pool: {e}"));
    let default_hook = DefaultHook::new();
    let hook_class: &dyn HookBase = hook.as_ref().map(|h| h.hook.as_ref()).unwrap_or(&default_hook);
    let hook_state = hook.as_ref().map(|h| &h.state);

    let mut outcomes = Vec::new();

    for (i, s) in file["swaps"].as_array().unwrap_or(&vec![]).iter().enumerate() {
        let input = SwapInput {
            amount_raw: u(&s["amountRaw"]),
            swap_kind: if s["swapKind"].as_u64() == Some(0) { SwapKind::GivenIn } else { SwapKind::GivenOut },
            token_in: s["tokenIn"].as_str().unwrap_or("").to_string(),
            token_out: s["tokenOut"].as_str().unwrap_or("").to_string(),
        };
        let expected = vec![s["outputRaw"].as_str().unwrap_or("").to_string()];
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            bush_maths::vault::swap::swap(&input, &pool_state, pool.as_ref(), hook_class, hook_state)
        }));
        outcomes.push(match res {
            Ok(Ok(out)) => Outcome { kind: "swap", index: i, expected, actual: Some(vec![out.to_string()]), error: None },
            Ok(Err(e)) => Outcome { kind: "swap", index: i, expected, actual: None, error: Some(format!("{e:?}")) },
            Err(_) => Outcome { kind: "swap", index: i, expected, actual: None, error: Some("panic".into()) },
        });
    }

    for (i, a) in file["adds"].as_array().unwrap_or(&vec![]).iter().enumerate() {
        let amounts: Vec<U256> = a["inputAmountsRaw"].as_array().unwrap_or(&vec![]).iter().map(u).collect();
        let bpt_out = u(&a["bptOutRaw"]);
        let input = AddLiquidityInput {
            pool: base.pool_address.clone(),
            max_amounts_in_raw: amounts.clone(),
            min_bpt_amount_out_raw: bpt_out,
            kind: if a["kind"] == "Unbalanced" { AddLiquidityKind::Unbalanced } else { AddLiquidityKind::SingleTokenExactOut },
        };
        // Expected: bptOut then amountsIn (the maths returns both; unbalanced adds echo the inputs).
        let mut expected = vec![bpt_out.to_string()];
        expected.extend(strs(&amounts));
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            bush_maths::vault::add_liquidity::add_liquidity(&input, &pool_state, pool.as_ref(), hook_class, hook_state)
        }));
        outcomes.push(match res {
            Ok(Ok(r)) => {
                let mut actual = vec![r.bpt_amount_out_raw.to_string()];
                actual.extend(strs(&r.amounts_in_raw));
                Outcome { kind: "add", index: i, expected, actual: Some(actual), error: None }
            }
            Ok(Err(e)) => Outcome { kind: "add", index: i, expected, actual: None, error: Some(format!("{e:?}")) },
            Err(_) => Outcome { kind: "add", index: i, expected, actual: None, error: Some("panic".into()) },
        });
    }

    for (i, r) in file["removes"].as_array().unwrap_or(&vec![]).iter().enumerate() {
        let amounts: Vec<U256> = r["amountsOutRaw"].as_array().unwrap_or(&vec![]).iter().map(u).collect();
        let bpt_in = u(&r["bptInRaw"]);
        let input = RemoveLiquidityInput {
            pool: base.pool_address.clone(),
            min_amounts_out_raw: amounts.clone(),
            max_bpt_amount_in_raw: bpt_in,
            kind: match r["kind"].as_str() {
                Some("Proportional") => RemoveLiquidityKind::Proportional,
                Some("SingleTokenExactIn") => RemoveLiquidityKind::SingleTokenExactIn,
                _ => RemoveLiquidityKind::SingleTokenExactOut,
            },
        };
        let mut expected = vec![bpt_in.to_string()];
        expected.extend(strs(&amounts));
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            bush_maths::vault::remove_liquidity::remove_liquidity(&input, &pool_state, pool.as_ref(), hook_class, hook_state)
        }));
        outcomes.push(match res {
            Ok(Ok(res)) => {
                let mut actual = vec![res.bpt_amount_in_raw.to_string()];
                actual.extend(strs(&res.amounts_out_raw));
                Outcome { kind: "remove", index: i, expected, actual: Some(actual), error: None }
            }
            Ok(Err(e)) => Outcome { kind: "remove", index: i, expected, actual: None, error: Some(format!("{e:?}")) },
            Err(_) => Outcome { kind: "remove", index: i, expected, actual: None, error: Some("panic".into()) },
        });
    }

    println!("{}", serde_json::to_string(&outcomes).unwrap());
}
