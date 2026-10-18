// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import {
    BondingPhase,
    BondingReClammCurveParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";

import { BaseBondingReClammTest } from "../utils/BaseBondingReClammTest.sol";

/**
 * @notice A visual proof that graduation doesn't move the price: the 5 ETH preset launch, printed side by side just
 * before and just after graduation, and the price through the whole lifecycle as a chart with graduation marked.
 * The numbers also land in TEST_REPORT.md (npm run test:bonding-reclamm:report).
 */
contract BondingReClammGraduationSnapshotTest is BaseBondingReClammTest {
    using FixedPoint for uint256;

    uint256 internal constant SUPPLY = 1e9 * 1e18;
    uint256 internal constant INITIAL_PRICE = 0.0000000015625e18;
    uint256 internal constant GRADUATION_PRICE = 0.000000025e18;

    struct Snapshot {
        uint256 price;
        uint256 launchBalance;
        uint256 quoteBalance;
        uint256 virtualLaunch;
        uint256 virtualQuote;
        uint256 smallBuyOut; // launch tokens for 0.001 ETH
        uint256 bigBuyOut; // launch tokens for 1 ETH
        uint256 sellOut; // ETH for 1M launch tokens
    }

    function setUp() public override {
        super.setUp();
        // The 5 ETH preset factory: it fixes the supply and curve of every launch.
        _useFactory(SUPPLY, BondingReClammCurveParams({ initialPrice: INITIAL_PRICE, graduationPrice: GRADUATION_PRICE }));
    }

    /**
     * @dev Graduation keeps the price exactly: the spot price, market cap and balances are the same on both sides
     * (only the virtual balances change, which changes the depth for bigger trades, not the price). Prints the table.
     */
    function testGraduationKeepsThePrice_SideBySide() public {
        _completeCurve(alice);
        Snapshot memory before = _snapshot();

        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Not graduated");
        Snapshot memory afterwards = _snapshot();

        uint256 change = afterwards.price > before.price ? afterwards.price - before.price : before.price - afterwards.price;
        assertApproxEqRel(afterwards.price, before.price, 1e6, "Graduation moved the price (> 1e-12)");
        assertEq(afterwards.launchBalance, before.launchBalance, "Launch balance changed");
        assertEq(afterwards.quoteBalance, before.quoteBalance, "WETH balance changed");
        assertApproxEqRel(afterwards.smallBuyOut, before.smallBuyOut, 1e15, "A small buy prices differently");

        console2.log("");
        console2.log("  GRADUATION SNAPSHOT (5 ETH preset: 1B tokens, 200M left for the pool)");
        console2.log("  ------------------------------------------------------------------------------------------");
        console2.log("                                     BEFORE (bonding curve)        AFTER (graduated, full range)");
        _row("spot price (ETH per token)", _fmt(before.price, 18, 15), _fmt(afterwards.price, 18, 15));
        _row("market cap (ETH)", _fmt(before.price.mulDown(SUPPLY), 18, 6), _fmt(afterwards.price.mulDown(SUPPLY), 18, 6));
        _row("launch tokens in the pool", _fmt(before.launchBalance, 18, 0), _fmt(afterwards.launchBalance, 18, 0));
        _row("WETH in the pool", _fmt(before.quoteBalance, 18, 6), _fmt(afterwards.quoteBalance, 18, 6));
        _row("virtual launch tokens", _fmt(before.virtualLaunch, 18, 0), _fmt(afterwards.virtualLaunch, 18, 0));
        _row("virtual WETH", _fmt(before.virtualQuote, 18, 6), _fmt(afterwards.virtualQuote, 18, 6));
        _row("0.001 ETH buys (tokens)", _fmt(before.smallBuyOut, 18, 2), _fmt(afterwards.smallBuyOut, 18, 2));
        _row("1 ETH buys (tokens)", _fmt(before.bigBuyOut, 18, 2), _fmt(afterwards.bigBuyOut, 18, 2));
        _row("1M tokens sell for (ETH)", _fmt(before.sellOut, 18, 6), _fmt(afterwards.sellOut, 18, 6));
        console2.log("  ------------------------------------------------------------------------------------------");
        console2.log(string.concat("  price change at graduation: ", vm.toString(change), " wei per token (", _ppt(change, before.price), " parts per trillion)"));
        console2.log("  Same price, same balances. Only the virtual balances change: the curve's large virtual reserves");
        console2.log("  give way to tiny ones, so small trades price the same and larger ones see the full-range depth.");
    }

    /**
     * @dev The price through the whole life of the launch: bonding buys up to completion, graduation, then trading
     * after. Printed as a chart; graduation sits on the line with no jump.
     */
    function testPriceThroughGraduation_Chart() public {
        uint256[] memory prices = new uint256[](40);
        string[] memory labels = new string[](40);
        uint256 n;

        prices[n] = _brc().computeCurrentLaunchTokenPrice();
        labels[n++] = "launch";

        // Bonding: 10 equal steps of the curve's launch tokens, the last one completing it.
        uint256 toGraduation = SUPPLY - _brc().getGraduationLaunchBalance();
        for (uint256 i = 0; i < 9; ++i) {
            _buyExactOut(bob, toGraduation / 10);
            prices[n] = _brc().computeCurrentLaunchTokenPrice();
            labels[n++] = "bonding buy";
        }
        _completeCurve(alice);
        uint256 beforeGraduation = _brc().computeCurrentLaunchTokenPrice();
        prices[n] = beforeGraduation;
        labels[n++] = "curve completed";

        vm.warp(block.timestamp + 1);
        _brc().graduate();
        uint256 afterGraduation = _brc().computeCurrentLaunchTokenPrice();
        prices[n] = afterGraduation;
        labels[n++] = ">> GRADUATED <<";
        assertApproxEqRel(afterGraduation, beforeGraduation, 1e6, "Jump at graduation");

        // Graduated: a few buys, then sells back down.
        for (uint256 i = 0; i < 5; ++i) {
            _buyExactIn(bob, 2e18);
            prices[n] = _brc().computeCurrentLaunchTokenPrice();
            labels[n++] = "graduated buy";
        }
        uint256 piece = launchToken.balanceOf(bob) / 6;
        for (uint256 i = 0; i < 5; ++i) {
            _sellExactIn(bob, piece);
            prices[n] = _brc().computeCurrentLaunchTokenPrice();
            labels[n++] = "graduated sell";
        }

        uint256 maxPrice;
        for (uint256 i = 0; i < n; ++i) if (prices[i] > maxPrice) maxPrice = prices[i];

        console2.log("");
        console2.log("  PRICE THROUGH THE LIFECYCLE (ETH per token; bar length = price, 60 = the highest)");
        for (uint256 i = 0; i < n; ++i) {
            uint256 width = (prices[i] * 60) / maxPrice;
            string memory bar = "";
            for (uint256 j = 0; j < width; ++j) bar = string.concat(bar, "#");
            console2.log(string.concat("  ", _pad(labels[i], 17), _pad(_fmt(prices[i], 18, 12), 16), " |", bar));
        }
        console2.log(string.concat("  graduation: ", _fmt(beforeGraduation, 18, 15), " -> ", _fmt(afterGraduation, 18, 15)));
    }

    /***************************************************************************
                                     Helpers
    ***************************************************************************/

    function _snapshot() internal view returns (Snapshot memory s) {
        s.price = _brc().computeCurrentLaunchTokenPrice();
        (s.launchBalance, s.quoteBalance) = _liveBalances();
        (s.virtualLaunch, s.virtualQuote) = _virtualLaunchAndQuote();

        // Quotes straight from the curve's maths with the current virtual balances (net of the 1% fee), so "before"
        // can be priced in the frozen completing block too.
        uint256[] memory balances = vault.getCurrentLiveBalances(pool);
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        s.smallBuyOut = ReClammMath.computeOutGivenIn(balances, virtualA, virtualB, _quoteTokenIndex, _launchTokenIndex, 0.00099e18);
        s.bigBuyOut = ReClammMath.computeOutGivenIn(balances, virtualA, virtualB, _quoteTokenIndex, _launchTokenIndex, 0.99e18);
        s.sellOut = ReClammMath.computeOutGivenIn(balances, virtualA, virtualB, _launchTokenIndex, _quoteTokenIndex, 990_000e18);
    }

    function _row(string memory label, string memory left, string memory right) internal pure {
        console2.log(string.concat("  ", _pad(label, 33), _pad(left, 30), right));
    }

    /// @dev `value` with `decimals` decimals, shown with `places` decimal places and thousands separators.
    function _fmt(uint256 value, uint256 decimals, uint256 places) internal pure returns (string memory) {
        uint256 whole = value / 10 ** decimals;
        string memory out = _thousands(whole);
        if (places == 0) return out;
        uint256 frac = (value % 10 ** decimals) / 10 ** (decimals - places);
        string memory fracStr = vm.toString(frac);
        while (bytes(fracStr).length < places) fracStr = string.concat("0", fracStr);
        return string.concat(out, ".", fracStr);
    }

    function _thousands(uint256 value) internal pure returns (string memory) {
        string memory digits = vm.toString(value);
        bytes memory b = bytes(digits);
        string memory out = "";
        for (uint256 i = 0; i < b.length; ++i) {
            if (i > 0 && (b.length - i) % 3 == 0) out = string.concat(out, ",");
            out = string.concat(out, string(abi.encodePacked(b[i])));
        }
        return out;
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        while (bytes(s).length < width) s = string.concat(s, " ");
        return s;
    }

    function _ppt(uint256 change, uint256 price) internal pure returns (string memory) {
        return vm.toString((change * 1e12) / price);
    }
}
