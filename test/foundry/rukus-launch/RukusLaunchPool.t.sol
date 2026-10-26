// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@bush.fi/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import { RukusLaunchPool } from "../../../contracts/rukus-launch/RukusLaunchPool.sol";
import {
    IRukusLaunchPool,
    RukusLaunchPoolParams,
    BondingPhase,
    RukusLaunchPoolDynamicData,
    RukusLaunchPoolImmutableData
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

contract RukusLaunchPoolTest is BaseRukusLaunchTest {
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    /***************************************************************************
                                  Bonding curve
    ***************************************************************************/

    function testInitialCurve() public view {
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();

        // Vt = Rt0 * P0 / (P1 - P0) = Rt0 / 15; Vq = P0 * (Rt0 + Vt).
        assertEq(virtualLaunch, _LAUNCH_SUPPLY / 15, "Virtual launch balance");
        assertEq(virtualQuote, (_LAUNCH_SUPPLY + virtualLaunch).mulDown(_INITIAL_PRICE), "Virtual quote balance");
        // Rt1 = Rt0 / (sqrt(16) + 1).
        assertEq(_brc().getGraduationLaunchBalance(), _LAUNCH_SUPPLY / 5, "Graduation balance");

        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertEq(launchBalance, _LAUNCH_SUPPLY, "Launch balance");
        assertEq(quoteBalance, 0, "Quote balance");

        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), _INITIAL_PRICE, 1e6, "Initial price");
    }

    /// @dev Without fees, the curve ends at the graduation price holding equal value of both tokens.
    function testCurveEndsAtGraduationPriceBalanced() public {
        _skipOnFork("forces a 0% swap fee (the live Vault enforces the minimum)");
        setSwapFeePercentage(0);
        _completeCurve(alice);

        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertEq(launchBalance, _LAUNCH_SUPPLY / 5, "Launch balance at graduation");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), _GRADUATION_PRICE, 1e6, "Graduation price");
        // 20M tokens at 0.0016 = 32,000 quote.
        assertApproxEqRel(quoteBalance, 32_000e18, 1e6, "Quote raised");
        assertApproxEqRel(quoteBalance, launchBalance.mulDown(_GRADUATION_PRICE), 1e6, "Not balanced");
    }

    /// @dev A buy is the virtual-reserve constant product: out = (Rt + Vt) * in / (Rq + Vq + in), after the fee.
    function testBuyFollowsVirtualReserveCurve__Fuzz(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, 1e12, 30_000e18);
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();

        uint256 netIn = quoteIn - quoteIn.mulUp(_SWAP_FEE);
        uint256 expected = ((launchBalance + virtualLaunch) * netIn) / (quoteBalance + virtualQuote + netIn);

        assertEq(_buyExactIn(alice, quoteIn), expected, "Launch tokens out");
    }

    function testSellFollowsVirtualReserveCurve() public {
        _buyExactIn(alice, 10_000e18);

        uint256 launchIn = 1_000_000e18;
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        uint256 netIn = launchIn - launchIn.mulUp(_SWAP_FEE);
        uint256 expected = ((quoteBalance + virtualQuote) * netIn) / (launchBalance + virtualLaunch + netIn);

        assertEq(_sellExactIn(alice, launchIn), expected, "Quote out");
    }

    /// @dev The curve can only pay out quote that buyers put in.
    function testCannotSellBeforeAnyBuy() public {
        vm.expectRevert(ReClammMath.AmountOutGreaterThanBalance.selector);
        _sellExactIn(alice, 1e18);
    }

    function testRoundTripNotProfitable__Fuzz(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, 1e15, 30_000e18);
        uint256 launchOut = _buyExactIn(alice, quoteIn);
        assertLe(_sellExactIn(alice, launchOut), quoteIn, "Round trip made a profit");
    }

    function testBondingSwapsNeverDecreaseInvariant__Fuzz(uint256 launchOut, uint256 sellFraction) public {
        launchOut = bound(launchOut, 1e15, _LAUNCH_SUPPLY - _brc().getGraduationLaunchBalance() - 1);
        sellFraction = bound(sellFraction, 1e15, 1e18);

        uint256 invariantBefore = _brc().computeInvariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        _buyExactOut(alice, launchOut);
        uint256 invariantAfterBuy = _brc().computeInvariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        assertGe(invariantAfterBuy, invariantBefore, "Buy decreased the invariant");

        _sellExactIn(alice, launchOut.mulDown(sellFraction));
        uint256 invariantAfterSell = _brc().computeInvariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        assertGe(invariantAfterSell, invariantAfterBuy, "Sell decreased the invariant");
    }

    function testLiquidityLockedWhileBonding() public {
        _buyExactIn(alice, 1_000e18);

        vm.prank(lp);
        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.removeLiquidityProportional(pool, 1e18, new uint256[](2), false, "");

        vm.prank(bob);
        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.addLiquidityProportional(pool, _maxAmounts(), 1e18, false, "");
    }

    /// @dev Checked after graduation: while bonding, the pool's hook rejects every add first.
    function testUnbalancedLiquidityAndDonationDisabled() public {
        _graduate();

        vm.prank(bob);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.addLiquidityUnbalanced(pool, _initAmounts(1e18), 0, false, "");

        vm.prank(bob);
        vm.expectRevert(IVaultErrors.DoesNotSupportDonation.selector);
        router.donate(pool, _initAmounts(1e18), false, "");
    }

    /***************************************************************************
                              Completion and graduation
    ***************************************************************************/

    function testCompletingBuyFreezesThePoolForTheBlock() public {
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();

        vm.expectEmit(pool);
        emit IRukusLaunchPool.BondingCurveCompleted(graduationBalance);
        _completeCurve(alice);

        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.COMPLETED), "Phase");
        assertEq(_brc().getBondingCompletedAt(), block.timestamp, "Completed at");

        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        _buyExactIn(bob, 1e18);

        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        _sellExactIn(alice, 1e18);

        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        _brc().graduate();

        vm.prank(lp);
        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        router.removeLiquidityProportional(pool, 1e18, new uint256[](2), false, "");
    }

    /// @dev Graduation keeps the price and goes (practically) full range: tiny virtual balances, and a range from far
    /// below to far above the price.
    function testGraduationKeepsPriceAndGoesFullRange() public {
        _completeCurve(alice);
        uint256 priceBefore = _brc().computeCurrentLaunchTokenPrice();

        vm.warp(block.timestamp + 1);
        _brc().graduate();

        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Phase");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), priceBefore, 1e4, "Graduation moved the price");

        // Virtual balances under 1% of the real ones: the pool trades like a 50/50 constant-product pool.
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        assertLt(virtualLaunch, launchBalance / 100, "Virtual launch balance not tiny");
        assertLt(virtualQuote, quoteBalance / 100, "Virtual quote balance not tiny");

        // The range: buying every launch token would take the price past 1,000x; selling, below 1/1,000x. (The 1% fee
        // on buys leaves the pool a little quote-heavy, which is what bounds the top; see the README.)
        (uint256 minPrice, uint256 maxPrice) = _launchPriceRange();
        assertGt(maxPrice, priceBefore * 1_000, "Top of range too low");
        assertLt(minPrice, priceBefore / 1_000, "Bottom of range too high");

        RukusLaunchPoolDynamicData memory data = _brc().getRukusLaunchPoolDynamicData();
        assertEq(data.virtualBalances[_launchTokenIndex], virtualLaunch, "Dynamic data virtual launch");
        assertEq(data.virtualBalances[_quoteTokenIndex], virtualQuote, "Dynamic data virtual quote");
    }

    /// @dev The first swap after completion graduates the pool, then trades on the ReClamm curve it just set up.
    function testFirstSwapAfterCompletionGraduates() public {
        _completeCurve(alice);
        vm.warp(block.timestamp + 1 hours);

        uint256 quoteIn = 100e18;
        uint256 netIn = quoteIn - quoteIn.mulUp(_SWAP_FEE);

        uint256 snapshot = vm.snapshotState();
        _brc().graduate();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        uint256 expected = ReClammMath.computeOutGivenIn(
            vault.getCurrentLiveBalances(pool),
            virtualA,
            virtualB,
            _quoteTokenIndex,
            _launchTokenIndex,
            netIn
        );
        vm.revertToState(snapshot);

        assertEq(_buyExactIn(bob, quoteIn), expected, "Swap not on the graduated curve");
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Phase");
    }

    function testGraduateOnlyOnce() public {
        vm.expectRevert(IRukusLaunchPool.NotReadyToGraduate.selector);
        _brc().graduate();

        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();

        vm.expectRevert(IRukusLaunchPool.NotReadyToGraduate.selector);
        _brc().graduate();
    }

    /***************************************************************************
                              Overshoot clamp
    ***************************************************************************/

    /// @dev The completing buy may go past the graduation balance by exactly 0.1% of it, and graduates normally.
    function testCompletingBuyMayOvershootByTheLimit() public {
        uint256 maxOut = _maxLaunchOut();
        _buyExactOut(alice, maxOut);

        (uint256 launchBalance, ) = _liveBalances();
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        assertEq(launchBalance, graduationBalance - graduationBalance.mulDown(0.1e16), "Not at the limit");
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.COMPLETED), "Phase");

        uint256 priceBefore = _brc().computeCurrentLaunchTokenPrice();
        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), priceBefore, 1e4, "Graduation moved the price");

        // The top of the range at the largest overshoot: still far above the price (measured ~92,000x).
        (, uint256 maxPrice) = _launchPriceRange();
        assertGt(maxPrice, priceBefore * 50_000, "Top of range too low");

        _sellExactIn(alice, 1_000_000e18);
        _buyExactIn(bob, 1_000e18);
    }

    /// @dev One wei more than the limit reverts, and the error says how much can be bought.
    function testCompletingBuyPastTheLimitReverts() public {
        uint256 maxOut = _maxLaunchOut();

        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.GraduationBuyTooLarge.selector, maxOut));
        _buyExactOut(alice, maxOut + 1);

        // Exact in: a buy far past completion (it would take ~3x what completing needs) reverts the same way.
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.GraduationBuyTooLarge.selector, maxOut));
        _buyExactIn(alice, 100_000e18);

        // Nothing happened: still bonding, with the whole supply.
        (uint256 launchBalance, ) = _liveBalances();
        assertEq(launchBalance, _LAUNCH_SUPPLY, "Balance moved");
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");
    }

    /// @dev Any buy is accepted if and only if it leaves at least the graduation balance less 0.1%, from any point on
    /// the curve.
    function testOvershootClamp__Fuzz(uint256 alreadyBought, uint256 launchOut) public {
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        alreadyBought = bound(alreadyBought, 0, _LAUNCH_SUPPLY - graduationBalance - 1);
        if (alreadyBought < 1e15) alreadyBought = 0; // the live Vault rejects dust trades
        if (alreadyBought > 0) _buyExactOut(bob, alreadyBought);

        (uint256 launchBalance, ) = _liveBalances();
        // From 0.001 token: the live Vault rejects dust trades (its minimum trade amount, 1e6 wei).
        launchOut = bound(launchOut, 1e15, launchBalance - 1);
        uint256 minBalance = graduationBalance - graduationBalance.mulDown(0.1e16);

        if (launchBalance - launchOut < minBalance) {
            vm.expectRevert(
                abi.encodeWithSelector(IRukusLaunchPool.GraduationBuyTooLarge.selector, launchBalance - minBalance)
            );
            _buyExactOut(alice, launchOut);
        } else {
            _buyExactOut(alice, launchOut);
            bool completed = launchBalance - launchOut <= graduationBalance;
            assertEq(_brc().getBondingCompletedAt() != 0, completed, "Completion");
        }
    }

    /// @dev getMaxBuyAmount: the overshoot limit while bonding, 0 in the completing block, everything after.
    function testGetMaxBuyAmount() public {
        assertEq(_brc().getMaxBuyAmount(), _maxLaunchOut(), "While bonding");
        _buyExactOut(alice, _brc().getMaxBuyAmount()); // exactly the max goes through
        assertEq(_brc().getMaxBuyAmount(), 0, "Completing block");

        vm.warp(block.timestamp + 1);
        (uint256 launchBalance, ) = _liveBalances();
        assertEq(_brc().getMaxBuyAmount(), launchBalance, "After completion (graduates on the next buy)");
        _brc().graduate();
        assertEq(_brc().getMaxBuyAmount(), launchBalance, "Graduated");
    }

    /// @dev After graduation the clamp no longer applies: a buy can take (almost) every launch token left.
    function testNoClampAfterGraduation() public {
        _graduate();
        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(bob, (launchBalance * 99) / 100);
    }

    function testLiquidityOperationGraduatesCompletedPool() public {
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);

        _giveLaunchTokens(bob, 1_000e18);
        vm.prank(bob);
        router.addLiquidityProportional(pool, _maxAmounts(), 1e18, false, "");

        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Phase");
    }

    /***************************************************************************
                                  Graduated pool
    ***************************************************************************/

    function testProportionalLiquidityAfterGraduation() public {
        _graduate();
        uint256 price = _brc().computeCurrentLaunchTokenPrice();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        uint256 supply = IERC20(pool).totalSupply();

        // +10% supply: the virtual balances grow 10% with the real ones.
        (uint256 launchBalance, ) = _liveBalances();
        _giveLaunchTokens(bob, launchBalance / 5);
        vm.prank(bob);
        router.addLiquidityProportional(pool, _maxAmounts(), supply / 10, false, "");
        (uint256 virtualAAfterAdd, uint256 virtualBAfterAdd) = _brc().getVirtualBalances();
        assertApproxEqRel(virtualAAfterAdd, (virtualA * 11) / 10, 1e6, "Virtual A after add");
        assertApproxEqRel(virtualBAfterAdd, (virtualB * 11) / 10, 1e6, "Virtual B after add");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), price, 1e6, "Add moved the price");

        // Bob takes his share back out.
        uint256 bobBpt = IERC20(pool).balanceOf(bob);
        vm.prank(bob);
        router.removeLiquidityProportional(pool, bobBpt, new uint256[](2), false, "");
        (uint256 virtualAAfterRemove, uint256 virtualBAfterRemove) = _brc().getVirtualBalances();
        assertApproxEqRel(virtualAAfterRemove, virtualA, 1e6, "Virtual A after remove");
        assertApproxEqRel(virtualBAfterRemove, virtualB, 1e6, "Virtual B after remove");
        assertApproxEqRel(_brc().computeCurrentLaunchTokenPrice(), price, 1e6, "Remove moved the price");
    }

    /// @dev After graduation nothing moves with time: pushed far up and left alone for a year, the price, the virtual
    /// balances and the range stay exactly where they were.
    function testGraduatedPriceNeverMovesWithTime() public {
        _graduate();

        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(bob, (launchBalance * 95) / 100);
        uint256 price = _brc().computeCurrentLaunchTokenPrice();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();

        vm.warp(block.timestamp + 365 days);
        assertEq(_brc().computeCurrentLaunchTokenPrice(), price, "Price moved");

        // A trade a year later prices off the same virtual balances.
        _buyExactIn(alice, 1e18);
        (uint256 virtualAAfter, uint256 virtualBAfter) = _brc().getVirtualBalances();
        assertEq(virtualAAfter, virtualA, "Virtual A moved");
        assertEq(virtualBAfter, virtualB, "Virtual B moved");
    }

    /***************************************************************************
                              Initialization and hooks
    ***************************************************************************/

    function testConstructorRejectsRukusShareAboveOne() public {
        vm.expectRevert(IRukusLaunchPool.InvalidRukusFeeShare.selector);
        new RukusLaunchPool(
            RukusLaunchPoolParams({
                name: "Direct",
                symbol: "DIRECT",
                version: _POOL_VERSION,
                launchToken: launchToken,
                launchTokenIndex: _launchTokenIndex,
                creatorFeeRecipient: _CREATOR_FEE_RECIPIENT,
                rukusFeeRecipient: _RUKUS_FEE_RECIPIENT,
                rukusFeeShare: 100e16 + 1,
                graduatedSwapFeePercentage: _GRADUATED_SWAP_FEE,
                graduatedCreatorFeePercentage: _GRADUATED_CREATOR_FEE_PERCENTAGE,
                curve: _defaultCurve()
            }),
            vault
        );
    }

    /// @dev The factory always initializes with launch tokens only; the pool enforces it too (deployed directly here,
    /// since a factory pool is already initialized).
    function testInitializeWithQuoteReverts() public {
        RukusLaunchPool direct = _deployDirectPool();
        _registerDirectPool(address(direct), address(direct));

        uint256[] memory amounts = _initAmounts(1_000_000e18);
        amounts[_quoteTokenIndex] = 1e18;
        _giveLaunchTokens(lp, 1_000_000e18);

        vm.prank(lp);
        vm.expectRevert(IRukusLaunchPool.QuoteBalanceNotZero.selector);
        router.initialize(address(direct), sortedTokens, amounts, 0, false, "");
    }

    /// @dev The pool checks its own params, whoever deploys it (the factory checks some of them first).
    function testConstructorRejectsInvalidParams() public {
        RukusLaunchPoolParams memory params = _directPoolParams();
        params.launchTokenIndex = 2;
        vm.expectRevert(IRukusLaunchPool.InvalidLaunchToken.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.launchToken = IERC20(address(0));
        vm.expectRevert(IRukusLaunchPool.InvalidLaunchToken.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.creatorFeeRecipient = address(0);
        vm.expectRevert(IRukusLaunchPool.InvalidCreatorFeeRecipient.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.rukusFeeRecipient = address(0);
        vm.expectRevert(IRukusLaunchPool.InvalidRukusFeeRecipient.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.graduatedSwapFeePercentage = 5e16 + 1;
        vm.expectRevert(IRukusLaunchPool.InvalidGraduatedSwapFee.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.graduatedCreatorFeePercentage = 99.999e16 + 1;
        vm.expectRevert(IRukusLaunchPool.InvalidGraduatedCreatorFee.selector);
        new RukusLaunchPool(params, vault);

        params = _directPoolParams();
        params.curve.graduationPrice = params.curve.initialPrice;
        vm.expectRevert(IRukusLaunchPool.InvalidBondingPrices.selector);
        new RukusLaunchPool(params, vault);

        // The valid params deploy.
        new RukusLaunchPool(_directPoolParams(), vault);
    }

    /// @dev Before initialization there are no balances: the price, the max buy and graduation all refuse.
    function testViewsAndGraduationNeedAnInitializedPool() public {
        RukusLaunchPool direct = _deployDirectPool();
        _registerDirectPool(address(direct), address(direct));

        vm.expectRevert(IRukusLaunchPool.PoolNotInitialized.selector);
        direct.computeCurrentLaunchTokenPrice();
        vm.expectRevert(IRukusLaunchPool.PoolNotInitialized.selector);
        direct.getMaxBuyAmount();
        vm.expectRevert(IRukusLaunchPool.PoolNotInitialized.selector);
        direct.graduate();
    }

    /// @dev The swap and liquidity hooks take a pool address: only their own is accepted (even from the Vault).
    function testHooksRejectAnotherPool() public {
        uint256[] memory balances = vault.getCurrentLiveBalances(pool);
        PoolSwapParams memory request;
        request.balancesScaled18 = balances;

        vm.startPrank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.InvalidPoolArgument.selector, alice));
        _brc().onBeforeSwap(request, alice);

        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.InvalidPoolArgument.selector, alice));
        _brc().onBeforeAddLiquidity(address(0), alice, AddLiquidityKind.PROPORTIONAL, balances, 1, balances, "");

        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.InvalidPoolArgument.selector, alice));
        _brc().onBeforeRemoveLiquidity(address(0), alice, RemoveLiquidityKind.PROPORTIONAL, 1, balances, balances, "");
        vm.stopPrank();
    }

    /**
     * @dev A remove that would scale a virtual balance to 0 (the whole BPT supply) is refused: the pool could no longer
     * quote one side. It can't happen through the Vault (the burn address holds the initial BPT and the Vault keeps
     * a minimum supply), so the hook is called as the Vault would, with the whole supply.
     */
    function testRemovingTheWholeSupplyCannotZeroTheVirtualBalances() public {
        _graduate();
        uint256[] memory balances = vault.getCurrentLiveBalances(pool);
        uint256 totalSupply = vault.totalSupply(pool);

        vm.prank(address(vault));
        vm.expectRevert(IRukusLaunchPool.ZeroVirtualBalance.selector);
        _brc().onBeforeRemoveLiquidity(address(0), pool, RemoveLiquidityKind.PROPORTIONAL, totalSupply, balances, balances, "");
    }

    function testCannotInitializeTwice() public {
        vm.prank(address(vault));
        vm.expectRevert(IRukusLaunchPool.PoolAlreadyInitialized.selector);
        _brc().onBeforeInitialize(_initAmounts(1e18), "");
    }

    function testHooksOnlyCallableByVault() public {
        uint256[] memory balances = vault.getCurrentLiveBalances(pool);

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        _brc().onBeforeInitialize(balances, "");

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        _brc().onBeforeAddLiquidity(address(0), pool, AddLiquidityKind.PROPORTIONAL, balances, 1, balances, "");

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        _brc().onBeforeRemoveLiquidity(address(0), pool, RemoveLiquidityKind.PROPORTIONAL, 1, balances, balances, "");

        PoolSwapParams memory request;
        request.balancesScaled18 = balances;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        _brc().onSwap(request);
    }

    function testOnRegisterOnlyForItself() public view {
        TokenConfig[] memory config = new TokenConfig[](2);
        config[0].token = sortedTokens[0];
        config[1].token = sortedTokens[1];
        LiquidityManagement memory lm;
        lm.disableUnbalancedLiquidity = true;

        assertTrue(_brc().onRegister(address(0), pool, config, lm), "Should register itself");
        assertFalse(_brc().onRegister(address(0), alice, config, lm), "Registered another pool");

        TokenConfig[] memory swapped = new TokenConfig[](2);
        swapped[0].token = sortedTokens[1];
        swapped[1].token = sortedTokens[0];
        assertFalse(_brc().onRegister(address(0), pool, swapped, lm), "Wrong launch token index");

        assertFalse(_brc().onRegister(address(0), pool, new TokenConfig[](3), lm), "Wrong token count");

        lm.enableDonation = true;
        assertFalse(_brc().onRegister(address(0), pool, config, lm), "Donations enabled");
        lm.enableDonation = false;
        lm.disableUnbalancedLiquidity = false;
        assertFalse(_brc().onRegister(address(0), pool, config, lm), "Unbalanced liquidity enabled");
    }

    /**
     * @dev Through the Vault: another pool can't register this pool as its hook. The initialize hooks get no pool
     * address to check (the Vault calls them only for the pool they're registered to), so this is what keeps another
     * pool's initialization, swaps and liquidity from ever reaching this pool's hooks.
     */
    function testAnotherPoolCannotUseThisPoolAsItsHook() public {
        RukusLaunchPool other = _deployDirectPool();
        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.HookRegistrationFailed.selector, pool, address(other), address(this))
        );
        _registerDirectPool(address(other), pool);

        // Registering with its own hook works, and initializing it leaves this pool untouched.
        _registerDirectPool(address(other), address(other));
        uint256 creatorFeeBefore = feeController.getPoolCreatorSwapFeePercentage(pool);
        (uint256 virtualABefore, uint256 virtualBBefore) = _brc().getVirtualBalances();
        _giveLaunchTokens(lp, 1_000_000e18);
        vm.prank(lp);
        router.initialize(address(other), sortedTokens, _initAmounts(1_000_000e18), 0, false, "");

        assertTrue(vault.isPoolInitialized(address(other)), "Other pool not initialized");
        assertEq(feeController.getPoolCreatorSwapFeePercentage(pool), creatorFeeBefore, "Creator fee changed");
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        assertEq(virtualA, virtualABefore, "Virtual A changed");
        assertEq(virtualB, virtualBBefore, "Virtual B changed");
    }

    /***************************************************************************
                                     Getters
    ***************************************************************************/

    function testBaseFunctions() public {
        assertEq(_brc().getMinimumSwapFeePercentage(), 0.001e16, "Min fee");
        assertEq(_brc().getMaximumSwapFeePercentage(), 5e16, "Max fee");
        assertEq(_brc().getMinimumInvariantRatio(), 0, "Min invariant ratio");
        assertEq(_brc().getMaximumInvariantRatio(), 0, "Max invariant ratio");

        vm.expectRevert(IRukusLaunchPool.RukusLaunchPoolBptRateUnsupported.selector);
        _brc().getRate();

        vm.expectRevert(IRukusLaunchPool.NotImplemented.selector);
        _brc().computeBalance(new uint256[](2), 0, 1e18);
    }

    function testImmutableData() public view {
        RukusLaunchPoolImmutableData memory data = _brc().getRukusLaunchPoolImmutableData();
        assertEq(address(data.tokens[0]), address(sortedTokens[0]), "Token 0");
        assertEq(address(data.tokens[1]), address(sortedTokens[1]), "Token 1");
        assertEq(address(data.launchToken), address(launchToken), "Launch token");
        assertEq(data.launchTokenIndex, _launchTokenIndex, "Launch token index");
        assertEq(data.initialPrice, _INITIAL_PRICE, "Initial price");
        assertEq(data.graduationPrice, _GRADUATION_PRICE, "Graduation price");
        assertEq(data.graduatedPriceRatio, 1e12 * 1e18, "Graduated price ratio");
        assertEq(data.graduatedPriceRatio, _brc().GRADUATED_PRICE_RATIO(), "Constant");

        (IERC20 token, uint256 index) = _brc().getLaunchToken();
        assertEq(address(token), address(launchToken), "getLaunchToken token");
        assertEq(index, _launchTokenIndex, "getLaunchToken index");
    }

    function testDynamicData() public {
        _buyExactIn(alice, 1_000e18);
        RukusLaunchPoolDynamicData memory data = _brc().getRukusLaunchPoolDynamicData();
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();

        assertTrue(data.isPoolInitialized, "Initialized");
        assertEq(uint256(data.phase), uint256(BondingPhase.BONDING), "Phase");
        assertEq(data.bondingCompletedAt, 0, "Completed at");
        assertEq(data.graduationLaunchBalance, _LAUNCH_SUPPLY / 5, "Graduation balance");
        assertEq(data.virtualBalances[0], virtualA, "Virtual A");
        assertEq(data.virtualBalances[1], virtualB, "Virtual B");
        assertEq(data.staticSwapFeePercentage, _SWAP_FEE, "Swap fee");
        assertEq(data.totalSupply, IERC20(pool).totalSupply(), "Total supply");
        assertEq(data.balancesLiveScaled18[_quoteTokenIndex], vault.getCurrentLiveBalances(pool)[_quoteTokenIndex], "Balances");
    }

    /***************************************************************************
                                     Helpers
    ***************************************************************************/

    function _graduate() internal {
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
    }

    /// @dev The most launch tokens a buy can take now, while bonding: down to the graduation balance less 0.1%.
    function _maxLaunchOut() internal view returns (uint256) {
        (uint256 launchBalance, ) = _liveBalances();
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        return launchBalance - (graduationBalance - graduationBalance.mulDown(0.1e16));
    }

    /// @dev The launch token's min and max price over the whole range: Vq^2 / L and L / Vl^2, with L the invariant.
    function _launchPriceRange() internal view returns (uint256 minPrice, uint256 maxPrice) {
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        uint256 invariant = (launchBalance + virtualLaunch).mulDown(quoteBalance + virtualQuote);
        minPrice = virtualQuote.mulDown(virtualQuote).divDown(invariant);
        maxPrice = invariant.divDown(virtualLaunch.mulDown(virtualLaunch));
    }

    /// @dev A RukusLaunchPool deployed directly (not through the factory), so not yet registered.
    function _deployDirectPool() internal returns (RukusLaunchPool) {
        return new RukusLaunchPool(_directPoolParams(), vault);
    }

    /// @dev Valid params for a pool deployed directly.
    function _directPoolParams() internal view returns (RukusLaunchPoolParams memory) {
        return
            RukusLaunchPoolParams({
                name: "Direct",
                symbol: "DIRECT",
                version: _POOL_VERSION,
                launchToken: launchToken,
                launchTokenIndex: _launchTokenIndex,
                creatorFeeRecipient: _CREATOR_FEE_RECIPIENT,
                rukusFeeRecipient: _RUKUS_FEE_RECIPIENT,
                rukusFeeShare: 50e16,
                graduatedSwapFeePercentage: _GRADUATED_SWAP_FEE,
                graduatedCreatorFeePercentage: _GRADUATED_CREATOR_FEE_PERCENTAGE,
                curve: _defaultCurve()
            });
    }

    /// @dev Registers `newPool` against launch token and WETH with `hooks` as its hooks contract, with the roles the
    /// factory gives (the pool is its own pool creator and swap fee manager, so its `onAfterInitialize` can run).
    function _registerDirectPool(address newPool, address hooks) internal {
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = newPool;
        roleAccounts.swapFeeManager = newPool;
        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = true;
        // Built by hand (vault.buildTokenConfig is a local-mock helper), so this also runs on the live Vault.
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        tokenConfig[0].token = sortedTokens[0];
        tokenConfig[1].token = sortedTokens[1];
        vault.registerPool(newPool, tokenConfig, _SWAP_FEE, 0, false, roleAccounts, hooks, liquidityManagement);
    }

    function _maxAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = MAX_UINT128;
        amounts[1] = MAX_UINT128;
    }
}

/// @dev The same tests with the launch token second in sorted order (so the curve's "A" and "B" are swapped).
contract RukusLaunchPoolLaunchTokenBTest is RukusLaunchPoolTest {
    constructor() {
        _launchTokenIndex = 1;
    }
}
