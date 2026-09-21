// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IBasePool } from "@bush.fi/v3-interfaces/contracts/vault/IBasePool.sol";
import { ISwapFeePercentageBounds } from "@bush.fi/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import {
    IUnbalancedLiquidityInvariantRatioBounds
} from "@bush.fi/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { PoolSwapParams, Rounding, SwapKind } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { Version } from "@bush.fi/v3-solidity-utils/contracts/helpers/Version.sol";
import { BushPoolToken } from "@bush.fi/v3-vault/contracts/BushPoolToken.sol";
import { PoolInfo } from "@bush.fi/v3-pool-utils/contracts/PoolInfo.sol";

/**
 * @notice TEMPLATE: a minimal two-token constant-sum pool with a fixed price.
 *
 * @dev This is the smallest pool that exercises everything the Vault asks of a pool, so it can serve as the
 * starting point for a new pool type. The maths is deliberately trivial:
 *
 *   invariant = balance0 * rate + balance1            (the pool's value, denominated in token1)
 *   1 token0  = `rate` token1, always                  (constant price; no slippage)
 *
 * A pool contract has three jobs, all called by the Vault with balances already scaled to 18 decimals:
 *   - `onSwap`           given an amount in (or out), return the amount out (or in);
 *   - `computeInvariant` the pool's invariant for a set of balances, rounded as the Vault asks;
 *   - `computeBalance`   the balance of one token that makes the invariant grow/shrink by a given ratio
 *                        (used by single-token add/remove liquidity).
 * plus the fee and invariant-ratio bounds the Vault enforces, and the ERC20 (BPT) behaviour from BushPoolToken.
 *
 * Rounding rule of thumb: every rounding decision must favour the Vault (round amounts the user receives down,
 * amounts the user pays up, invariants as the `rounding` argument says). The off-chain maths in
 * The off-chain maths (maths/<lang>) must reproduce these exact choices to match the contract to the wei.
 */
contract ConstantSumPool is IBasePool, BushPoolToken, PoolInfo, Version {
    using FixedPoint for uint256;

    /// @notice Parameters the factory passes to the constructor (ABI-encoded together with the Vault address).
    struct NewPoolParams {
        string name;
        string symbol;
        string version;
        uint256 rate;
    }

    // Swap fee bounds enforced by the Vault when the fee is set. 18-decimal percentages (1e18 = 100%).
    uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0;
    uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    // Bounds on how much an unbalanced add/remove may change the invariant. A constant-sum pool has no curvature,
    // so wide bounds are safe; curved pools (weighted, stable) use these to keep their maths well-behaved.
    uint256 private constant _MIN_INVARIANT_RATIO = 50e16; // 50%
    uint256 private constant _MAX_INVARIANT_RATIO = 200e16; // 200%

    /// @dev How many token1 one token0 is worth, as an 18-decimal fixed-point number. Immutable: set on creation.
    uint256 private immutable _rate;

    error InvalidRate();
    error InvalidTokenIndex();

    constructor(
        NewPoolParams memory params,
        IVault vault
    ) BushPoolToken(vault, params.name, params.symbol) PoolInfo(vault) Version(params.version) {
        if (params.rate == 0) {
            revert InvalidRate();
        }
        _rate = params.rate;
    }

    /// @notice The fixed price: how many token1 one token0 is worth (18 decimals).
    function getConstantSumRate() external view returns (uint256) {
        return _rate;
    }

    /// @inheritdoc IBasePool
    function onSwap(PoolSwapParams memory request) public view override returns (uint256 amountCalculatedScaled18) {
        if (request.indexIn > 1 || request.indexOut > 1 || request.indexIn == request.indexOut) {
            revert InvalidTokenIndex();
        }

        bool token0In = request.indexIn == 0;

        if (request.kind == SwapKind.EXACT_IN) {
            // The user receives the calculated amount: round down.
            amountCalculatedScaled18 = token0In
                ? request.amountGivenScaled18.mulDown(_rate)
                : request.amountGivenScaled18.divDown(_rate);
        } else {
            // The user pays the calculated amount: round up.
            amountCalculatedScaled18 = token0In
                ? request.amountGivenScaled18.divUp(_rate)
                : request.amountGivenScaled18.mulUp(_rate);
        }
    }

    /// @inheritdoc IBasePool
    function computeInvariant(uint256[] memory balances, Rounding rounding) public view override returns (uint256) {
        uint256 token0Value = rounding == Rounding.ROUND_UP ? balances[0].mulUp(_rate) : balances[0].mulDown(_rate);
        return token0Value + balances[1];
    }

    /// @inheritdoc IBasePool
    function computeBalance(
        uint256[] memory balances,
        uint256 tokenInIndex,
        uint256 invariantRatio
    ) external view override returns (uint256 newBalance) {
        // The balance the user must end up providing: round the target invariant up, and the balance up.
        uint256 newInvariant = computeInvariant(balances, Rounding.ROUND_UP).mulUp(invariantRatio);

        if (tokenInIndex == 0) {
            newBalance = (newInvariant - balances[1]).divUp(_rate);
        } else if (tokenInIndex == 1) {
            newBalance = newInvariant - balances[0].mulDown(_rate);
        } else {
            revert InvalidTokenIndex();
        }
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure override returns (uint256) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure override returns (uint256) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure override returns (uint256) {
        return _MIN_INVARIANT_RATIO;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure override returns (uint256) {
        return _MAX_INVARIANT_RATIO;
    }
}
