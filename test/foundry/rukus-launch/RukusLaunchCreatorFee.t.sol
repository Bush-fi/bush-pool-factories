// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import {
    IBondingReClammPool,
    BondingPhase,
    BondingReClammCurveParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";
import {
    IBondingReClammPoolFactory,
    BondingLaunchParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPoolFactory.sol";

import { BaseBondingReClammTest } from "../utils/BaseBondingReClammTest.sol";

/**
 * @notice The creator fee: the pool is its own pool creator and fixes the creator share at 99.999% when initialized, so
 * fees leave the pool (keeping the curve exact) and go to the launch's creator fee recipient.
 */
contract BondingReClammCreatorFeeTest is BaseBondingReClammTest {
    using FixedPoint for uint256;

    IProtocolFeeController internal controller;

    function setUp() public virtual override {
        super.setUp();
        controller = vault.getProtocolFeeController();
    }

    /***************************************************************************
                                     Setup
    ***************************************************************************/

    function testPoolIsItsOwnPoolCreator() public view {
        PoolRoleAccounts memory roles = vault.getPoolRoleAccounts(pool);
        assertEq(roles.poolCreator, pool, "Pool creator");
        assertEq(_brc().getCreatorFeeRecipient(), _CREATOR_FEE_RECIPIENT, "Recipient");
    }

    /// @dev Set during `create` (in the after-initialize hook), in both the fee controller and the Vault.
    function testCreatorFeeSetAtCreate() public view {
        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), 99.999e16, "Controller creator fee");
        assertGe(vault.getPoolConfig(pool).aggregateSwapFeePercentage, 99.99e16, "Vault aggregate fee");
        assertEq(_brc().CREATOR_FEE_PERCENTAGE(), 99.999e16, "Constant");
    }

    function testFactoryRejectsZeroRecipient() public {
        BondingLaunchParams memory params = _launchParams();
        params.creatorFeeRecipient = address(0);
        vm.expectRevert(IBondingReClammPool.InvalidCreatorFeeRecipient.selector);
        factory.create(params, _SWAP_FEE, "x");
    }

    /// @dev Nobody can change the creator fee: only the pool creator can, and the pool has no function that does.
    function testNobodyCanChangeTheFee() public {
        address[4] memory accounts = [address(admin), lp, alice, address(factory)];
        for (uint256 i = 0; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IProtocolFeeController.CallerIsNotPoolCreator.selector, accounts[i], pool)
            );
            controller.setPoolCreatorSwapFeePercentage(pool, 0);
        }
    }

    /***************************************************************************
                                   Withdrawal
    ***************************************************************************/

    /// @dev Fees from buys (in quote) and sells (in launch tokens) reach the recipient; the pool never keeps any.
    function testWithdrawPaysTheRecipient() public {
        uint256 bought = _buyExactIn(alice, 10_000e18);
        _sellExactIn(alice, bought / 2);

        uint256 quoteFees = vault.getAggregateSwapFeeAmount(pool, quoteToken);
        uint256 launchFees = vault.getAggregateSwapFeeAmount(pool, launchToken);
        assertApproxEqRel(quoteFees, 100e18, 1e15, "Buy fee: ~1% of 10,000");
        assertGt(launchFees, 0, "No sell fee");

        // The creator's part of the fee: all of it after the protocol's share (0 locally, 30% on Robinhood Chain).
        (uint256 protocolShare, ) = controller.getPoolProtocolSwapFeeInfo(pool);
        uint256 creatorPart = FixedPoint.ONE - protocolShare;

        vm.prank(hacker); // anyone can trigger it
        _brc().withdrawCreatorFees();

        assertApproxEqRel(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), quoteFees.mulDown(creatorPart), 1e14, "Quote fees not paid");
        assertApproxEqRel(launchToken.balanceOf(_CREATOR_FEE_RECIPIENT), launchFees.mulDown(creatorPart), 1e14, "Launch fees not paid");
        assertEq(quoteToken.balanceOf(pool), 0, "Pool holds quote");
        assertEq(launchToken.balanceOf(pool), 0, "Pool holds launch tokens");
        assertEq(vault.getAggregateSwapFeeAmount(pool, quoteToken), 0, "Quote fees left in the Vault");
    }

    /// @dev The fee controller's permissionless withdrawal pays the pool creator (the pool); the pool forwards it.
    function testFeesPaidToThePoolAreForwarded() public {
        _buyExactIn(alice, 10_000e18);
        vm.startPrank(hacker);
        controller.collectAggregateFees(pool);
        controller.withdrawPoolCreatorFees(pool);
        vm.stopPrank();
        uint256 atPool = quoteToken.balanceOf(pool);
        assertGt(atPool, 0, "Nothing paid to the pool");

        _brc().withdrawCreatorFees();
        assertEq(quoteToken.balanceOf(pool), 0, "Pool kept fees");
        assertEq(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), atPool, "Not forwarded");
    }

    /***************************************************************************
                              Curve stays exact
    ***************************************************************************/

    /**
     * @dev Heavy trading while bonding (volume ~50x the raise) no longer drifts the curve: the fees leave the pool, so
     * it still completes at the graduation price, graduates balanced, and the graduated range's top stays near the
     * 1e12 width's million-x (it was ~140x with fees kept in the pool).
     */
    function testHeavyBondingVolumeStillGraduatesBalanced() public {
        for (uint256 i = 0; i < 25; ++i) {
            uint256 bought = _buyExactIn(bob, 30_000e18);
            _sellExactIn(bob, bought);
        }
        _completeCurve(alice);

        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), _GRADUATION_PRICE, 1e14, "Price drifted");
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertApproxEqRel(quoteBalance, launchBalance.mulDown(_GRADUATION_PRICE), 1e14, "Not balanced");

        vm.warp(block.timestamp + 1);
        _brc().graduate();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        uint256 invariant = (launchBalance + virtualLaunch).mulDown(quoteBalance + virtualQuote);
        uint256 maxPrice = invariant.divDown(virtualLaunch.mulDown(virtualLaunch));
        assertGt(maxPrice, _GRADUATION_PRICE * 500_000, "Top of the range too low");
    }

    /***************************************************************************
                          Launch preset: 5 ETH, 800M / 200M
    ***************************************************************************/

    /**
     * @dev 1B tokens, 800M sold on the curve and 200M left for the graduated pool, graduating at 5 ETH of real reserves.
     * 200M = 1B / (r + 1) gives r = 4, so graduationPrice = 16 x initialPrice; 5 ETH / 200M sets the prices.
     */
    function testLaunchPreset5Eth() public {
        BondingReClammCurveParams memory curve = BondingReClammCurveParams({
            initialPrice: 0.0000000015625e18,
            graduationPrice: 0.000000025e18
        });
        _useFactory(1e9 * 1e18, curve);

        assertEq(_brc().getGraduationLaunchBalance(), 200e6 * 1e18, "200M left at graduation");
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        assertApproxEqRel(virtualLaunch, uint256(1e9 * 1e18) / 15, 1e9, "Virtual launch ~66.7M");
        assertApproxEqRel(virtualQuote, 1.6666666667e18, 1e9, "Virtual quote ~1.67 ETH");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), curve.initialPrice, 1e9, "Initial price");

        // Some trading back and forth, then the curve is bought out exactly.
        uint256 bought = _buyExactIn(bob, 2e18);
        _sellExactIn(bob, bought);
        _completeCurve(alice);

        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertEq(launchBalance, 200e6 * 1e18, "Launch left");
        assertApproxEqRel(quoteBalance, 5e18, 1e14, "Not 5 ETH of net real reserves");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), curve.graduationPrice, 1e14, "Graduation price");

        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Graduated");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), curve.graduationPrice, 1e14, "Graduation moved it");
    }
}
