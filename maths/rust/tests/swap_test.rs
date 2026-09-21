use bush_maths::common::types::*;
use bush_maths::vault::Vault;
mod utils;
use utils::read_test_data;

#[test]
fn test_swaps() {
    let test_data = read_test_data().expect("Failed to read test data");
    let vault = Vault::new();

    for swap_test in test_data.swaps {
        println!("Swap Test: {}", swap_test.test);
        // Get the pool data for this test
        let pool_data = test_data
            .pools
            .get(&swap_test.test)
            .unwrap_or_else(|| panic!("Pool not found for test: {}", swap_test.test));

        let pool_state = pool_data.clone();

        // Create SwapInput
        let swap_input = SwapInput {
            amount_raw: swap_test.amount_raw,
            token_in: swap_test.token_in.clone(),
            token_out: swap_test.token_out.clone(),
            swap_kind: match swap_test.swap_kind {
                0 => SwapKind::GivenIn,
                1 => SwapKind::GivenOut,
                _ => panic!("Unsupported swap kind: {}", swap_test.swap_kind),
            },
        };

        // Perform swap operation
        let result = vault
            .swap(
                &swap_input,
                &pool_state,
                test_data.hook_states.get(&swap_test.test),
            )
            .expect("Swap failed");

        assert_eq!(
            result, swap_test.output_raw,
            "Swap result mismatch for test: {}",
            swap_test.test
        );
    }
}
