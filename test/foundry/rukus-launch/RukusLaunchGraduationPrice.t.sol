// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ArrayHelpers } from "@bush.fi/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import {
    IRukusLaunchPool,
    BondingPhase,
    RukusLaunchCurveParams
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

/**
 * @notice Graduation must not move the launch token's price: the curve's virtual balances are replaced, the real
 * balances stay, and the spot price (Rq + Vq) / (Rl + Vl) must come out the same.
 * @dev Prices are compared exactly, by cross-multiplying the totals (no division, so no 18-decimal rounding of the
 * price itself: `computeCurrentLaunchTokenPrice` rounds to 1 wei, which for a 1e-8 ETH token is already 1e-10 of it).
 * The error is reported in parts per 1e36. The swap fee floor is 0.001% (1e13 parts per 1e18): any move below it can't
 * be arbitraged, and the bound here is ~1e11 times tighter than that.
 *
 * Balances are whole wei, so no pool can state a price more finely than 1 wei of its smaller total. The bound allows
 * that granularity on top of 1e-15. It only matters for dust launches (e.g. 1 token at 1e-12 ETH, a raise of ~5e5 wei);
 * for any launch whose totals are above ~1e15 wei, 1e-15 is the whole bound.
 */
contract RukusLaunchGraduationPriceTest is BaseRukusLaunchTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    /// @dev The largest price change graduation may cause: 1e-15 of the price (in parts per 1e36).
    uint256 internal constant _MAX_PRICE_ERROR = 1e21;
    uint256 internal constant _PRECISION = 1e36;

    bytes32 internal constant _VIRTUAL_BALANCES_UPDATED = keccak256("VirtualBalancesUpdated(uint256,uint256)");

    /**
     * @dev Any launch the factory accepts, any bonding history, any completing buy the overshoot limit allows, any
     * swap fee: graduation keeps the price to within 1e-15 of it. Each run deploys a factory and runs ~10 trades
     * through the Vault, so it runs fewer times than the default.
     */
    /// forge-config: default.fuzz.runs = 2000
    function testGraduationKeepsThePriceExactly__Fuzz(
        uint256 supply,
        uint256 initialPrice,
        uint256 bondingPriceRatio,
        uint256 swapFee,
        uint256 overshootSeed,
        uint256 historySeed
    ) public {
        supply = bound(supply, 1e18, 1e30);
        initialPrice = bound(initialPrice, 1e6, 1e18);
        bondingPriceRatio = bound(bondingPriceRatio, 1.01e18, 1e6 * 1e18);
        // 0.5% to 5% (enough to cover the Rukus cut), at the Vault's 1e11 precision.
        swapFee = (bound(swapFee, 0.5e16, 5e16) / 1e11) * 1e11;
        vm.assume(_tryLaunch(supply, initialPrice, initialPrice.mulDown(bondingPriceRatio), swapFee));

        _tradeTheCurve(historySeed);
        _completeWithOvershoot(overshootSeed);

        (uint256 error, uint256 granularity) = _graduateAndMeasure();
        assertLe(error, _MAX_PRICE_ERROR + granularity, "Graduation moved the price by more than 1e-15 (plus 1 wei)");
    }

    /**
     * @dev A sweep from tiny to huge launches: 1 token to 1 trillion, prices from 1e-12 to 1 ETH, bonding ratios from
     * 1.01x to 1,000,000x, completed exactly and at the overshoot limit. Logs the worst price error seen. (Split by
     * supply to stay under the gas limit of unoptimized coverage builds.)
     */
    function testGraduationPriceErrorSweep_OneToken() public {
        _sweep(1e18);
    }

    function testGraduationPriceErrorSweep_OneBillionTokens() public {
        _sweep(1e27);
    }

    function testGraduationPriceErrorSweep_OneTrillionTokens() public {
        _sweep(1e30);
    }

    /**
     * @dev Graduation lands on the same virtual balances whichever operation triggers it: `graduate()`, the first swap
     * after completion, or the first proportional add. (The swap and the add then trade or scale on top of that.)
     */
    function testEveryGraduationPathGivesTheSameVirtualBalances() public {
        _completeWithOvershoot(12345);
        vm.warp(block.timestamp + 1);

        uint256 snapshot = vm.snapshotState();
        _brc().graduate();
        (uint256 expectedA, uint256 expectedB) = _brc().getVirtualBalances();
        vm.revertToState(snapshot);

        // The first swap after completion.
        vm.recordLogs();
        _buyExactIn(bob, 1e18);
        (uint256 swapA, uint256 swapB) = _graduationVirtualBalances(vm.getRecordedLogs());
        assertEq(swapA, expectedA, "Swap: virtual A");
        assertEq(swapB, expectedB, "Swap: virtual B");
        vm.revertToState(snapshot);

        // The first proportional add after completion.
        _giveLaunchTokens(lp, _LAUNCH_SUPPLY);
        vm.recordLogs();
        vm.prank(lp);
        router.addLiquidityProportional(pool, [MAX_UINT128, MAX_UINT128].toMemoryArray(), 1e18, false, "");
        (uint256 addA, uint256 addB) = _graduationVirtualBalances(vm.getRecordedLogs());
        assertEq(addA, expectedA, "Add: virtual A");
        assertEq(addB, expectedB, "Add: virtual B");
    }

    /**
     * @dev What a trader sees: the first small buy and sell after graduation execute at the price the curve ended on,
     * apart from the fee and the trade's own (tiny) price impact.
     */
    function testFirstTradesAfterGraduationAreAtTheCurvesPrice() public {
        _completeCurve(alice);
        (uint256 launchTotal, uint256 quoteTotal) = _totals();
        vm.warp(block.timestamp + 1);
        _brc().graduate();

        // 0.001% of the pool's WETH: the price impact is about that much, the fee is 1%.
        (, uint256 quoteBalance) = _liveBalances();
        uint256 quoteIn = quoteBalance / 100_000;
        uint256 launchOut = _buyExactIn(bob, quoteIn);
        // Expected out at the curve's last price, after the fee: quoteIn (1 - fee) * launchTotal / quoteTotal.
        uint256 expectedOut = Math.mulDiv(quoteIn.mulDown(FixedPoint.ONE - _SWAP_FEE), launchTotal, quoteTotal);
        assertLe(launchOut, expectedOut, "Bought more than the curve's price allows");
        assertApproxEqRel(launchOut, expectedOut, 2e13, "First buy not at the curve's price (beyond its impact)");

        uint256 quoteOut = _sellExactIn(bob, launchOut);
        assertLt(quoteOut, quoteIn, "Round trip made a profit");
        assertApproxEqRel(quoteOut, quoteIn.mulDown(FixedPoint.ONE - _SWAP_FEE).mulDown(FixedPoint.ONE - _SWAP_FEE), 4e13, "Sell");
    }

    /***************************************************************************
                                    Helpers
    ***************************************************************************/

    function _sweep(uint256 supply) internal {
        uint256[3] memory initialPrices = [uint256(1e6), 1e12, 1e18];
        uint256[3] memory ratios = [uint256(1.01e18), 16e18, 1e6 * 1e18];

        uint256 worst;
        uint256 worstDust;
        uint256 cases;
        uint256 dustCases;
        for (uint256 p = 0; p < initialPrices.length; ++p) {
            for (uint256 r = 0; r < ratios.length; ++r) {
                for (uint256 o = 0; o < 2; ++o) {
                    uint256 snapshot = vm.snapshotState();
                    uint256 graduationPrice = initialPrices[p].mulDown(ratios[r]);
                    if (_tryLaunch(supply, initialPrices[p], graduationPrice, _SWAP_FEE)) {
                        _completeWithOvershoot(o == 0 ? 0 : type(uint256).max);
                        (uint256 error, uint256 granularity) = _graduateAndMeasure();
                        assertLe(error, _MAX_PRICE_ERROR + granularity, "Graduation moved the price");
                        if (granularity > _MAX_PRICE_ERROR) {
                            if (error > worstDust) worstDust = error;
                            ++dustCases;
                        } else {
                            if (error > worst) worst = error;
                            ++cases;
                        }
                    }
                    vm.revertToState(snapshot);
                }
            }
        }

        assertGt(cases + dustCases, 10, "Too few launches in the sweep");
        assertLe(worst, _MAX_PRICE_ERROR, "Graduation moved the price by more than 1e-15");
        console2.log("graduation price sweep, supply (tokens):", supply / 1e18);
        console2.log("  launches:", cases);
        console2.log("  worst price change (parts per 1e36):", worst);
        console2.log("  dust launches (totals under 1e15 wei), limited by 1 wei:", dustCases);
        console2.log("  worst dust price change (parts per 1e36):", worstDust);
    }

    function externalLaunch(uint256 supply, RukusLaunchCurveParams memory curve, uint256 swapFee) external {
        factory = _deployFactory(supply, curve);
        (pool, launchToken) = _launch(_launchTokenIndex, swapFee);
    }

    /// @dev Launches from a new factory with this supply and curve; false if the factory or pool rejects them.
    function _tryLaunch(uint256 supply, uint256 initialPrice, uint256 graduationPrice, uint256 swapFee) internal returns (bool) {
        try this.externalLaunch(supply, RukusLaunchCurveParams(initialPrice, graduationPrice), swapFee) {
            // Enough WETH to buy any curve here (the Vault holds up to 2^128).
            deal(address(quoteToken), alice, 1e38);
            deal(address(quoteToken), bob, 1e38);
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Up to 8 random bonding trades short of completing the curve: buys of up to 90% of what's left to sell,
    /// sells of up to all alice holds, with time passing.
    function _tradeTheCurve(uint256 seed) internal {
        for (uint256 i = 0; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            (uint256 launchBalance, ) = _liveBalances();
            uint256 toGraduation = launchBalance - _brc().getGraduationLaunchBalance();
            uint256 fraction = 1e16 + (seed % 89e16);
            if (seed & 1 == 0 || launchToken.balanceOf(alice) == 0) {
                uint256 launchOut = toGraduation.mulDown(fraction);
                if (launchOut > 1e6) _buyExactOut(alice, launchOut);
            } else {
                uint256 launchIn = launchToken.balanceOf(alice).mulDown(fraction);
                if (launchIn > 1e6) _sellExactIn(alice, launchIn);
            }
            vm.warp(block.timestamp + ((seed >> 64) % 1 days));
        }
    }

    /// @dev Completes the curve, going past the graduation balance by `seed` within the overshoot limit (the maximum
    /// for `type(uint256).max`).
    function _completeWithOvershoot(uint256 seed) internal {
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        uint256 maxOvershoot = graduationBalance.mulDown(_brc().MAX_GRADUATION_OVERSHOOT());
        uint256 overshoot = seed == type(uint256).max ? maxOvershoot : seed % (maxOvershoot + 1);
        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(alice, launchBalance - graduationBalance + overshoot);
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.COMPLETED), "Curve not completed");
    }

    /// @dev Graduates, and returns how far the price moved and 1 wei of each total, both in parts per 1e36 of the
    /// price. Also checks the real balances don't move, and that the range is the graduated one (to its own 1 wei).
    function _graduateAndMeasure() internal returns (uint256 error, uint256 granularity) {
        (uint256 launchBefore, uint256 quoteBefore) = _liveBalances();
        (uint256 launchTotalBefore, uint256 quoteTotalBefore) = _totals();

        vm.warp(block.timestamp + 1);
        _brc().graduate();

        (uint256 launchAfter, uint256 quoteAfter) = _liveBalances();
        assertEq(launchAfter, launchBefore, "Launch balance moved");
        assertEq(quoteAfter, quoteBefore, "WETH balance moved");
        (uint256 launchTotalAfter, uint256 quoteTotalAfter) = _totals();

        // price = quoteTotal / launchTotal; compare quoteAfter * launchBefore with quoteBefore * launchAfter.
        uint256 crossAfter = quoteTotalAfter * launchTotalBefore;
        uint256 crossBefore = quoteTotalBefore * launchTotalAfter;
        uint256 diff = crossAfter > crossBefore ? crossAfter - crossBefore : crossBefore - crossAfter;
        error = Math.mulDiv(diff, _PRECISION, crossBefore);
        granularity = _PRECISION / launchTotalAfter + _PRECISION / quoteTotalAfter;

        // The width: (1 + Ra/Va)(1 + Rb/Vb) squared, so each whole-wei virtual balance can move it by ~2/V.
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        uint256 priceRatio = ReClammMath.computePriceRatio(vault.getCurrentLiveBalances(pool), virtualA, virtualB);
        uint256 widthTolerance = 1e9 + 4e18 / virtualA + 4e18 / virtualB;
        assertApproxEqRel(priceRatio, _brc().GRADUATED_PRICE_RATIO(), widthTolerance, "Not the graduated range");
    }

    /// @dev (launch, quote) totals: real plus virtual balances.
    function _totals() internal view returns (uint256 launchTotal, uint256 quoteTotal) {
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        return (launchBalance + virtualLaunch, quoteBalance + virtualQuote);
    }

    /// @dev The virtual balances graduation set: the first `VirtualBalancesUpdated` the pool emitted.
    function _graduationVirtualBalances(Vm.Log[] memory logs) internal view returns (uint256, uint256) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics[0] == _VIRTUAL_BALANCES_UPDATED) {
                return abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        revert("No graduation");
    }
}

contract RukusLaunchGraduationPriceLaunchTokenBTest is RukusLaunchGraduationPriceTest {
    constructor() {
        _launchTokenIndex = 1;
    }
}
