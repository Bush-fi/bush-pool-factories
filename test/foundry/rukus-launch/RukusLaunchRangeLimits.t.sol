// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { Rounding } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

/**
 * @notice The graduated pool pushed to the very ends of its 1e12x range: the top (no launch tokens left in the pool)
 * and the bottom (no WETH left), including exact-balance and minimum-size trades there.
 * @dev After graduation the virtual balances are fixed, so the range is exact: with invariant L = (Rl + Vl)(Rq + Vq),
 * the launch price tops out at L / Vl^2 (Rl = 0) and bottoms out at Vq^2 / L (Rq = 0). After every trade the pool must:
 * keep its virtual balances, quote a positive price inside the range, and never lose invariant. A trade at an edge may
 * only fail by asking for more than the pool holds, or for less than the Vault's minimum trade.
 */
contract RukusLaunchRangeLimitsTest is BaseRukusLaunchTest {
    using FixedPoint for uint256;

    uint256 internal constant _WHALE_WETH = 1e30;
    uint256 internal constant _WHALE_LAUNCH = _LAUNCH_SUPPLY * 1e9;
    uint256 internal constant _MAX_STEPS = 400;

    uint256 internal _virtualLaunch;
    uint256 internal _virtualQuote;
    uint256 internal _lastInvariant;

    function setUp() public override {
        super.setUp();
        _graduateWithOvershoot(0);
    }

    /***************************************************************************
                                    The top
    ***************************************************************************/

    /// @dev Buy half the launch tokens left, again and again, then the rest exactly: the pool reaches the top.
    function testDrainTheLaunchSideToTheTop() public {
        uint256 graduationPrice = _brc().computeCurrentLaunchTokenPrice();
        uint256 launchBefore = launchToken.balanceOf(whale());
        uint256 steps = _drainLaunchSide();
        (uint256 launchLeft, uint256 quoteAtTop) = _liveBalances();
        (, uint256 maxPrice) = _priceRange();
        uint256 topPrice = _brc().computeCurrentLaunchTokenPrice();

        assertEq(launchLeft, 0, "Launch side not drained");
        assertApproxEqRel(topPrice, maxPrice, 1e12, "Not at the top of the range");
        assertGt(topPrice, graduationPrice * 999_000, "Top is not ~1e6x the graduation price");

        // The way back down works: every launch token sells back, and the pool still trades both ways.
        _sellExactIn(whale(), launchToken.balanceOf(whale()) - launchBefore);
        _assertHealthy("after selling back from the top");
        _assertStillTrades();

        console2.log("top: steps to drain:", steps);
        console2.log("  price / graduation (x):", topPrice / graduationPrice);
        console2.log("  WETH in the pool at the top:", quoteAtTop / 1e18);
    }

    /// @dev At the top, asking for the whole launch balance plus one fails cleanly; the whole balance goes through.
    function testExactOutOfTheWholeLaunchBalance() public {
        _halveRepeatedly(true, 1e12);
        (uint256 launchLeft, ) = _liveBalances();
        assertGt(launchLeft, 0, "Drained too early");

        _expectEdgeRevert(_tryBuyExactOut(launchLeft + 1), ReClammMath.AmountOutGreaterThanBalance.selector);
        _expectEdgeRevert(_tryBuyExactOut(type(uint128).max), ReClammMath.AmountOutGreaterThanBalance.selector);

        assertEq(_tryBuyExactOut(launchLeft - 1).length, 0, "Balance - 1 failed");
        _assertHealthy("balance - 1");
        (launchLeft, ) = _liveBalances();
        assertEq(launchLeft, 1, "One wei left");
        _takeTheLastWei(true);
    }

    /// @dev Minimum-size and round-trip trades at the top: they quote, settle, and never pay out more than came in.
    function testSmallTradesAndRoundTripsAtTheTop() public {
        _halveRepeatedly(true, 1e18);
        _assertEdgeTradesSafe();
    }

    /***************************************************************************
                                   The bottom
    ***************************************************************************/

    /// @dev Sell launch tokens for half the WETH left, again and again, then the rest exactly: the pool hits bottom.
    function testDrainTheQuoteSideToTheBottom() public {
        uint256 graduationPrice = _brc().computeCurrentLaunchTokenPrice();
        uint256 steps = _drainQuoteSide();
        (uint256 launchAtBottom, uint256 quoteLeft) = _liveBalances();
        (uint256 minPrice, ) = _priceRange();
        uint256 bottomPrice = _brc().computeCurrentLaunchTokenPrice();

        assertEq(quoteLeft, 0, "Quote side not drained");
        assertGt(bottomPrice, 0, "Price hit zero");
        assertApproxEqRel(bottomPrice, minPrice, 1e12, "Not at the bottom of the range");
        assertLt(bottomPrice, graduationPrice / 999_000, "Bottom is not ~1e-6x the graduation price");

        // The way back up works: buy back all the WETH's worth, and the pool still trades both ways.
        _buyExactIn(whale(), 1e18);
        _assertHealthy("after buying at the bottom");
        _assertStillTrades();

        console2.log("bottom: steps to drain:", steps);
        console2.log("  graduation / price (x):", graduationPrice / bottomPrice);
        console2.log("  launch tokens in the pool at the bottom:", launchAtBottom / 1e18);
    }

    /// @dev At the bottom, asking for all the WETH plus one fails cleanly; the whole balance goes through.
    function testExactOutOfTheWholeQuoteBalance() public {
        _halveRepeatedly(false, 1e12);
        (, uint256 quoteLeft) = _liveBalances();
        assertGt(quoteLeft, 0, "Drained too early");

        _expectEdgeRevert(_trySellExactOut(quoteLeft + 1), ReClammMath.AmountOutGreaterThanBalance.selector);
        _expectEdgeRevert(_trySellExactOut(type(uint128).max), ReClammMath.AmountOutGreaterThanBalance.selector);

        assertEq(_trySellExactOut(quoteLeft - 1).length, 0, "Balance - 1 failed");
        _assertHealthy("balance - 1");
        (, quoteLeft) = _liveBalances();
        assertEq(quoteLeft, 1, "One wei left");
        _takeTheLastWei(false);
    }

    /// @dev Minimum-size and round-trip trades at the bottom: they quote, settle, and never pay out more than came in.
    function testSmallTradesAndRoundTripsAtTheBottom() public {
        _halveRepeatedly(false, 1e18);
        _assertEdgeTradesSafe();
    }

    /***************************************************************************
                                  Random routes
    ***************************************************************************/

    /**
     * @dev Graduate from any completing buy the overshoot limit allows, then take a random route toward one end of the
     * range (mostly toward it, sometimes back), drain that end exactly, and come back from it. The pool stays healthy
     * after every step, and only ever refuses a trade for asking too much or too little.
     * Each run is ~100 trades through the Vault, so it runs fewer times than the default.
     */
    /// forge-config: default.fuzz.runs = 512
    function testRandomRouteToAnEnd__Fuzz(uint256 seed, uint256 overshoot, bool toTheTop) public {
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        overshoot = bound(overshoot, 0, graduationBalance.mulDown(_brc().MAX_GRADUATION_OVERSHOOT()));
        (pool, launchToken) = _launch(_launchTokenIndex);
        _graduateWithOvershoot(overshoot);

        for (uint256 i = 0; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool towardTheEnd = seed % 4 != 0;
            bool buy = towardTheEnd == toTheTop;
            // 1% to 90% of what the pool holds of the token going out.
            uint256 fraction = 1e16 + ((seed >> 8) % 89e16);
            (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
            bytes memory reason = buy
                ? _tryBuyExactOut(launchBalance.mulDown(fraction))
                : _trySellExactOut(quoteBalance.mulDown(fraction));
            _requireEdgeRevertOrSuccess(reason);
            vm.warp(block.timestamp + ((seed >> 128) % 2 days));
        }

        if (toTheTop) {
            _drainLaunchSide();
            (uint256 launchLeft, ) = _liveBalances();
            assertEq(launchLeft, 0, "Launch side not drained");
            (, uint256 quoteBalance) = _liveBalances();
            assertEq(_trySellExactOut(quoteBalance / 2).length, 0, "Can't sell back from the top");
        } else {
            _drainQuoteSide();
            (, uint256 quoteLeft) = _liveBalances();
            assertEq(quoteLeft, 0, "Quote side not drained");
            (uint256 launchBalance, ) = _liveBalances();
            assertEq(_tryBuyExactOut(launchBalance / 2).length, 0, "Can't buy back from the bottom");
        }
        _assertHealthy("coming back from the end");
        _assertStillTrades();
    }

    function externalBuyExactOut(uint256 launchOut) external {
        vm.prank(whale());
        router.swapSingleTokenExactOut(pool, quoteToken, launchToken, launchOut, MAX_UINT128, MAX_UINT256, false, "");
    }

    function externalSellExactOut(uint256 quoteOut) external {
        vm.prank(whale());
        router.swapSingleTokenExactOut(pool, launchToken, quoteToken, quoteOut, MAX_UINT128, MAX_UINT256, false, "");
    }

    /***************************************************************************
                                    Helpers
    ***************************************************************************/

    function whale() internal view returns (address) {
        return hacker;
    }

    /// @dev Completes the current pool's curve `overshoot` past the graduation balance, graduates, funds the whale.
    function _graduateWithOvershoot(uint256 overshoot) internal {
        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(alice, launchBalance - _brc().getGraduationLaunchBalance() + overshoot);
        vm.warp(block.timestamp + 1);
        _brc().graduate();

        (_virtualLaunch, _virtualQuote) = _virtualLaunchAndQuote();
        _lastInvariant = _invariant();
        deal(address(quoteToken), whale(), _WHALE_WETH);
        _giveLaunchTokens(whale(), _WHALE_LAUNCH);
        vm.startPrank(whale());
        approveForSender();
        vm.stopPrank();
    }

    /// @dev Buys half the launch tokens left until a buy fails, then the exact rest. Returns the trades it took.
    function _drainLaunchSide() internal returns (uint256 steps) {
        steps = _halveRepeatedly(true, 0);
        (uint256 launchLeft, ) = _liveBalances();
        if (launchLeft > 0) {
            assertEq(_tryBuyExactOut(launchLeft).length, 0, "Exact-out of the whole launch balance failed");
            _assertHealthy("whole launch balance");
            ++steps;
        }
    }

    /// @dev Sells for half the WETH left until a sell fails, then the exact rest. Returns the trades it took.
    function _drainQuoteSide() internal returns (uint256 steps) {
        steps = _halveRepeatedly(false, 0);
        (, uint256 quoteLeft) = _liveBalances();
        if (quoteLeft > 0) {
            assertEq(_trySellExactOut(quoteLeft).length, 0, "Exact-out of the whole quote balance failed");
            _assertHealthy("whole quote balance");
            ++steps;
        }
    }

    /// @dev Takes half of one side at a time (launch if `buy`, else WETH) until it holds `floor` or less, or a trade
    /// fails at the edge.
    function _halveRepeatedly(bool buy, uint256 floor) internal returns (uint256 steps) {
        for (; steps < _MAX_STEPS; ++steps) {
            (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
            uint256 balance = buy ? launchBalance : quoteBalance;
            if (balance <= floor || balance / 2 == 0) break;
            bytes memory reason = buy ? _tryBuyExactOut(balance / 2) : _trySellExactOut(balance / 2);
            if (reason.length > 0) {
                _requireEdgeRevert(reason);
                break;
            }
        }
        assertLt(steps, _MAX_STEPS, "Never reached the end");
    }

    /// @dev Exact-out buy of `launchOut` by the whale; returns the revert reason, empty on success (then checks health).
    function _tryBuyExactOut(uint256 launchOut) internal returns (bytes memory reason) {
        try this.externalBuyExactOut(launchOut) {
            _assertHealthy("buy");
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @dev Exact-out sell for `quoteOut` by the whale; returns the revert reason, empty on success (then checks health).
    function _trySellExactOut(uint256 quoteOut) internal returns (bytes memory reason) {
        try this.externalSellExactOut(quoteOut) {
            _assertHealthy("sell");
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @dev The last wei of one side (launch if `buy`, else WETH): the Vault's minimum trade refuses it if it has one
    /// (the live Vault does); otherwise it goes through and the side is empty.
    function _takeTheLastWei(bool buy) internal {
        bytes memory reason = buy ? _tryBuyExactOut(1) : _trySellExactOut(1);
        if (vault.getMinimumTradeAmount() > 1) {
            _expectEdgeRevert(reason, IVaultErrors.TradeAmountTooSmall.selector);
        } else {
            assertEq(reason.length, 0, "Last wei refused");
            (uint256 launchLeft, uint256 quoteLeft) = _liveBalances();
            assertEq(buy ? launchLeft : quoteLeft, 0, "Side not empty");
        }
    }

    /// @dev Tiny to normal trades both ways and buy/sell round trips, at whatever edge the pool is at. A trade below the
    /// Vault's minimum may be refused; none may pay out more than came in.
    function _assertEdgeTradesSafe() internal {
        uint256[6] memory sizes = [uint256(1), 2, 1e3, 1e6, 1e12, 1e18];
        for (uint256 i = 0; i < sizes.length; ++i) {
            // Buy with WETH, sell everything bought: never get more WETH back than went in.
            uint256 quoteBefore = quoteToken.balanceOf(lp);
            (bool bought, uint256 launchOut) = _tryExactIn(lp, quoteToken, launchToken, sizes[i]);
            if (bought && launchOut > 0) {
                (bool sold, ) = _tryExactIn(lp, launchToken, quoteToken, launchOut);
                if (sold) assertLe(quoteToken.balanceOf(lp), quoteBefore, "Buy/sell round trip profit");
            }

            // Sell launch tokens, buy back with everything received: never get more launch tokens than went in.
            _giveLaunchTokens(lp, sizes[i]);
            uint256 launchBefore = launchToken.balanceOf(lp);
            (bool soldFirst, uint256 quoteOut) = _tryExactIn(lp, launchToken, quoteToken, sizes[i]);
            if (soldFirst && quoteOut > 0) {
                (bool boughtBack, ) = _tryExactIn(lp, quoteToken, launchToken, quoteOut);
                if (boughtBack) assertLe(launchToken.balanceOf(lp), launchBefore, "Sell/buy round trip profit");
            }
        }
    }

    function externalExactIn(address trader, IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn) external returns (uint256) {
        vm.prank(trader);
        return router.swapSingleTokenExactIn(pool, tokenIn, tokenOut, amountIn, 0, MAX_UINT256, false, "");
    }

    /// @dev Exact-in swap that may fail only at the edge; checks health after it.
    function _tryExactIn(
        address trader,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn
    ) internal returns (bool ok, uint256 amountOut) {
        try this.externalExactIn(trader, tokenIn, tokenOut, amountIn) returns (uint256 out) {
            _assertHealthy("exact in");
            return (true, out);
        } catch (bytes memory reason) {
            _requireEdgeRevert(reason);
        }
    }

    /// @dev Buys and sells a little through the Router, both ways.
    function _assertStillTrades() internal {
        uint256 bought = _buyExactIn(lp, 1e15);
        assertGt(bought, 0, "Can't buy");
        assertGt(_sellExactIn(lp, bought), 0, "Can't sell");
        _assertHealthy("still trades");
    }

    /// @dev Virtual balances fixed, a positive price inside the range, and the invariant never down.
    function _assertHealthy(string memory step) internal {
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        assertEq(virtualLaunch, _virtualLaunch, string.concat("Virtual launch moved: ", step));
        assertEq(virtualQuote, _virtualQuote, string.concat("Virtual quote moved: ", step));

        uint256 price = _brc().computeCurrentLaunchTokenPrice();
        (uint256 minPrice, uint256 maxPrice) = _priceRange();
        assertGt(price, 0, string.concat("Price hit zero: ", step));
        assertGe(price, minPrice.mulDown(FixedPoint.ONE - 1e9), string.concat("Below the range: ", step));
        assertLe(price, maxPrice.mulUp(FixedPoint.ONE + 1e9), string.concat("Above the range: ", step));

        uint256 invariant = _invariant();
        assertGe(invariant, _lastInvariant, string.concat("Invariant went down: ", step));
        _lastInvariant = invariant;
    }

    /// @dev The launch price at the ends of the range: (Vq^2 / L, L / Vl^2).
    function _priceRange() internal view returns (uint256 minPrice, uint256 maxPrice) {
        uint256 invariant = _invariant();
        minPrice = _virtualQuote.divDown(invariant.divUp(_virtualQuote));
        maxPrice = invariant.divUp(_virtualLaunch).divUp(_virtualLaunch);
    }

    function _invariant() internal view returns (uint256) {
        return _brc().computeInvariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
    }

    function _isEdgeRevert(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 selector = bytes4(reason);
        return
            selector == ReClammMath.AmountOutGreaterThanBalance.selector ||
            selector == IVaultErrors.TradeAmountTooSmall.selector;
    }

    function _requireEdgeRevert(bytes memory reason) internal pure {
        if (_isEdgeRevert(reason) == false) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _requireEdgeRevertOrSuccess(bytes memory reason) internal pure {
        if (reason.length > 0) _requireEdgeRevert(reason);
    }

    function _expectEdgeRevert(bytes memory reason, bytes4 expected) internal pure {
        assertGt(reason.length, 0, "Expected a revert");
        if (bytes4(reason) != expected) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
