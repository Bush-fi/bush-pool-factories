// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@bush.fi/v3-interfaces/contracts/vault/IBasePool.sol";

/**
 * @notice Where a RukusLaunch pool is in its life.
 * @dev BONDING: swaps run on the bonding curve (fixed virtual balances); liquidity is locked.
 * COMPLETED: a buy took the launch token balance down to the graduation balance. The pool is frozen for the rest of
 * that block, and graduates on the first interaction (or `graduate()` call) in a later block.
 * GRADUATED: the pool is a (practically) full-range constant-product pool: its virtual balances are tiny and fixed,
 * changing only with proportional adds and removes, which are now open.
 */
enum BondingPhase {
    BONDING,
    COMPLETED,
    GRADUATED
}

/**
 * @notice The curve a RukusLaunch pool is created with.
 * @dev Prices are of one whole launch token in whole quote tokens, as 18-decimal FP.
 * @param initialPrice Price at the start of the bonding curve, when the pool holds no quote token
 * @param graduationPrice Price at which the bonding curve completes and the pool graduates. The curve is set so that
 * at this price the quote raised is worth exactly the launch tokens left, so the graduated pool starts balanced.
 */
struct RukusLaunchCurveParams {
    uint256 initialPrice;
    uint256 graduationPrice;
}

/// @notice RukusLaunchPool constructor arguments (the factory fills in the launch token's index).
struct RukusLaunchPoolParams {
    string name;
    string symbol;
    string version;
    IERC20 launchToken;
    uint256 launchTokenIndex;
    address creatorFeeRecipient;
    address rukusFeeRecipient;
    uint256 rukusFeeShare;
    uint256 graduatedSwapFeePercentage;
    uint256 graduatedCreatorFeePercentage;
    RukusLaunchCurveParams curve;
}

/// @notice Everything that changes, in one call: what an integrator (and the off-chain maths) needs to price the pool.
struct RukusLaunchPoolDynamicData {
    uint256[] balancesLiveScaled18;
    uint256 staticSwapFeePercentage;
    uint256 totalSupply;
    bool isPoolInitialized;
    BondingPhase phase;
    uint256 bondingCompletedAt;
    uint256 graduationLaunchBalance;
    uint256[] virtualBalances;
}

/// @notice Everything fixed at creation.
struct RukusLaunchPoolImmutableData {
    IERC20[] tokens;
    uint256[] decimalScalingFactors;
    IERC20 launchToken;
    uint256 launchTokenIndex;
    uint256 initialPrice;
    uint256 graduationPrice;
    uint256 graduatedPriceRatio;
    address creatorFeeRecipient;
    uint256 creatorFeePercentage;
    address rukusFeeRecipient;
    uint256 rukusFeeShare;
    uint256 graduatedSwapFeePercentage;
    uint256 graduatedCreatorFeePercentage;
    uint256 minSwapFeePercentage;
    uint256 maxSwapFeePercentage;
}

interface IRukusLaunchPool is IBasePool {
    /********************************************************
                            Events
    ********************************************************/

    /**
     * @notice The pool was initialized and the bonding curve set.
     * @param launchBalance The launch tokens deposited (scaled18)
     * @param graduationLaunchBalance The launch token balance at which the curve completes (scaled18)
     */
    event BondingCurveStarted(uint256 launchBalance, uint256 graduationLaunchBalance);

    /**
     * @notice A buy took the launch token balance to the graduation balance; the pool graduates in a later block.
     * @param launchBalance The launch token balance after that buy (scaled18)
     */
    event BondingCurveCompleted(uint256 launchBalance);

    /**
     * @notice The pool left the bonding curve for its full-range shape, at the price it had.
     * @param virtualBalanceA The new virtual balance of token A
     * @param virtualBalanceB The new virtual balance of token B
     * @param priceRatio The width the virtual balances were solved for (max price / min price, before fees widen it)
     */
    event Graduated(uint256 virtualBalanceA, uint256 virtualBalanceB, uint256 priceRatio);

    /**
     * @notice The virtual balances changed (at initialization, at graduation, and with each proportional add or remove).
     * @param virtualBalanceA The new virtual balance of token A
     * @param virtualBalanceB The new virtual balance of token B
     */
    event VirtualBalancesUpdated(uint256 virtualBalanceA, uint256 virtualBalanceB);

    /********************************************************
                            Errors
    ********************************************************/

    /// @notice The pool does not implement this (unbalanced liquidity is disabled).
    error NotImplemented();

    /// @notice The pool is already initialized.
    error PoolAlreadyInitialized();

    /// @notice The pool is not initialized yet.
    error PoolNotInitialized();

    /// @notice A hook was called for a pool other than this one.
    error InvalidPoolArgument(address pool);

    /// @notice The BPT of a RukusLaunch pool has no rate (as in ReClamm: the invariant is not linear in balances).
    error RukusLaunchPoolBptRateUnsupported();

    /// @notice The launch token is not one of the pool's two tokens, or its index is wrong.
    error InvalidLaunchToken();

    /// @notice The initial price is zero, or the graduation price is not above it.
    error InvalidBondingPrices();

    /// @notice graduationPrice / initialPrice is outside [MIN_BONDING_PRICE_RATIO, MAX_BONDING_PRICE_RATIO].
    error BondingPriceRatioOutOfBounds(uint256 bondingPriceRatio);

    /// @notice The pool must be initialized with launch tokens only: the bonding curve starts with no quote.
    error QuoteBalanceNotZero();

    /// @notice A virtual balance came out zero (initial balance or price too small to represent the curve).
    error ZeroVirtualBalance();

    /**
     * @notice The buy completing the curve would go past the graduation balance by more than `MAX_GRADUATION_OVERSHOOT`.
     * @param maxLaunchAmountOut The most launch tokens (scaled18) a buy can take right now
     */
    error GraduationBuyTooLarge(uint256 maxLaunchAmountOut);

    /// @notice The creator fee recipient is the zero address.
    error InvalidCreatorFeeRecipient();

    /// @notice The Rukus fee recipient is the zero address.
    error InvalidRukusFeeRecipient();

    /// @notice The Rukus share of the creator fees is above 100%.
    error InvalidRukusFeeShare();

    /// @notice The graduated swap fee is outside the pool's swap fee bounds.
    error InvalidGraduatedSwapFee();

    /// @notice The graduated creator fee is above the fee controller's 99.999% maximum.
    error InvalidGraduatedCreatorFee();

    /// @notice Liquidity can only be added or removed after the pool graduates.
    error LiquidityLockedUntilGraduation();

    /// @notice The bonding curve completed in this block; the pool graduates in the next one.
    error GraduationPending();

    /// @notice `graduate()` was called while the curve is still bonding, or after graduation.
    error NotReadyToGraduate();

    /********************************************************
                            Functions
    ********************************************************/

    /**
     * @notice Graduates a completed pool. Anyone can call it, from the block after the curve completed.
     * @dev Swaps and liquidity operations graduate the pool themselves when needed, so this is only a convenience
     * (e.g., for a launchpad that wants the event emitted promptly, or to pay graduation's gas rather than leave it to
     * the next trader). Graduating switches to the graduated swap and creator fees and pays out the creator fees
     * collected while bonding.
     */
    function graduate() external;

    /**
     * @notice Pays the creator fees collected so far, split between the creator fee recipient and the Rukus fee
     * recipient (`getRukusFeeShare()` to Rukus, the rest to the creator). Anyone can call it.
     * @dev The pool is its own pool creator, so the fee controller owes the fees to the pool; this has the controller
     * pay them to the pool, then splits everything the pool holds (including anything paid to it earlier, e.g. through
     * the controller's permissionless `withdrawPoolCreatorFees(pool)`).
     */
    function withdrawCreatorFees() external;

    /**
     * @notice The most launch tokens a buy can take right now (launch tokens have 18 decimals, so raw = scaled18).
     * @dev While bonding: down to the graduation balance less `MAX_GRADUATION_OVERSHOOT` (a bigger buy reverts with
     * `GraduationBuyTooLarge`). In the block the curve completed: 0 (everything reverts `GraduationPending`). After
     * that, and once graduated: the whole launch balance (no cap). For frontends sizing the buy that completes the curve.
     */
    function getMaxBuyAmount() external view returns (uint256);

    /// @notice Where creator fees are paid. Fixed at creation.
    function getCreatorFeeRecipient() external view returns (address);

    /// @notice Where the Rukus share of the creator fees is paid. Fixed at creation (by the factory).
    function getRukusFeeRecipient() external view returns (address);

    /**
     * @notice The Rukus share of the creator fees (18-decimal FP). Fixed at creation by the factory, from its Rukus fee
     * percentage, the swap fee and the protocol swap fee at the time, so that Rukus gets that percentage of every trade
     * while bonding. The share stays the same after graduation, so Rukus's cut then moves with the graduated fees.
     */
    function getRukusFeeShare() external view returns (uint256);

    /**
     * @notice The swap fee and the creator share of it from graduation on (18-decimal FP). Fixed at creation: the swap
     * fee by the launcher, the creator share by the factory.
     */
    function getGraduatedFees() external view returns (uint256 swapFeePercentage, uint256 creatorFeePercentage);

    /// @notice The current phase.
    function getBondingPhase() external view returns (BondingPhase);

    /// @notice The launch token and its index in the pool's (sorted) tokens.
    function getLaunchToken() external view returns (IERC20 launchToken, uint256 launchTokenIndex);

    /// @notice Timestamp of the buy that completed the curve (0 while bonding).
    function getBondingCompletedAt() external view returns (uint256);

    /// @notice The launch token balance (scaled18) at or below which the curve completes.
    function getGraduationLaunchBalance() external view returns (uint256);

    /**
     * @notice The virtual balances swaps use: the bonding curve's while bonding (and while COMPLETED, until graduation
     * runs), the graduated ones after. They never change with time.
     */
    function getVirtualBalances() external view returns (uint256 virtualBalanceA, uint256 virtualBalanceB);

    /// @notice Current spot price of one whole launch token in whole quote tokens (18-decimal FP, before fees).
    function computeCurrentLaunchTokenPrice() external view returns (uint256);

    /// @notice See `RukusLaunchPoolDynamicData`.
    function getRukusLaunchPoolDynamicData() external view returns (RukusLaunchPoolDynamicData memory);

    /// @notice See `RukusLaunchPoolImmutableData`.
    function getRukusLaunchPoolImmutableData() external view returns (RukusLaunchPoolImmutableData memory);
}
