//  pnpm test -- bondingReClammPool.test.ts
//
// The overshoot clamp: while bonding, the buy that completes the curve may go at most 0.1% past the graduation
// balance (BondingReClammPool.MAX_GRADUATION_OVERSHOOT). The generated test data only records swaps the chain accepted,
// so the rejection is checked here.

import { describe, expect, test } from 'vitest';
import { SwapKind } from '../src/index';
import { BondingReClammState } from '../src/bondingReClamm/data';
import { BondingPhase, BondingReClamm } from '../src/bondingReClamm/bondingReClamm';

const E18 = 10n ** 18n;
const GRADUATION_BALANCE = 20_000_000n * E18;
// Graduation balance less 0.1% of it.
const MIN_LAUNCH_BALANCE = GRADUATION_BALANCE - GRADUATION_BALANCE / 1000n;
// 1,000 tokens above the graduation balance, on the default test curve (100M from 0.0001 to 0.0016).
const BALANCES = [GRADUATION_BALANCE + 1_000n * E18, 31_998n * E18];
const MAX_OUT = BALANCES[0] - MIN_LAUNCH_BALANCE;

function pool(phase: BondingPhase): BondingReClamm {
    return new BondingReClamm({
        poolAddress: '0x1234567890abcdef1234567890abcdef12345678',
        poolType: 'BONDING_RECLAMM',
        tokens: ['0xLaunch', '0xQuote'],
        scalingFactors: [1n, 1n],
        tokenRates: [E18, E18],
        balancesLiveScaled18: BALANCES,
        swapFee: 0n,
        aggregateSwapFee: 0n,
        totalSupply: E18,
        supportsUnbalancedLiquidity: false,
        currentTimestamp: 1_000_000n,
        phase: BigInt(phase),
        launchTokenIndex: 0n,
        graduationLaunchBalance: GRADUATION_BALANCE,
        bondingCompletedAt: 0n,
        graduatedPriceRatio: 10n ** 30n,
        virtualBalances: [6_666_666_666_666_666_666_666_666n, 10_666_666_666_666_666_666_666n],
    } as unknown as BondingReClammState);
}

const buyExactOut = (amountOut: bigint) => ({
    swapKind: SwapKind.GivenOut,
    amountGivenScaled18: amountOut,
    balancesLiveScaled18: BALANCES,
    indexIn: 1,
    indexOut: 0,
});

describe('bondingReClamm overshoot clamp', () => {
    test('a buy down to the limit is accepted', () => {
        expect(pool(BondingPhase.BONDING).onSwap(buyExactOut(MAX_OUT))).toBeGreaterThan(0n);
    });

    test('one wei past the limit is rejected', () => {
        expect(() => pool(BondingPhase.BONDING).onSwap(buyExactOut(MAX_OUT + 1n))).toThrow('GraduationBuyTooLarge');
    });

    test('an exact-in buy past the limit is rejected', () => {
        const p = pool(BondingPhase.BONDING);
        expect(() =>
            p.onSwap({ swapKind: SwapKind.GivenIn, amountGivenScaled18: 100_000n * E18, balancesLiveScaled18: BALANCES, indexIn: 1, indexOut: 0 }),
        ).toThrow('GraduationBuyTooLarge');
    });

    test('the max swap amount stops at the limit', () => {
        const p = pool(BondingPhase.BONDING);
        const params = { balancesLiveScaled18: BALANCES, tokenRates: [E18, E18], scalingFactors: [1n, 1n], indexIn: 1, indexOut: 0 };
        expect(p.getMaxSwapAmount({ ...params, swapKind: SwapKind.GivenOut })).toBe(MAX_OUT);
        const maxIn = p.getMaxSwapAmount({ ...params, swapKind: SwapKind.GivenIn });
        const out = p.onSwap({ swapKind: SwapKind.GivenIn, amountGivenScaled18: maxIn, balancesLiveScaled18: BALANCES, indexIn: 1, indexOut: 0 });
        expect(out).toBeLessThanOrEqual(MAX_OUT);
    });

    test('no clamp once graduated', () => {
        expect(pool(BondingPhase.GRADUATED).onSwap(buyExactOut(MAX_OUT * 100n))).toBeGreaterThan(0n);
    });
});
