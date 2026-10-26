//! The overshoot clamp: while bonding, the buy that completes the curve may go at most 0.1% past the graduation
//! balance (RukusLaunchPool.MAX_GRADUATION_OVERSHOOT). The generated test data only records swaps the chain
//! accepted, so the rejection is checked here.

use bush_maths::common::types::{SwapKind, SwapParams};
use bush_maths::pool_kit::U256;
use bush_maths::pools::rukus_launch::{BondingPhase, RukusLaunchMutable, RukusLaunchPool};
use bush_maths::PoolBase;

fn e18(n: u128) -> U256 {
    U256::from(n) * U256::from(10u128.pow(18))
}

fn graduation_balance() -> U256 {
    e18(20_000_000)
}

fn balances() -> Vec<U256> {
    vec![graduation_balance() + e18(1_000), e18(31_998)]
}

fn max_out() -> U256 {
    let g = graduation_balance();
    balances()[0] - (g - g / U256::from(1000u64))
}

fn pool(phase: BondingPhase) -> RukusLaunchPool {
    RukusLaunchPool::new(RukusLaunchMutable {
        phase,
        launch_token_index: 0,
        graduation_launch_balance: graduation_balance(),
        bonding_completed_at: U256::ZERO,
        graduated_price_ratio: U256::from(10u128.pow(30)),
        virtual_balance_a: U256::from(6_666_666_666_666_666_666_666_666u128),
        virtual_balance_b: U256::from(10_666_666_666_666_666_666_666u128),
        current_timestamp: U256::from(1_000_000u64),
    })
}

fn buy(kind: SwapKind, amount: U256) -> SwapParams {
    SwapParams {
        swap_kind: kind,
        token_in_index: 1,
        token_out_index: 0,
        amount_scaled_18: amount,
        balances_live_scaled_18: balances(),
    }
}

#[test]
fn buy_down_to_the_limit_is_accepted() {
    assert!(pool(BondingPhase::Bonding).on_swap(&buy(SwapKind::GivenOut, max_out())).unwrap() > U256::ZERO);
}

#[test]
fn one_wei_past_the_limit_is_rejected() {
    let err = pool(BondingPhase::Bonding).on_swap(&buy(SwapKind::GivenOut, max_out() + U256::from(1u64))).unwrap_err();
    assert!(format!("{err:?}").contains("GraduationBuyTooLarge"));
}

#[test]
fn exact_in_past_the_limit_is_rejected() {
    let err = pool(BondingPhase::Bonding).on_swap(&buy(SwapKind::GivenIn, e18(100_000))).unwrap_err();
    assert!(format!("{err:?}").contains("GraduationBuyTooLarge"));
}

#[test]
fn no_clamp_once_graduated() {
    assert!(pool(BondingPhase::Graduated).on_swap(&buy(SwapKind::GivenOut, max_out() * U256::from(100u64))).unwrap() > U256::ZERO);
}
