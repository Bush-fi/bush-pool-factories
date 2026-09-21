// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IPoolVersion } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@bush.fi/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@bush.fi/v3-solidity-utils/contracts/helpers/Version.sol";

import { ReClammPoolHelper } from "../reclamm/ReClammPoolHelper.sol";
import { ReClammPoolFactoryLib, ReClammPriceParams } from "../reclamm/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolParams } from "../reclamm/interfaces/IReClammPool.sol";
import { ReClammPoolMock } from "./ReClammPoolMock.sol";

/// @notice ReClammPool Mock factory.
contract ReClammPoolFactoryMock is IPoolVersion, BasePoolFactory, Version {
    using SafeCast for uint256;

    // solhint-disable-next-line immutable-vars-naming
    ReClammPoolHelper public immutable reClammPoolHelper;

    string private _poolVersion;

    constructor(
        IVault vault,
        ReClammPoolHelper helper,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(ReClammPoolMock).creationCode) Version(factoryVersion) {
        reClammPoolHelper = helper;
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /**
     * @notice Deploys a new `ReClammPool`.
     * @param name The name of the pool
     * @param symbol The symbol of the pool
     * @param tokens An array of descriptors for the tokens the pool will manage
     * @param roleAccounts Addresses the Vault will allow to change certain pool settings
     * @param swapFeePercentage Initial swap fee percentage
     * @param priceParams Initial min, max and target prices; flags indicating whether token prices incorporate rates
     * @param dailyPriceShiftExponent Virtual balances will change by 2^(dailyPriceShiftExponent) per day
     * @param centerednessMargin How far the price can be from the center before the price range starts to move
     * @param salt The salt value that will be passed to deployment
     */
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        PoolRoleAccounts memory roleAccounts,
        uint256 swapFeePercentage,
        ReClammPriceParams memory priceParams,
        uint256 dailyPriceShiftExponent,
        uint256 centerednessMargin,
        bytes32 salt
    ) external returns (address pool) {
        ReClammPoolFactoryLib.validateTokenConfig(tokens, priceParams);

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = false;
        liquidityManagement.disableUnbalancedLiquidity = true;

        pool = _create(
            abi.encode(
                ReClammPoolParams({
                    name: name,
                    symbol: symbol,
                    version: _poolVersion,
                    initialMinPrice: priceParams.initialMinPrice,
                    initialMaxPrice: priceParams.initialMaxPrice,
                    initialTargetPrice: priceParams.initialTargetPrice,
                    tokenAPriceIncludesRate: priceParams.tokenAPriceIncludesRate,
                    tokenBPriceIncludesRate: priceParams.tokenBPriceIncludesRate,
                    dailyPriceShiftExponent: dailyPriceShiftExponent,
                    centerednessMargin: centerednessMargin.toUint64()
                }),
                getVault(),
                reClammPoolHelper
            ),
            salt
        );

        _registerPoolWithVault(
            pool,
            tokens,
            swapFeePercentage,
            false, // not exempt from protocol fees
            roleAccounts,
            pool, // The pool is the hook
            liquidityManagement
        );
    }
}
