// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@bush.fi/v3-interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseVaultTest } from "@bush.fi/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { PoolHandler } from "./PoolHandler.sol";

/**
 * @notice Property tests every pool should pass, whatever its curve. Inherit it instead of `BaseVaultTest` and
 * override `createPoolFactory`, `createPool` and `initPool` as usual; the tests below then run against your pool.
 *
 * They check properties, not numbers, so they work before you've worked out a single expected value:
 *   - fuzz tests (random arguments, `[fuzz] runs` times each, failures shrunk to a minimal counterexample):
 *       the invariant rounds as asked and scales linearly with the balances; a swap never decreases the
 *       invariant; swapping there and back never makes a profit; computeBalance reaches its target; and through
 *       the Vault, swaps and single-token adds/removes never dilute the LPs;
 *   - an invariant test: `PoolHandler` performs random sequences of swaps, adds and removes, so the pool drifts
 *     into states no fixed setup starts from, and every step must keep the invariant per BPT from going down.
 * They catch rounding and consistency bugs, not a formula that's consistently wrong: add tests with hand-worked
 * numbers for that.
 *
 * Tune the ranges below to the pool's real limits, as wide as it really supports, by assigning them in your test's
 * constructor (not `setUp`: the invariant-test handler is built from them during `setUp`).
 *
 *   forge test --match-path 'test/foundry/<family>/*' --fuzz-runs 256    # quick iteration
 *   forge test --match-test <name> --fuzz-seed <seed> -vvv               # replay a failure
 */
abstract contract PoolPropertiesTest is BaseVaultTest {
    using FixedPoint for uint256;

    uint256 internal constant MIN_SWAP_FEE_FLOOR = 1e12; // 0.0001%

    /// @dev The pool's tokens in Vault (address-sorted) order, filled in `setUp`.
    IERC20[] internal poolTokens;

    // Fuzz ranges. Keep them as wide as the pool really supports (edges are where bugs are) and narrow them only
    // where it legitimately refuses: e.g. weighted pools cap a swap at 30% of the balance.
    uint256 internal minBalance = 1e18; // pool balances (scaled18) for the maths-only tests
    uint256 internal maxBalance = 1e27;
    uint256 internal minAmount = 1e12; // smallest swap / BPT amount (the Vault rejects tiny trades anyway)
    uint256 internal maxSwapRatio = 30e16; // largest swap, as a fraction of the balance it's taken from
    uint256 internal maxLiquidityRatio = 30e16; // largest single-token add/remove, as a fraction of supply
    // How far `computeInvariant(2 * balances)` may be from `2 * computeInvariant(balances)` (1e8 = 1e-10 relative).
    // Exact formulas stay within a few wei; iterative ones (Newton's method, like StableMath) need some slack.
    uint256 internal invariantRelTolerance = 1e8;
    // How far the invariant (per BPT) may drop in an operation that must never lower it (1e18 = 100%). Zero for pools
    // whose invariant is exact (ConstantSum). Pools whose invariant is approximated (WeightedMath's pow, StableMath's
    // Newton iteration) drift by ~1e-23 to 1e-18 relative, far below any swap fee: allow that, and no more. `setUp`
    // enforces at least 1000x below the 0.0001% fee floor, so a tolerance can never hide a real value leak.
    uint256 internal invariantRelDecreaseTolerance = 0;

    PoolHandler internal handler;

    function setUp() public virtual override {
        require(invariantRelDecreaseTolerance <= MIN_SWAP_FEE_FLOOR / 1000, "invariantRelDecreaseTolerance too loose");
        super.setUp();

        IERC20[] memory tokens = vault.getPoolTokens(pool);
        for (uint256 i = 0; i < tokens.length; i++) {
            poolTokens.push(tokens[i]);
        }

        // Invariant tests call only the handler's operations.
        handler = new PoolHandler(
            IVault(address(vault)),
            IRouter(address(router)),
            pool,
            alice,
            lp,
            maxLiquidityRatio,
            invariantRelDecreaseTolerance
        );
        targetContract(address(handler));
    }

    /***************************************************************************
                          Invariant test (random sequences)
    ***************************************************************************/

    /// @dev Runs and depth are set in foundry.toml's [invariant] section.
    function invariant_operationsNeverDiluteLps() public view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    /***************************************************************************
                                 Pool bounds
    ***************************************************************************/

    function testBoundsAreConsistent() public view {
        IBasePool p = IBasePool(pool);
        assertLe(p.getMinimumSwapFeePercentage(), p.getMaximumSwapFeePercentage(), "Swap fee bounds inverted");
        assertLe(p.getMinimumInvariantRatio(), FixedPoint.ONE, "Min invariant ratio above 100%");
        assertGe(p.getMaximumInvariantRatio(), FixedPoint.ONE, "Max invariant ratio below 100%");
    }

    /// @dev The swap fee must cover the rounding error of the pool's fixed-point maths, or repeated tiny swaps can
    /// extract it: 0.0001% is the floor for every pool.
    function testMinimumSwapFeeAtLeastFloor() public view {
        assertGe(IBasePool(pool).getMinimumSwapFeePercentage(), MIN_SWAP_FEE_FLOOR, "Minimum swap fee below 0.0001%");
    }

    /***************************************************************************
                        computeInvariant (maths only, fuzzed)
    ***************************************************************************/

    function testInvariantRoundingFuzz(uint256 balanceSeed) public view {
        uint256[] memory balances = _randomBalances(balanceSeed);

        assertGe(
            _invariant(balances, Rounding.ROUND_UP),
            _invariant(balances, Rounding.ROUND_DOWN),
            "ROUND_UP invariant below ROUND_DOWN"
        );
    }

    function testInvariantScalesLinearlyFuzz(uint256 balanceSeed) public view {
        uint256[] memory balances = _randomBalances(balanceSeed);
        uint256[] memory doubled = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            doubled[i] = balances[i] * 2;
        }

        // Proportional adds/removes mint BPT pro rata; unbalanced ones by invariant growth. The two only agree if the
        // invariant is linear in the balances.
        assertApproxEqRel(
            _invariant(doubled, Rounding.ROUND_DOWN),
            _invariant(balances, Rounding.ROUND_DOWN) * 2,
            invariantRelTolerance,
            "Invariant not linear in the balances"
        );
    }

    /***************************************************************************
                             onSwap (maths only, fuzzed)
    ***************************************************************************/

    function testSwapExactInNeverDecreasesInvariantFuzz(uint256 balanceSeed, uint256 amountIn, uint256 pairSeed) public {
        uint256[] memory balances = _randomBalances(balanceSeed);
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        amountIn = bound(amountIn, minAmount, balances[indexIn].mulDown(maxSwapRatio));

        uint256 amountOut = _onSwap(SwapKind.EXACT_IN, amountIn, balances, indexIn, indexOut);
        // Asking for more than the pool holds: the Vault reverts this swap, nothing to check.
        if (amountOut >= balances[indexOut]) return;

        assertGe(
            _invariant(_afterSwap(balances, indexIn, indexOut, amountIn, amountOut), Rounding.ROUND_DOWN),
            _lessTolerance(_invariant(balances, Rounding.ROUND_DOWN)),
            "EXACT_IN swap decreased the invariant"
        );
    }

    function testSwapExactOutNeverDecreasesInvariantFuzz(uint256 balanceSeed, uint256 amountOut, uint256 pairSeed) public {
        uint256[] memory balances = _randomBalances(balanceSeed);
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        amountOut = bound(amountOut, minAmount, balances[indexOut].mulDown(maxSwapRatio));

        uint256 amountIn = _onSwap(SwapKind.EXACT_OUT, amountOut, balances, indexIn, indexOut);

        assertGe(
            _invariant(_afterSwap(balances, indexIn, indexOut, amountIn, amountOut), Rounding.ROUND_DOWN),
            _lessTolerance(_invariant(balances, Rounding.ROUND_DOWN)),
            "EXACT_OUT swap decreased the invariant"
        );
    }

    /// @dev Sell `amountIn` of one token, sell the proceeds straight back: you can't end up with more than you started.
    function testSwapExactInRoundTripNotProfitableFuzz(uint256 balanceSeed, uint256 amountIn, uint256 pairSeed) public {
        uint256[] memory balances = _randomBalances(balanceSeed);
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        amountIn = bound(amountIn, minAmount, balances[indexIn].mulDown(maxSwapRatio));

        uint256 amountOut = _onSwap(SwapKind.EXACT_IN, amountIn, balances, indexIn, indexOut);
        if (amountOut == 0 || amountOut >= balances[indexOut]) return;
        balances = _afterSwap(balances, indexIn, indexOut, amountIn, amountOut);

        (bool ok, uint256 amountBack) = _tryOnSwap(SwapKind.EXACT_IN, amountOut, balances, indexOut, indexIn);
        if (!ok) return; // the pool refuses the return leg (e.g. a max-in ratio): no profit possible
        assertLe(amountBack, amountIn, "EXACT_IN round trip made a profit");
    }

    /// @dev Buy `amountOut` of one token, sell it straight back: you can't get back more than you paid.
    function testSwapExactOutRoundTripNotProfitableFuzz(uint256 balanceSeed, uint256 amountOut, uint256 pairSeed) public {
        uint256[] memory balances = _randomBalances(balanceSeed);
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        amountOut = bound(amountOut, minAmount, balances[indexOut].mulDown(maxSwapRatio));

        uint256 amountIn = _onSwap(SwapKind.EXACT_OUT, amountOut, balances, indexIn, indexOut);
        balances = _afterSwap(balances, indexIn, indexOut, amountIn, amountOut);

        (bool ok, uint256 amountBack) = _tryOnSwap(SwapKind.EXACT_IN, amountOut, balances, indexOut, indexIn);
        if (!ok) return; // the pool refuses the return leg (e.g. a max-in ratio): no profit possible
        assertLe(amountBack, amountIn, "EXACT_OUT round trip made a profit");
    }

    /***************************************************************************
                          computeBalance (maths only, fuzzed)
    ***************************************************************************/

    function testComputeBalanceReachesTargetInvariantFuzz(uint256 balanceSeed, uint256 invariantRatio, uint256 tokenSeed) public view {
        uint256[] memory balances = _randomBalances(balanceSeed);
        IBasePool p = IBasePool(pool);
        invariantRatio = bound(invariantRatio, p.getMinimumInvariantRatio(), p.getMaximumInvariantRatio());
        uint256 tokenIndex = tokenSeed % balances.length;

        uint256 newBalance;
        try p.computeBalance(balances, tokenIndex, invariantRatio) returns (uint256 result) {
            newBalance = result;
        } catch {
            // Some targets can't be reached by changing one token (it would need a negative balance). Reverting is
            // the right answer then: the Vault reverts the add/remove.
            return;
        }

        uint256 target = _invariant(balances, Rounding.ROUND_DOWN).mulDown(invariantRatio);
        balances[tokenIndex] = newBalance;
        // The user supplies (or keeps) this balance, so it must reach the target: never short of it.
        assertGe(
            _invariant(balances, Rounding.ROUND_DOWN),
            _lessTolerance(target),
            "computeBalance falls short of the target invariant"
        );
    }

    /***************************************************************************
                              Through the Vault (fuzzed)
    ***************************************************************************/

    function testSwapExactInThroughVaultFuzz(uint256 amountIn, uint256 pairSeed) public {
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        uint256[] memory balancesBefore = vault.getCurrentLiveBalances(pool);
        amountIn = bound(amountIn, minAmount, balancesBefore[indexIn].mulDown(maxSwapRatio));

        // What the pool quotes for the amount left after the Vault takes the swap fee from it. (The test tokens have
        // 18 decimals and no rate provider, so raw amounts equal scaled18 ones.)
        uint256 fee = amountIn.mulUp(vault.getStaticSwapFeePercentage(pool));
        uint256 quoted = _onSwap(SwapKind.EXACT_IN, amountIn - fee, balancesBefore, indexIn, indexOut);
        vm.assume(quoted < balancesBefore[indexOut]);

        uint256 tokenOutBefore = poolTokens[indexOut].balanceOf(alice);
        vm.prank(alice);
        uint256 amountOut = router.swapSingleTokenExactIn(
            pool,
            poolTokens[indexIn],
            poolTokens[indexOut],
            amountIn,
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        // A hook with a dynamic fee or adjusted amounts legitimately changes the result; the other checks still hold.
        if (!_hookChangesSwapAmounts()) assertEq(amountOut, quoted, "Vault result differs from the pool's quote");
        assertEq(poolTokens[indexOut].balanceOf(alice) - tokenOutBefore, amountOut, "Tokens not received");
        _assertInvariantNotDecreased(balancesBefore);
    }

    function testSwapExactOutThroughVaultFuzz(uint256 amountOut, uint256 pairSeed) public {
        (uint256 indexIn, uint256 indexOut) = _pair(pairSeed);
        uint256[] memory balancesBefore = vault.getCurrentLiveBalances(pool);
        amountOut = bound(amountOut, minAmount, balancesBefore[indexOut].mulDown(maxSwapRatio));

        uint256 tokenInBefore = poolTokens[indexIn].balanceOf(alice);
        vm.prank(alice);
        uint256 amountIn = router.swapSingleTokenExactOut(
            pool,
            poolTokens[indexIn],
            poolTokens[indexOut],
            amountOut,
            tokenInBefore, // max in: not MAX_UINT256, which overflows when the Vault scales it
            MAX_UINT256,
            false,
            bytes("")
        );

        assertEq(tokenInBefore - poolTokens[indexIn].balanceOf(alice), amountIn, "Tokens not paid");
        _assertInvariantNotDecreased(balancesBefore);
    }

    /// @dev Uses computeBalance. Existing LPs must not be diluted: invariant per BPT never goes down.
    function testAddLiquiditySingleTokenFuzz(uint256 bptAmountOut, uint256 tokenSeed) public {
        uint256 supply = IERC20(pool).totalSupply();
        uint256 maxGrowth = IBasePool(pool).getMaximumInvariantRatio() - FixedPoint.ONE;
        bptAmountOut = bound(bptAmountOut, minAmount, supply.mulDown(_min(maxGrowth, maxLiquidityRatio)));
        uint256 invariantBefore = _invariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        IERC20 tokenIn = poolTokens[tokenSeed % poolTokens.length];
        // Read before the prank, which only covers the next call.
        uint256 maxAmountIn = tokenIn.balanceOf(alice);

        vm.prank(alice);
        router.addLiquiditySingleTokenExactOut(pool, tokenIn, maxAmountIn, bptAmountOut, false, bytes(""));

        assertEq(IERC20(pool).balanceOf(alice), bptAmountOut, "BPT not received");
        _assertInvariantPerBptNotDecreased(invariantBefore, supply);
    }

    /// @dev Uses computeBalance. Remaining LPs must not be diluted: invariant per BPT never goes down.
    function testRemoveLiquiditySingleTokenFuzz(uint256 bptAmountIn, uint256 tokenSeed) public {
        uint256 supply = IERC20(pool).totalSupply();
        uint256 maxShrink = FixedPoint.ONE - IBasePool(pool).getMinimumInvariantRatio();
        bptAmountIn = bound(bptAmountIn, minAmount, supply.mulDown(_min(maxShrink, maxLiquidityRatio)));
        uint256 invariantBefore = _invariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        IERC20 tokenOut = poolTokens[tokenSeed % poolTokens.length];

        uint256 tokenOutBefore = tokenOut.balanceOf(lp);
        vm.prank(lp);
        uint256 amountOut = router.removeLiquiditySingleTokenExactIn(pool, bptAmountIn, tokenOut, 1, false, bytes(""));

        assertEq(tokenOut.balanceOf(lp) - tokenOutBefore, amountOut, "Tokens not received");
        _assertInvariantPerBptNotDecreased(invariantBefore, supply);
    }

    /***************************************************************************
                                     Helpers
    ***************************************************************************/

    /// @dev One random balance per pool token, each in [minBalance, maxBalance], from a single fuzzed seed.
    function _randomBalances(uint256 seed) internal view returns (uint256[] memory balances) {
        balances = new uint256[](poolTokens.length);
        for (uint256 i = 0; i < balances.length; i++) {
            balances[i] = bound(uint256(keccak256(abi.encode(seed, i))), minBalance, maxBalance);
        }
    }

    /// @dev Two different token indices from one fuzzed seed (works for any token count).
    function _pair(uint256 seed) internal view returns (uint256 indexIn, uint256 indexOut) {
        uint256 n = poolTokens.length;
        indexIn = seed % n;
        indexOut = (indexIn + 1 + ((seed / n) % (n - 1))) % n;
    }

    function _invariant(uint256[] memory balances, Rounding rounding) internal view returns (uint256) {
        return IBasePool(pool).computeInvariant(balances, rounding);
    }

    function _onSwap(
        SwapKind kind,
        uint256 amountGiven,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) internal returns (uint256) {
        // Not a view: IBasePool.onSwap may write state (e.g. a pool that tracks its last trade).
        return
            IBasePool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    amountGivenScaled18: amountGiven,
                    balancesScaled18: balances,
                    indexIn: indexIn,
                    indexOut: indexOut,
                    router: address(router),
                    userData: bytes("")
                })
            );
    }

    function _tryOnSwap(
        SwapKind kind,
        uint256 amountGiven,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) internal returns (bool ok, uint256 amountCalculated) {
        try
            IBasePool(pool).onSwap(
                PoolSwapParams({
                    kind: kind,
                    amountGivenScaled18: amountGiven,
                    balancesScaled18: balances,
                    indexIn: indexIn,
                    indexOut: indexOut,
                    router: address(router),
                    userData: bytes("")
                })
            )
        returns (uint256 result) {
            return (true, result);
        } catch {
            return (false, 0);
        }
    }

    function _hookChangesSwapAmounts() internal view returns (bool) {
        HooksConfig memory hooksConfig = vault.getHooksConfig(pool);
        return
            hooksConfig.hooksContract != address(0) &&
            (hooksConfig.shouldCallComputeDynamicSwapFee || hooksConfig.enableHookAdjustedAmounts);
    }

    function _afterSwap(
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256[] memory balancesAfter) {
        balancesAfter = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; i++) {
            balancesAfter[i] = balances[i];
        }
        balancesAfter[indexIn] += amountIn;
        balancesAfter[indexOut] -= amountOut;
    }

    function _assertInvariantNotDecreased(uint256[] memory balancesBefore) internal view {
        assertGe(
            _invariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN),
            _lessTolerance(_invariant(balancesBefore, Rounding.ROUND_DOWN)),
            "Swap decreased the invariant"
        );
    }

    function _assertInvariantPerBptNotDecreased(uint256 invariantBefore, uint256 supplyBefore) internal view {
        uint256 invariantAfter = _invariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        uint256 supplyAfter = IERC20(pool).totalSupply();
        // invariantAfter / supplyAfter >= invariantBefore / supplyBefore, cross-multiplied to avoid rounding.
        assertGe(invariantAfter * supplyBefore, _lessTolerance(invariantBefore * supplyAfter), "Invariant per BPT decreased");
    }

    /// @dev `x` less the allowed relative drift of an approximated invariant (see invariantRelDecreaseTolerance).
    function _lessTolerance(uint256 x) internal view returns (uint256) {
        return x - (x * invariantRelDecreaseTolerance) / FixedPoint.ONE;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
