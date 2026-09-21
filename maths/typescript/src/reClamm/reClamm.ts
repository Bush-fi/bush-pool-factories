// Port of contracts/reclamm/ReClammPool.sol: the pool-level maths on top of ReClammMath.
//
// A ReClamm pool is a 2-token constant-product pool with virtual balances that bound the price to a range, and that
// move over time to re-center the range on the market price. Liquidity can only be added or removed proportionally
// (the Vault handles that without the pool), so the pool's job is swaps and the invariant.

import { MAX_UINT256 } from '../constants';
import { toRawUndoRateRoundDown } from '../vault/utils';
import {
    MaxSingleTokenRemoveParams,
    MaxSwapParams,
    PoolBase,
    Rounding,
    SwapKind,
    SwapParams,
} from '../vault/types';
import type { ReClammState } from './data';
import {
    computeCurrentVirtualBalances,
    computeInGivenOut,
    computeInvariant,
    computeOutGivenIn,
    PriceRatioState,
} from './reClammMath';

/** ReClammPool._MIN_SWAP_FEE_PERCENTAGE / _MAX_SWAP_FEE_PERCENTAGE. */
export const MIN_SWAP_FEE_PERCENTAGE = 1000000000000n; // 0.001%
export const MAX_SWAP_FEE_PERCENTAGE = 100000000000000000n; // 10%

export class ReClamm implements PoolBase {
    public lastVirtualBalanceA: bigint;
    public lastVirtualBalanceB: bigint;
    public dailyPriceShiftBase: bigint;
    public lastTimestamp: bigint;
    public centerednessMargin: bigint;
    public priceRatioState: PriceRatioState;
    public currentTimestamp: bigint;

    constructor(poolState: ReClammState) {
        [this.lastVirtualBalanceA, this.lastVirtualBalanceB] = poolState.lastVirtualBalances;
        this.dailyPriceShiftBase = poolState.dailyPriceShiftBase;
        this.lastTimestamp = poolState.lastTimestamp;
        this.centerednessMargin = poolState.centerednessMargin;
        this.priceRatioState = {
            startFourthRootPriceRatio: poolState.startFourthRootPriceRatio,
            endFourthRootPriceRatio: poolState.endFourthRootPriceRatio,
            priceRatioUpdateStartTime: poolState.priceRatioUpdateStartTime,
            priceRatioUpdateEndTime: poolState.priceRatioUpdateEndTime,
        };
        this.currentTimestamp = poolState.currentTimestamp;
    }

    // The invariant ratio bounds are required by the interface but unused: liquidity is proportional only.
    getMaximumInvariantRatio(): bigint {
        return 0n;
    }

    getMinimumInvariantRatio(): bigint {
        return 0n;
    }

    /** Largest swap the pool accepts: the one that takes the whole real balance of the token out. */
    getMaxSwapAmount(p: MaxSwapParams): bigint {
        const { balancesLiveScaled18, indexIn, indexOut, tokenRates, scalingFactors, swapKind } = p;
        const { virtualBalanceA, virtualBalanceB } = this.currentVirtualBalances(balancesLiveScaled18);
        const [virtualIn, virtualOut] = indexIn === 0 ? [virtualBalanceA, virtualBalanceB] : [virtualBalanceB, virtualBalanceA];
        const balanceOut = balancesLiveScaled18[indexOut];

        if (swapKind === SwapKind.GivenIn) {
            // Solve computeOutGivenIn for Ao == Bo: Ai = Bo * (Bi + Vi) / Vo.
            const maxIn18 = (balanceOut * (balancesLiveScaled18[indexIn] + virtualIn)) / virtualOut;
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

    /** ReClammPool.onSwap. */
    onSwap(swapParams: SwapParams): bigint {
        const { swapKind, balancesLiveScaled18, indexIn, indexOut, amountGivenScaled18 } = swapParams;
        const { virtualBalanceA, virtualBalanceB } = this.currentVirtualBalances(balancesLiveScaled18);

        if (swapKind === SwapKind.GivenIn) {
            return computeOutGivenIn(balancesLiveScaled18, virtualBalanceA, virtualBalanceB, indexIn, indexOut, amountGivenScaled18);
        }
        return computeInGivenOut(balancesLiveScaled18, virtualBalanceA, virtualBalanceB, indexIn, indexOut, amountGivenScaled18);
    }

    /** ReClammPool.computeInvariant. */
    computeInvariant(balancesLiveScaled18: bigint[], rounding: Rounding): bigint {
        const { virtualBalanceA, virtualBalanceB } = this.currentVirtualBalances(balancesLiveScaled18);
        return computeInvariant(balancesLiveScaled18, virtualBalanceA, virtualBalanceB, rounding);
    }

    /** ReClammPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced adds and removes. */
    computeBalance(): bigint {
        throw new Error('NotImplemented');
    }

    /** ReClammPool._computeCurrentVirtualBalances: the virtual balances as of `currentTimestamp`. */
    currentVirtualBalances(balancesLiveScaled18: bigint[]): { virtualBalanceA: bigint; virtualBalanceB: bigint; changed: boolean } {
        return computeCurrentVirtualBalances(
            balancesLiveScaled18,
            this.lastVirtualBalanceA,
            this.lastVirtualBalanceB,
            this.dailyPriceShiftBase,
            this.lastTimestamp,
            this.centerednessMargin,
            this.priceRatioState,
            this.currentTimestamp,
        );
    }
}

