// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice What a launcher chooses for a launch. The supply and the bonding curve are not here: the factory fixes them
 * for every launch (see `getLaunchConfig`). Buyers always pay in WETH (or ETH, through the Router).
 * @param name The launch token's name (the pool's BPT is named after it)
 * @param symbol The launch token's symbol
 * @param creatorFeeRecipient Where the creator share of the swap fee goes (a user or a contract); fixed for good
 * @param metadataURI Off-chain metadata (image, description, links), emitted in `RukusLaunchCreated`, not stored
 * @param minInitialBuyAmountOut With ETH sent to `create`: the fewest launch tokens the creator's initial buy accepts
 * @param graduatedSwapFeePercentage The swap fee from graduation on, within the pool's bounds (0.001% to 5%); fixed
 * for good
 * @param graduatedCreatorFeePercentage The creator share of the swap fee from graduation on (after the protocol's),
 * from the factory's minimum (`getMinGraduatedCreatorFeePercentage`) to 99.999%; the rest of each fee stays in the
 * pool. Rukus's cut after graduation is a fixed share of the creator fees, so it scales with this. Fixed for good
 */
struct RukusLaunchParams {
    string name;
    string symbol;
    address creatorFeeRecipient;
    string metadataURI;
    uint256 minInitialBuyAmountOut;
    uint256 graduatedSwapFeePercentage;
    uint256 graduatedCreatorFeePercentage;
}

interface IRukusLaunchPoolFactory {
    /**
     * @notice A launch was created: a new token, its pool, the pool initialized with the whole supply, and optionally
     * the creator's initial buy.
     * @param pool The RukusLaunchPool
     * @param launchToken The token it sells
     * @param creator The account that created the launch (and received the initial buy, if any)
     * @param supply The launch token's whole supply, all of it in the pool
     * @param metadataURI Off-chain metadata for the token
     * @param initialBuyAmountIn WETH spent on the creator's initial buy (0 if none)
     * @param initialBuyAmountOut Launch tokens the initial buy bought
     */
    event RukusLaunchCreated(
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

    /// @notice The Rukus fee recipient given to the factory is the zero address.
    error InvalidRukusFeeRecipient();

    /// @notice The minimum graduated creator fee given to the factory is above the fee controller's 99.999% maximum.
    error InvalidMinGraduatedCreatorFee();

    /**
     * @notice The launch's graduated creator fee is below the factory's minimum.
     * @param graduatedCreatorFeePercentage The graduated creator fee given to `create`
     * @param minGraduatedCreatorFeePercentage The factory's minimum
     */
    error GraduatedCreatorFeeBelowMinimum(uint256 graduatedCreatorFeePercentage, uint256 minGraduatedCreatorFeePercentage);

    /**
     * @notice The swap fee, after the protocol's share, doesn't cover the Rukus cut of every trade.
     * @param swapFeePercentage The swap fee given to `create`
     */
    error SwapFeeTooLowForRukusFee(uint256 swapFeePercentage);
}
