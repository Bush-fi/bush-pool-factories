import { MathSol } from '../utils/math';

/**
 * CowPool itself is a plain WeightedPool (poolType `COW` maps to the Weighted maths). What is specific to the CoW
 * integration lives in `CowRouter`: swaps and donations that also credit a protocol fee. These helpers mirror the
 * fee arithmetic in `CowRouter._donateToPool` / `_setProtocolFeePercentage`.
 */

/** CowRouter._MAX_PROTOCOL_FEE_PERCENTAGE: 50% */
export const MAX_PROTOCOL_FEE_PERCENTAGE = 500000000000000000n;

export type DonationSplit = {
    donatedAmount: bigint;
    protocolFeeAmount: bigint;
};

/** CowRouter._setProtocolFeePercentage: reverts with ProtocolFeePercentageAboveLimit above the max. */
export function validateProtocolFeePercentage(protocolFeePercentage: bigint): void {
    if (protocolFeePercentage > MAX_PROTOCOL_FEE_PERCENTAGE) {
        throw new Error('ProtocolFeePercentageAboveLimit');
    }
}

/**
 * CowRouter._donateToPool, per token: the protocol fee is taken (rounded up) from the amount the caller sends, and
 * the remainder is donated to the pool.
 */
export function splitDonationAndProtocolFee(
    donationAndFees: bigint,
    protocolFeePercentage: bigint,
): DonationSplit {
    const protocolFeeAmount = MathSol.mulUpFixed(
        donationAndFees,
        protocolFeePercentage,
    );
    return {
        donatedAmount: donationAndFees - protocolFeeAmount,
        protocolFeeAmount,
    };
}

export function splitDonationAmounts(
    amountsToDonate: bigint[],
    protocolFeePercentage: bigint,
): DonationSplit[] {
    return amountsToDonate.map((amount) =>
        splitDonationAndProtocolFee(amount, protocolFeePercentage),
    );
}
