// Port of contracts/bonding-reclamm/lib/BondingReClammMath.sol: the graduation solve (the bonding curve setup only
// runs at initialization, so the maths never needs it). Call for call, with the same fixed-point primitives.

import { MathSol, ReClammMath, sqrt, WAD } from '../poolKit';

/**
 * BondingReClammMath.computeGraduationVirtualBalances: new virtual balances for the ReClamm range at the current
 * price, for the given sqrt(price ratio). See the contract for the derivation.
 */
export function computeGraduationVirtualBalances(
    balancesScaled18: bigint[],
    virtualBalanceA: bigint,
    virtualBalanceB: bigint,
    sqrtPriceRatio: bigint,
): { virtualBalanceA: bigint; virtualBalanceB: bigint } {
    const totalA = balancesScaled18[ReClammMath.a] + virtualBalanceA;
    const totalB = balancesScaled18[ReClammMath.b] + virtualBalanceB;

    const alpha = MathSol.divDownFixed(balancesScaled18[ReClammMath.a], totalA);
    const beta = MathSol.divDownFixed(balancesScaled18[ReClammMath.b], totalB);

    const linearTerm = MathSol.mulDownFixed(sqrtPriceRatio, alpha + beta);
    const productTerm = 4n * (sqrtPriceRatio - WAD) * MathSol.mulDownFixed(MathSol.mulDownFixed(sqrtPriceRatio, alpha), beta);
    const squaredLinearTerm = linearTerm * linearTerm;
    const discriminant = squaredLinearTerm > productTerm ? squaredLinearTerm - productTerm : 0n;

    const u = MathSol.divDownFixed(linearTerm + sqrt(discriminant), 2n * (sqrtPriceRatio - WAD));

    if (u <= alpha || u <= beta) throw new Error('ZeroVirtualBalance');

    const newVirtualBalanceA = MathSol.mulDownFixed(totalA, u - alpha);
    const newVirtualBalanceB = MathSol.mulDownFixed(totalB, u - beta);

    if (newVirtualBalanceA === 0n || newVirtualBalanceB === 0n) throw new Error('ZeroVirtualBalance');

    return { virtualBalanceA: newVirtualBalanceA, virtualBalanceB: newVirtualBalanceB };
}
