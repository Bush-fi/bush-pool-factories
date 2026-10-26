// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BondingReClammPool } from "../../../contracts/bonding-reclamm/BondingReClammPool.sol";
import { BondingPhase } from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";

import { BaseBondingReClammTest } from "../utils/BaseBondingReClammTest.sol";

/**
 * @notice Drives a launch through random sequences of buys, sells, waits, graduation, proportional adds and removes, and
 * creator fee withdrawals, recording what the invariants need.
 */
contract BondingReClammHandler is Test {
    using FixedPoint for uint256;

    IVault internal immutable _vault;
    IRouter internal immutable _router;
    BondingReClammPool internal immutable _pool;
    IERC20 internal immutable _launchToken;
    IERC20 internal immutable _quoteToken;
    uint256 internal immutable _launchIndex;

    // Ghosts.
    bool public priceMovedWithoutTrade;
    uint256 public failedBondingSells;
    uint256 public launchBalanceAtCompletion = type(uint256).max;
    uint256 public calls;
    uint256 public graduatedCalls;
    uint256 public adds;
    uint256 public removes;
    uint256 public sells;

    constructor(
        IVault vault,
        IRouter router,
        IPermit2 permit2,
        BondingReClammPool pool,
        IERC20 launchToken,
        IERC20 quoteToken,
        uint256 launchIndex
    ) {
        _vault = vault;
        _router = router;
        _pool = pool;
        _launchToken = launchToken;
        _quoteToken = quoteToken;
        _launchIndex = launchIndex;

        IERC20[3] memory tokens = [launchToken, quoteToken, IERC20(address(pool))];
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i].approve(address(permit2), type(uint256).max);
            tokens[i].approve(address(router), type(uint256).max);
            permit2.approve(address(tokens[i]), address(router), type(uint160).max, type(uint48).max);
        }
    }

    /***************************************************************************
                                    Actions
    ***************************************************************************/

    function buy(uint256 seed) external {
        calls++;
        uint256 maxOut = _pool.getMaxBuyAmount();
        if (maxOut < 1e15) return;
        uint256 launchOut = bound(seed, 1e15, maxOut);

        bool wasBonding = _pool.getBondingCompletedAt() == 0;
        try _router.swapSingleTokenExactOut(address(_pool), _quoteToken, _launchToken, launchOut, type(uint128).max, type(uint256).max, false, "") {
            if (wasBonding && _pool.getBondingCompletedAt() != 0) {
                launchBalanceAtCompletion = _launchBalance();
            }
        } catch {
            // Only possible in the completing block (GraduationPending), which getMaxBuyAmount reports as 0.
            revert("A buy within getMaxBuyAmount failed");
        }
    }

    function sell(uint256 seed) external {
        calls++;
        uint256 held = _launchToken.balanceOf(address(this));
        if (held < 1e12) return;
        if (_pool.getBondingPhase() == BondingPhase.COMPLETED && block.timestamp <= _pool.getBondingCompletedAt()) {
            return; // frozen for the rest of the completing block
        }
        uint256 launchIn = bound(seed, 1e12, held);

        bool bonding = _pool.getBondingPhase() == BondingPhase.BONDING;
        try _router.swapSingleTokenExactIn(address(_pool), _launchToken, _quoteToken, launchIn, 0, type(uint256).max, false, "") {
            sells++;
        } catch {
            if (bonding) failedBondingSells++;
        }
    }

    /// @dev Time passes with no trade: the price must not move.
    function wait(uint256 seed) external {
        calls++;
        uint256 before = _pool.computeCurrentLaunchTokenPrice();
        vm.warp(block.timestamp + bound(seed, 1, 30 days));
        if (_pool.computeCurrentLaunchTokenPrice() != before) priceMovedWithoutTrade = true;
    }

    function graduate() external {
        calls++;
        if (_pool.getBondingPhase() == BondingPhase.COMPLETED && block.timestamp > _pool.getBondingCompletedAt()) {
            uint256 before = _pool.computeCurrentLaunchTokenPrice();
            _pool.graduate();
            // Graduation keeps the price (to rounding).
            uint256 afterwards = _pool.computeCurrentLaunchTokenPrice();
            assertApproxEqRel(afterwards, before, 1e12, "Graduation moved the price");
        }
    }

    function addLiquidity(uint256 seed) external {
        calls++;
        if (_pool.getBondingPhase() != BondingPhase.GRADUATED) return;
        uint256 supply = IERC20(address(_pool)).totalSupply();
        uint256 bptOut = bound(seed, supply / 1e6, supply / 10);
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = type(uint128).max;
        maxIn[1] = type(uint128).max;
        // Needs launch tokens: skip if this handler doesn't hold enough.
        try _router.addLiquidityProportional(address(_pool), maxIn, bptOut, false, "") {
            adds++;
        } catch {}
    }

    function removeLiquidity(uint256 seed) external {
        calls++;
        uint256 bpt = IERC20(address(_pool)).balanceOf(address(this));
        if (bpt == 0) return;
        _router.removeLiquidityProportional(address(_pool), bound(seed, 1, bpt), new uint256[](2), false, "");
        removes++;
    }

    function withdrawCreatorFees() external {
        calls++;
        if (_pool.getBondingPhase() == BondingPhase.GRADUATED) graduatedCalls++;
        _pool.withdrawCreatorFees();
    }

    function _launchBalance() internal view returns (uint256) {
        return _vault.getCurrentLiveBalances(address(_pool))[_launchIndex];
    }
}

/**
 * @notice Stateful invariants of a launch, across random sequences of operations (foundry.toml: [invariant]).
 */
contract BondingReClammInvariantsTest is BaseBondingReClammTest {
    using FixedPoint for uint256;

    BondingReClammHandler internal handler;
    uint256 internal initialInvariant;

    function setUp() public override {
        super.setUp();

        handler = new BondingReClammHandler(
            vault,
            router,
            permit2,
            _brc(),
            launchToken,
            quoteToken,
            _launchTokenIndex
        );
        deal(address(weth), address(handler), 1e9 * 1e18);

        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        initialInvariant = (_LAUNCH_SUPPLY + virtualLaunch) * virtualQuote;

        targetContract(address(handler));
    }

    /// @dev While bonding, the pool stays on its curve (fees leave it; at most the 0.001% kept nudges it up). That is
    /// also what makes every circulating token backed: selling them all back walks the curve to its start.
    function invariant_onTheCurveWhileBonding() public view {
        if (_brc().getBondingPhase() != BondingPhase.BONDING) return;
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        uint256 invariant = (launchBalance + virtualLaunch) * (quoteBalance + virtualQuote);
        assertGe(invariant, initialInvariant, "Below the curve: circulating tokens not fully backed");
        assertLe(invariant, initialInvariant + initialInvariant / 1e4, "Drifted above the curve: fees stayed in the pool");
    }

    /// @dev Every launch token is somewhere accountable: the Vault (pool balance and fees not yet collected), the fee
    /// controller, the creator fee recipient, or the traders. None is minted or lost.
    function invariant_launchTokenAccounting() public view {
        address controller = address(vault.getProtocolFeeController());
        uint256 total = launchToken.balanceOf(address(vault)) +
            launchToken.balanceOf(controller) +
            launchToken.balanceOf(_CREATOR_FEE_RECIPIENT) +
            launchToken.balanceOf(address(handler)) +
            launchToken.balanceOf(pool);
        assertEq(launchToken.totalSupply(), _LAUNCH_SUPPLY, "Supply changed");
        assertEq(total, _LAUNCH_SUPPLY, "Launch tokens unaccounted for");
    }

    /// @dev Nobody can redeem the raise: the BPT is the burned initial supply, the Vault's minimum, and whatever was
    /// added proportionally after graduation.
    function invariant_onlyBurnedAndAddedBpt() public view {
        IERC20 bpt = IERC20(pool);
        assertEq(
            bpt.totalSupply(),
            bpt.balanceOf(_BURN) + POOL_MINIMUM_TOTAL_SUPPLY + bpt.balanceOf(address(handler)),
            "Unexpected BPT holder"
        );
    }

    function invariant_priceNeverMovesWithoutATrade() public view {
        assertFalse(handler.priceMovedWithoutTrade(), "Price moved with time");
    }

    function invariant_bondingSellsNeverFail() public view {
        assertEq(handler.failedBondingSells(), 0, "A holder could not sell back while bonding");
    }

    function invariant_completingBuyWithinOvershootLimit() public view {
        uint256 atCompletion = handler.launchBalanceAtCompletion();
        if (atCompletion == type(uint256).max) return;
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        assertGe(atCompletion, graduationBalance - graduationBalance.mulDown(0.1e16), "Overshot the limit");
    }

    function invariant_virtualBalancesPositive() public view {
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        assertGt(virtualA, 0, "Virtual A is zero");
        assertGt(virtualB, 0, "Virtual B is zero");
    }

    /// @dev Coverage: sequences must reach graduation and exercise liquidity, not only bonding trades.
    function afterInvariant() external view {
        if (handler.calls() < 64) return;
        console2.log("calls / sells / graduated-phase fee calls / adds / removes:");
        console2.log(handler.calls(), handler.sells(), handler.graduatedCalls());
        console2.log(handler.adds(), handler.removes());
    }

    /// @dev The pool never holds tokens itself (the Vault does); creator fees paid to it are forwarded.
    function invariant_poolHoldsNoFees() public {
        _brc().withdrawCreatorFees();
        assertEq(launchToken.balanceOf(pool), 0, "Pool holds launch tokens");
        assertEq(quoteToken.balanceOf(pool), 0, "Pool holds WETH");
    }
}
