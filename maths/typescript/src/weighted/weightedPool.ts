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
import {
    _computeOutGivenExactIn,
    _computeInGivenExactOut,
    _computeBalanceOutGivenInvariant,
    _MAX_IN_RATIO,
    _MAX_OUT_RATIO,
    _MAX_INVARIANT_RATIO,
    _MIN_INVARIANT_RATIO,
    _computeInvariantUp,
    _computeInvariantDown,
} from './weightedMath';

/** MinTokenBalanceLib.ABSOLUTE_MIN_TOKEN_BALANCE */
export const ABSOLUTE_MIN_TOKEN_BALANCE = 1000000n;

export class Weighted implements PoolBase {
    public normalizedWeights: bigint[];
    public minTokenBalances: bigint[];

    constructor(poolState: {
        weights: bigint[];
        minTokenBalances?: bigint[];
        scalingFactors?: bigint[];
    }) {
        this.normalizedWeights = poolState.weights;
        // MinTokenBalanceLib.computeMinTokenBalances: max(1e6, 10^(18 - decimals)) per token.
        this.minTokenBalances =
            poolState.minTokenBalances ??
            poolState.weights.map((_, i) =>
                MathSol.max(
                    ABSOLUTE_MIN_TOKEN_BALANCE,
                    poolState.scalingFactors?.[i] ?? 0n,
                ),
            );
    }

    /** WeightedPool._ensureMinimumBalance */
    private ensureMinimumBalance(
        tokenIndex: number,
        endingBalanceScaled18: bigint,
    ): void {
        const minimum = this.minTokenBalances[tokenIndex] ?? 0n;
        if (endingBalanceScaled18 < minimum) {
            throw new Error('TokenBalanceBelowMin');
        }
    }

    /** WeightedPool._ensureMinTokenBalances */
    private ensureMinTokenBalances(balancesLiveScaled18: bigint[]): void {
        balancesLiveScaled18.forEach((b, i) => this.ensureMinimumBalance(i, b));
    }

    getMaximumInvariantRatio(): bigint {
        return _MAX_INVARIANT_RATIO;
    }

    getMinimumInvariantRatio(): bigint {
        return _MIN_INVARIANT_RATIO;
    }

    /**
     * Returns the max amount that can be swapped in relation to the swapKind.
     * @param maxSwapParams
     * @returns GivenIn: Returns the max amount in. GivenOut: Returns the max amount out.
     */
    getMaxSwapAmount(maxSwapParams: MaxSwapParams): bigint {
        const {
            balancesLiveScaled18,
            indexIn,
            indexOut,
            tokenRates,
            scalingFactors,
            swapKind,
        } = maxSwapParams;
        if (swapKind === SwapKind.GivenIn) {
            const max18 = MathSol.mulDownFixed(
                balancesLiveScaled18[indexIn],
                _MAX_IN_RATIO,
            );
            // Scale to token in (and remove rate)
            return toRawUndoRateRoundDown(
                max18,
                scalingFactors[indexIn],
                tokenRates[indexIn],
            );
        }

        const max18 = MathSol.mulDownFixed(
            balancesLiveScaled18[indexOut],
            _MAX_OUT_RATIO,
        );
        // Scale to token out
        return toRawUndoRateRoundDown(
            max18,
            scalingFactors[indexOut],
            tokenRates[indexOut],
        );
    }

    getMaxSingleTokenAddAmount(): bigint {
        return MAX_UINT256;
    }

    getMaxSingleTokenRemoveAmount(
        maxRemoveParams: MaxSingleTokenRemoveParams,
    ): bigint {
        const {
            isExactIn,
            totalSupply,
            tokenOutBalance,
            tokenOutScalingFactor,
            tokenOutRate,
        } = maxRemoveParams;
        return this.getMaxSwapAmount({
            swapKind: isExactIn ? SwapKind.GivenIn : SwapKind.GivenOut,
            balancesLiveScaled18: [totalSupply, tokenOutBalance],
            tokenRates: [1000000000000000000n, tokenOutRate],
            scalingFactors: [1000000000000000000n, tokenOutScalingFactor],
            indexIn: 0,
            indexOut: 1,
        });
    }

    onSwap(swapParams: SwapParams): bigint {
        const {
            swapKind,
            balancesLiveScaled18: balancesScaled18,
            indexIn,
            indexOut,
            amountGivenScaled18,
        } = swapParams;
        // WeightedPool.onSwap rounds the token-in balance up on both ExactIn and ExactOut swaps.
        const balanceTokenInScaled18 = balancesScaled18[indexIn] + 1n;
        const balanceTokenOutScaled18 = balancesScaled18[indexOut];
        this.ensureMinimumBalance(indexIn, balanceTokenInScaled18);

        let calculatedAmountScaled18: bigint;
        let amountOutScaled18: bigint;
        if (swapKind === SwapKind.GivenIn) {
            calculatedAmountScaled18 = _computeOutGivenExactIn(
                balanceTokenInScaled18,
                this.normalizedWeights[indexIn],
                balanceTokenOutScaled18,
                this.normalizedWeights[indexOut],
                amountGivenScaled18,
            );
            amountOutScaled18 = calculatedAmountScaled18;
        } else {
            calculatedAmountScaled18 = _computeInGivenExactOut(
                balanceTokenInScaled18,
                this.normalizedWeights[indexIn],
                balanceTokenOutScaled18,
                this.normalizedWeights[indexOut],
                amountGivenScaled18,
            );
            amountOutScaled18 = amountGivenScaled18;
        }
        // The swap must not drop the token-out balance below the minimum.
        this.ensureMinimumBalance(
            indexOut,
            balanceTokenOutScaled18 - amountOutScaled18,
        );
        return calculatedAmountScaled18;
    }
    computeInvariant(
        balancesLiveScaled18: bigint[],
        rounding: Rounding,
    ): bigint {
        this.ensureMinTokenBalances(balancesLiveScaled18);
        if (rounding === Rounding.ROUND_UP)
            return _computeInvariantUp(
                this.normalizedWeights,
                balancesLiveScaled18,
            );
        else
            return _computeInvariantDown(
                this.normalizedWeights,
                balancesLiveScaled18,
            );
    }
    computeBalance(
        balancesLiveScaled18: bigint[],
        tokenInIndex: number,
        invariantRatio: bigint,
    ): bigint {
        const originalBalance = balancesLiveScaled18[tokenInIndex];
        const newBalance = _computeBalanceOutGivenInvariant(
            originalBalance,
            this.normalizedWeights[tokenInIndex],
            invariantRatio,
        );
        // WeightedPool.computeBalance: whichever of the two balances is lower must stay above the minimum.
        this.ensureMinimumBalance(
            tokenInIndex,
            originalBalance <= newBalance ? originalBalance : newBalance,
        );
        return newBalance;
    }
}
