"""
CowPool itself is a plain WeightedPool (pool type ``COW`` maps to the Weighted maths). What is specific to the CoW
integration lives in ``CowRouter``: swaps and donations that also credit a protocol fee. These helpers mirror the fee
arithmetic in ``CowRouter._donateToPool`` / ``_setProtocolFeePercentage``.
"""
from dataclasses import dataclass
from typing import List

from src.common.maths import mul_up_fixed

# CowRouter._MAX_PROTOCOL_FEE_PERCENTAGE: 50%
MAX_PROTOCOL_FEE_PERCENTAGE = 500000000000000000


@dataclass
class DonationSplit:
    donated_amount: int
    protocol_fee_amount: int


def validate_protocol_fee_percentage(protocol_fee_percentage: int) -> None:
    """CowRouter._setProtocolFeePercentage: reverts with ProtocolFeePercentageAboveLimit above the max."""
    if protocol_fee_percentage > MAX_PROTOCOL_FEE_PERCENTAGE:
        raise ValueError("ProtocolFeePercentageAboveLimit")


def split_donation_and_protocol_fee(
    donation_and_fees: int, protocol_fee_percentage: int
) -> DonationSplit:
    """
    CowRouter._donateToPool, per token: the protocol fee is taken (rounded up) from the amount the caller sends,
    and the remainder is donated to the pool.
    """
    protocol_fee_amount = mul_up_fixed(donation_and_fees, protocol_fee_percentage)
    return DonationSplit(
        donated_amount=donation_and_fees - protocol_fee_amount,
        protocol_fee_amount=protocol_fee_amount,
    )


def split_donation_amounts(
    amounts_to_donate: List[int], protocol_fee_percentage: int
) -> List[DonationSplit]:
    return [
        split_donation_and_protocol_fee(amount, protocol_fee_percentage)
        for amount in amounts_to_donate
    ]
