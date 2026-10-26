// Port of contracts/rukus-launch/RukusLaunchPool.sol, implementing the bush-maths `PoolBase` interface.
//
// A RukusLaunch pool sells its launch token along a bonding curve (pump.fun's virtual-reserve curve) and then
// graduates, in place, into a (practically) full-range pool. The swap maths is ReClamm's (constant product on real +
// virtual balances) in both phases; what changes is the virtual balances it runs with:
//   - BONDING:   the bonding curve's, which never move (and the buy completing the curve may go at most 0.1% past
//                the graduation balance);
//   - COMPLETED: the curve sold out. In the block it did, every operation reverts (GraduationPending). In a later
//                block, the first operation graduates the pool: the virtual balances are re-solved at the current
//                price for the graduated width (1e12x), and that operation runs on the result;
//   - GRADUATED: the graduated ones, which never move with time (only proportional adds and removes scale them).
// Liquidity is proportional only (adds/removes are locked until graduation, which the Vault's flow here does not
// model: the generator records only operations the chain accepted).

import {
    MathSol,
    MAX_UINT256,
    ReClammMath,
    toRawUndoRateRoundDown,
    type MaxSingleTokenRemoveParams,
    type MaxSwapParams,
    type PoolBase,
    Rounding,
    SwapKind,
    type SwapParams,
} from '../poolKit';
import type { RukusLaunchState } from './data';
import { computeGraduationVirtualBalances } from './rukusLaunchMath';

/** IRukusLaunchPool.BondingPhase. */
export enum BondingPhase {
    BONDING = 0,
    COMPLETED = 1,
    GRADUATED = 2,
}

/** RukusLaunchPool.MAX_GRADUATION_OVERSHOOT: 0.1% of the graduation balance. */
export const MAX_GRADUATION_OVERSHOOT = 1_000_000_000_000_000n;

export class RukusLaunch implements PoolBase {
    public phase: BondingPhase;
    public launchTokenIndex: number;
    public graduationLaunchBalance: bigint;
    public bondingCompletedAt: bigint;
    public graduatedPriceRatio: bigint;
    public virtualBalanceA: bigint;
    public virtualBalanceB: bigint;
    public currentTimestamp: bigint;

    constructor(poolState: RukusLaunchState) {
        this.phase = Number(poolState.phase) as BondingPhase;
        this.launchTokenIndex = Number(poolState.launchTokenIndex);
        this.graduationLaunchBalance = poolState.graduationLaunchBalance;
        this.bondingCompletedAt = poolState.bondingCompletedAt;
        this.graduatedPriceRatio = poolState.graduatedPriceRatio;
        [this.virtualBalanceA, this.virtualBalanceB] = poolState.virtualBalances;
        this.currentTimestamp = poolState.currentTimestamp;
    }

    // The invariant ratio bounds are required by the interface but unused: liquidity is proportional only.
    getMaximumInvariantRatio(): bigint {
        return 0n;
    }

    getMinimumInvariantRatio(): bigint {
        return 0n;
    }

    /**
     * Largest swap the pool accepts: the one that takes the whole real balance of the token out, or, for a buy while
     * bonding, the one that takes the launch balance down to the overshoot limit.
     */
    getMaxSwapAmount(p: MaxSwapParams): bigint {
        const { balancesLiveScaled18, indexIn, indexOut, tokenRates, scalingFactors, swapKind } = p;
        const { virtualBalanceA, virtualBalanceB } = this.swapVirtualBalances(balancesLiveScaled18);
        const [virtualIn, virtualOut] = indexIn === 0 ? [virtualBalanceA, virtualBalanceB] : [virtualBalanceB, virtualBalanceA];
        const balanceOut = balancesLiveScaled18[indexOut];

        let maxOut18 = balanceOut;
        if (this.phase === BondingPhase.BONDING && indexOut === this.launchTokenIndex) {
            const minLaunchBalance = this.minLaunchBalance();
            maxOut18 = balanceOut > minLaunchBalance ? balanceOut - minLaunchBalance : 0n;
        }

        if (swapKind === SwapKind.GivenIn) {
            // Solve computeOutGivenIn for Ao: Ai = Ao * (Bi + Vi) / (Bo + Vo - Ao).
            const maxIn18 = (maxOut18 * (balancesLiveScaled18[indexIn] + virtualIn)) / (balanceOut + virtualOut - maxOut18);
            return toRawUndoRateRoundDown(maxIn18, scalingFactors[indexIn], tokenRates[indexIn]);
        }
        return toRawUndoRateRoundDown(maxOut18, scalingFactors[indexOut], tokenRates[indexOut]);
    }

    /** RukusLaunchPool._minLaunchBalance: the graduation balance less the overshoot allowed. */
    minLaunchBalance(): bigint {
        return this.graduationLaunchBalance - MathSol.mulDownFixed(this.graduationLaunchBalance, MAX_GRADUATION_OVERSHOOT);
    }

    getMaxSingleTokenAddAmount(): bigint {
        return MAX_UINT256;
    }

    getMaxSingleTokenRemoveAmount(p: MaxSingleTokenRemoveParams): bigint {
        return p.tokenOutBalance;
    }

    /** RukusLaunchPool.onSwap. */
    onSwap(swapParams: SwapParams): bigint {
        const { swapKind, balancesLiveScaled18, indexIn, indexOut, amountGivenScaled18 } = swapParams;
        const { virtualBalanceA, virtualBalanceB } = this.swapVirtualBalances(balancesLiveScaled18);

        const amountCalculated =
            swapKind === SwapKind.GivenIn
                ? ReClammMath.computeOutGivenIn(balancesLiveScaled18, virtualBalanceA, virtualBalanceB, indexIn, indexOut, amountGivenScaled18)
                : ReClammMath.computeInGivenOut(balancesLiveScaled18, virtualBalanceA, virtualBalanceB, indexIn, indexOut, amountGivenScaled18);

        // While bonding, the buy that completes the curve may go at most MAX_GRADUATION_OVERSHOOT past it.
        if (this.phase === BondingPhase.BONDING && indexOut === this.launchTokenIndex) {
            const launchOut = swapKind === SwapKind.GivenIn ? amountCalculated : amountGivenScaled18;
            const launchBalanceAfter = balancesLiveScaled18[indexOut] - launchOut;
            if (launchBalanceAfter <= this.graduationLaunchBalance && launchBalanceAfter < this.minLaunchBalance()) {
                throw new Error('GraduationBuyTooLarge');
            }
        }
        return amountCalculated;
    }

    /** RukusLaunchPool.computeInvariant: a view, so a completed pool still uses the bonding virtual balances. */
    computeInvariant(balancesLiveScaled18: bigint[], rounding: Rounding): bigint {
        return ReClammMath.computeInvariant(balancesLiveScaled18, this.virtualBalanceA, this.virtualBalanceB, rounding);
    }

    /** RukusLaunchPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced adds and removes. */
    computeBalance(): bigint {
        throw new Error('NotImplemented');
    }

    /**
     * The virtual balances `onSwap` runs with: the stored ones (they never change with time), except that a COMPLETED
     * pool queried in a later block graduates first, as the contract does.
     */
    swapVirtualBalances(balancesLiveScaled18: bigint[]): { virtualBalanceA: bigint; virtualBalanceB: bigint } {
        if (this.phase === BondingPhase.COMPLETED) {
            // RukusLaunchPool._graduate.
            if (this.currentTimestamp <= this.bondingCompletedAt) throw new Error('GraduationPending');
            return computeGraduationVirtualBalances(
                balancesLiveScaled18,
                this.virtualBalanceA,
                this.virtualBalanceB,
                ReClammMath.sqrtScaled18(this.graduatedPriceRatio),
            );
        }
        return { virtualBalanceA: this.virtualBalanceA, virtualBalanceB: this.virtualBalanceB };
    }
}
