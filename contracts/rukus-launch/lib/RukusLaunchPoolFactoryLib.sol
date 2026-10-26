// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IRukusLaunchPool, RukusLaunchCurveParams } from "../interfaces/IRukusLaunchPool.sol";

library RukusLaunchPoolFactoryLib {
    using FixedPoint for uint256;

    // solhint-disable private-vars-leading-underscore

    // graduationPrice / initialPrice. Below ~1%, the bonding virtual balances grow to ~100x the supply and the curve is
    // nearly flat, which is a fixed-price sale (use FixedPriceLBPool for that). Above 1e6x, the curve keeps less than
    // 0.1% of the supply for the graduated pool (Rt1 = Rt0 / (sqrt(ratio) + 1)), too little to make a market with.
    // pump.fun's curve is ~14.7x.
    uint256 internal constant MIN_BONDING_PRICE_RATIO = 1.01e18;
    uint256 internal constant MAX_BONDING_PRICE_RATIO = 1e6 * 1e18;

    // The pool's creator share of the swap fee (the fee controller's maximum); the factory needs it to size the Rukus
    // share of the creator fees.
    uint256 internal constant CREATOR_FEE_PERCENTAGE = 99.999e16;

    // The pool's swap fee bounds, bonding and graduated; the factory checks the graduated fee against them up front.
    uint256 internal constant MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant MAX_SWAP_FEE_PERCENTAGE = 5e16; // 5%

    // solhint-enable private-vars-leading-underscore

    /// @notice Checks a swap fee is within the pool's bounds (reverts with the pool's `InvalidGraduatedSwapFee`).
    function validateGraduatedSwapFee(uint256 swapFeePercentage) internal pure {
        if (swapFeePercentage < MIN_SWAP_FEE_PERCENTAGE || swapFeePercentage > MAX_SWAP_FEE_PERCENTAGE) {
            revert IRukusLaunchPool.InvalidGraduatedSwapFee();
        }
    }

    /// @notice Checks the bonding curve's prices.
    function validateCurveParams(RukusLaunchCurveParams memory curve) internal pure {
        if (curve.initialPrice == 0 || curve.graduationPrice <= curve.initialPrice) {
            revert IRukusLaunchPool.InvalidBondingPrices();
        }

        uint256 bondingPriceRatio = curve.graduationPrice.divDown(curve.initialPrice);
        if (bondingPriceRatio < MIN_BONDING_PRICE_RATIO || bondingPriceRatio > MAX_BONDING_PRICE_RATIO) {
            revert IRukusLaunchPool.BondingPriceRatioOutOfBounds(bondingPriceRatio);
        }
    }
}
