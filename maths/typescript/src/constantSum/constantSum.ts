// TEMPLATE: exact fixed-point port of contracts/ConstantSumPool.sol, implementing the bush-maths `PoolBase`
// interface so the bush-maths Vault flow (token scaling, rates, swap fees, hooks) can run it.
//
// Rules for a port that matches the contract to the wei:
//   - use bigint and the bush-maths fixed-point helpers (MathSol.mulDownFixed etc.), never floating point;
//   - mirror every rounding direction of the Solidity (mulDown/mulUp/divDown/divUp) call for call;
//   - reproduce every revert as a throw (the check treats "both fail" as a match).

import { MAX_UINT256 } from '../constants';
import { MathSol } from '../utils/math';
import { toRawUndoRateRoundDown } from '../vault/utils';
import {
    MaxSingleTokenRemoveParams,
    MaxSwapParams,
    type PoolBase,
    Rounding,
    SwapKind,
    type SwapParams,
} from '../vault/types';

/** The Vault's invariant-ratio bounds for unbalanced liquidity operations (ConstantSumPool._MIN/_MAX_INVARIANT_RATIO). */
export const _MIN_INVARIANT_RATIO = 500000000000000000n; // 50%
export const _MAX_INVARIANT_RATIO = 2000000000000000000n; // 200%

export class ConstantSum implements PoolBase {
    /** How many token1 one token0 is worth, 18 decimals (ConstantSumPool._rate). */
    public rate: bigint;

    constructor(poolState: { rate: bigint }) {
        this.rate = poolState.rate;
    }

    getMaximumInvariantRatio(): bigint {
        return _MAX_INVARIANT_RATIO;
    }

    getMinimumInvariantRatio(): bigint {
        return _MIN_INVARIANT_RATIO;
    }

    /** Largest swap the pool accepts: here, whatever the token-out balance can pay for. */
    getMaxSwapAmount(p: MaxSwapParams): bigint {
        const { balancesLiveScaled18, indexIn, indexOut, tokenRates, scalingFactors, swapKind } = p;
        const balanceOut = balancesLiveScaled18[indexOut];
        if (swapKind === SwapKind.GivenIn) {
            // Amount in that would drain token out: balanceOut priced in token in.
            const maxIn18 = indexIn === 0 ? MathSol.divDownFixed(balanceOut, this.rate) : MathSol.mulDownFixed(balanceOut, this.rate);
            return toRawUndoRateRoundDown(maxIn18, scalingFactors[indexIn], tokenRates[indexIn]);
        }
        return toRawUndoRateRoundDown(balanceOut, scalingFactors[indexOut], tokenRates[indexOut]);
    }

    getMaxSingleTokenAddAmount(): bigint {
        return MAX_UINT256;
    }

    getMaxSingleTokenRemoveAmount(p: MaxSingleTokenRemoveParams): bigint {
        return p.tokenOutBalance;
    }

    // ConstantSumPool.onSwap
    onSwap(swapParams: SwapParams): bigint {
        const { swapKind, indexIn, amountGivenScaled18 } = swapParams;
        const token0In = indexIn === 0;
        if (swapKind === SwapKind.GivenIn) {
            // The user receives the calculated amount: round down.
            return token0In ? MathSol.mulDownFixed(amountGivenScaled18, this.rate) : MathSol.divDownFixed(amountGivenScaled18, this.rate);
        }
        // The user pays the calculated amount: round up.
        return token0In ? MathSol.divUpFixed(amountGivenScaled18, this.rate) : MathSol.mulUpFixed(amountGivenScaled18, this.rate);
    }

    // ConstantSumPool.computeInvariant: balance0 * rate + balance1
    computeInvariant(balancesLiveScaled18: bigint[], rounding: Rounding): bigint {
        const token0Value =
            rounding === Rounding.ROUND_UP
                ? MathSol.mulUpFixed(balancesLiveScaled18[0], this.rate)
                : MathSol.mulDownFixed(balancesLiveScaled18[0], this.rate);
        return token0Value + balancesLiveScaled18[1];
    }

    // ConstantSumPool.computeBalance
    computeBalance(balancesLiveScaled18: bigint[], tokenInIndex: number, invariantRatio: bigint): bigint {
        const newInvariant = MathSol.mulUpFixed(this.computeInvariant(balancesLiveScaled18, Rounding.ROUND_UP), invariantRatio);
        if (tokenInIndex === 0) {
            return MathSol.divUpFixed(newInvariant - balancesLiveScaled18[1], this.rate);
        }
        if (tokenInIndex === 1) {
            return newInvariant - MathSol.mulDownFixed(balancesLiveScaled18[0], this.rate);
        }
        throw new Error('InvalidTokenIndex');
    }
}
