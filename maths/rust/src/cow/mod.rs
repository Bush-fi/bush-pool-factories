//! CowPool itself is a plain WeightedPool (pool type `COW` uses the Weighted maths). What is specific to the CoW
//! integration lives in `CowRouter`: swaps and donations that also credit a protocol fee. These helpers mirror the
//! fee arithmetic in `CowRouter._donateToPool` / `_setProtocolFeePercentage`.

use crate::common::errors::PoolError;
use crate::common::maths::mul_up_fixed;
use alloy_primitives::U256;

/// CowRouter._MAX_PROTOCOL_FEE_PERCENTAGE: 50%
pub fn max_protocol_fee_percentage() -> U256 {
    U256::from(500_000_000_000_000_000u128)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DonationSplit {
    pub donated_amount: U256,
    pub protocol_fee_amount: U256,
}

/// CowRouter._setProtocolFeePercentage: reverts with ProtocolFeePercentageAboveLimit above the max.
pub fn validate_protocol_fee_percentage(protocol_fee_percentage: U256) -> Result<(), PoolError> {
    if protocol_fee_percentage > max_protocol_fee_percentage() {
        return Err(PoolError::Custom("ProtocolFeePercentageAboveLimit".to_string()));
    }
    Ok(())
}

/// CowRouter._donateToPool, per token: the protocol fee is taken (rounded up) from the amount the caller sends, and
/// the remainder is donated to the pool.
pub fn split_donation_and_protocol_fee(
    donation_and_fees: U256,
    protocol_fee_percentage: U256,
) -> Result<DonationSplit, PoolError> {
    let protocol_fee_amount = mul_up_fixed(&donation_and_fees, &protocol_fee_percentage)?;
    Ok(DonationSplit {
        donated_amount: donation_and_fees - protocol_fee_amount,
        protocol_fee_amount,
    })
}

pub fn split_donation_amounts(
    amounts_to_donate: &[U256],
    protocol_fee_percentage: U256,
) -> Result<Vec<DonationSplit>, PoolError> {
    amounts_to_donate
        .iter()
        .map(|amount| split_donation_and_protocol_fee(*amount, protocol_fee_percentage))
        .collect()
}
