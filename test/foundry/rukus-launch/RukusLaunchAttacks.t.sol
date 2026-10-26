// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { IAuthentication } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IVaultAdmin } from "@bush.fi/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammMath } from "../../../contracts/reclamm/lib/ReClammMath.sol";
import { IRukusLaunchPool, BondingPhase } from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";

import { BaseRukusLaunchTest } from "../utils/BaseRukusLaunchTest.sol";

/**
 * @notice Attack and trading scenarios, beyond the unit tests in RukusLaunchPool.t.sol.
 *
 * Every test account starts with 1e9 of both tokens, so "launch tokens" here are not only those bought from the pool.
 * Tests that care about who bought what track it explicitly.
 */
contract RukusLaunchAttacksTest is BaseRukusLaunchTest {
    using FixedPoint for uint256;

    function setUp() public virtual override {
        super.setUp();
        // `hacker` isn't in BaseVaultTest's approved users.
        vm.startPrank(hacker);
        approveForSender();
        IERC20(pool).approve(address(router), type(uint256).max);
        vm.stopPrank();
        // So that a withdrawal attempt by the factory fails on its (zero) BPT balance, not on allowance.
        vm.prank(address(factory));
        IERC20(pool).approve(address(router), type(uint256).max);
    }

    /***************************************************************************
                    1. Late LP after graduation: fair share, not the pool
    ***************************************************************************/

    /// @dev Bob adds after graduation and redeems straight away: he gets back what he put in (less rounding), and the
    /// pool keeps everything it had before.
    function testLateLpRedeemsOnlyHisShare__Fuzz(uint256 bptFraction) public {
        bptFraction = bound(bptFraction, 1e12, 10e18); // 0.0001% to 10x the existing supply
        _graduate();

        (uint256 launchBefore, uint256 quoteBefore) = _liveBalances();
        uint256 bptOut = IERC20(pool).totalSupply().mulDown(bptFraction);
        _giveLaunchTokens(bob, launchBefore.mulUp(bptFraction) + 1e18);

        vm.prank(bob);
        uint256[] memory amountsIn = router.addLiquidityProportional(pool, _maxAmounts(), bptOut, false, "");
        assertEq(IERC20(pool).balanceOf(bob), bptOut, "BPT minted");

        vm.prank(bob);
        uint256[] memory amountsOut = router.removeLiquidityProportional(pool, bptOut, new uint256[](2), false, "");

        for (uint256 i = 0; i < 2; ++i) {
            assertLe(amountsOut[i], amountsIn[i], "Bob got back more than he put in");
            assertApproxEqAbs(amountsOut[i], amountsIn[i], 10, "Bob lost more than rounding");
        }

        (uint256 launchAfter, uint256 quoteAfter) = _liveBalances();
        assertGe(launchAfter, launchBefore, "Pool lost launch tokens");
        assertGe(quoteAfter, quoteBefore, "Pool lost quote");
    }

    /// @dev Trading happens while Bob is in the pool: on exit he gets exactly his BPT's share of the balances then,
    /// whatever the price did. The creator's BPT is still worth the rest.
    function testLateLpShareIsProportionalAfterTrading__Fuzz(uint256 bptFraction, uint256 tradeSeed) public {
        bptFraction = bound(bptFraction, 1e15, 2e18);
        _graduate();

        uint256 bobBpt = IERC20(pool).totalSupply().mulDown(bptFraction);
        (uint256 launchBalance, ) = _liveBalances();
        _giveLaunchTokens(bob, launchBalance.mulUp(bptFraction) + 1e18);
        vm.prank(bob);
        router.addLiquidityProportional(pool, _maxAmounts(), bobBpt, false, "");

        // Some trading over a few days, both directions.
        for (uint256 i = 0; i < 6; ++i) {
            uint256 r = uint256(keccak256(abi.encode(tradeSeed, i)));
            vm.warp(block.timestamp + 6 hours);
            if (r % 2 == 0) {
                _buyExactIn(alice, 100e18 + (r % 3_000e18));
            } else {
                _sellExactIn(alice, 100_000e18 + (r % 3_000_000e18));
            }
        }

        uint256[] memory balances = vault.getCurrentLiveBalances(pool);
        uint256 supply = IERC20(pool).totalSupply();

        vm.prank(bob);
        uint256[] memory amountsOut = router.removeLiquidityProportional(pool, bobBpt, new uint256[](2), false, "");
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(amountsOut[i], (balances[i] * bobBpt) / supply, "Not Bob's proportional share");
        }
    }

    function testLateLpCannotRedeemMoreBptThanHeHolds() public {
        _graduate();
        uint256 bptOut = IERC20(pool).totalSupply() / 10;
        (uint256 launchBalance, ) = _liveBalances();
        _giveLaunchTokens(bob, launchBalance / 5);
        vm.prank(bob);
        router.addLiquidityProportional(pool, _maxAmounts(), bptOut, false, "");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, bptOut, bptOut + 1)
        );
        router.removeLiquidityProportional(pool, bptOut + 1, new uint256[](2), false, "");
    }

    /// @dev JIT liquidity: add a lot, push the price, take the liquidity back out, trade back. It cannot pay: Bob's
    /// own swap moves the price against his own share as much as the rest of the pool's.
    function testJitAddSwapRemoveNotProfitable__Fuzz(uint256 bptFraction, uint256 quoteIn) public {
        bptFraction = bound(bptFraction, 1e17, 20e18);
        quoteIn = bound(quoteIn, 100e18, 20_000e18);
        _graduate();
        (uint256 launchBalance, ) = _liveBalances();
        _giveLaunchTokens(bob, launchBalance.mulUp(bptFraction) + 1e18);

        uint256 launchStart = launchToken.balanceOf(bob);
        uint256 quoteStart = quoteToken.balanceOf(bob);
        uint256 price = _brc().computeCurrentLaunchTokenPrice();

        uint256 bpt = IERC20(pool).totalSupply().mulDown(bptFraction);
        vm.startPrank(bob);
        router.addLiquidityProportional(pool, _maxAmounts(), bpt, false, "");
        uint256 launchOut = router.swapSingleTokenExactIn(pool, quoteToken, launchToken, quoteIn, 0, MAX_UINT256, false, "");
        router.removeLiquidityProportional(pool, bpt, new uint256[](2), false, "");
        router.swapSingleTokenExactIn(pool, launchToken, quoteToken, launchOut, 0, MAX_UINT256, false, "");
        vm.stopPrank();

        _assertNoProfit(bob, launchStart, quoteStart, price);
    }

    /**
     * @dev Fixed (was: the creator's BPT owned the whole raise after graduation). The factory mints the initial BPT to
     * a burn address, so nobody can withdraw the raise: not the creator, not the factory, not anyone else.
     */
    function testInitialBptIsBurnedSoNobodyCanTakeTheRaise() public {
        uint256 supply = IERC20(pool).totalSupply();
        assertEq(IERC20(pool).balanceOf(_BURN), supply - POOL_MINIMUM_TOTAL_SUPPLY, "BPT not burned");
        assertEq(IERC20(pool).balanceOf(lp), 0, "LP holds BPT");
        assertEq(IERC20(pool).balanceOf(alice), 0, "Pool creator holds BPT");
        assertEq(IERC20(pool).balanceOf(address(factory)), 0, "Factory holds BPT");
        assertEq(IERC20(pool).balanceOf(address(this)), 0, "Launcher holds BPT");

        _graduate();
        (, uint256 quoteRaised) = _liveBalances();

        address[4] memory accounts = [address(lp), alice, hacker, address(factory)];
        for (uint256 i = 0; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, accounts[i], 0, 1e18)
            );
            router.removeLiquidityProportional(pool, 1e18, new uint256[](2), false, "");
        }

        (, uint256 quoteAfter) = _liveBalances();
        assertEq(quoteAfter, quoteRaised, "Raise moved");
    }

    /***************************************************************************
                    2. Liquidity before graduation (locked, but see recovery mode)
    ***************************************************************************/

    /// @dev No kind of add or remove works while bonding, before or after the first buy, for anyone.
    function testEveryLiquidityPathLockedWhileBonding() public {
        _assertLiquidityLocked(lp);

        _buyExactIn(alice, 5_000e18);
        _assertLiquidityLocked(lp);
        _assertLiquidityLocked(alice);
        _assertLiquidityLocked(bob);
    }

    /// @dev Someone who isn't an LP can't get BPT during bonding either: the hook rejects the add before any BPT exists.
    function testOutsiderCannotMintBptWhileBonding() public {
        _buyExactIn(alice, 5_000e18);

        vm.prank(bob);
        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.addLiquidityProportional(pool, _maxAmounts(), 1e18, false, "");
        assertEq(IERC20(pool).balanceOf(bob), 0, "Bob got BPT");
    }

    /**
     * @dev Fixed (was: recovery-mode exits skip the bonding lock, so the creator's BPT could take the raise mid-curve
     * once governance paused the Vault). Anyone can still turn recovery mode on after a pause, but there's no BPT to
     * exit with: it was burned. Buyers can still sell back.
     */
    function testRecoveryModeCannotTakeTheRaiseMidCurve() public {
        uint256 aliceLaunch = _buyExactIn(alice, 10_000e18);
        (, uint256 quoteRaised) = _liveBalances();

        _skipOnFork("pauses the Vault, which needs the local mock");
        vault.manualPauseVault();
        vm.prank(hacker);
        vault.enableRecoveryMode(pool);
        vault.manualUnpauseVault();

        address[3] memory accounts = [address(lp), alice, hacker];
        for (uint256 i = 0; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, accounts[i], 0, 1e18)
            );
            router.removeLiquidityRecovery(pool, 1e18, new uint256[](2));
        }

        (, uint256 quoteAfter) = _liveBalances();
        assertEq(quoteAfter, quoteRaised, "Raise moved");

        // Alice can still sell everything back (in recovery mode, swaps keep working).
        uint256 quoteOut = _sellExactIn(alice, aliceLaunch);
        assertGt(quoteOut, 9_700e18, "Alice could not sell back");
    }

    /// @dev The same through a pool pause (only possible inside the factory's pause window, by governance).
    function testRecoveryModeAfterPoolPauseCannotTakeTheRaise() public {
        _buyExactIn(alice, 10_000e18);

        _skipOnFork("pauses the pool, which needs the local mock");
        vault.manualPausePool(pool);
        vm.prank(hacker);
        vault.enableRecoveryMode(pool);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, lp, 0, 1e18));
        router.removeLiquidityRecovery(pool, 1e18, new uint256[](2));
    }

    /// @dev Without a pause, recovery mode needs governance: a random account can't turn it on.
    function testRecoveryModeNotPermissionlessWhenUnpaused() public {
        vm.prank(hacker);
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        vault.enableRecoveryMode(pool);
    }

    /***************************************************************************
                    3. Everyone sells back before the curve completes
    ***************************************************************************/

    /// @dev Several buyers, then everyone sells everything back in a different order: every sell works, every token and
    /// every quote is accounted for (pool + fees taken out), the pool is back on its curve, and the group got out less
    /// than it put in. The curve then still completes and graduates normally.
    function testEveryoneSellsBackBeforeBonding() public {
        address[4] memory buyers = [address(alice), bob, lp, hacker];
        uint256[4] memory spends = [uint256(3_000e18), 12_000e18, 500e18, 9_000e18];
        uint256[4] memory bought;
        uint256 totalQuoteIn;

        for (uint256 i = 0; i < 4; ++i) {
            bought[i] = _buyExactIn(buyers[i], spends[i]);
            totalQuoteIn += spends[i];
        }
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.BONDING), "Completed by accident");

        uint256 totalQuoteOut;
        uint256[4] memory order = [uint256(2), 0, 3, 1];
        for (uint256 j = 0; j < 4; ++j) {
            uint256 i = order[j];
            uint256 quoteOut = _sellExactIn(buyers[i], bought[i]);
            totalQuoteOut += quoteOut;
            // Each seller loses at most ~2 fees on the round trip... or gains if they bought early and sold after
            // later buyers. Only the group total is bounded.
        }

        _assertFeesLeftThePool(totalQuoteIn, totalQuoteOut);

        // The fees left the pool (99.999% creator share), so it is back on its curve: at its initial price but for the
        // launch tokens the sell fees took (bought, and still backed by the quote left in the pool).
        (uint256 launchBalance, ) = _liveBalances();
        assertLt(launchBalance, _LAUNCH_SUPPLY, "Sell fees took no launch tokens");
        assertGt(launchBalance, (_LAUNCH_SUPPLY * 98) / 100, "Sell fees took more than ~1% of what was bought");

        // The curve still works: complete and graduate.
        _completeCurve(bob);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Did not graduate");
    }

    /// forge-config: default.fuzz.runs = 512
    /// @dev Random buys and sells by three traders, then everyone exits. Whatever the order, every exit succeeds (the
    /// pool always holds enough quote to buy back every token it sold) and the group never extracts quote.
    function testRandomTradingThenFullExit__Fuzz(uint256 seed) public {
        address[3] memory traders = [address(alice), bob, hacker];
        uint256[3] memory held;
        uint256 totalQuoteIn;
        uint256 totalQuoteOut;

        for (uint256 step = 0; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 t = r % 3;
            if ((r >> 8) % 3 != 0 || held[t] == 0) {
                // Buy, but don't complete the curve.
                (uint256 launchNow, ) = _liveBalances();
                uint256 room = launchNow - _brc().getGraduationLaunchBalance();
                if (room < 2e18) continue;
                uint256 launchOut = 1e18 + ((r >> 16) % (room / 4));
                totalQuoteIn += _buyExactOut(traders[t], launchOut);
                held[t] += launchOut;
            } else {
                uint256 launchIn = 1 + ((r >> 16) % held[t]);
                totalQuoteOut += _sellExactIn(traders[t], launchIn);
                held[t] -= launchIn;
            }
        }

        for (uint256 t = 0; t < 3; ++t) {
            if (held[t] > 0) totalQuoteOut += _sellExactIn(traders[t], held[t]);
        }

        _assertFeesLeftThePool(totalQuoteIn, totalQuoteOut);
        assertLe(totalQuoteOut, totalQuoteIn, "Traders extracted quote");
    }

    /// @dev Rounding with no fee: tiny round trips can't print money either.
    function testDustRoundTripNotProfitableWithoutFee__Fuzz(uint256 quoteIn, uint256 warmup) public {
        _skipOnFork("forces a 0% swap fee (the live Vault enforces the minimum)");
        setSwapFeePercentage(0);
        warmup = bound(warmup, 0, 20_000e18);
        if (warmup > 0) _buyExactIn(alice, warmup);

        quoteIn = bound(quoteIn, 1, 1e12);
        uint256 launchOut;
        try this.externalBuy(bob, quoteIn) returns (uint256 out) {
            launchOut = out;
        } catch {
            return; // Too small to trade at all.
        }
        if (launchOut == 0) return;
        try this.externalSell(bob, launchOut) returns (uint256 quoteOut) {
            assertLe(quoteOut, quoteIn, "Dust round trip made a profit");
        } catch {}
    }

    /***************************************************************************
                                Other attack vectors
    ***************************************************************************/

    /**
     * @dev Fixed (was: launch tokens from outside the pool could be dumped into the curve and take buyers' quote). The
     * factory mints the whole supply and puts all of it in the pool, so none exist anywhere else: nobody can sell a
     * token they didn't buy from the curve.
     */
    function testNoLaunchTokensExistOutsideThePool() public view {
        (uint256 launchBalance, ) = _liveBalances();
        assertEq(launchToken.totalSupply(), _LAUNCH_SUPPLY, "Supply");
        assertEq(launchBalance, _LAUNCH_SUPPLY, "Not all in the pool");
        assertEq(launchToken.balanceOf(address(vault)), _LAUNCH_SUPPLY, "Vault does not hold the supply");
        assertEq(launchToken.balanceOf(address(factory)), 0, "Factory kept tokens");
        assertEq(launchToken.balanceOf(address(this)), 0, "Launcher kept tokens");
    }

    /// @dev With no outside supply, a sell can never take more quote than buyers paid in: every launch token held was
    /// bought, so selling it all back just walks the curve back to its start.
    function testSellingEverythingBoughtNeverExceedsTheRaise__Fuzz(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, 1e18, 31_000e18);
        uint256 bought = _buyExactIn(alice, quoteIn);
        uint256 quoteOut = _sellExactIn(alice, bought);
        assertLt(quoteOut, quoteIn, "Sold back for more than the raise");
    }

    /**
     * @dev Flash-loan style: buy out the curve (anywhere up to the 0.1% overshoot limit), then dump into the graduated
     * pool the next second. The freeze makes this a loss: the attacker bought on the curve and sells into a pool that
     * starts at that price and only goes down as he sells.
     */
    function testBuyoutThenDumpAfterGraduationLoses__Fuzz(uint256 overshoot) public {
        (uint256 launchBalance, ) = _liveBalances();
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        overshoot = bound(overshoot, 0, graduationBalance.mulDown(0.1e16));

        uint256 launchStart = launchToken.balanceOf(hacker);
        uint256 quoteStart = quoteToken.balanceOf(hacker);

        uint256 launchOut = launchBalance - graduationBalance + overshoot;
        _buyExactOut(hacker, launchOut);
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.COMPLETED), "Not completed");

        vm.warp(block.timestamp + 1);
        _sellAsMuchAsPossible(hacker, launchOut);

        assertLt(quoteToken.balanceOf(hacker), quoteStart, "Buyout and dump returned more quote than it cost");
        assertGe(launchToken.balanceOf(hacker), launchStart, "Sold more than bought");
    }

    /// @dev On L2s several blocks share a timestamp. The freeze is by timestamp, so a new block in the same second is
    /// still frozen (stricter than "the rest of the block").
    function testFreezeHoldsAcrossBlocksWithTheSameTimestamp() public {
        _completeCurve(alice);
        vm.roll(block.number + 5);

        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        _sellExactIn(alice, 1e18);
        vm.expectRevert(IRukusLaunchPool.GraduationPending.selector);
        _brc().graduate();
    }

    /// @dev A whale can't buy past the overshoot limit on the curve (it would lower the graduated range's top). The
    /// most it can take still graduates cleanly (keeping the price), and the pool keeps trading both ways.
    function testWhaleCappedAtTheOvershootLimitThenGraduates() public {
        (uint256 launchBalance, ) = _liveBalances();
        uint256 graduationBalance = _brc().getGraduationLaunchBalance();
        uint256 maxOut = launchBalance - (graduationBalance - graduationBalance.mulDown(0.1e16));

        vm.expectRevert(abi.encodeWithSelector(IRukusLaunchPool.GraduationBuyTooLarge.selector, maxOut));
        _buyExactOut(hacker, launchBalance - 1e18);

        _buyExactOut(hacker, maxOut);

        vm.warp(block.timestamp + 1);
        _brc().graduate();
        assertEq(uint256(_brc().getBondingPhase()), uint256(BondingPhase.GRADUATED), "Did not graduate");

        _sellExactIn(hacker, 1_000_000e18);
        _buyExactIn(alice, 1e18);
        vm.warp(block.timestamp + 1 days);
        _sellExactIn(hacker, 1_000_000e18);
    }

    /// @dev The graduated pool can't be round-tripped for profit, including by the first trader after graduation.
    function testGraduatedRoundTripNotProfitable__Fuzz(uint256 quoteIn, uint256 delay) public {
        quoteIn = bound(quoteIn, 1e15, 15_000e18);
        delay = bound(delay, 1, 10 days);
        _completeCurve(alice);
        vm.warp(block.timestamp + delay);

        uint256 launchOut = _buyExactIn(bob, quoteIn);
        assertLe(_sellExactIn(bob, launchOut), quoteIn, "Graduated round trip made a profit");
    }

    /**
     * @dev The pool is its own swap fee manager: nobody can change the fee rate (not the creator, not the launchpad, not
     * governance), while bonding or after graduation. The pool itself only sets it once, at graduation.
     */
    function testNobodyCanChangeTheFeeRate() public {
        // Governance included (needs the local authorizer to grant the role; on the fork, admin has no role anyway).
        if (onFork == false) {
            authorizer.grantRole(vault.getActionId(IVaultAdmin.setStaticSwapFeePercentage.selector), admin);
        }
        address[5] memory accounts = [address(admin), lp, alice, address(factory), _CREATOR_FEE_RECIPIENT];

        for (uint256 phase = 0; phase < 2; ++phase) {
            for (uint256 i = 0; i < accounts.length; ++i) {
                vm.prank(accounts[i]);
                vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
                vault.setStaticSwapFeePercentage(pool, 5e16);
            }
            if (phase == 0) {
                _completeCurve(alice);
                vm.warp(block.timestamp + 1);
                _brc().graduate();
            }
        }
        (uint256 graduatedSwapFee, ) = _brc().getGraduatedFees();
        assertEq(vault.getStaticSwapFeePercentage(pool), graduatedSwapFee, "Fee changed");
    }

    /// @dev Push the graduated pool hard and trade straight back (within the hour): two fees and the price impact.
    function testPushAndQuicklyReverseNotProfitable__Fuzz(uint256 pushFraction, uint256 holdTime) public {
        pushFraction = bound(pushFraction, 10e16, 95e16);
        holdTime = bound(holdTime, 1, 1 hours);
        _graduate();

        uint256 launchStart = launchToken.balanceOf(hacker);
        uint256 quoteStart = quoteToken.balanceOf(hacker);

        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(hacker, launchBalance.mulDown(pushFraction));
        vm.warp(block.timestamp + holdTime);
        _sellAsMuchAsPossible(hacker, launchToken.balanceOf(hacker) - launchStart);

        assertLt(quoteToken.balanceOf(hacker), quoteStart, "Quick push and reverse made a profit");
    }

    /**
     * @dev Fixed (was: push-and-hold, where the ReClamm range drifted after a pushed price with no trades, and the
     * pusher sold back higher). The graduated pool never moves with time, so holding a push for any length of time is
     * the same as reversing it at once: a loss of two fees and the price impact.
     */
    function testPushAndHoldNotProfitable__Fuzz(uint256 pushFraction, uint256 holdTime) public {
        pushFraction = bound(pushFraction, 10e16, 99e16);
        holdTime = bound(holdTime, 1, 365 days);
        _graduate();

        uint256 quoteStart = quoteToken.balanceOf(hacker);
        uint256 launchStart = launchToken.balanceOf(hacker);
        (uint256 launchBalance, ) = _liveBalances();
        _buyExactOut(hacker, launchBalance.mulDown(pushFraction));

        vm.warp(block.timestamp + holdTime);
        _sellAsMuchAsPossible(hacker, launchToken.balanceOf(hacker) - launchStart);
        assertLt(quoteToken.balanceOf(hacker), quoteStart, "Push and hold made a profit");
    }

    /***************************************************************************
                                     Helpers
    ***************************************************************************/

    function externalBuy(address buyer, uint256 quoteIn) external returns (uint256) {
        return _buyExactIn(buyer, quoteIn);
    }

    function externalSell(address seller, uint256 launchIn) external returns (uint256) {
        return _sellExactIn(seller, launchIn);
    }

    /// @dev Sells `amount`, or the largest amount the pool can still pay out for (halving until a sell goes through).
    function _sellAsMuchAsPossible(address seller, uint256 amount) internal returns (uint256 sold) {
        for (uint256 i = 0; i < 60 && amount > 1e12; ++i) {
            try this.externalSell(seller, amount) {
                sold += amount;
                return sold;
            } catch {
                amount /= 2;
            }
        }
    }

    /**
     * @dev With the fees leaving the pool, every token is accounted for: the pool's balances plus the fees the Vault
     * took out of them (protocol and creator shares) are exactly the whole supply and the traders' net quote, and the
     * pool sits on its bonding curve (the invariant is the initial one, give or take rounding in the pool's favor).
     */
    function _assertFeesLeftThePool(uint256 totalQuoteIn, uint256 totalQuoteOut) internal view {
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        uint256 launchFees = vault.getAggregateSwapFeeAmount(pool, launchToken);
        uint256 quoteFees = vault.getAggregateSwapFeeAmount(pool, quoteToken);

        assertEq(launchBalance + launchFees, _LAUNCH_SUPPLY, "Launch token accounting");
        assertEq(quoteBalance + quoteFees, totalQuoteIn - totalQuoteOut, "Quote accounting");

        (uint256 virtualLaunch, uint256 virtualQuote) = _virtualLaunchAndQuote();
        uint256 initialInvariant = (_LAUNCH_SUPPLY + virtualLaunch) * virtualQuote;
        uint256 invariant = (launchBalance + virtualLaunch) * (quoteBalance + virtualQuote);
        assertGe(invariant, initialInvariant, "Below the curve");
        assertApproxEqRel(invariant, initialInvariant, 1e12, "Off the curve: fees stayed in the pool");
    }

    function _assertLiquidityLocked(address holder) internal {
        vm.startPrank(holder);
        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.removeLiquidityProportional(pool, 1e18, new uint256[](2), false, "");

        // Single-token paths: the pool's hook rejects them while bonding (the Vault would anyway, after graduation).
        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.removeLiquiditySingleTokenExactIn(pool, 1e18, quoteToken, 0, false, "");

        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.addLiquiditySingleTokenExactOut(pool, quoteToken, MAX_UINT128, 1e18, false, "");

        vm.expectRevert(IRukusLaunchPool.LiquidityLockedUntilGraduation.selector);
        router.addLiquidityProportional(pool, _maxAmounts(), 1e18, false, "");
        vm.stopPrank();
    }

    /// @dev Values the account's change in both tokens at `price`; it must not be up.
    function _assertNoProfit(address account, uint256 launchStart, uint256 quoteStart, uint256 price) internal view {
        int256 launchDelta = int256(launchToken.balanceOf(account)) - int256(launchStart);
        int256 quoteDelta = int256(quoteToken.balanceOf(account)) - int256(quoteStart);
        int256 value = quoteDelta + (launchDelta * int256(price)) / 1e18;
        assertLe(value, 0, "Attack made a profit");
    }

    function _graduate() internal {
        _completeCurve(alice);
        vm.warp(block.timestamp + 1);
        _brc().graduate();
    }

    function _maxAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = MAX_UINT128;
        amounts[1] = MAX_UINT128;
    }
}
