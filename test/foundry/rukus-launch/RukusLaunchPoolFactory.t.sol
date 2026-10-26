// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { PoolRoleAccounts, TokenInfo, TokenType } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { RukusLaunchPool } from "../../../contracts/rukus-launch/RukusLaunchPool.sol";
import { RukusLaunchPoolFactory } from "../../../contracts/rukus-launch/RukusLaunchPoolFactory.sol";
import {
    IRukusLaunchPool,
    BondingPhase,
    RukusLaunchCurveParams
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";
import {
    IRukusLaunchPoolFactory,
    RukusLaunchParams
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPoolFactory.sol";
import { RukusLaunchPoolFactoryLib } from "../../../contracts/rukus-launch/lib/RukusLaunchPoolFactoryLib.sol";
import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

contract RukusLaunchPoolFactoryTest is BaseRukusLaunchTest {
    using FixedPoint for uint256;

    function testCreatePool() public view {
        assertTrue(factory.isPoolFromFactory(pool), "Not from factory");
        assertEq(factory.getPoolVersion(), _POOL_VERSION, "Pool version");
        assertEq(RukusLaunchPool(pool).version(), _POOL_VERSION, "Version on the pool");

        assertEq(vault.getHooksConfig(pool).hooksContract, pool, "The pool should be its own hook");
        assertTrue(vault.getPoolConfig(pool).liquidityManagement.disableUnbalancedLiquidity, "Unbalanced enabled");
        assertFalse(vault.getPoolConfig(pool).liquidityManagement.enableDonation, "Donation enabled");
        assertEq(IERC20Metadata(pool).name(), "Launch Rukus Launch Pool", "Pool name");
        assertEq(IERC20Metadata(pool).symbol(), "LAUNCH-RUKUS", "Pool symbol");
    }

    /// @dev One call: a new token, all of it in the pool, the pool initialized and bonding, the BPT burned.
    function testCreateLaunchesTokenAndInitializesPool() public view {
        IERC20Metadata token = IERC20Metadata(address(launchToken));
        assertEq(token.name(), "Launch", "Token name");
        assertEq(token.symbol(), "LAUNCH", "Token symbol");
        assertEq(token.decimals(), 18, "Token decimals");
        assertEq(token.totalSupply(), _LAUNCH_SUPPLY, "Token supply");

        assertTrue(vault.isPoolInitialized(pool), "Not initialized");
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertEq(launchBalance, _LAUNCH_SUPPLY, "Whole supply not in the pool");
        assertEq(quoteBalance, 0, "Quote in the pool");
        assertEq(uint256(RukusLaunchPool(pool).getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");

        assertEq(IERC20(pool).balanceOf(_BURN), IERC20(pool).totalSupply() - POOL_MINIMUM_TOTAL_SUPPLY, "BPT burned");

        (IERC20 poolLaunchToken, uint256 index) = RukusLaunchPool(pool).getLaunchToken();
        assertEq(address(poolLaunchToken), address(launchToken), "Pool launch token");
        assertEq(index, _launchTokenIndex, "Launch index");

        (TokenType[] memory types, ) = _tokenTypes();
        assertEq(uint256(types[0]), uint256(TokenType.STANDARD), "Token 0 type");
        assertEq(uint256(types[1]), uint256(TokenType.STANDARD), "Token 1 type");
    }

    function testCreateEmitsLaunchCreated() public {
        RukusLaunchParams memory params = _launchParams();
        bytes32 salt = bytes32(uint256(0xbeef));
        address predicted = factory.getLaunchTokenAddress(params, address(this), salt);

        vm.expectEmit(false, true, true, true, address(factory));
        emit IRukusLaunchPoolFactory.RukusLaunchCreated(
            address(0),
            IERC20(predicted),
            address(this),
            _LAUNCH_SUPPLY,
            "ipfs://launch",
            0,
            0
        );
        (, IERC20 token) = factory.create(params, _SWAP_FEE, salt);
        assertEq(address(token), predicted, "Predicted address");
    }

    /// @dev Names and symbols have no length limit (stored as strings; the BPT's EIP-712 name falls back to storage
    /// past 31 bytes): a 1,000-character name and symbol launch, and only cost more gas.
    function testLongNameAndSymbolDoNotRevert() public {
        bytes memory long = new bytes(1000);
        for (uint256 i = 0; i < long.length; ++i) {
            long[i] = bytes1(uint8(65 + (i % 26)));
        }
        RukusLaunchParams memory params = _launchParams();
        params.name = string(long);
        params.symbol = string(long);

        uint256 gasBefore = gasleft();
        factory.create(_launchParams(), _SWAP_FEE, "short");
        uint256 shortGas = gasBefore - gasleft();
        gasBefore = gasleft();
        (address newPool, IERC20 newToken) = factory.create(params, _SWAP_FEE, "long");
        uint256 longGas = gasBefore - gasleft();

        assertEq(IERC20Metadata(address(newToken)).name(), string(long), "Token name");
        assertEq(IERC20Metadata(address(newToken)).symbol(), string(long), "Token symbol");
        assertEq(IERC20Metadata(newPool).name(), string.concat(string(long), " Rukus Launch Pool"), "Pool name");
        assertEq(IERC20Metadata(newPool).symbol(), string.concat(string(long), "-RUKUS"), "Pool symbol");
        console2.log("create gas, short names:", shortGas);
        console2.log("create gas, 1,000-character names:", longGas);
    }

    /// @dev Different creators get different addresses for the same salt (no squatting someone else's launch).
    function testSaltIsPerCreator() public view {
        RukusLaunchParams memory params = _launchParams();
        assertTrue(
            factory.getLaunchTokenAddress(params, alice, bytes32(0)) !=
                factory.getLaunchTokenAddress(params, bob, bytes32(0)),
            "Same address for two creators"
        );
    }

    function testCreateBothLaunchTokenOrders() public {
        for (uint256 i = 0; i < 2; ++i) {
            (address newPool, IERC20 token) = _launch(i);
            (, uint256 index) = RukusLaunchPool(newPool).getLaunchToken();
            assertEq(index, i, "Launch index");
            assertEq(address(vault.getPoolTokens(newPool)[i]), address(token), "Token order");
            assertEq(vault.getCurrentLiveBalances(newPool)[i], _LAUNCH_SUPPLY, "Supply in the pool");
        }
    }

    function testLaunchHookOnlyVault() public {
        RukusLaunchPoolFactory.LaunchState memory state;
        state.pool = pool;
        state.launchToken = launchToken;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        factory.launchHook(state, _LAUNCH_SUPPLY);
    }

    /// @dev Roles are fixed: no pause manager, and the pool is its own pool creator and its own swap fee manager (only
    /// it can change the fee rate, which it does once, at graduation).
    function testRolesAreFixed() public view {
        PoolRoleAccounts memory roles = vault.getPoolRoleAccounts(pool);
        assertEq(roles.pauseManager, address(0), "Pause manager");
        assertEq(roles.swapFeeManager, pool, "Swap fee manager");
        assertEq(roles.poolCreator, pool, "Pool creator");
    }

    /// @dev The quote token is always WETH: the launch can't be paired with a look-alike.
    function testQuoteTokenIsWeth() public view {
        assertEq(address(factory.getWeth()), address(weth), "Factory WETH");
        assertEq(address(quoteToken), address(weth), "Pool quote");
        IERC20[] memory tokens = vault.getPoolTokens(pool);
        assertTrue(address(tokens[0]) == address(weth) || address(tokens[1]) == address(weth), "WETH not in the pool");
    }

    function testConstructorRejectsZeroWeth() public {
        vm.expectRevert(IRukusLaunchPoolFactory.InvalidWeth.selector);
        new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(0)),
            _RUKUS_FEE_RECIPIENT,
            _RUKUS_FEE_PERCENTAGE,
            _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE,
            _LAUNCH_SUPPLY,
            _defaultCurve(),
            "f",
            "p"
        );
    }

    function testConstructorRejectsZeroRukusFeeRecipient() public {
        vm.expectRevert(IRukusLaunchPoolFactory.InvalidRukusFeeRecipient.selector);
        new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(weth)),
            address(0),
            _RUKUS_FEE_PERCENTAGE,
            _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE,
            _LAUNCH_SUPPLY,
            _defaultCurve(),
            "f",
            "p"
        );
    }

    function testRukusFeeRecipientPassedToPools() public view {
        assertEq(factory.getRukusFeeRecipient(), _RUKUS_FEE_RECIPIENT, "Factory");
        assertEq(_brc().getRukusFeeRecipient(), _RUKUS_FEE_RECIPIENT, "Pool");
    }

    /// @dev share = rukusFee / (swapFee * (1 - protocolFee) * 99.999%), fixed in the pool at create.
    function testRukusFeeShareSetAtCreate() public view {
        assertEq(factory.getRukusFeePercentage(), _RUKUS_FEE_PERCENTAGE, "Factory Rukus fee");
        (uint256 protocolFee, ) = vault.getProtocolFeeController().getPoolProtocolSwapFeeInfo(pool);
        uint256 creatorFee = _SWAP_FEE.mulDown(FixedPoint.ONE - protocolFee).mulDown(99.999e16);
        assertEq(_brc().getRukusFeeShare(), _RUKUS_FEE_PERCENTAGE.divUp(creatorFee), "Pool share");
        assertEq(_brc().getRukusLaunchPoolImmutableData().rukusFeeShare, _brc().getRukusFeeShare(), "Immutable data");
    }

    function testCreateRejectsSwapFeeBelowRukusFee() public {
        uint256 swapFee = _RUKUS_FEE_PERCENTAGE - 1e11;
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPoolFactory.SwapFeeTooLowForRukusFee.selector, swapFee));
        factory.create(_launchParams(), swapFee, "low");
    }

    function testCreateRejectsSwapFeeAbove5Percent() public {
        vm.expectRevert(IVaultErrors.SwapFeePercentageTooHigh.selector);
        factory.create(_launchParams(), 5e16 + 1e11, "high");
    }

    function testZeroRukusFeeGivesTheCreatorEverything() public {
        factory = new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(weth)),
            _RUKUS_FEE_RECIPIENT,
            0,
            _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE,
            _LAUNCH_SUPPLY,
            _defaultCurve(),
            "f",
            "p"
        );
        (pool, launchToken) = _launch(_launchTokenIndex);
        assertEq(_brc().getRukusFeeShare(), 0, "Share");
    }

    /// @dev With a 1% Rukus fee, Rukus gets 1% of every buy, whatever swap fee (up to 5%) the launcher picks.
    function testRukusGetsItsCutAtAnySwapFee__Fuzz(uint256 swapFee) public {
        uint256 rukusFee = 1e16;
        factory = new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(weth)),
            _RUKUS_FEE_RECIPIENT,
            rukusFee,
            _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE,
            _LAUNCH_SUPPLY,
            _defaultCurve(),
            "f",
            "p"
        );
        (uint256 protocolFee, ) = vault.getProtocolFeeController().getPoolProtocolSwapFeeInfo(pool);
        uint256 minSwapFee = rukusFee.divUp((FixedPoint.ONE - protocolFee).mulDown(99.999e16));
        // The Vault keeps fees to 1e11 precision.
        swapFee = (bound(swapFee, minSwapFee, 5e16) / 1e11 + 1) * 1e11;
        swapFee = swapFee > 5e16 ? 5e16 : swapFee;
        (pool, launchToken) = _launch(_launchTokenIndex, swapFee);

        uint256 quoteIn = 10_000e18;
        _buyExactIn(alice, quoteIn);
        _brc().withdrawCreatorFees();

        assertApproxEqRel(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), quoteIn.mulDown(rukusFee), 1e13, "Rukus cut");
        uint256 creatorCut = quoteIn.mulDown(swapFee).mulDown(FixedPoint.ONE - protocolFee).mulDown(99.999e16) -
            quoteIn.mulDown(rukusFee);
        assertApproxEqAbs(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), creatorCut, 1e14, "Creator gets the rest");
    }

    /***************************************************************************
                              Creator's initial buy
    ***************************************************************************/

    /// @dev ETH sent to `create` buys launch tokens for the caller, in the same transaction as the launch.
    function testInitialBuyWithEth() public {
        uint256 ethIn = 1_000e18;
        uint256 expectedOut = _referenceBuyExactIn(ethIn, "buy");
        _assertInitialBuy(ethIn, expectedOut, "buy");
    }

    /// @dev Any initial buy short of completing the curve gets what the same buy through the Router gets.
    function testInitialBuyMatchesARouterBuy__Fuzz(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e9, 1_000e18);
        uint256 expectedOut = _referenceBuyExactIn(ethIn, "fuzz");
        _assertInitialBuy(ethIn, expectedOut, "fuzz");
    }

    /// @dev The minimum is exact: the amount the buy gets passes, one more reverts with the Vault's swap limit.
    function testInitialBuyRespectsMinimumOut() public {
        uint256 ethIn = 1e18;
        uint256 expectedOut = _referenceBuyExactIn(ethIn, "min");
        RukusLaunchParams memory params = _launchParams();
        vm.deal(bob, ethIn);
        uint256 snapshot = vm.snapshotState();

        params.minInitialBuyAmountOut = expectedOut + 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SwapLimit.selector, expectedOut, expectedOut + 1));
        factory.create{ value: ethIn }(params, _SWAP_FEE, "min");
        vm.revertToState(snapshot);

        params.minInitialBuyAmountOut = expectedOut;
        vm.prank(bob);
        (, IERC20 newToken) = factory.create{ value: ethIn }(params, _SWAP_FEE, "min");
        assertEq(newToken.balanceOf(bob), expectedOut, "Initial buy amount");
    }

    /// @dev Without ETH there is no initial buy, so the minimum is ignored: the launch goes ahead and nobody gets tokens.
    function testMinimumOutIgnoredWithoutEth() public {
        RukusLaunchParams memory params = _launchParams();
        params.minInitialBuyAmountOut = 1_000e18;

        vm.expectEmit(false, true, true, true, address(factory));
        emit IRukusLaunchPoolFactory.RukusLaunchCreated(
            address(0),
            IERC20(factory.getLaunchTokenAddress(params, bob, "none")),
            bob,
            _LAUNCH_SUPPLY,
            "ipfs://launch",
            0,
            0
        );
        vm.prank(bob);
        (address newPool, IERC20 newToken) = factory.create(params, _SWAP_FEE, "none");

        assertEq(newToken.balanceOf(bob), 0, "Creator got tokens");
        assertEq(vault.getCurrentLiveBalances(newPool)[newToken < quoteToken ? 0 : 1], _LAUNCH_SUPPLY, "Pool balance");
        assertEq(uint256(RukusLaunchPool(newPool).getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");
    }

    /// @dev The initial buy pays the swap fee like any buy: Rukus and the creator get their cuts of it.
    function testInitialBuyPaysTheFees() public {
        uint256 ethIn = 100e18;
        vm.deal(bob, ethIn);
        vm.prank(bob);
        (address newPool, ) = factory.create{ value: ethIn }(_launchParams(), _SWAP_FEE, "fees");
        RukusLaunchPool(newPool).withdrawCreatorFees();

        (uint256 protocolFee, ) = vault.getProtocolFeeController().getPoolProtocolSwapFeeInfo(newPool);
        uint256 rukusCut = ethIn.mulDown(_RUKUS_FEE_PERCENTAGE);
        uint256 creatorCut = ethIn.mulDown(_SWAP_FEE).mulDown(FixedPoint.ONE - protocolFee).mulDown(99.999e16) -
            rukusCut;
        assertApproxEqRel(quoteToken.balanceOf(_RUKUS_FEE_RECIPIENT), rukusCut, 1e13, "Rukus cut");
        assertApproxEqAbs(quoteToken.balanceOf(_CREATOR_FEE_RECIPIENT), creatorCut, 1e14, "Creator gets the rest");
    }

    /// @dev The biggest initial buy allowed completes the curve inside `create`, and the pool is past bonding.
    function testInitialBuyCanCompleteTheCurve() public {
        uint256 ethIn = _ethToCompleteTheCurve("full");
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();

        vm.deal(bob, ethIn);
        vm.expectEmit(false, false, false, false);
        emit IRukusLaunchPool.BondingCurveCompleted(0);
        vm.prank(bob);
        (address newPool, IERC20 newToken) = factory.create{ value: ethIn }(_launchParams(), _SWAP_FEE, "full");

        RukusLaunchPool newRukusPool = RukusLaunchPool(newPool);
        uint256 launchBalance = vault.getCurrentLiveBalances(newPool)[newToken < quoteToken ? 0 : 1];
        uint256 minLaunchBalance = graduationBalance -
            graduationBalance.mulDown(newRukusPool.MAX_GRADUATION_OVERSHOOT());
        assertLe(launchBalance, graduationBalance, "Curve not completed");
        assertGe(launchBalance, minLaunchBalance, "Past the overshoot limit");
        assertEq(newToken.balanceOf(bob), _LAUNCH_SUPPLY - launchBalance, "Initial buy amount");
        assertEq(uint256(newRukusPool.getBondingPhase()), uint256(BondingPhase.COMPLETED), "Phase");
        assertEq(newRukusPool.getBondingCompletedAt(), block.timestamp, "Completed at");
        assertEq(bob.balance, 0, "ETH not spent");
    }

    /// @dev The initial buy is a normal buy: it can't go past the overshoot limit either.
    function testInitialBuyCannotOvershoot() public {
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        uint256 minLaunchBalance = graduationBalance - graduationBalance.mulDown(_brc().MAX_GRADUATION_OVERSHOOT());
        uint256 maxOut = _LAUNCH_SUPPLY - minLaunchBalance;

        // 1% more than completing the curve takes: well past the 0.1% overshoot, well short of the whole balance.
        uint256 ethIn = _ethToCompleteTheCurve("over");
        ethIn += ethIn / 100;
        vm.deal(bob, ethIn);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.GraduationBuyTooLarge.selector, maxOut));
        factory.create{ value: ethIn }(_launchParams(), _SWAP_FEE, "over");
    }

    /// @dev ETH that would buy more than the pool holds fails in the swap maths, before the overshoot check.
    function testInitialBuyLargerThanTheSupplyReverts() public {
        vm.deal(bob, 1_000_000e18);
        vm.prank(bob);
        vm.expectRevert(ReClammMath.AmountOutGreaterThanBalance.selector);
        factory.create{ value: 1_000_000e18 }(_launchParams(), _SWAP_FEE, "big");
    }

    /// @dev The ETH that buys exactly down to the graduation balance right after bob launches with `salt`.
    function _ethToCompleteTheCurve(bytes32 salt) internal returns (uint256 ethIn) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        (address refPool, IERC20 refToken) = factory.create(_launchParams(), _SWAP_FEE, salt);
        uint256 launchOut = _LAUNCH_SUPPLY - RukusLaunchPool(refPool).getGraduationLaunchBalance();
        vm.prank(bob);
        ethIn = router.swapSingleTokenExactOut(refPool, quoteToken, refToken, launchOut, MAX_UINT128, MAX_UINT256, false, "");
        vm.revertToState(snapshot);
    }

    /// @dev What `ethIn` buys through the Router right after bob launches with `salt` (the same pool `create` makes).
    function _referenceBuyExactIn(uint256 ethIn, bytes32 salt) internal returns (uint256 launchOut) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        (address refPool, IERC20 refToken) = factory.create(_launchParams(), _SWAP_FEE, salt);
        vm.prank(bob);
        launchOut = router.swapSingleTokenExactIn(refPool, quoteToken, refToken, ethIn, 0, MAX_UINT256, false, "");
        vm.revertToState(snapshot);
    }

    /// @dev Bob launches with `ethIn`: checks the event, his tokens, and that nothing is left in the factory.
    function _assertInitialBuy(uint256 ethIn, uint256 expectedOut, bytes32 salt) internal {
        RukusLaunchParams memory params = _launchParams();
        vm.deal(bob, ethIn);

        vm.expectEmit(false, true, true, true, address(factory));
        emit IRukusLaunchPoolFactory.RukusLaunchCreated(
            address(0),
            IERC20(factory.getLaunchTokenAddress(params, bob, salt)),
            bob,
            _LAUNCH_SUPPLY,
            "ipfs://launch",
            ethIn,
            expectedOut
        );
        vm.prank(bob);
        (address newPool, IERC20 newToken) = factory.create{ value: ethIn }(params, _SWAP_FEE, salt);

        assertEq(newToken.balanceOf(bob), expectedOut, "Initial buy amount");
        assertEq(bob.balance, 0, "ETH not spent");
        assertEq(newToken.balanceOf(address(factory)), 0, "Factory kept tokens");
        assertEq(weth.balanceOf(address(factory)), 0, "Factory kept WETH");
        assertEq(address(factory).balance, 0, "Factory kept ETH");
        uint256 launchBalance = vault.getCurrentLiveBalances(newPool)[newToken < quoteToken ? 0 : 1];
        assertEq(launchBalance, _LAUNCH_SUPPLY - expectedOut, "Pool balance");
        assertEq(uint256(RukusLaunchPool(newPool).getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");
    }

    /// @dev The factory fixes the supply and curve of every launch; `create` takes neither.
    function testLaunchConfigIsTheFactorys() public view {
        (uint256 supply, RukusLaunchCurveParams memory curve) = factory.getLaunchConfig();
        assertEq(supply, _LAUNCH_SUPPLY, "Supply");
        assertEq(curve.initialPrice, _INITIAL_PRICE, "Initial price");
        assertEq(curve.graduationPrice, _GRADUATION_PRICE, "Graduation price");
        assertEq(launchToken.totalSupply(), _LAUNCH_SUPPLY, "Launch supply");
        assertEq(_brc().getRukusLaunchPoolImmutableData().initialPrice, _INITIAL_PRICE, "Pool initial price");
        assertEq(_brc().getRukusLaunchPoolImmutableData().graduationPrice, _GRADUATION_PRICE, "Pool graduation price");
    }

    /// @dev A 1-wei supply on a 16x curve rounds the curve's virtual launch balance to 0: `create` refuses it.
    function testCreateRejectsASupplyTooSmallForTheCurve() public {
        factory = _deployFactory(1, _defaultCurve());
        vm.expectRevert(IRukusLaunchPool.ZeroVirtualBalance.selector);
        factory.create(_launchParams(), _SWAP_FEE, "dust");
    }

    function testConstructorRejectsInvalidSupply() public {
        vm.expectRevert(IRukusLaunchPoolFactory.InvalidLaunchSupply.selector);
        _deployFactory(0, _defaultCurve());

        uint256 max = factory.MAX_LAUNCH_SUPPLY();
        vm.expectRevert(IRukusLaunchPoolFactory.InvalidLaunchSupply.selector);
        _deployFactory(max + 1, _defaultCurve());

        // The bound itself is accepted, and launches.
        factory = _deployFactory(max, _defaultCurve());
        factory.create(_launchParams(), _SWAP_FEE, "max");
    }

    function testConstructorRejectsInvalidPrices() public {
        RukusLaunchCurveParams memory curve = _defaultCurve();
        curve.initialPrice = 0;
        vm.expectRevert(IRukusLaunchPool.InvalidBondingPrices.selector);
        _deployFactory(_LAUNCH_SUPPLY, curve);

        curve = _defaultCurve();
        curve.graduationPrice = curve.initialPrice;
        vm.expectRevert(IRukusLaunchPool.InvalidBondingPrices.selector);
        _deployFactory(_LAUNCH_SUPPLY, curve);
    }

    function testConstructorRejectsBondingPriceRatioOutOfBounds() public {
        RukusLaunchCurveParams memory curve = _defaultCurve();
        curve.graduationPrice = (curve.initialPrice * 1.005e18) / 1e18;
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.BondingPriceRatioOutOfBounds.selector, 1.005e18));
        _deployFactory(_LAUNCH_SUPPLY, curve);

        curve.graduationPrice = curve.initialPrice * 2e6;
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.BondingPriceRatioOutOfBounds.selector, 2e6 * 1e18));
        _deployFactory(_LAUNCH_SUPPLY, curve);

        // The bounds themselves are accepted, and launch.
        curve.graduationPrice = (curve.initialPrice * RukusLaunchPoolFactoryLib.MIN_BONDING_PRICE_RATIO) / 1e18;
        _deployFactory(_LAUNCH_SUPPLY, curve).create(_launchParams(), _SWAP_FEE, "min");
        curve.graduationPrice = (curve.initialPrice * RukusLaunchPoolFactoryLib.MAX_BONDING_PRICE_RATIO) / 1e18;
        _deployFactory(_LAUNCH_SUPPLY, curve).create(_launchParams(), _SWAP_FEE, "max");
    }

    function _tokenTypes() internal view returns (TokenType[] memory types, IERC20[] memory tokens) {
        TokenInfo[] memory info;
        (tokens, info, , ) = vault.getPoolTokenInfo(pool);
        types = new TokenType[](2);
        types[0] = info[0].tokenType;
        types[1] = info[1].tokenType;
    }
}
