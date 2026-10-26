// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import { BondingPhase } from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";

import { BaseBondingReClammTest } from "../utils/BaseBondingReClammTest.sol";

/**
 * @notice Extreme price paths through the graduated (full-range) pool: a 5,000x run and a full round trip back down,
 * and a crash pushed far past anything the real supply could do.
 */
contract BondingReClammExtremeMovesTest is BaseBondingReClammTest {
    using FixedPoint for uint256;

    function setUp() public override {
        super.setUp();
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
    }

    /**
     * @dev The token runs 5,000x above its graduation price, in steps, then every holder sells everything back. Every
     * buy and every sell goes through, the pool never runs dry, the price comes back down below where it graduated,
     * and the pool still trades afterwards. The virtual balances never move.
     */
    function testRun5000xThenEveryoneSellsBack() public {
        uint256 graduationPrice = _brc().computeCurrentLaunchTokenPrice();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();

        // Up: buy 10% of the launch tokens left at a time until the price is 5,000x.
        uint256 steps;
        while (_brc().computeCurrentLaunchTokenPrice() < graduationPrice * 5_000) {
            (uint256 launchBalance, ) = _liveBalances();
            _buyExactOut(bob, launchBalance / 10);
            vm.warp(block.timestamp + 1 hours);
            steps++;
        }
        uint256 peakPrice = _brc().computeCurrentLaunchTokenPrice();
        (uint256 launchAtPeak, uint256 quoteAtPeak) = _liveBalances();
        assertGt(launchAtPeak, 0, "Ran out of launch tokens on the way up");

        // Down: every holder sells everything, in 20 pieces each.
        uint256 lowestPrice = peakPrice;
        address[2] memory holders = [address(alice), bob];
        for (uint256 h = 0; h < holders.length; ++h) {
            uint256 piece = launchToken.balanceOf(holders[h]) / 20;
            for (uint256 i = 0; i < 20; ++i) {
                _sellExactIn(holders[h], i == 19 ? launchToken.balanceOf(holders[h]) : piece);
                vm.warp(block.timestamp + 1 hours);
            }
            assertEq(launchToken.balanceOf(holders[h]), 0, "A holder could not sell everything");
        }
        uint256 finalPrice = _brc().computeCurrentLaunchTokenPrice();
        if (finalPrice < lowestPrice) lowestPrice = finalPrice;
        (uint256 launchAtEnd, uint256 quoteAtEnd) = _liveBalances();

        assertLt(finalPrice, graduationPrice, "Did not come back below the graduation price");
        assertGt(finalPrice, 0, "Price hit zero");
        assertGt(quoteAtEnd, 0, "Pool ran out of WETH");

        (uint256 virtualAAfter, uint256 virtualBAfter) = _brc().getVirtualBalances();
        assertEq(virtualAAfter, virtualA, "Virtual A moved");
        assertEq(virtualBAfter, virtualB, "Virtual B moved");

        // Still a working market.
        _buyExactIn(lp, 1e18);
        _sellExactIn(lp, launchToken.balanceOf(lp));

        console2.log("5,000x run in buys of 10%:", steps);
        console2.log("  peak price / graduation (x):", peakPrice / graduationPrice);
        console2.log("  launch tokens left in the pool at the peak:", launchAtPeak / 1e18);
        console2.log("  WETH in the pool at the peak / at the end:", quoteAtPeak / 1e18, quoteAtEnd / 1e18);
        console2.log("  final price / graduation (per million):", (finalPrice * 1e6) / graduationPrice);
        console2.log("  launch tokens back in the pool:", launchAtEnd / 1e18);
    }

    /**
     * @dev Far past what the supply allows (stand-in tokens, 100x the whole supply): keep dumping until the pool
     * stops paying. The price heads toward the floor of the 1e12 range (a millionth of the graduation price) but never
     * reaches zero; sells only ever fail by asking for more WETH than the pool has; and the pool still trades both ways.
     */
    function testCrashTowardZeroDoesNotBreak() public {
        uint256 graduationPrice = _brc().computeCurrentLaunchTokenPrice();
        _giveLaunchTokens(hacker, _LAUNCH_SUPPLY * 100);
        vm.startPrank(hacker);
        approveForSender();
        vm.stopPrank();

        uint256 sellSize = _LAUNCH_SUPPLY;
        for (uint256 i = 0; i < 100; ++i) {
            try this.externalSell(hacker, sellSize) {} catch (bytes memory reason) {
                assertEq(bytes4(reason), ReClammMath.AmountOutGreaterThanBalance.selector, "Unexpected revert");
                break;
            }
        }

        uint256 bottomPrice = _brc().computeCurrentLaunchTokenPrice();
        (, uint256 quoteLeft) = _liveBalances();
        assertGt(bottomPrice, 0, "Price hit zero");
        assertLt(bottomPrice, graduationPrice / 1_000, "Not a real crash");

        // The pool still quotes and trades both ways at the bottom.
        uint256 bought = _buyExactIn(lp, 1e15);
        assertGt(bought, 0, "Can't buy at the bottom");
        _sellExactIn(lp, bought);

        console2.log("crash: price / graduation (per billion):", (bottomPrice * 1e9) / graduationPrice);
        console2.log("  WETH left in the pool (wei):", quoteLeft);
    }

    function externalSell(address seller, uint256 amount) external {
        _sellExactIn(seller, amount);
    }
}
