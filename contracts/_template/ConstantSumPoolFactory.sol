// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IPoolVersion } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    PoolRoleAccounts,
    LiquidityManagement
} from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@bush.fi/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@bush.fi/v3-solidity-utils/contracts/helpers/Version.sol";

import { ConstantSumPool } from "./ConstantSumPool.sol";

/**
 * @notice TEMPLATE: factory for `ConstantSumPool`.
 * @dev A factory does two things in `create`: deploy the pool with CREATE2 (`_create`) and register it with the
 * Vault (`_registerPoolWithVault`) with its tokens, swap fee, role accounts, hooks contract and liquidity settings.
 * `BasePoolFactory` supplies both, plus pause-window handling and `isPoolFromFactory`.
 */
contract ConstantSumPoolFactory is IPoolVersion, BasePoolFactory, Version {
    string private _poolVersion;

    error ConstantSumPoolNeedsTwoTokens();

    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(ConstantSumPool).creationCode) Version(factoryVersion) {
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /**
     * @notice Deploys a new `ConstantSumPool`.
     * @dev Tokens must be sorted by address for pool registration.
     * @param name The name of the pool (also the BPT name)
     * @param symbol The symbol of the pool (also the BPT symbol)
     * @param tokens Exactly two token descriptors
     * @param rate How many token1 one token0 is worth, 18 decimals
     * @param roleAccounts Addresses the Vault will allow to change certain pool settings
     * @param swapFeePercentage Initial swap fee percentage
     * @param salt The salt value that will be passed to CREATE2
     */
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        uint256 rate,
        PoolRoleAccounts memory roleAccounts,
        uint256 swapFeePercentage,
        bytes32 salt
    ) external returns (address pool) {
        if (tokens.length != 2) {
            revert ConstantSumPoolNeedsTwoTokens();
        }

        // Defaults: unbalanced add/remove allowed, no donations, no custom liquidity operations.
        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();

        pool = _create(
            abi.encode(
                ConstantSumPool.NewPoolParams({ name: name, symbol: symbol, version: _poolVersion, rate: rate }),
                getVault()
            ),
            salt
        );

        _registerPoolWithVault(
            pool,
            tokens,
            swapFeePercentage,
            false, // not exempt from protocol fees
            roleAccounts,
            address(0), // no hooks contract
            liquidityManagement
        );
    }
}
