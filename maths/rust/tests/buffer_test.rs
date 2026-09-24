use alloy_primitives::U256;
use bush_maths::common::types::*;
use bush_maths::pools::buffer::{BufferImmutable, BufferMutable, BufferState};
use bush_maths::vault::Vault;

const WRAPPED: &str = "0xd4fa2d31b7968e448877f69a96de69f5de8cd23e";
const UNDERLYING: &str = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";

fn buffer() -> BufferState {
    BufferState {
        mutable: BufferMutable {
            rate: U256::from(1122761623535914092u128),
            max_deposit: Some(U256::from(1900471418535512u128)),
            max_mint: Some(U256::from(1692675790387594u128)),
        },
        immutable: BufferImmutable {
            pool_address: WRAPPED.to_string(),
            tokens: vec![WRAPPED.to_string(), UNDERLYING.to_string()],
        },
    }
}

fn input(amount_raw: U256, token_in: &str, token_out: &str, swap_kind: SwapKind) -> SwapInput {
    SwapInput {
        amount_raw,
        swap_kind,
        token_in: token_in.to_string(),
        token_out: token_out.to_string(),
    }
}

#[test]
fn wraps_when_below_max_deposit() {
    let amount = Vault::new()
        .swap_buffer(
            &input(U256::from(100000000u64), WRAPPED, UNDERLYING, SwapKind::GivenIn),
            &buffer(),
        )
        .unwrap();
    assert_eq!(amount, U256::from(112276162u64));
}

#[test]
fn throws_when_above_max_deposit() {
    let pool = buffer();
    let err = Vault::new()
        .swap_buffer(
            &input(
                pool.mutable.max_deposit.unwrap() + U256::from(1),
                "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
                "0xb19382073c7A0aDdbb56Ac6AF1808Fa49e377B75",
                SwapKind::GivenIn,
            ),
            &pool,
        )
        .unwrap_err();
    assert_eq!(
        err.to_string(),
        "ERC4626ExceededMaxDeposit 1900471418535513 1900471418535512"
    );
}

#[test]
fn wraps_when_below_max_mint() {
    let amount = Vault::new()
        .swap_buffer(
            &input(U256::from(100000000u64), WRAPPED, UNDERLYING, SwapKind::GivenOut),
            &buffer(),
        )
        .unwrap();
    assert_eq!(amount, U256::from(89066101u64));
}

#[test]
fn throws_when_above_max_mint() {
    let pool = buffer();
    let err = Vault::new()
        .swap_buffer(
            &input(
                pool.mutable.max_mint.unwrap() + U256::from(1),
                "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
                "0xb19382073c7A0aDdbb56Ac6AF1808Fa49e377B75",
                SwapKind::GivenOut,
            ),
            &pool,
        )
        .unwrap_err();
    assert_eq!(
        err.to_string(),
        "ERC4626ExceededMaxMint 1692675790387595 1692675790387594"
    );
}

#[test]
fn throws_when_below_minimum_wrap_amount() {
    let err = Vault::new()
        .swap_buffer(
            &input(U256::from(999), UNDERLYING, WRAPPED, SwapKind::GivenIn),
            &buffer(),
        )
        .unwrap_err();
    assert_eq!(err.to_string(), "wrapAmountTooSmall");
}
