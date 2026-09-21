use alloy_primitives::U256;
use bush_maths::common::types::*;
use bush_maths::vault::Vault;
mod utils;
use utils::read_test_data;
use utils::get_pool_address;

#[test]
fn test_add_liquidity() {
    let test_data = read_test_data().expect("Failed to read test data");
    let vault = Vault::new();

    for add in test_data.adds {
        println!("Testing add liquidity: {} (kind: {})", add.test, add.kind);

        // Get the pool data for this test
        let pool = test_data
            .pools
            .get(&add.test)
            .unwrap_or_else(|| panic!("No pool data found for test: {}", add.test));

        let pool_state = pool.clone();

        // Convert kind to AddLiquidityKind
        let kind = match add.kind {
            0 => AddLiquidityKind::Unbalanced,
            1 => AddLiquidityKind::SingleTokenExactOut,
            _ => panic!("Unsupported add kind: {}", add.kind),
        };

        // Create add liquidity input
        let add_input = AddLiquidityInput {
            pool: get_pool_address(pool),
            max_amounts_in_raw: add.input_amounts_raw.clone(),
            min_bpt_amount_out_raw: add.bpt_out_raw,
            kind,
        };

        // Perform add liquidity
        match vault.add_liquidity(&add_input, &pool_state, test_data.hook_states.get(&add.test)) {
            Ok(calculated_amounts) => {
                /*
                 * Relax test assertion to accept off-by-1 error because testData might
                 * return amounts off-by-1 when compared to actual implementations.
                 * e.g. getCurrentLiveBalances rounds pools balances down, while solidity
                 * rounds pool balances up when loading pool data within add liquidity operations
                 */
                let min_expected = add.bpt_out_raw.saturating_sub(U256::from(1));
                let max_expected = add.bpt_out_raw.saturating_add(U256::from(1));
                assert!(
                    calculated_amounts.bpt_amount_out_raw >= min_expected,
                    "BPT amount out too low for test: {} (expected: {}, got: {}, min: {})",
                    add.test,
                    add.bpt_out_raw,
                    calculated_amounts.bpt_amount_out_raw,
                    min_expected
                );
                assert!(
                    calculated_amounts.bpt_amount_out_raw <= max_expected,
                    "BPT amount out too high for test: {} (expected: {}, got: {}, max: {})",
                    add.test,
                    add.bpt_out_raw,
                    calculated_amounts.bpt_amount_out_raw,
                    max_expected
                );
                assert_eq!(
                    calculated_amounts.amounts_in_raw, add.input_amounts_raw,
                    "Amounts in mismatch for test: {}",
                    add.test
                );
                println!("✓ Test passed: {} (kind: {})", add.test, add.kind);
            }
            Err(e) => {
                panic!("Add liquidity failed for test {}: {:?}", add.test, e);
            }
        }
    }
}
