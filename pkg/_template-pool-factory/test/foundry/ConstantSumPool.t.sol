// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@bush.fi/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { CastingHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseVaultTest } from "@bush.fi/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { ConstantSumPoolFactory } from "../../contracts/ConstantSumPoolFactory.sol";
import { ConstantSumPool } from "../../contracts/ConstantSumPool.sol";

/**
 * @notice TEMPLATE: tests for the pool and its factory.
 * @dev `BaseVaultTest` deploys a Vault, Router, test tokens and users; we override `createPoolFactory`, `createPool`
 * and `initPool` so the base test works with our factory, then test the pool's behaviour through the Vault.
 */
contract ConstantSumPoolTest is BaseVaultTest {
    using ArrayHelpers for *;
    using CastingHelpers for address[];
    using FixedPoint for uint256;

    string private constant POOL_VERSION = "Pool v1";
    uint256 private constant RATE = 2e18; // 1 token0 = 2 token1
    uint256 private constant SWAP_FEE = 1e16; // 1%

    IERC20[] private poolTokens;

    function setUp() public override {
        super.setUp();
    }

    function createPoolFactory() internal override returns (address) {
        return address(new ConstantSumPoolFactory(IVault(address(vault)), 365 days, "Factory v1", POOL_VERSION));
    }

    function createPool() internal override returns (address newPool, bytes memory poolArgs) {
        IERC20[] memory sortedTokens = InputHelpers.sortTokens([address(dai), address(usdc)].toMemoryArray().asIERC20());
        TokenConfig[] memory tokenConfigs = vault.buildTokenConfig(sortedTokens);
        for (uint256 i = 0; i < sortedTokens.length; i++) {
            poolTokens.push(sortedTokens[i]);
        }

        PoolRoleAccounts memory roleAccounts;
        newPool = ConstantSumPoolFactory(poolFactory).create(
            "Constant Sum Pool",
            "CSP",
            tokenConfigs,
            RATE,
            roleAccounts,
            SWAP_FEE,
            bytes32(0)
        );
        vm.label(newPool, "constant sum pool");

        poolArgs = abi.encode(
            ConstantSumPool.NewPoolParams({ name: "Constant Sum Pool", symbol: "CSP", version: POOL_VERSION, rate: RATE }),
            vault
        );
    }

    function initPool() internal override {
        vm.prank(lp);
        router.initialize(pool, poolTokens, [poolInitAmount, poolInitAmount].toMemoryArray(), 0, false, bytes(""));
    }

    function testPoolIsFromFactory() public view {
        assertTrue(ConstantSumPoolFactory(poolFactory).isPoolFromFactory(pool), "Pool not registered with factory");
        assertEq(ConstantSumPool(pool).getConstantSumRate(), RATE, "Wrong rate");
    }

    function testInvariant() public view {
        uint256[] memory balances = [uint256(100e18), uint256(50e18)].toMemoryArray();
        // 100 * 2 + 50 = 250
        assertEq(ConstantSumPool(pool).computeInvariant(balances, Rounding.ROUND_DOWN), 250e18, "Wrong invariant");
    }

    function testSwapExactInThroughVault() public {
        uint256 amountIn = 10e18;
        IERC20 tokenIn = poolTokens[0];
        IERC20 tokenOut = poolTokens[1];

        uint256 balanceBefore = tokenOut.balanceOf(alice);
        vm.prank(alice);
        uint256 amountOut = router.swapSingleTokenExactIn(pool, tokenIn, tokenOut, amountIn, 0, MAX_UINT256, false, bytes(""));

        // 1 token0 = 2 token1, minus the 1% swap fee taken from the amount in.
        uint256 expected = (amountIn - amountIn.mulUp(SWAP_FEE)).mulDown(RATE);
        assertEq(amountOut, expected, "Wrong amount out");
        assertEq(tokenOut.balanceOf(alice) - balanceBefore, amountOut, "Tokens not received");
    }

    function testSwapExactOutRoundsAgainstUser() public view {
        // Buying 1 wei of token0 costs 2 wei of token1 exactly; buying 1 wei of token1 costs 1 wei of token0 (rounded up).
        uint256[] memory balances = [uint256(100e18), uint256(100e18)].toMemoryArray();
        assertEq(_quoteExactOut(balances, 1, 0, 1), 2, "token1 -> token0 exact out");
        assertEq(_quoteExactOut(balances, 0, 1, 1), 1, "token0 -> token1 exact out");
    }

    function _quoteExactOut(
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut,
        uint256 amountOut
    ) private view returns (uint256) {
        return
            ConstantSumPool(pool).onSwap(
                PoolSwapParams({
                    kind: SwapKind.EXACT_OUT,
                    amountGivenScaled18: amountOut,
                    balancesScaled18: balances,
                    indexIn: indexIn,
                    indexOut: indexOut,
                    router: address(router),
                    userData: bytes("")
                })
            );
    }
}
