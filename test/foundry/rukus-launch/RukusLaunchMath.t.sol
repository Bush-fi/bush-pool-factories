// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import { IRukusLaunchPool } from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";
import { RukusLaunchMath } from "../../../contracts/rukus-launch/lib/RukusLaunchMath.sol";
import { RukusLaunchPoolFactoryLib } from "../../../contracts/rukus-launch/lib/RukusLaunchPoolFactoryLib.sol";

/// @notice The bonding curve setup and the graduation solve, over the whole parameter range the factory accepts.
contract RukusLaunchMathTest is Test {
    using FixedPoint for uint256;

    uint256 internal constant _MAX_PRICE_RATIO = 20e18; // ReClammPoolFactoryLib.MAX_PRICE_RATIO
    uint256 internal constant _MIN_PRICE_RATIO = 1.0001e18; // ReClammPoolFactoryLib.MIN_PRICE_RATIO

    /// @dev The curve starts at P0, reaches P1 at the graduation balance, and is balanced (quote raised = P1 * Rt1) there.
    function testBondingCurve__Fuzz(uint256 launchBalance, uint256 initialPrice, uint256 bondingPriceRatio) public pure {
        launchBalance = bound(launchBalance, 1e18, 1e30);
        initialPrice = bound(initialPrice, 1e9, 1e24);
        bondingPriceRatio = bound(
            bondingPriceRatio,
            RukusLaunchPoolFactoryLib.MIN_BONDING_PRICE_RATIO,
            RukusLaunchPoolFactoryLib.MAX_BONDING_PRICE_RATIO
        );
        uint256 graduationPrice = initialPrice.mulDown(bondingPriceRatio);

        (uint256 virtualLaunch, uint256 virtualQuote, uint256 graduationBalance) = RukusLaunchMath
            .computeBondingCurve(launchBalance, initialPrice, graduationPrice);

        _assertClose(virtualQuote.divDown(launchBalance + virtualLaunch), initialPrice, "Initial price");

        // Walk the curve to the graduation balance: (Rt1 + Vt)(Rq1 + Vq) = (Rt0 + Vt) Vq.
        uint256 totalLaunch = graduationBalance + virtualLaunch;
        uint256 totalQuote = ((launchBalance + virtualLaunch) * virtualQuote) / totalLaunch;
        uint256 quoteRaised = totalQuote - virtualQuote;

        _assertClose(totalQuote.divDown(totalLaunch), graduationPrice, "Graduation price");
        _assertClose(quoteRaised, graduationBalance.mulDown(graduationPrice), "Not balanced at graduation");
    }

    /// @dev Within 1e-8, or 10 wei. Dust launches (one token at the lowest prices) raise only ~1e9-1e11 wei of quote,
    /// so wei rounding alone is ~1e-9 of the result (seen: 5 wei off 3.8e9, 180 wei off 1.76e11). Real launches are far
    /// more precise; 1e-8 is still 1,000x under the minimum swap fee.
    function _assertClose(uint256 actual, uint256 expected, string memory message) internal pure {
        uint256 tolerance = expected / 1e8;
        assertApproxEqAbs(actual, expected, tolerance > 10 ? tolerance : 10, message);
    }

    /**
     * @dev Graduation keeps the price, and gives the requested price ratio, from any state the curve can complete in.
     * The launch side (A here) can be anything down to empty (a buy can overshoot to the last token). The quote side
     * cannot be small: completing the curve takes at least `(r - 1) / r` of its total in real quote, with
     * r = sqrt(graduationPrice / initialPrice) >= sqrt(1.01), so >= 0.5%. Fees and overshoot only add to it, and
     * liquidity is locked. The fuzz goes 50x below that. Virtual balances start at one whole token: below that, wei
     * granularity alone moves the price by more than the tolerance (a launch has Vt >= supply / 1e6).
     */
    function testGraduationVirtualBalances__Fuzz(
        uint256[2] memory balanceSeeds,
        uint256[2] memory virtualSeeds,
        uint256 priceRatio
    ) public pure {
        uint256 virtualA = bound(virtualSeeds[0], 1e18, 1e30);
        uint256 virtualB = bound(virtualSeeds[1], 1e18, 1e30);
        uint256[] memory balances = new uint256[](2);
        balances[0] = bound(balanceSeeds[0], 0, 1e30);
        balances[1] = bound(balanceSeeds[1], virtualB / 1e4, 1e30);
        priceRatio = bound(priceRatio, _MIN_PRICE_RATIO, _MAX_PRICE_RATIO);

        (uint256 newVirtualA, uint256 newVirtualB) = RukusLaunchMath.computeGraduationVirtualBalances(
            balances,
            virtualA,
            virtualB,
            ReClammMath.sqrtScaled18(priceRatio)
        );

        // Same price: (Rb + Vb') / (Ra + Va') == (Rb + Vb) / (Ra + Va), cross-multiplied. The real shares are 18-decimal,
        // so when one is tiny the price can move by ~1e-12; the tolerance (1e-10) is still 1e5 below the minimum fee.
        assertApproxEqRel(
            (balances[1] + newVirtualB) * (balances[0] + virtualA),
            (balances[1] + virtualB) * (balances[0] + newVirtualA),
            1e8,
            "Graduation moved the price"
        );
        assertApproxEqRel(ReClammMath.computePriceRatio(balances, newVirtualA, newVirtualB), priceRatio, 1e9, "Ratio");
    }

    /// @dev With equal value on both sides, the solve is ReClamm's centered initialization: Va = Ra / (Q^(1/4) - 1).
    function testGraduationOfBalancedPoolIsCentered__Fuzz(uint256 launchBalance, uint256 priceRatio) public pure {
        launchBalance = bound(launchBalance, 1e18, 1e30);
        priceRatio = bound(priceRatio, _MIN_PRICE_RATIO, _MAX_PRICE_RATIO);

        // Rt1 and Rq1 from the default test curve's shape (P1 / P0 = 16): both are (r - 1) / r of their totals.
        uint256[] memory balances = new uint256[](2);
        balances[0] = launchBalance;
        balances[1] = launchBalance / 2;
        uint256 virtualA = launchBalance / 3;
        uint256 virtualB = launchBalance / 6;

        (uint256 newVirtualA, uint256 newVirtualB) = RukusLaunchMath.computeGraduationVirtualBalances(
            balances,
            virtualA,
            virtualB,
            ReClammMath.sqrtScaled18(priceRatio)
        );

        (uint256 centeredness, ) = ReClammMath.computeCenteredness(balances, newVirtualA, newVirtualB);
        assertApproxEqAbs(centeredness, 1e18, 1e9, "Not centered");

        uint256 expectedVirtualA = launchBalance.divDown(ReClammMath.fourthRootScaled18(priceRatio) - 1e18);
        assertApproxEqRel(newVirtualA, expectedVirtualA, 1e9, "Not ReClamm's centered virtual balance");
    }

    /**
     * @dev The graduation the pool actually runs: at the fixed 1e12x width, from any state a curve can complete in.
     * Any supply and prices the factory accepts, an overshoot anywhere from none to all but one wei of the launch
     * balance, and up to 10% extra quote (fees). The solve must never revert (a reverting graduation would freeze the
     * pool for good), must keep the price, and must leave both virtual balances non-zero.
     */
    function testGraduationAtFullRangeNeverReverts__Fuzz(
        uint256 launchBalance,
        uint256 initialPrice,
        uint256 bondingPriceRatio,
        uint256 launchLeftSeed,
        uint256 extraQuote
    ) public pure {
        launchBalance = bound(launchBalance, 1e18, 1e30);
        initialPrice = bound(initialPrice, 1e9, 1e24);
        bondingPriceRatio = bound(
            bondingPriceRatio,
            RukusLaunchPoolFactoryLib.MIN_BONDING_PRICE_RATIO,
            RukusLaunchPoolFactoryLib.MAX_BONDING_PRICE_RATIO
        );
        uint256 graduationPrice = initialPrice.mulDown(bondingPriceRatio);
        (uint256 virtualLaunch, uint256 virtualQuote, uint256 graduationBalance) = RukusLaunchMath
            .computeBondingCurve(launchBalance, initialPrice, graduationPrice);

        // Bought down to anywhere from the graduation balance to 1 wei, along the curve; then extra quote (fees).
        uint256 launchLeft = bound(launchLeftSeed, 1, graduationBalance);
        uint256 quote = ((launchBalance + virtualLaunch) * virtualQuote) / (launchLeft + virtualLaunch) - virtualQuote;
        quote += quote.mulDown(bound(extraQuote, 0, 10e16));

        uint256[] memory balances = new uint256[](2);
        balances[0] = launchLeft;
        balances[1] = quote;

        (uint256 newVirtualA, uint256 newVirtualB) = RukusLaunchMath.computeGraduationVirtualBalances(
            balances,
            virtualLaunch,
            virtualQuote,
            1e6 * 1e18 // sqrt(RukusLaunchPool.GRADUATED_PRICE_RATIO)
        );

        assertGt(newVirtualA, 0, "Zero virtual A");
        assertGt(newVirtualB, 0, "Zero virtual B");
        // Within 1e-8: dust launches (one token at the lowest price, ~1e9 wei of quote) carry wei-granularity error of
        // a few 1e-10; normal launches are far below that. Still 1,000x under the minimum swap fee (1e-5).
        assertApproxEqRel(
            (balances[1] + newVirtualB) * (balances[0] + virtualLaunch),
            (balances[1] + virtualQuote) * (balances[0] + newVirtualA),
            1e10,
            "Graduation moved the price"
        );
    }

    /// @dev A supply too small for its curve rounds the virtual launch balance to 0: refused, not a curve with no depth.
    /// forge-config: default.allow_internal_expect_revert = true
    function testBondingCurveRejectsZeroVirtualBalance() public {
        // Va = Rt0 * P0 / (P1 - P0) = 1 wei * 1 / 15, rounded down to 0.
        vm.expectRevert(IRukusLaunchPool.ZeroVirtualBalance.selector);
        RukusLaunchMath.computeBondingCurve(1, 1e18, 16e18);
    }

    /// @dev A pool with no real balances has no price to keep: the solve refuses it (graduation can't get there; a
    /// completed curve always holds quote and launch tokens).
    /// forge-config: default.allow_internal_expect_revert = true
    function testGraduationRejectsEmptyPool() public {
        uint256[] memory balances = new uint256[](2);
        vm.expectRevert(IRukusLaunchPool.ZeroVirtualBalance.selector);
        RukusLaunchMath.computeGraduationVirtualBalances(balances, 1e18, 1e18, 1e6 * 1e18);
    }

    /// @dev Totals so small that a graduated virtual balance rounds to 0 wei: refused, so the pool can never quote a
    /// price of 0 or infinity.
    /// forge-config: default.allow_internal_expect_revert = true
    function testGraduationRejectsVirtualBalanceRoundingToZero() public {
        // Token A: 1 wei real + 1 wei virtual. Its graduated virtual balance is ~2 * 0.0005 wei, rounded down to 0.
        uint256[] memory balances = new uint256[](2);
        balances[0] = 1;
        balances[1] = 1e30;
        vm.expectRevert(IRukusLaunchPool.ZeroVirtualBalance.selector);
        RukusLaunchMath.computeGraduationVirtualBalances(balances, 1, 1e30, 1e6 * 1e18);
    }
}
