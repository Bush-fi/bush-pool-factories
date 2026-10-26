// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath, a, b } from "../../reclamm/lib/ReClammMath.sol";
import { IRukusLaunchPool } from "../interfaces/IRukusLaunchPool.sol";

/**
 * @notice The two pieces of maths a RukusLaunch pool adds to ReClammMath: setting up the bonding curve, and
 * re-solving the virtual balances at graduation. Everything else (swaps, the invariant, range movement after
 * graduation) is ReClammMath as is.
 *
 * Both phases use the same invariant, `(Ra + Va)(Rb + Vb)`. While bonding, the virtual balances are fixed, which makes
 * the pool exactly a pump.fun-style virtual-reserve curve: `(Rt + Vt)(Rq + Vq) = k`, with the quote balance `Rq`
 * starting at zero (t = launch token, q = quote token).
 */
library RukusLaunchMath {
    using FixedPoint for uint256;

    /**
     * @notice The bonding curve's virtual balances, and the launch balance at which it completes.
     * @dev With `P0` the initial price, `P1` the graduation price and `r = sqrt(P1 / P0)`:
     *
     * +---------------------------------------------------------------+
     * |   Vt = Rt0 * P0 / (P1 - P0)      Vq = P0 * (Rt0 + Vt)          |
     * |   Rt1 = Rt0 / (r + 1)                                          |
     * +---------------------------------------------------------------+
     *
     * `Vq / (Rt0 + Vt) = P0` puts the starting price at P0. On the curve, the price at a launch balance Rt is
     * `k / (Rt + Vt)^2`, so it reaches P1 at `Rt + Vt = (Rt0 + Vt) / r`; solving that together with "the quote raised
     * equals `P1 * Rt`" gives the two expressions above. So at graduation the pool holds equal value of both tokens and
     * the ReClamm range it graduates into is centered. (pump.fun's constants, P1 / P0 ~ 14.7, give Rt1 ~ 20.7% of the
     * supply, which is the share pump.fun reserves for the migrated pool.)
     *
     * @param launchBalance The initial launch token balance Rt0 (scaled18)
     * @param initialPrice P0, as 18-decimal FP
     * @param graduationPrice P1, as 18-decimal FP (> P0)
     * @return virtualLaunch Vt
     * @return virtualQuote Vq
     * @return graduationLaunchBalance Rt1
     */
    function computeBondingCurve(
        uint256 launchBalance,
        uint256 initialPrice,
        uint256 graduationPrice
    ) internal pure returns (uint256 virtualLaunch, uint256 virtualQuote, uint256 graduationLaunchBalance) {
        virtualLaunch = Math.mulDiv(launchBalance, initialPrice, graduationPrice - initialPrice);
        virtualQuote = (launchBalance + virtualLaunch).mulDown(initialPrice);

        if (virtualLaunch == 0 || virtualQuote == 0) {
            revert IRukusLaunchPool.ZeroVirtualBalance();
        }

        uint256 sqrtBondingPriceRatio = ReClammMath.sqrtScaled18(graduationPrice.divDown(initialPrice));
        graduationLaunchBalance = launchBalance.divDown(sqrtBondingPriceRatio + FixedPoint.ONE);
    }

    /**
     * @notice New virtual balances for the ReClamm range, at the pool's current price, for a given price ratio.
     * @dev Graduation must not move the price (or it opens an arbitrage against the pool), so the new virtual balances
     * `Va', Vb'` must satisfy, with `X = Ra + Va` and `Y = Rb + Vb` the current totals:
     *
     * 1. (Rb + Vb') / (Ra + Va') = Y / X                       (same price)
     * 2. (1 + Ra/Va') (1 + Rb/Vb') = sqrt(priceRatio) = Q      (see ReClammMath.computePriceRatio)
     *
     * Writing `Ra + Va' = u X` (so `Rb + Vb' = u Y` by 1), and `alpha = Ra / X`, `beta = Rb / Y` (the real share of
     * each total, in [0, 1)), 2 becomes a quadratic in u:
     *
     *     (Q - 1) u^2 - Q (alpha + beta) u + Q alpha beta = 0
     *
     *           Q (alpha + beta) + sqrt(Q^2 (alpha + beta)^2 - 4 (Q - 1) Q alpha beta)
     *     u  =  -----------------------------------------------------------------------
     *                                         2 (Q - 1)
     *
     *     Va' = X (u - alpha)        Vb' = Y (u - beta)
     *
     * The discriminant is never negative (`(alpha + beta)^2 >= 4 alpha beta`), and the quadratic is negative at both
     * `u = alpha` and `u = beta` (it equals `-alpha^2` and `-beta^2` there), so the larger root is above both and the
     * new virtual balances are positive. When the pool holds equal value of both tokens (alpha == beta), this reduces
     * to ReClamm's centered initialization, `Va' = Ra / (Q^(1/2) - 1)` with `Q^(1/2)` the fourth root of the ratio.
     *
     * @param balancesScaled18 Current real balances
     * @param virtualBalanceA Current (bonding) virtual balance of token A
     * @param virtualBalanceB Current (bonding) virtual balance of token B
     * @param sqrtPriceRatio Square root of the graduated price ratio (18-decimal FP, > 1)
     * @return newVirtualBalanceA The graduated virtual balance of token A
     * @return newVirtualBalanceB The graduated virtual balance of token B
     */
    function computeGraduationVirtualBalances(
        uint256[] memory balancesScaled18,
        uint256 virtualBalanceA,
        uint256 virtualBalanceB,
        uint256 sqrtPriceRatio
    ) internal pure returns (uint256 newVirtualBalanceA, uint256 newVirtualBalanceB) {
        uint256 totalA = balancesScaled18[a] + virtualBalanceA;
        uint256 totalB = balancesScaled18[b] + virtualBalanceB;

        uint256 alpha = balancesScaled18[a].divDown(totalA);
        uint256 beta = balancesScaled18[b].divDown(totalB);

        // Q (alpha + beta), 18 decimals; its square and the product term are 36 decimals, so that Math.sqrt returns 18.
        uint256 linearTerm = sqrtPriceRatio.mulDown(alpha + beta);
        uint256 productTerm = 4 * (sqrtPriceRatio - FixedPoint.ONE) * sqrtPriceRatio.mulDown(alpha).mulDown(beta);
        uint256 squaredLinearTerm = linearTerm * linearTerm;
        // Never negative on paper; the guard only absorbs rounding when alpha ~ beta ~ 0.
        uint256 discriminant = squaredLinearTerm > productTerm ? squaredLinearTerm - productTerm : 0;

        uint256 u = (linearTerm + Math.sqrt(discriminant)).divDown(2 * (sqrtPriceRatio - FixedPoint.ONE));

        if (u <= alpha || u <= beta) {
            revert IRukusLaunchPool.ZeroVirtualBalance();
        }

        newVirtualBalanceA = totalA.mulDown(u - alpha);
        newVirtualBalanceB = totalB.mulDown(u - beta);

        if (newVirtualBalanceA == 0 || newVirtualBalanceB == 0) {
            revert IRukusLaunchPool.ZeroVirtualBalance();
        }
    }
}
