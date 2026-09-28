// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@bush.fi/v3-interfaces/contracts/vault/IBasePool.sol";
import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultMock } from "@bush.fi/v3-interfaces/contracts/test/IVaultMock.sol";
import { Rounding } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

/**
 * @notice Random operations on one pool, for Foundry invariant testing (see `PoolPropertiesTest`).
 * @dev Foundry calls these functions in random order with random arguments, `depth` calls per run, so the pool
 * wanders through states no hand-written test starts from: lopsided balances, tiny or huge supply, long runs of
 * swaps in one direction. After every successful operation the handler checks that the invariant per BPT did not go
 * down: swaps (fees stay in the pool) and adds/removes (rounded against the user) must never dilute the LPs.
 *
 * The first operation of each run lowers the pool's swap fee to its minimum: fees stay in the pool, so a high fee
 * hides maths errors smaller than itself. At the minimum, any error bigger than the fee floor shows up. (1-wei
 * rounding errors are below every fee; the maths-only fuzz tests in `PoolPropertiesTest` catch those.)
 *
 * A failed check is recorded, not asserted: an assert inside the handler would just be a revert, which Foundry
 * discards. `PoolPropertiesTest.invariant_*` then fails on the recorded violation. Operations the pool or the Vault
 * refuse (too big, too small, outside the invariant-ratio bounds) revert and are discarded, as on chain.
 */
contract PoolHandler is Test {
    using FixedPoint for uint256;

    IVault public immutable vault;
    IRouter public immutable router;
    address public immutable pool;
    address public immutable trader; // swaps and adds
    address public immutable lp; // removes (holds the initial BPT)
    uint256 public immutable maxOperationRatio; // largest operation, as a fraction of the balance / supply
    uint256 public immutable invariantRelDecreaseTolerance; // see PoolPropertiesTest

    IERC20[] internal _tokens;

    uint256 public violations;
    string public firstViolation;
    mapping(bytes32 => uint256) public calls;

    uint256 private constant _MIN_AMOUNT = 1e12;

    bool private _feeLowered;

    constructor(
        IVault vault_,
        IRouter router_,
        address pool_,
        address trader_,
        address lp_,
        uint256 maxOperationRatio_,
        uint256 invariantRelDecreaseTolerance_
    ) {
        vault = vault_;
        router = router_;
        pool = pool_;
        trader = trader_;
        lp = lp_;
        maxOperationRatio = maxOperationRatio_;
        invariantRelDecreaseTolerance = invariantRelDecreaseTolerance_;
        _tokens = vault_.getPoolTokens(pool_);
    }

    /***************************************************************************
                                  Operations
    ***************************************************************************/

    /// @dev Only inside invariant runs (the handler's own calls), so the fuzz and hand-worked tests keep their fee.
    modifier atMinimumFee() {
        if (!_feeLowered) {
            IVaultMock(address(vault)).manualSetStaticSwapFeePercentage(pool, IBasePool(pool).getMinimumSwapFeePercentage());
            _feeLowered = true;
        }
        _;
    }

    function swapExactIn(uint256 amountIn, uint256 tokenSeed, uint256 offsetSeed) external atMinimumFee {
        (uint256 i, uint256 o) = _pair(tokenSeed, offsetSeed);
        amountIn = _boundToBalance(amountIn, i);
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        vm.prank(trader);
        router.swapSingleTokenExactIn(pool, _tokens[i], _tokens[o], amountIn, 0, type(uint256).max, false, "");

        _check("swapExactIn", invariantBefore, supplyBefore);
    }

    function swapExactOut(uint256 amountOut, uint256 tokenSeed, uint256 offsetSeed) external atMinimumFee {
        (uint256 i, uint256 o) = _pair(tokenSeed, offsetSeed);
        amountOut = _boundToBalance(amountOut, o);
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        uint256 maxAmountIn = _tokens[i].balanceOf(trader);
        vm.prank(trader);
        router.swapSingleTokenExactOut(pool, _tokens[i], _tokens[o], amountOut, maxAmountIn, type(uint256).max, false, "");

        _check("swapExactOut", invariantBefore, supplyBefore);
    }

    function addUnbalanced(uint256 amountSeed, uint256 tokenMask) external atMinimumFee {
        uint256[] memory amountsIn = new uint256[](_tokens.length);
        for (uint256 k = 0; k < _tokens.length; k++) {
            // Each token in or not (at least one in), each with its own size.
            if ((tokenMask >> k) & 1 == 1 || k == tokenMask % _tokens.length) {
                amountsIn[k] = _boundToBalance(uint256(keccak256(abi.encode(amountSeed, k))), k);
            }
        }
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        vm.prank(trader);
        router.addLiquidityUnbalanced(pool, amountsIn, 0, false, "");

        _check("addUnbalanced", invariantBefore, supplyBefore);
    }

    function addSingleTokenExactOut(uint256 bptOut, uint256 tokenSeed) external atMinimumFee {
        uint256 i = tokenSeed % _tokens.length;
        bptOut = _boundToSupply(bptOut);
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        uint256 maxAmountIn = _tokens[i].balanceOf(trader);
        vm.prank(trader);
        router.addLiquiditySingleTokenExactOut(pool, _tokens[i], maxAmountIn, bptOut, false, "");

        _check("addSingleTokenExactOut", invariantBefore, supplyBefore);
    }

    function removeProportional(uint256 bptIn) external atMinimumFee {
        bptIn = _boundToLpBalance(bptIn);
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        vm.prank(lp);
        router.removeLiquidityProportional(pool, bptIn, new uint256[](_tokens.length), false, "");

        _check("removeProportional", invariantBefore, supplyBefore);
    }

    function removeSingleTokenExactIn(uint256 bptIn, uint256 tokenSeed) external atMinimumFee {
        uint256 i = tokenSeed % _tokens.length;
        bptIn = _boundToLpBalance(bptIn);
        (uint256 invariantBefore, uint256 supplyBefore) = _state();

        vm.prank(lp);
        router.removeLiquiditySingleTokenExactIn(pool, bptIn, _tokens[i], 1, false, "");

        _check("removeSingleTokenExactIn", invariantBefore, supplyBefore);
    }

    /***************************************************************************
                                   Internals
    ***************************************************************************/

    function _state() private view returns (uint256 invariant, uint256 supply) {
        invariant = IBasePool(pool).computeInvariant(vault.getCurrentLiveBalances(pool), Rounding.ROUND_DOWN);
        supply = vault.totalSupply(pool);
    }

    function _check(string memory operation, uint256 invariantBefore, uint256 supplyBefore) private {
        calls[keccak256(bytes(operation))]++;
        (uint256 invariantAfter, uint256 supplyAfter) = _state();
        // invariantAfter / supplyAfter >= invariantBefore / supplyBefore (less the allowed drift of an approximated
        // invariant), cross-multiplied to avoid rounding.
        uint256 floor = invariantBefore * supplyAfter;
        floor -= (floor * invariantRelDecreaseTolerance) / FixedPoint.ONE;
        if (invariantAfter * supplyBefore < floor) {
            if (violations == 0) {
                firstViolation = string.concat(
                    operation,
                    ": invariant/supply went from ",
                    vm.toString(invariantBefore),
                    "/",
                    vm.toString(supplyBefore),
                    " to ",
                    vm.toString(invariantAfter),
                    "/",
                    vm.toString(supplyAfter)
                );
            }
            violations++;
        }
    }

    /// @dev Two different token indices from two seeds (works for any token count).
    function _pair(uint256 tokenSeed, uint256 offsetSeed) private view returns (uint256 i, uint256 o) {
        uint256 n = _tokens.length;
        i = tokenSeed % n;
        o = (i + 1 + (offsetSeed % (n - 1))) % n;
    }

    function _boundToBalance(uint256 amount, uint256 tokenIndex) private view returns (uint256) {
        (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(pool);
        uint256 max = balancesRaw[tokenIndex].mulDown(maxOperationRatio);
        return bound(amount, _MIN_AMOUNT, max > _MIN_AMOUNT ? max : _MIN_AMOUNT);
    }

    function _boundToSupply(uint256 bpt) private view returns (uint256) {
        uint256 max = vault.totalSupply(pool).mulDown(maxOperationRatio);
        return bound(bpt, _MIN_AMOUNT, max > _MIN_AMOUNT ? max : _MIN_AMOUNT);
    }

    function _boundToLpBalance(uint256 bpt) private view returns (uint256) {
        uint256 held = IERC20(pool).balanceOf(lp);
        uint256 max = vault.totalSupply(pool).mulDown(maxOperationRatio);
        if (held < max) max = held;
        return bound(bpt, _MIN_AMOUNT, max > _MIN_AMOUNT ? max : _MIN_AMOUNT);
    }
}
