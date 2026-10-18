// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice What a launcher chooses for a launch. The supply and the bonding curve are not here: the factory fixes them
 * for every launch (see `getLaunchConfig`). Buyers always pay in WETH (or ETH, through the Router).
 * @param name The launch token's name (the pool's BPT is named after it)
 * @param symbol The launch token's symbol
 * @param creatorFeeRecipient Where the creator share of the swap fee goes (a user or a contract); fixed for good
 * @param metadataURI Off-chain metadata (image, description, links), emitted in `BondingLaunchCreated`, not stored
 * @param minInitialBuyAmountOut With ETH sent to `create`: the fewest launch tokens the creator's initial buy accepts
 */
struct BondingLaunchParams {
    string name;
    string symbol;
    address creatorFeeRecipient;
    string metadataURI;
    uint256 minInitialBuyAmountOut;
}

interface IBondingReClammPoolFactory {
    /**
     * @notice A launch was created: a new token, its pool, the pool initialized with the whole supply, and optionally
     * the creator's initial buy.
     * @param pool The BondingReClammPool
     * @param launchToken The token it sells
     * @param creator The account that created the launch (and received the initial buy, if any)
     * @param supply The launch token's whole supply, all of it in the pool
     * @param metadataURI Off-chain metadata for the token
     * @param initialBuyAmountIn WETH spent on the creator's initial buy (0 if none)
     * @param initialBuyAmountOut Launch tokens the initial buy bought
     */
    event BondingLaunchCreated(
        address indexed pool,
        IERC20 indexed launchToken,
        address indexed creator,
        uint256 supply,
        string metadataURI,
        uint256 initialBuyAmountIn,
        uint256 initialBuyAmountOut
    );

    /// @notice The launch supply is zero or above `MAX_LAUNCH_SUPPLY`.
    error InvalidLaunchSupply();

    /// @notice The WETH address given to the factory is zero.
    error InvalidWeth();
}
