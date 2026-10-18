// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IBondingReClammPool, BondingReClammCurveParams } from "../interfaces/IBondingReClammPool.sol";

library BondingReClammPoolFactoryLib {
    using FixedPoint for uint256;

    // solhint-disable private-vars-leading-underscore

    // graduationPrice / initialPrice. Below ~1%, the bonding virtual balances grow to ~100x the supply and the curve is
    // nearly flat, which is a fixed-price sale (use FixedPriceLBPool for that). Above 1e6x, the curve keeps less than
    // 0.1% of the supply for the graduated pool (Rt1 = Rt0 / (sqrt(ratio) + 1)), too little to make a market with.
    // pump.fun's curve is ~14.7x.
    uint256 internal constant MIN_BONDING_PRICE_RATIO = 1.01e18;
    uint256 internal constant MAX_BONDING_PRICE_RATIO = 1e6 * 1e18;

    // solhint-enable private-vars-leading-underscore

    /// @notice Checks the bonding curve's prices.
    function validateCurveParams(BondingReClammCurveParams memory curve) internal pure {
        if (curve.initialPrice == 0 || curve.graduationPrice <= curve.initialPrice) {
            revert IBondingReClammPool.InvalidBondingPrices();
        }

        uint256 bondingPriceRatio = curve.graduationPrice.divDown(curve.initialPrice);
        if (bondingPriceRatio < MIN_BONDING_PRICE_RATIO || bondingPriceRatio > MAX_BONDING_PRICE_RATIO) {
            revert IBondingReClammPool.BondingPriceRatioOutOfBounds(bondingPriceRatio);
        }
    }
}
