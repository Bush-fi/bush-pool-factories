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

import { BondingReClammCurveParams, BondingReClammPoolParams } from "./interfaces/IBondingReClammPool.sol";
import { IBondingReClammPoolFactory, BondingLaunchParams } from "./interfaces/IBondingReClammPoolFactory.sol";
import { BondingReClammPoolFactoryLib } from "./lib/BondingReClammPoolFactoryLib.sol";
import { BondingReClammPool } from "./BondingReClammPool.sol";
import { BondingLaunchToken } from "./BondingLaunchToken.sol";

/**
 * @notice Launches a token, pump.fun style: one call deploys a new fixed-supply token, a `BondingReClammPool` that
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
 * of the pool); creator fees go to the launch's `creatorFeeRecipient`. The quote token is always WETH, so a launch
 * from this factory can't be paired with a look-alike token.
 */
contract BondingReClammPoolFactory is IBondingReClammPoolFactory, IPoolVersion, BasePoolFactory, Version {
    /// @notice Where the initial BPT goes: nobody holds the key, so the pool's liquidity is permanent.
    address public constant BPT_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The largest launch supply: 1 trillion tokens. Keeps the curve's virtual balances well inside uint128.
    uint256 public constant MAX_LAUNCH_SUPPLY = 1e12 * 1e18;

    IWETH private immutable _WETH;

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
     * @param launchSupply Every launch token's supply (18 decimals), all of it put in the pool
     * @param curve Every launch's bonding curve (initial and graduation prices)
     * @param factoryVersion Version string of the factory
     * @param poolVersion Version string of its pools
     */
    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        IWETH weth,
        uint256 launchSupply,
        BondingReClammCurveParams memory curve,
        string memory factoryVersion,
        string memory poolVersion
    ) BasePoolFactory(vault, pauseWindowDuration, type(BondingReClammPool).creationCode) Version(factoryVersion) {
        if (address(weth) == address(0)) {
            revert InvalidWeth();
        }
        if (launchSupply == 0 || launchSupply > MAX_LAUNCH_SUPPLY) {
            revert InvalidLaunchSupply();
        }
        BondingReClammPoolFactoryLib.validateCurveParams(curve);

        _WETH = weth;
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

    /// @notice The supply and bonding curve of every launch from this factory.
    function getLaunchConfig() external view returns (uint256 launchSupply, BondingReClammCurveParams memory curve) {
        return (_LAUNCH_SUPPLY, BondingReClammCurveParams({ initialPrice: _INITIAL_PRICE, graduationPrice: _GRADUATION_PRICE }));
    }

    /**
     * @notice Creates a launch: a new token, its pool against WETH, initialized with the whole supply, the initial BPT
     * burned, and, if ETH is sent, the creator's initial buy (the launch tokens go to the caller). The supply and the
     * curve are the factory's (`getLaunchConfig`).
     * @param launch The token's name and symbol, its creator fee recipient and metadata, and the initial buy's minimum
     * @param swapFeePercentage The swap fee rate (only governance can change it afterwards)
     * @param salt Salt for the token and pool addresses (combined with the caller and the chain id)
     * @return pool The new BondingReClammPool
     * @return launchToken The new token
     */
    function create(
        BondingLaunchParams memory launch,
        uint256 swapFeePercentage,
        bytes32 salt
    ) external payable returns (address pool, IERC20 launchToken) {
        launchToken = new BondingLaunchToken{ salt: _computeFinalSalt(salt) }(
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

        emit BondingLaunchCreated(
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
        BondingLaunchParams memory launch,
        address creator,
        bytes32 salt
    ) external view returns (address) {
        bytes32 finalSalt = keccak256(abi.encode(creator, block.chainid, salt));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BondingLaunchToken).creationCode,
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
        BondingLaunchParams memory launch,
        LaunchState memory state,
        TokenConfig[] memory tokens,
        uint256 swapFeePercentage,
        bytes32 salt
    ) internal returns (address pool) {
        pool = _create(
            abi.encode(
                BondingReClammPoolParams({
                    name: string.concat(launch.name, " Bonding Pool"),
                    symbol: string.concat(launch.symbol, "-BRECLAMM"),
                    version: _poolVersion,
                    launchToken: state.launchToken,
                    launchTokenIndex: state.launchTokenIndex,
                    creatorFeeRecipient: launch.creatorFeeRecipient,
                    curve: BondingReClammCurveParams({ initialPrice: _INITIAL_PRICE, graduationPrice: _GRADUATION_PRICE })
                }),
                getVault()
            ),
            salt
        );

        // No pause manager and no swap fee manager; the pool is its own pool creator (see the contract notes).
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = pool;

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
