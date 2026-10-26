// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolVersion } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import { IRateProvider } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    TokenType,
    PoolRoleAccounts,
    LiquidityManagement,
    SwapKind,
    VaultSwapParams
} from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@bush.fi/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@bush.fi/v3-solidity-utils/contracts/helpers/Version.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { RukusLaunchCurveParams, RukusLaunchPoolParams } from "./interfaces/IRukusLaunchPool.sol";
import { IRukusLaunchPoolFactory, RukusLaunchParams } from "./interfaces/IRukusLaunchPoolFactory.sol";
import { RukusLaunchPoolFactoryLib } from "./lib/RukusLaunchPoolFactoryLib.sol";
import { RukusLaunchPool } from "./RukusLaunchPool.sol";
import { RukusLaunchToken } from "./RukusLaunchToken.sol";

/**
 * @notice Launches a token, pump.fun style: one call deploys a new fixed-supply token, a `RukusLaunchPool` that
 * sells it for WETH, initializes the pool with the whole supply, and optionally makes the creator's first buy.
 * @dev Doing it all in one transaction closes the ways a launch could be drained or front-run:
 *
 * - Every launch token starts in the pool, so every one in circulation was bought from the curve. The curve always
 *   holds enough WETH to buy them all back; a premine sold into it would take buyers' WETH instead.
 * - The initial BPT is minted to a burn address. Nobody can redeem the raise after graduation, or through a
 *   recovery-mode exit (which skips the pool's liquidity lock) if governance ever pauses the Vault or the pool.
 * - Nobody else can initialize the pool first, or buy before the creator's initial buy.
 *
 * The launch token's supply and the bonding curve are fixed by the factory, for every launch: set when the factory is
 * deployed (e.g. 1B tokens, 800M sold on the curve and 200M left for the pool, graduating at 5 ETH), never by a
 * launcher. A different shape is a different factory deployment.
 *
 * Roles are fixed: no pause manager, no swap fee manager (only governance can change the fee rate), and the pool is
 * its own pool creator, so it can fix the creator share of the swap fee at 99.999% when initialized (keeping fees out
 * of the pool); creator fees are split between the launch's `creatorFeeRecipient` and the factory's `rukusFeeRecipient`.
 * The quote token is always WETH, so a launch from this factory can't be paired with a look-alike token.
 *
 * Rukus gets a fixed cut of every trade, `rukusFeePercentage` (set when the factory is deployed), whatever swap fee the
 * launcher picks: at `create`, the factory works out the share of the creator fees that comes to, from the swap fee and
 * the protocol swap fee, and fixes it in the pool (see `computeRukusFeeShare`). The creator gets the rest of the swap
 * fee after the protocol's share, so the swap fee must at least cover the Rukus cut.
 *
 * At graduation the pool switches to the launcher's `graduatedSwapFeePercentage` and `graduatedCreatorFeePercentage`
 * (the rest of each fee then stays in the pool), and pays out the bonding fees. The factory sets a floor on the
 * graduated creator fee (`minGraduatedCreatorFeePercentage`). Rukus keeps the same share of the creator fees, so its
 * cut of a graduated trade follows those fees: a lower graduated creator fee means a smaller Rukus cut.
 */
contract RukusLaunchPoolFactory is IRukusLaunchPoolFactory, IPoolVersion, BasePoolFactory, Version {
    using FixedPoint for uint256;

    /// @notice Where the initial BPT goes: nobody holds the key, so the pool's liquidity is permanent.
    address public constant BPT_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The largest launch supply: 1 trillion tokens. Keeps the curve's virtual balances well inside uint128.
    uint256 public constant MAX_LAUNCH_SUPPLY = 1e12 * 1e18;

    IWETH private immutable _WETH;

    // Receives the Rukus share of every launch's creator fees.
    address private immutable _RUKUS_FEE_RECIPIENT;
    // Rukus's cut of every trade (18-decimal FP, of the amount in).
    uint256 private immutable _RUKUS_FEE_PERCENTAGE;
    // The lowest creator share of the swap fee from graduation on that a launch may choose.
    uint256 private immutable _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE;

    // The supply and curve of every launch.
    uint256 private immutable _LAUNCH_SUPPLY;
    uint256 private immutable _INITIAL_PRICE;
    uint256 private immutable _GRADUATION_PRICE;

    string private _poolVersion;

    // What the Vault callback needs (too many values to pass as arguments without via-IR).
    struct LaunchState {
        address pool;
        IERC20 launchToken;
        uint256 launchTokenIndex;
        uint256 initialBuyAmountIn;
        uint256 minInitialBuyAmountOut;
        address buyer;
    }

    /**
     * @param vault The Vault
     * @param pauseWindowDuration How long governance can pause this factory's pools
     * @param weth The quote token of every launch
     * @param rukusFeeRecipient Where the Rukus share of every launch's creator fees goes
     * @param rukusFeePercentage Rukus's cut of every trade (18-decimal FP, e.g. 1e16 for 1%)
     * @param minGraduatedCreatorFeePercentage The lowest creator share of the swap fee from graduation on that a launch
     * may choose (18-decimal FP, at most 99.999%)
     * @param launchSupply Every launch token's supply (18 decimals), all of it put in the pool
     * @param curve Every launch's bonding curve (initial and graduation prices)
     * @param factoryVersion Version string of the factory
     * @param poolVersion Version string of its pools
     */
    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        IWETH weth,
        address rukusFeeRecipient,
        uint256 rukusFeePercentage,
        uint256 minGraduatedCreatorFeePercentage,
        uint256 launchSupply,
        RukusLaunchCurveParams memory curve,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(RukusLaunchPool).creationCode) Version(factoryVersion) {
        if (address(weth) == address(0)) {
            revert InvalidWeth();
        }
        if (rukusFeeRecipient == address(0)) {
            revert InvalidRukusFeeRecipient();
        }
        if (minGraduatedCreatorFeePercentage > RukusLaunchPoolFactoryLib.CREATOR_FEE_PERCENTAGE) {
            revert InvalidMinGraduatedCreatorFee();
        }
        if (launchSupply == 0 || launchSupply > MAX_LAUNCH_SUPPLY) {
            revert InvalidLaunchSupply();
        }
        RukusLaunchPoolFactoryLib.validateCurveParams(curve);

        _WETH = weth;
        _RUKUS_FEE_RECIPIENT = rukusFeeRecipient;
        _RUKUS_FEE_PERCENTAGE = rukusFeePercentage;
        _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE = minGraduatedCreatorFeePercentage;
        _LAUNCH_SUPPLY = launchSupply;
        _INITIAL_PRICE = curve.initialPrice;
        _GRADUATION_PRICE = curve.graduationPrice;
        _poolVersion = poolVersion;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    /// @notice The quote token of every launch.
    function getWeth() external view returns (IWETH) {
        return _WETH;
    }

    /// @notice Where the Rukus share of every launch's creator fees goes.
    function getRukusFeeRecipient() external view returns (address) {
        return _RUKUS_FEE_RECIPIENT;
    }

    /// @notice Rukus's cut of every trade from this factory's launches (18-decimal FP, of the amount in).
    function getRukusFeePercentage() external view returns (uint256) {
        return _RUKUS_FEE_PERCENTAGE;
    }

    /// @notice The lowest creator share of the swap fee from graduation on that a launch may choose (18-decimal FP).
    function getMinGraduatedCreatorFeePercentage() external view returns (uint256) {
        return _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE;
    }

    /**
     * @notice The share of the creator fees a launch with this swap fee gives Rukus, so that Rukus gets
     * `getRukusFeePercentage()` of every trade.
     * @dev The protocol takes its share of the swap fee first, and the pool's creator share (99.999%) applies to the
     * rest: Rukus's cut is `swapFee * (1 - protocolFee) * creatorFee * share`. Rounded up, so Rukus gets at least its
     * cut. Uses the global protocol swap fee, which the Vault gives the pool when it registers it; if governance later
     * changes the pool's protocol fee, the share stays as it was.
     * @param swapFeePercentage The swap fee the launch will be created with
     * @return rukusFeeShare The share (18-decimal FP); reverts with `SwapFeeTooLowForRukusFee` above 100%
     */
    function computeRukusFeeShare(uint256 swapFeePercentage) public view returns (uint256 rukusFeeShare) {
        if (_RUKUS_FEE_PERCENTAGE == 0) {
            return 0;
        }

        uint256 protocolFeePercentage = getVault().getProtocolFeeController().getGlobalProtocolSwapFeePercentage();
        uint256 creatorFeePercentage = swapFeePercentage.mulDown(FixedPoint.ONE - protocolFeePercentage).mulDown(
            RukusLaunchPoolFactoryLib.CREATOR_FEE_PERCENTAGE
        );
        if (creatorFeePercentage < _RUKUS_FEE_PERCENTAGE) {
            revert SwapFeeTooLowForRukusFee(swapFeePercentage);
        }

        return _RUKUS_FEE_PERCENTAGE.divUp(creatorFeePercentage);
    }

    /// @notice The supply and bonding curve of every launch from this factory.
    function getLaunchConfig() external view returns (uint256 launchSupply, RukusLaunchCurveParams memory curve) {
        return (_LAUNCH_SUPPLY, RukusLaunchCurveParams({ initialPrice: _INITIAL_PRICE, graduationPrice: _GRADUATION_PRICE }));
    }

    /**
     * @notice Creates a launch: a new token, its pool against WETH, initialized with the whole supply, the initial BPT
     * burned, and, if ETH is sent, the creator's initial buy (the launch tokens go to the caller). The supply and the
     * curve are the factory's (`getLaunchConfig`).
     * @param launch The token's name and symbol, its creator fee recipient and metadata, the initial buy's minimum, and
     * the swap fee and creator fee from graduation on
     * @param swapFeePercentage The swap fee rate while bonding, up to 5% (nobody can change it; the pool replaces it with
     * the graduated fee at graduation). It must cover the Rukus cut after the protocol's share (see
     * `computeRukusFeeShare`).
     * @param salt Salt for the token and pool addresses (combined with the caller and the chain id)
     * @return pool The new RukusLaunchPool
     * @return launchToken The new token
     */
    function create(
        RukusLaunchParams memory launch,
        uint256 swapFeePercentage,
        bytes32 salt
    ) external payable returns (address pool, IERC20 launchToken) {
        // The pool checks the 99.999% maximum; the floor is the factory's.
        if (launch.graduatedCreatorFeePercentage < _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE) {
            revert GraduatedCreatorFeeBelowMinimum(
                launch.graduatedCreatorFeePercentage,
                _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE
            );
        }

        launchToken = new RukusLaunchToken{ salt: _computeFinalSalt(salt) }(
            launch.name,
            launch.symbol,
            _LAUNCH_SUPPLY,
            address(this)
        );

        LaunchState memory state;
        state.launchToken = launchToken;
        state.initialBuyAmountIn = msg.value;
        state.minInitialBuyAmountOut = launch.minInitialBuyAmountOut;
        state.buyer = msg.sender;

        (TokenConfig[] memory tokens, uint256 launchTokenIndex) = _buildTokenConfig(launchToken);
        state.launchTokenIndex = launchTokenIndex;
        pool = _createAndRegister(launch, state, tokens, swapFeePercentage, salt);
        state.pool = pool;

        if (msg.value > 0) {
            _WETH.deposit{ value: msg.value }();
        }
        uint256 initialBuyAmountOut = abi.decode(
            getVault().unlock(abi.encodeCall(this.launchHook, (state, _LAUNCH_SUPPLY))),
            (uint256)
        );

        emit RukusLaunchCreated(
            pool,
            launchToken,
            msg.sender,
            _LAUNCH_SUPPLY,
            launch.metadataURI,
            msg.value,
            initialBuyAmountOut
        );
    }

    /**
     * @notice The address `create` will deploy the launch token at, for a given caller.
     * @dev Lets a launchpad know the token's sort order (and so its index in the pool) before creating.
     */
    function getLaunchTokenAddress(
        RukusLaunchParams memory launch,
        address creator,
        bytes32 salt
    ) external view returns (address) {
        bytes32 finalSalt = keccak256(abi.encode(creator, block.chainid, salt));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(RukusLaunchToken).creationCode,
                abi.encode(launch.name, launch.symbol, _LAUNCH_SUPPLY, address(this))
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), finalSalt, initCodeHash)))));
    }

    /**
     * @notice Vault callback for `create`: initializes the pool with the whole launch supply (BPT to the burn address),
     * then makes the initial buy, if any, with the WETH the factory wrapped.
     * @dev Only the Vault can call it, and the Vault only calls back the account that unlocked it: this factory, inside
     * `create`.
     * @return initialBuyAmountOut Launch tokens bought for the caller (0 without an initial buy)
     */
    function launchHook(LaunchState memory state, uint256 supply) external returns (uint256 initialBuyAmountOut) {
        IVault vault = getVault();
        if (msg.sender != address(vault)) {
            revert IVaultErrors.SenderIsNotVault(msg.sender);
        }

        uint256[] memory amounts = new uint256[](2);
        amounts[state.launchTokenIndex] = supply;
        vault.initialize(state.pool, BPT_BURN_ADDRESS, vault.getPoolTokens(state.pool), amounts, 0, "");

        state.launchToken.transfer(address(vault), supply);
        vault.settle(state.launchToken, supply);

        if (state.initialBuyAmountIn == 0) {
            return 0;
        }

        (, uint256 amountIn, uint256 amountOut) = vault.swap(
            VaultSwapParams({
                kind: SwapKind.EXACT_IN,
                pool: state.pool,
                tokenIn: IERC20(address(_WETH)),
                tokenOut: state.launchToken,
                amountGivenRaw: state.initialBuyAmountIn,
                limitRaw: state.minInitialBuyAmountOut,
                userData: ""
            })
        );

        IERC20(address(_WETH)).transfer(address(vault), amountIn);
        vault.settle(IERC20(address(_WETH)), amountIn);
        vault.sendTo(state.launchToken, state.buyer, amountOut);

        return amountOut;
    }

    function _createAndRegister(
        RukusLaunchParams memory launch,
        LaunchState memory state,
        TokenConfig[] memory tokens,
        uint256 swapFeePercentage,
        bytes32 salt
    ) internal returns (address pool) {
        pool = _create(
            abi.encode(
                RukusLaunchPoolParams({
                    name: string.concat(launch.name, " Rukus Launch Pool"),
                    symbol: string.concat(launch.symbol, "-RUKUS"),
                    version: _poolVersion,
                    launchToken: state.launchToken,
                    launchTokenIndex: state.launchTokenIndex,
                    creatorFeeRecipient: launch.creatorFeeRecipient,
                    rukusFeeRecipient: _RUKUS_FEE_RECIPIENT,
                    rukusFeeShare: computeRukusFeeShare(swapFeePercentage),
                    graduatedSwapFeePercentage: launch.graduatedSwapFeePercentage,
                    graduatedCreatorFeePercentage: launch.graduatedCreatorFeePercentage,
                    curve: RukusLaunchCurveParams({ initialPrice: _INITIAL_PRICE, graduationPrice: _GRADUATION_PRICE })
                }),
                getVault()
            ),
            salt
        );

        // No pause manager. The pool is its own pool creator and its own swap fee manager: only it can change the fee
        // rate, and it does once, at graduation (see the contract notes).
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = pool;
        roleAccounts.swapFeeManager = pool;

        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = false;
        liquidityManagement.disableUnbalancedLiquidity = true;

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

    /// @dev The launch token and WETH, STANDARD without rate providers, sorted by address as the Vault requires.
    function _buildTokenConfig(
        IERC20 launchToken
    ) internal view returns (TokenConfig[] memory tokens, uint256 launchTokenIndex) {
        IERC20 weth = IERC20(address(_WETH));
        launchTokenIndex = address(launchToken) < address(weth) ? 0 : 1;

        tokens = new TokenConfig[](2);
        tokens[launchTokenIndex].token = launchToken;
        tokens[1 - launchTokenIndex].token = weth;
        for (uint256 i = 0; i < 2; ++i) {
            tokens[i].tokenType = TokenType.STANDARD;
            tokens[i].rateProvider = IRateProvider(address(0));
        }
    }
}
