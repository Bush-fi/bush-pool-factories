// Port of contracts/reclamm/lib/ReClammMath.sol. Every function mirrors its Solidity namesake call for call, with
// the same fixed-point primitives and rounding, so the results match the contract to the wei.
//
// ReClamm pools are always 2-token pools; token `a` is index 0 and token `b` index 1 (registration order).

import { WAD } from '../utils/math';
import { LogExpMath, MathSol } from '../utils/math';
import { sqrt } from '../utils/ozMath';
import { Rounding } from '../vault/types';

export const a = 0;
export const b = 1;

/** ReClammMath.PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT: scales the daily price shift exponent to the per-second tau. */
export const PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT = 124649n;

const THIRTY_DAYS = 30n * 24n * 60n * 60n;

/** ReClammMath.PriceRatioState (fourth roots are 18-decimal fixed point, times are unix seconds). */
export type PriceRatioState = {
    startFourthRootPriceRatio: bigint;
    endFourthRootPriceRatio: bigint;
    priceRatioUpdateStartTime: bigint;
    priceRatioUpdateEndTime: bigint;
};

/**
 * FixedPoint.powDown, ported exactly. `MathSol.powDownFixed` rounds the y == 2 / y == 4 shortcuts *up* (a
 * balancer-maths quirk), which is not what the contract does, so ReClamm keeps its own copy.
 */
function powDown(x: bigint, y: bigint): bigint {
    if (y === WAD) return x;
    if (y === 2n * WAD) return MathSol.mulDownFixed(x, x);
    if (y === 4n * WAD) {
        const square = MathSol.mulDownFixed(x, x);
        return MathSol.mulDownFixed(square, square);
    }
    const raw = LogExpMath.pow(x, y);
    const maxError = MathSol.mulUpFixed(raw, MathSol.MAX_POW_RELATIVE_ERROR) + 1n;
    return raw < maxError ? 0n : raw - maxError;
}

/** ReClammMath.computeInvariant (4-arg overload): (Ra + Va) * (Rb + Vb), without the square root. */
export function computeInvariant(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    rounding: Rounding,
): bigint {
    const mulUpOrDown = rounding === Rounding.ROUND_DOWN ? MathSol.mulDownFixed : MathSol.mulUpFixed;
    return mulUpOrDown(balancesScaled18[a] + virtualBalanceA, balancesScaled18[b] + virtualBalanceB);
}

/** ReClammMath.computeOutGivenIn: Ao = (Bo + Vo) * Ai / (Bi + Vi + Ai). */
export function computeOutGivenIn(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    tokenInIndex: number,
    tokenOutIndex: number,
    amountInScaled18: bigint,
): bigint {
    const [virtualBalanceTokenIn, virtualBalanceTokenOut] =
        tokenInIndex === a ? [virtualBalanceA, virtualBalanceB] : [virtualBalanceB, virtualBalanceA];

    const amountOutScaled18 =
        ((balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut) * amountInScaled18) /
        (balancesScaled18[tokenInIndex] + virtualBalanceTokenIn + amountInScaled18);

    // Amount out cannot be greater than the real balance of the token in the pool.
    if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) throw new Error('AmountOutGreaterThanBalance');

    return amountOutScaled18;
}

/** ReClammMath.computeInGivenOut: Ai = (Bi + Vi) * Ao / (Bo + Vo - Ao), rounded up. */
export function computeInGivenOut(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    tokenInIndex: number,
    tokenOutIndex: number,
    amountOutScaled18: bigint,
): bigint {
    // Amount out cannot be greater than the real balance of the token in the pool.
    if (amountOutScaled18 > balancesScaled18[tokenOutIndex]) throw new Error('AmountOutGreaterThanBalance');

    const [virtualBalanceTokenIn, virtualBalanceTokenOut] =
        tokenInIndex === a ? [virtualBalanceA, virtualBalanceB] : [virtualBalanceB, virtualBalanceA];

    // Round up to favor the vault (i.e. request larger amount in from the user).
    return MathSol.mulDivUpFixed(
        balancesScaled18[tokenInIndex] + virtualBalanceTokenIn,
        amountOutScaled18,
        balancesScaled18[tokenOutIndex] + virtualBalanceTokenOut - amountOutScaled18,
    );
}

/**
 * ReClammMath.computeCurrentVirtualBalances: the virtual balances at `currentTimestamp`, after applying any
 * in-progress price ratio update and, if the pool is outside the target range, the price range shift since
 * `lastTimestamp`. Returns the stored balances unchanged when queried in the block they were stored.
 */
export function computeCurrentVirtualBalances(
    balancesScaled18: bigint[],
    lastVirtualBalanceA: bigint,
    lastVirtualBalanceB: bigint,
    dailyPriceShiftBase: bigint,
    lastTimestamp: bigint,
    centerednessMargin: bigint,
    priceRatioState: PriceRatioState,
    currentTimestamp: bigint,
): { virtualBalanceA: bigint; virtualBalanceB: bigint; changed: boolean } {
    // Per-block VB freeze (see the contract for the rationale).
    if (lastTimestamp === currentTimestamp) {
        return { virtualBalanceA: lastVirtualBalanceA, virtualBalanceB: lastVirtualBalanceB, changed: false };
    }

    let currentVirtualBalanceA = lastVirtualBalanceA;
    let currentVirtualBalanceB = lastVirtualBalanceB;
    let changed = false;

    const currentFourthRootPriceRatio = computeFourthRootPriceRatio(
        currentTimestamp,
        priceRatioState.startFourthRootPriceRatio,
        priceRatioState.endFourthRootPriceRatio,
        priceRatioState.priceRatioUpdateStartTime,
        priceRatioState.priceRatioUpdateEndTime,
    );

    // If the price ratio is updating, shrink/expand the price interval by recalculating the virtual balances.
    if (
        currentTimestamp > priceRatioState.priceRatioUpdateStartTime &&
        lastTimestamp < priceRatioState.priceRatioUpdateEndTime
    ) {
        ({ virtualBalanceA: currentVirtualBalanceA, virtualBalanceB: currentVirtualBalanceB } =
            computeVirtualBalancesUpdatingPriceRatio(
                currentFourthRootPriceRatio,
                balancesScaled18,
                lastVirtualBalanceA,
                lastVirtualBalanceB,
            ));
        changed = true;
    }

    const { centeredness, isPoolAboveCenter } = computeCenteredness(
        balancesScaled18,
        currentVirtualBalanceA,
        currentVirtualBalanceB,
    );

    // If the pool is outside the target range, track the market price by moving the price interval.
    if (centeredness < centerednessMargin) {
        ({ virtualBalanceA: currentVirtualBalanceA, virtualBalanceB: currentVirtualBalanceB } =
            computeVirtualBalancesUpdatingPriceRange(
                balancesScaled18,
                currentVirtualBalanceA,
                currentVirtualBalanceB,
                isPoolAboveCenter,
                dailyPriceShiftBase,
                currentTimestamp,
                lastTimestamp,
            ));
        changed = true;
    }

    return { virtualBalanceA: currentVirtualBalanceA, virtualBalanceB: currentVirtualBalanceB, changed };
}

/** ReClammMath.computeVirtualBalancesUpdatingPriceRatio: new virtual balances for a target fourth-root price ratio. */
export function computeVirtualBalancesUpdatingPriceRatio(
    currentFourthRootPriceRatio: bigint,
    balancesScaled18: bigint[],
    lastVirtualBalanceA: bigint,
    lastVirtualBalanceB: bigint,
): { virtualBalanceA: bigint; virtualBalanceB: bigint } {
    const { centeredness: poolCenteredness, isPoolAboveCenter } = computeCenteredness(
        balancesScaled18,
        lastVirtualBalanceA,
        lastVirtualBalanceB,
    );

    const [balanceTokenUndervalued, lastVirtualBalanceUndervalued, lastVirtualBalanceOvervalued] = isPoolAboveCenter
        ? [balancesScaled18[a], lastVirtualBalanceA, lastVirtualBalanceB]
        : [balancesScaled18[b], lastVirtualBalanceB, lastVirtualBalanceA];

    const sqrtPriceRatio = MathSol.mulDownFixed(currentFourthRootPriceRatio, currentFourthRootPriceRatio);

    // Vu = Ru * (1 + c + sqrt(c * (c + 4 * sqrtQ - 2) + 1)) / (2 * (sqrtQ - 1))
    const virtualBalanceUndervalued =
        (balanceTokenUndervalued *
            (WAD +
                poolCenteredness +
                sqrt(poolCenteredness * (poolCenteredness + 4n * sqrtPriceRatio - 2n * WAD) + WAD * WAD))) /
        (2n * (sqrtPriceRatio - WAD));

    const virtualBalanceOvervalued =
        (virtualBalanceUndervalued * lastVirtualBalanceOvervalued) / lastVirtualBalanceUndervalued;

    return isPoolAboveCenter
        ? { virtualBalanceA: virtualBalanceUndervalued, virtualBalanceB: virtualBalanceOvervalued }
        : { virtualBalanceA: virtualBalanceOvervalued, virtualBalanceB: virtualBalanceUndervalued };
}

/**
 * ReClammMath.computeVirtualBalancesUpdatingPriceRange: shifts the price range toward the market price by decaying
 * the overvalued virtual balance over the elapsed time (capped at 30 days), then re-deriving the other one.
 */
export function computeVirtualBalancesUpdatingPriceRange(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    isPoolAboveCenter: boolean,
    dailyPriceShiftBase: bigint,
    currentTimestamp: bigint,
    lastTimestamp: bigint,
): { virtualBalanceA: bigint; virtualBalanceB: bigint } {
    const sqrtPriceRatio = sqrtScaled18(computePriceRatio(balancesScaled18, virtualBalanceA, virtualBalanceB));

    const [balancesScaledUndervalued, balancesScaledOvervalued] = isPoolAboveCenter
        ? [balancesScaled18[a], balancesScaled18[b]]
        : [balancesScaled18[b], balancesScaled18[a]];
    let [virtualBalanceUndervalued, virtualBalanceOvervalued] = isPoolAboveCenter
        ? [virtualBalanceA, virtualBalanceB]
        : [virtualBalanceB, virtualBalanceA];

    const duration = MathSol.min(currentTimestamp - lastTimestamp, THIRTY_DAYS);

    // Vo = Vo * (1 - tau)^duration
    virtualBalanceOvervalued = MathSol.mulUpFixed(virtualBalanceOvervalued, powDown(dailyPriceShiftBase, duration * WAD));

    // Never shrink Vo below what keeps the overvalued balance inside the price range.
    virtualBalanceOvervalued = MathSol.max(
        virtualBalanceOvervalued,
        MathSol.divUpFixed(balancesScaledOvervalued, sqrtScaled18(sqrtPriceRatio) - WAD),
    );

    // Vu = Ru * (Vo + Ro) / ((sqrtQ - 1) * Vo - Ro)
    virtualBalanceUndervalued =
        (balancesScaledUndervalued * (virtualBalanceOvervalued + balancesScaledOvervalued)) /
        (MathSol.mulUpFixed(sqrtPriceRatio - WAD, virtualBalanceOvervalued) - balancesScaledOvervalued);

    return isPoolAboveCenter
        ? { virtualBalanceA: virtualBalanceUndervalued, virtualBalanceB: virtualBalanceOvervalued }
        : { virtualBalanceA: virtualBalanceOvervalued, virtualBalanceB: virtualBalanceUndervalued };
}

/** ReClammMath.isPoolWithinTargetRange. */
export function isPoolWithinTargetRange(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    centerednessMargin: bigint,
): boolean {
    return computeCenteredness(balancesScaled18, virtualBalanceA, virtualBalanceB).centeredness >= centerednessMargin;
}

/**
 * ReClammMath.computeCenteredness: how close the pool is to the center of its price range (1 = centered, 0 = at an
 * edge), and on which side of the center it sits.
 */
export function computeCenteredness(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
): { centeredness: bigint; isPoolAboveCenter: boolean } {
    if (balancesScaled18[a] === 0n) return { centeredness: 0n, isPoolAboveCenter: false };
    if (balancesScaled18[b] === 0n) return { centeredness: 0n, isPoolAboveCenter: true };

    const numerator = balancesScaled18[a] * virtualBalanceB;
    const denominator = virtualBalanceA * balancesScaled18[b];

    const isPoolAboveCenter = numerator > denominator;

    // Math.mulDiv(x, ONE, y): exact, floored.
    const centeredness = isPoolAboveCenter ? (denominator * WAD) / numerator : (numerator * WAD) / denominator;

    return { centeredness, isPoolAboveCenter };
}

/** ReClammMath.computeFourthRootPriceRatio: the fourth-root price ratio interpolated (geometrically) at `currentTime`. */
export function computeFourthRootPriceRatio(
    currentTime: bigint,
    startFourthRootPriceRatio: bigint,
    endFourthRootPriceRatio: bigint,
    priceRatioUpdateStartTime: bigint,
    priceRatioUpdateEndTime: bigint,
): bigint {
    if (currentTime >= priceRatioUpdateEndTime) return endFourthRootPriceRatio;
    if (currentTime <= priceRatioUpdateStartTime) return startFourthRootPriceRatio;

    const exponent = MathSol.divDownFixed(
        currentTime - priceRatioUpdateStartTime,
        priceRatioUpdateEndTime - priceRatioUpdateStartTime,
    );

    const currentFourthRootPriceRatio = MathSol.mulDownFixed(
        startFourthRootPriceRatio,
        powDown(MathSol.divDownFixed(endFourthRootPriceRatio, startFourthRootPriceRatio), exponent),
    );

    // Since we're rounding current fourth root price ratio down, we only need to check the lower boundary.
    const minimumFourthRootPriceRatio = MathSol.min(startFourthRootPriceRatio, endFourthRootPriceRatio);
    return MathSol.max(minimumFourthRootPriceRatio, currentFourthRootPriceRatio);
}

/** ReClammMath.computePriceRatio: maxPrice / minPrice = ((1 + Ra/Va) * (1 + Rb/Vb))^2. */
export function computePriceRatio(balancesScaled18: bigint[], virtualBalanceA: bigint, virtualBalanceB: bigint): bigint {
    const sqrtPriceRatio = MathSol.mulDownFixed(
        WAD + MathSol.divDownFixed(balancesScaled18[a], virtualBalanceA),
        WAD + MathSol.divDownFixed(balancesScaled18[b], virtualBalanceB),
    );
    return MathSol.mulDownFixed(sqrtPriceRatio, sqrtPriceRatio);
}

/** ReClammMath.computePriceRange: the min and max price of token A in terms of token B. */
export function computePriceRange(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
): { minPrice: bigint; maxPrice: bigint } {
    const currentInvariant = computeInvariant(balancesScaled18, virtualBalanceA, virtualBalanceB, Rounding.ROUND_DOWN);

    // P_min(a) = Vb^2 / L
    const minPrice = (virtualBalanceB * virtualBalanceB) / currentInvariant;
    // P_max(a) = priceRatio * P_min(a)
    const maxPrice = MathSol.mulDownFixed(computePriceRatio(balancesScaled18, virtualBalanceA, virtualBalanceB), minPrice);

    return { minPrice, maxPrice };
}

/** ReClammMath.toDailyPriceShiftBase: 1 - tau, from the daily price shift exponent (percentage). */
export function toDailyPriceShiftBase(dailyPriceShiftExponent: bigint): bigint {
    return WAD - dailyPriceShiftExponent / PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT;
}

/** ReClammMath.toDailyPriceShiftExponent: the inverse of `toDailyPriceShiftBase`. */
export function toDailyPriceShiftExponent(dailyPriceShiftBase: bigint): bigint {
    return (WAD - dailyPriceShiftBase) * PRICE_SHIFT_EXPONENT_INTERNAL_ADJUSTMENT;
}

/** ReClammMath.sqrtScaled18: square root of an 18-decimal fixed-point number (floored). */
export function sqrtScaled18(valueScaled18: bigint): bigint {
    return sqrt(valueScaled18 * WAD);
}

/** ReClammMath.fourthRootScaled18. */
export function fourthRootScaled18(valueScaled18: bigint): bigint {
    return sqrt(sqrt(valueScaled18 * WAD) * WAD);
}
