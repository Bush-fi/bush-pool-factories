//! Typed access to the `pool` block of a test-data file (maths/testData), as written by maths/check. Numbers are
//! decimal strings. Each pool's state implements `from_json` on top of this; `crate::pools::state_from_json` picks
//! the one matching `poolType`.

use crate::common::types::BasePoolState;
use alloy_primitives::U256;
use serde_json::Value;

/// The `pool` block of a test-data file (see maths/testData). Numbers are decimal strings.
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
