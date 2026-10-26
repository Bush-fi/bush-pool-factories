// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import {
    IRukusLaunchPool,
    BondingPhase,
    RukusLaunchCurveParams,
    RukusLaunchPoolImmutableData
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";
import {
    IRukusLaunchPoolFactory,
    RukusLaunchParams
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPoolFactory.sol";

import { RukusLaunchPoolFactory } from "../../../contracts/rukus-launch/RukusLaunchPoolFactory.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

/**
 * @notice The creator fee: the pool is its own pool creator and fixes the creator share at 99.999% when initialized, so
 * fees leave the pool (keeping the curve exact) and go to the launch's creator fee recipient.
 */
contract RukusLaunchCreatorFeeTest is BaseRukusLaunchTest {
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
        assertEq(_brc().getRukusFeeRecipient(), _RUKUS_FEE_RECIPIENT, "Rukus recipient");
        assertEq(_brc().getRukusFeeShare(), factory.computeRukusFeeShare(_SWAP_FEE), "Rukus share");
    }

    /// @dev Set during `create` (in the after-initialize hook), in both the fee controller and the Vault.
    function testCreatorFeeSetAtCreate() public view {
        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), 99.999e16, "Controller creator fee");
        assertGe(vault.getPoolConfig(pool).aggregateSwapFeePercentage, 99.99e16, "Vault aggregate fee");
        assertEq(_brc().CREATOR_FEE_PERCENTAGE(), 99.999e16, "Constant");
    }

    function testFactoryRejectsZeroRecipient() public {
        RukusLaunchParams memory params = _launchParams();
        params.creatorFeeRecipient = address(0);
        vm.expectRevert(IRukusLaunchPool.InvalidCreatorFeeRecipient.selector);
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

    /// @dev Fees from buys (in quote) and sells (in launch tokens) are split by the Rukus share; the pool keeps none.
    function testWithdrawSplitsBetweenCreatorAndRukus() public {
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

        uint256 quotePaid = quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT) + quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT);
        uint256 launchPaid = launchToken.balanceOf(_CREATOR_FEE_RECIPIENT) + launchToken.balanceOf(_RUKUS_FEE_RECIPIENT);
        assertApproxEqRel(quotePaid, quoteFees.mulDown(creatorPart), 1e14, "Quote fees not paid");
        assertApproxEqRel(launchPaid, launchFees.mulDown(creatorPart), 1e14, "Launch fees not paid");

        // Rukus gets its share, rounded down; the creator gets the rest.
        uint256 share = _brc().getRukusFeeShare();
        assertEq(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), quotePaid.mulDown(share), "Rukus quote share");
        assertEq(launchToken.balanceOf(_RUKUS_FEE_RECIPIENT), launchPaid.mulDown(share), "Rukus launch share");
        assertEq(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), quotePaid - quotePaid.mulDown(share), "Creator quote share");

        // That is Rukus's cut of the trade: 0.25% of the 10,000 bought with.
        assertApproxEqRel(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), 25e18, 1e14, "Rukus cut of the buy");
        assertEq(quoteToken.balanceOf(pool), 0, "Pool holds quote");
        assertEq(launchToken.balanceOf(pool), 0, "Pool holds launch tokens");
        assertEq(vault.getAggregateSwapFeeAmount(pool, quoteToken), 0, "Quote fees left in the Vault");
    }

    /// @dev The fee controller's permissionless withdrawal pays the pool creator (the pool); the pool splits it.
    function testFeesPaidToThePoolAreSplit() public {
        _buyExactIn(alice, 10_000e18);
        vm.startPrank(hacker);
        controller.collectAggregateFees(pool);
        controller.withdrawPoolCreatorFees(pool);
        vm.stopPrank();
        uint256 atPool = quoteToken.balanceOf(pool);
        assertGt(atPool, 0, "Nothing paid to the pool");

        _brc().withdrawCreatorFees();
        assertEq(quoteToken.balanceOf(pool), 0, "Pool kept fees");
        uint256 rukusPart = atPool.mulDown(_brc().getRukusFeeShare());
        assertEq(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), rukusPart, "Rukus not paid");
        assertEq(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), atPool - rukusPart, "Creator not paid");
    }

    /***************************************************************************
                                  Graduation
    ***************************************************************************/

    uint256 internal constant _GRAD_SWAP_FEE = 0.5e16;
    uint256 internal constant _GRAD_CREATOR_FEE = 50e16;

    /// @dev A launch whose fees change at graduation: 0.5% swap fee, half of it (after the protocol) to the creator.
    function _launchWithGraduatedFees() internal {
        _launchWithGraduatedFees(_MIN_GRADUATED_CREATOR_FEE_PERCENTAGE, _GRAD_CREATOR_FEE);
    }

    /// @dev As above, from a factory with this floor, and with this graduated creator fee.
    function _launchWithGraduatedFees(uint256 minCreatorFee, uint256 creatorFee) internal {
        factory = _deployFactoryWithMinCreatorFee(minCreatorFee);
        RukusLaunchParams memory params = _launchParams();
        params.graduatedSwapFeePercentage = _GRAD_SWAP_FEE;
        params.graduatedCreatorFeePercentage = creatorFee;
        (pool, launchToken) = _launch(_launchTokenIndex, _SWAP_FEE, params);
    }

    function _deployFactoryWithMinCreatorFee(uint256 minCreatorFee) internal returns (RukusLaunchPoolFactory) {
        return
            new RukusLaunchPoolFactory(
                vault,
                365 days,
                IWETH(address(weth)),
                _RUKUS_FEE_RECIPIENT,
                _RUKUS_FEE_PERCENTAGE,
                minCreatorFee,
                _LAUNCH_SUPPLY,
                _defaultCurve(),
                "f",
                "p"
            );
    }

    function _aggregateFee(uint256 creatorFee) internal view returns (uint256) {
        (uint256 protocolFee, ) = controller.getPoolProtocolSwapFeeInfo(pool);
        return controller.computeAggregateFeePercentage(protocolFee, creatorFee);
    }

    /**
     * @dev The swap that graduates the pool switches both fees and pays out the bonding fees, in one transaction. The
     * Vault loads a swap's fee rate and split before `onBeforeSwap`, so that swap still pays the bonding swap fee, split
     * at the bonding creator share; the next swap pays the graduated ones.
     */
    function testGraduatingSwapSwitchesFeesAndPaysOut() public {
        _launchWithGraduatedFees();
        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), 99.999e16, "Bonding creator fee");
        (uint256 gradSwapFee, uint256 gradCreatorFee) = _brc().getGraduatedFees();
        assertEq(gradSwapFee, _GRAD_SWAP_FEE, "Graduated swap fee");
        assertEq(gradCreatorFee, _GRAD_CREATOR_FEE, "Graduated creator fee");

        _completeCurve(alice);
        uint256 bondingFees = vault.getAggregateSwapFeeAmount(pool, quoteToken);
        assertGt(bondingFees, 0, "No bonding fees");
        assertEq(vault.getStaticSwapFeePercentage(pool), _SWAP_FEE, "Fee switched before graduation");
        vm.warp(block.timestamp + 1);

        uint256 quoteIn = 1e18;
        _buyExactIn(bob, quoteIn);

        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Not graduated");
        assertEq(vault.getStaticSwapFeePercentage(pool), _GRAD_SWAP_FEE, "Static fee not switched");
        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), _GRAD_CREATOR_FEE, "Creator fee not switched");
        assertEq(vault.getPoolConfig(pool).aggregateSwapFeePercentage, _aggregateFee(_GRAD_CREATOR_FEE), "Vault fee");

        // The bonding fees were paid out, split by the Rukus share.
        (uint256 protocolFee, ) = controller.getPoolProtocolSwapFeeInfo(pool);
        uint256 paid = quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT) + quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT);
        assertApproxEqRel(paid, bondingFees.mulDown(FixedPoint.ONE - protocolFee), 1e14, "Bonding fees not paid");
        assertEq(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), paid.mulDown(_brc().getRukusFeeShare()), "Rukus share");
        assertEq(quoteToken.balanceOf(pool), 0, "Pool kept fees");

        // Only the graduating swap's fee is left: the 1% bonding fee on the amount in, at the bonding aggregate share.
        uint256 graduatingSwapFee = vault.getAggregateSwapFeeAmount(pool, quoteToken);
        assertApproxEqRel(
            graduatingSwapFee,
            quoteIn.mulDown(_SWAP_FEE).mulDown(_aggregateFee(99.999e16)),
            1e12,
            "Graduating swap fee"
        );

        // The next swap: the graduated 0.5%, at the graduated aggregate share.
        _buyExactIn(bob, quoteIn);
        assertApproxEqRel(
            vault.getAggregateSwapFeeAmount(pool, quoteToken) - graduatingSwapFee,
            quoteIn.mulDown(_GRAD_SWAP_FEE).mulDown(_aggregateFee(_GRAD_CREATOR_FEE)),
            1e12,
            "Swap after graduating"
        );
    }

    /**
     * @dev The Vault's static swap fee is the fee charged in every phase, so an aggregator reading it quotes the pool
     * right: there is no dynamic fee hook to simulate.
     */
    function testStaticFeeIsTheFeeChargedInEveryPhase() public {
        _launchWithGraduatedFees();
        assertFalse(vault.getHooksConfig(pool).shouldCallComputeDynamicSwapFee, "Dynamic fee hook");

        // Bonding, then completed (not graduated yet): the bonding fee.
        uint256 quoteIn = 1e18;
        _assertSwapChargesTheStaticFee(quoteIn, _SWAP_FEE, 99.999e16, "Bonding");
        _completeCurve(alice);
        assertEq(vault.getStaticSwapFeePercentage(pool), _SWAP_FEE, "Completed");

        // Graduated (here by `graduate`): the graduated fee, and that's what a swap pays.
        vm.warp(block.timestamp + 1);
        _brc().graduate();
        _assertSwapChargesTheStaticFee(quoteIn, _GRAD_SWAP_FEE, _GRAD_CREATOR_FEE, "Graduated");
    }

    /// @dev Graduation sets the static fee, which the Vault refuses while the pool is paused: it waits for the unpause.
    function testGraduationWaitsForAPause() public {
        _skipOnFork("pauses the pool, which needs the local mock");
        _launchWithGraduatedFees();
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);

        vault.manualSetPoolPaused(pool, true);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.PoolPaused.selector, pool));
        _brc().graduate();

        vault.manualSetPoolPaused(pool, false);
        _brc().graduate();
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Not graduated");
        assertEq(vault.getStaticSwapFeePercentage(pool), _GRAD_SWAP_FEE, "Static fee not switched");
    }

    /// @dev The static fee is `expectedFee`, and a buy of `quoteIn` pays exactly that, split at `creatorFee`.
    function _assertSwapChargesTheStaticFee(
        uint256 quoteIn,
        uint256 expectedFee,
        uint256 creatorFee,
        string memory phase
    ) internal {
        assertEq(vault.getStaticSwapFeePercentage(pool), expectedFee, string.concat(phase, ": static fee"));
        uint256 feesBefore = vault.getAggregateSwapFeeAmount(pool, quoteToken);
        _buyExactIn(bob, quoteIn);
        assertApproxEqRel(
            vault.getAggregateSwapFeeAmount(pool, quoteToken) - feesBefore,
            quoteIn.mulDown(expectedFee).mulDown(_aggregateFee(creatorFee)),
            1e12,
            string.concat(phase, ": fee charged")
        );
    }

    /// @dev After graduation: the graduated swap fee, and the pool keeps the part of it not owed as protocol/creator fees.
    function testGraduatedSwapsKeepPartOfTheFee() public {
        _launchWithGraduatedFees();
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();

        uint256 feesBefore = vault.getAggregateSwapFeeAmount(pool, quoteToken);
        uint256 quoteIn = 1e18;
        _buyExactIn(bob, quoteIn);
        uint256 aggregate = _aggregateFee(_GRAD_CREATOR_FEE);
        assertApproxEqRel(
            vault.getAggregateSwapFeeAmount(pool, quoteToken) - feesBefore,
            quoteIn.mulDown(_GRAD_SWAP_FEE).mulDown(aggregate),
            1e12,
            "Graduated fee"
        );
        assertLt(aggregate, 99e16, "Pool keeps none of the fee");
    }

    /// @dev `graduate()` takes the same path: fees switched and bonding fees paid out.
    function testGraduateSwitchesFeesAndPaysOut() public {
        _launchWithGraduatedFees();
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        vm.prank(hacker); // anyone can trigger it
        _brc().graduate();

        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), _GRAD_CREATOR_FEE, "Creator fee not switched");
        assertEq(vault.getAggregateSwapFeeAmount(pool, quoteToken), 0, "Bonding fees left in the Vault");
        assertGt(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), 0, "Rukus not paid");
        assertGt(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), 0, "Creator not paid");
    }

    /// @dev While bonding, the static swap fee applies (the graduated one only from graduation on).
    function testBondingUsesTheStaticFee() public {
        _launchWithGraduatedFees();
        uint256 quoteIn = 1_000e18;
        _buyExactIn(bob, quoteIn);
        assertApproxEqRel(
            vault.getAggregateSwapFeeAmount(pool, quoteToken),
            quoteIn.mulDown(_SWAP_FEE).mulDown(_aggregateFee(99.999e16)),
            1e12,
            "Bonding fee"
        );
    }

    /// @dev The launcher's graduated swap fee and creator fee both reach the pool; the factory holds only the floor.
    function testGraduatedFeesPassedToThePool() public {
        _launchWithGraduatedFees();
        assertEq(factory.getMinGraduatedCreatorFeePercentage(), _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE, "Factory floor");
        (uint256 poolSwapFee, uint256 poolCreatorFee) = _brc().getGraduatedFees();
        assertEq(poolSwapFee, _GRAD_SWAP_FEE, "Pool swap fee");
        assertEq(poolCreatorFee, _GRAD_CREATOR_FEE, "Pool creator fee");
        RukusLaunchPoolImmutableData memory data = _brc().getRukusLaunchPoolImmutableData();
        assertEq(data.graduatedSwapFeePercentage, _GRAD_SWAP_FEE, "Immutable data swap fee");
        assertEq(data.graduatedCreatorFeePercentage, _GRAD_CREATOR_FEE, "Immutable data creator fee");
    }

    /**
     * @dev The launcher's graduated creator fee must be from the factory's floor to 99.999%: one wei below the floor
     * reverts with the floor, one wei above the maximum with the pool's check; both ends are allowed, and the launch
     * graduates onto them.
     */
    function testCreateEnforcesTheGraduatedCreatorFeeFloor() public {
        uint256 floor = 30e16;
        factory = _deployFactoryWithMinCreatorFee(floor);
        RukusLaunchParams memory params = _launchParams();

        params.graduatedCreatorFeePercentage = floor - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IRukusLaunchPoolFactory.GraduatedCreatorFeeBelowMinimum.selector, floor - 1, floor)
        );
        factory.create(params, _SWAP_FEE, "below");

        params.graduatedCreatorFeePercentage = 99.999e16 + 1;
        vm.expectRevert(IRukusLaunchPool.InvalidGraduatedCreatorFee.selector);
        factory.create(params, _SWAP_FEE, "above");

        uint256[2] memory ends = [floor, 99.999e16];
        for (uint256 i = 0; i < ends.length; ++i) {
            params.graduatedCreatorFeePercentage = ends[i];
            (pool, launchToken) = _launch(_launchTokenIndex, _SWAP_FEE, params);
            _completeCurve(alice);
            vm.warp(block.timestamp + 1);
            _brc().graduate();
            assertEq(controller.getPoolCreatorSwapFeePercentage(pool), ends[i], "Graduated creator fee");
        }
    }

    /// @dev With no floor, a launch may take no creator fee after graduation: the whole fee (after the protocol's)
    /// then stays in the pool, and the creator and Rukus get nothing from graduated trades.
    function testZeroFloorAllowsNoCreatorFeeAfterGraduation() public {
        _launchWithGraduatedFees(0, 0);
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertEq(controller.getPoolCreatorSwapFeePercentage(pool), 0, "Creator fee");

        uint256 rukusBefore = quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT);
        uint256 creatorBefore = quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT);
        _buyExactIn(bob, 1e18);
        _brc().withdrawCreatorFees();
        assertEq(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), rukusBefore, "Rukus paid after graduation");
        assertEq(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), creatorBefore, "Creator paid after graduation");
    }

    /// @dev Rukus's cut after graduation is a fixed share of the creator fees, so it scales with the launch's graduated
    /// creator fee: at 25%, half of what it is at 50%.
    function testRukusCutAfterGraduationScalesWithTheCreatorFee() public {
        uint256[2] memory creatorFees = [uint256(50e16), 25e16];
        uint256[2] memory rukusCuts;
        for (uint256 i = 0; i < creatorFees.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _launchWithGraduatedFees(_MIN_GRADUATED_CREATOR_FEE_PERCENTAGE, creatorFees[i]);
            _completeCurve(alice);
            vm.warp(block.timestamp + 1);
            _brc().graduate();

            uint256 rukusBefore = quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT);
            uint256 quoteIn = 100e18;
            _buyExactIn(bob, quoteIn);
            _brc().withdrawCreatorFees();
            rukusCuts[i] = quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT) - rukusBefore;

            (uint256 protocolFee, ) = controller.getPoolProtocolSwapFeeInfo(pool);
            uint256 expected = quoteIn
                .mulDown(_GRAD_SWAP_FEE)
                .mulDown(FixedPoint.ONE - protocolFee)
                .mulDown(creatorFees[i])
                .mulDown(_brc().getRukusFeeShare());
            assertApproxEqRel(rukusCuts[i], expected, 1e12, "Rukus cut after graduation");
            vm.revertToState(snapshot);
        }
        assertApproxEqRel(rukusCuts[1] * 2, rukusCuts[0], 1e12, "Rukus cut doesn't scale with the creator fee");
    }

    /// @dev The launcher's graduated swap fee must be within the pool's bounds, [0.001%, 5%]: one wei outside either
    /// reverts `create`; each bound itself is allowed, and the launch graduates onto it.
    function testCreateRejectsGraduatedSwapFeeOutOfBounds() public {
        RukusLaunchParams memory params = _launchParams();
        uint256[2] memory invalid = [uint256(0.001e16 - 1), 5e16 + 1];
        for (uint256 i = 0; i < invalid.length; ++i) {
            params.graduatedSwapFeePercentage = invalid[i];
            vm.expectRevert(IRukusLaunchPool.InvalidGraduatedSwapFee.selector);
            factory.create(params, _SWAP_FEE, keccak256(abi.encode("invalid graduated fee", i)));
        }

        uint256[2] memory bounds = [uint256(0.001e16), 5e16];
        for (uint256 i = 0; i < bounds.length; ++i) {
            params.graduatedSwapFeePercentage = bounds[i];
            (pool, launchToken) = _launch(_launchTokenIndex, _SWAP_FEE, params);
            _completeCurve(alice);
            vm.warp(block.timestamp + 1);
            _brc().graduate();
            assertEq(vault.getStaticSwapFeePercentage(pool), bounds[i], "Graduated fee");
        }
    }

    /// @dev The floor can be at most the 99.999% maximum (then every launch must take exactly that).
    function testFactoryRejectsMinGraduatedCreatorFeeAboveMax() public {
        factory = _deployFactoryWithMinCreatorFee(99.999e16);
        assertEq(factory.getMinGraduatedCreatorFeePercentage(), 99.999e16, "Floor at the maximum");

        vm.expectRevert(IRukusLaunchPoolFactory.InvalidMinGraduatedCreatorFee.selector);
        new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(weth)),
            _RUKUS_FEE_RECIPIENT,
            _RUKUS_FEE_PERCENTAGE,
            99.999e16 + 1,
            _LAUNCH_SUPPLY,
            _defaultCurve(),
            "f",
            "p"
        );
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
        RukusLaunchCurveParams memory curve = RukusLaunchCurveParams({
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
