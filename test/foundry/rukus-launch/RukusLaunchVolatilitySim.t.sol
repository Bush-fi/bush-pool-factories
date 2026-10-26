// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";


import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

/**
 * @notice How the graduated (full-range, fixed) pool copes with meme-coin volatility. Not a pass/fail test: it prints
 * a table. Skipped unless `RUN_SIM=true` (see `testSimulateFullRange` for the command).
 *
 * Each run graduates a fresh launch, then follows a 45-day market price path hour by hour. Every hour an arbitrageur
 * trades the pool toward the market price (stopping a fee short of it, as a real arbitrageur would). Measured:
 * - Stuck: hours the pool price ends more than 3% off the market, because the pool ran out of one token (its range
 *   didn't reach the price yet).
 * - LP/HODL: what the pool's balances are worth at the end, against the balances it graduated with held untouched,
 *   both at the final market price. Below 100% is the LPs' loss (impermanent loss, plus what arbitrage took).
 * And separately, the push-and-hold attack from RukusLaunchAttacks.t.sol (buy 80%, 95% or 99% of the launch tokens
 * left, wait 7 days with nobody trading, sell back): the attacker's profit in quote.
 */
contract RukusLaunchVolatilitySim is BaseRukusLaunchTest {
    using FixedPoint for uint256;

    uint256 private constant _HOURS = 45 * 24;
    uint256 private constant _STUCK_TOLERANCE = 3e16; // 3%

    uint256 private _failedTrades;

    struct Result {
        uint256 stuckHours;
        uint256 lpOverHodl; // 18 decimals
        uint256 finalMarketOverStart; // 18 decimals
    }

    function setUp() public override {
        super.setUp();
        vm.startPrank(hacker);
        approveForSender();
        vm.stopPrank();
    }

    // Runs 5 paths of 45 days hour by hour: raise Foundry's gas limit.
    // FOUNDRY_GAS_LIMIT=9000000000 RUN_SIM=true forge test --match-contract RukusLaunchVolatilitySim -vv

    function testSimulateFullRange() public {
        if (!vm.envOr("RUN_SIM", false)) {
            vm.skip(true);
        }

        string[5] memory paths = [
            "random 15%/day",
            "frenzy 60%->15%",
            "2000% day, then 15%",
            "200x in 10 days, then -15%/day x10",
            "dump -15%/day x10"
        ];

        uint256 start = vm.snapshotState();
        console2.log("== graduated full range (1e12x), fixed");
        for (uint256 p = 0; p < paths.length; ++p) {
            vm.revertToState(start);
            _setUpGraduated();
            _failedTrades = 0;
            Result memory r = _runPath(p);
            console2.log(
                string.concat(
                    "  ",
                    paths[p],
                    ": stuck ",
                    vm.toString(r.stuckHours),
                    "h / 1080h, LP/HODL ",
                    _pct(r.lpOverHodl),
                    ", market ended at ",
                    _pct(r.finalMarketOverStart),
                    " of start, failed trades ",
                    vm.toString(_failedTrades)
                )
            );
        }

        uint256[3] memory pushes = [uint256(80e16), 95e16, 99e16];
        for (uint256 i = 0; i < pushes.length; ++i) {
            vm.revertToState(start);
            _setUpGraduated();
            console2.log(
                string.concat(
                    "  push-and-hold, buy ",
                    vm.toString(pushes[i] / 1e16),
                    "% of launch left, 7 days: attacker profit ",
                    _signed(_pushAndHold(pushes[i])),
                    " quote"
                )
            );
        }
    }

    /***************************************************************************
                                     Paths
    ***************************************************************************/

    /// @dev The hourly return (18 decimals, signed) for a path at an hour. Deterministic.
    function _hourlyReturn(uint256 path, uint256 hour) internal pure returns (int256) {
        uint256 day = hour / 24;
        int256 sigma15 = 0.0306e18; // 15% daily volatility, per hour (0.15 / sqrt(24))
        int256 noise = _normal(path, hour);

        if (path == 1 && day < 3) {
            return (noise * 0.1225e18) / 1e18; // 60% daily volatility
        }
        if (path == 2 && day == 1) {
            return 0.135353e18; // 21^(1/24) - 1: +2000% in a day
        }
        if (path == 3 && day < 10) {
            return 0.022322e18; // 200^(1/240) - 1: 200x in 10 days
        }
        if (path == 3 && day < 20) {
            return -0.006749e18; // 0.85^(1/24) - 1
        }
        if (path == 4 && day < 10) {
            return -0.006749e18;
        }
        return (noise * sigma15) / 1e18;
    }

    /// @dev Roughly standard normal: the sum of four uniforms on [-1, 1], scaled to unit variance.
    function _normal(uint256 path, uint256 hour) internal pure returns (int256 z) {
        for (uint256 i = 0; i < 4; ++i) {
            uint256 u = uint256(keccak256(abi.encode(path, hour, i))) % 2e18;
            z += int256(u) - 1e18;
        }
        z = (z * 0.866025e18) / 1e18;
    }

    /***************************************************************************
                                   Simulation
    ***************************************************************************/

    function _setUpGraduated() internal {
        (pool, launchToken) = _launch(_launchTokenIndex);
        _giveLaunchTokens(bob, 1e9 * 1e18); // the arbitrageur's inventory (stands in for other venues / holders)

        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
    }

    function _runPath(uint256 path) internal returns (Result memory r) {
        uint256 startMarket = _poolPrice();
        uint256 market = startMarket;
        (uint256 launch0, uint256 quote0) = _liveBalances();

        for (uint256 hour = 0; hour < _HOURS; ++hour) {
            int256 ret = _hourlyReturn(path, hour);
            market = uint256((int256(market) * (1e18 + ret)) / 1e18);
            vm.warp(block.timestamp + 1 hours);

            _arbitrage(market);

            uint256 poolPrice = _poolPrice();
            uint256 gap = poolPrice > market ? poolPrice.divDown(market) - 1e18 : market.divDown(poolPrice) - 1e18;
            if (gap > _STUCK_TOLERANCE) r.stuckHours++;
        }

        (uint256 launch1, uint256 quote1) = _liveBalances();
        r.lpOverHodl = (launch1.mulDown(market) + quote1).divDown(launch0.mulDown(market) + quote0);
        r.finalMarketOverStart = market.divDown(startMarket);
    }

    /// @dev Trades the pool toward `market`, stopping a fee short of it; capped by what the pool holds.
    function _arbitrage(uint256 market) internal {
        (uint256 x, uint256 y, uint256 launchBalance, uint256 quoteBalance) = _totals();
        uint256 poolPrice = y.divDown(x);

        if (market > poolPrice.mulDown(1e18 + _SWAP_FEE)) {
            // Buy launch tokens until the pool price is market * (1 - fee).
            uint256 target = market.mulDown(1e18 - _SWAP_FEE);
            uint256 newX = Math.sqrt(Math.mulDiv(x, y, target) * 1e18);
            if (newX >= x) return;
            uint256 out = Math.min(x - newX, launchBalance - launchBalance / 1000);
            if (out < 1e15) return;
            try this.buyExactOut(out) {} catch {
                _failedTrades++;
            }
        } else if (market < poolPrice.mulDown(1e18 - _SWAP_FEE)) {
            // Sell launch tokens until the pool price is market / (1 - fee).
            uint256 target = market.divDown(1e18 - _SWAP_FEE);
            uint256 newY = Math.sqrt(Math.mulDiv(x, y, 1e18) * target);
            if (newY >= y) return;
            uint256 out = Math.min(y - newY, quoteBalance - quoteBalance / 1000);
            if (out < 1e12) return;
            try this.sellForExactQuote(out) {} catch {
                _failedTrades++;
            }
        }
    }

    /// @dev Push-and-hold: buy a fraction of the launch tokens left, wait 7 days unopposed, sell back.
    function _pushAndHold(uint256 fraction) internal returns (int256) {
        uint256 quoteStart = quoteToken.balanceOf(hacker);
        uint256 launchStart = launchToken.balanceOf(hacker);
        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(hacker, launchBalance.mulDown(fraction));

        vm.warp(block.timestamp + 7 days);
        uint256 amount = launchToken.balanceOf(hacker) - launchStart;
        for (uint256 i = 0; i < 60 && amount > 1e12; ++i) {
            try this.sellExactIn(hacker, amount) {
                break;
            } catch {
                amount /= 2;
            }
        }
        return int256(quoteToken.balanceOf(hacker)) - int256(quoteStart);
    }

    /***************************************************************************
                                     Helpers
    ***************************************************************************/

    function buyExactOut(uint256 launchOut) external {
        _buyExactOut(bob, launchOut);
    }

    function sellForExactQuote(uint256 quoteOut) external {
        vm.prank(bob);
        router.swapSingleTokenExactOut(pool, launchToken, quoteToken, quoteOut, MAX_UINT128, MAX_UINT256, false, "");
    }

    function sellExactIn(address seller, uint256 launchIn) external {
        _sellExactIn(seller, launchIn);
    }

    /// @dev (launch total, quote total, launch real, quote real): the totals include the current virtual balances.
    function _totals() internal view returns (uint256 x, uint256 y, uint256 launchBalance, uint256 quoteBalance) {
        (launchBalance, quoteBalance) = _liveBalances();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _launchTokenIndex == 0
            ? (virtualA, virtualB)
            : (virtualB, virtualA);
        x = launchBalance + virtualLaunch;
        y = quoteBalance + virtualQuote;
    }

    function _poolPrice() internal view returns (uint256) {
        (uint256 x, uint256 y, , ) = _totals();
        return y.divDown(x);
    }

    function _pct(uint256 value) internal pure returns (string memory) {
        return string.concat(vm.toString(value / 1e16), ".", vm.toString((value / 1e15) % 10), "%");
    }

    function _signed(int256 value) internal pure returns (string memory) {
        return value < 0 ? string.concat("-", vm.toString(uint256(-value) / 1e18)) : vm.toString(uint256(value) / 1e18);
    }
}
