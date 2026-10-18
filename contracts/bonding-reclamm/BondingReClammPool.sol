// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IProtocolFeeController} from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import {ISwapFeePercentageBounds} from "@bush.fi/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import {IUnbalancedLiquidityInvariantRatioBounds} from "@bush.fi/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import {IBasePool} from "@bush.fi/v3-interfaces/contracts/vault/IBasePool.sol";
import {IHooks} from "@bush.fi/v3-interfaces/contracts/vault/IHooks.sol";
import {IVault} from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import {FixedPoint} from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {Version} from "@bush.fi/v3-solidity-utils/contracts/helpers/Version.sol";
import {BushPoolToken} from "@bush.fi/v3-vault/contracts/BushPoolToken.sol";
import {BaseHooks} from "@bush.fi/v3-vault/contracts/BaseHooks.sol";
import {PoolInfo} from "@bush.fi/v3-pool-utils/contracts/PoolInfo.sol";

import {ReClammMath, a, b} from "../reclamm/lib/ReClammMath.sol";
import {BondingReClammMath} from "./lib/BondingReClammMath.sol";
import {BondingReClammPoolFactoryLib} from "./lib/BondingReClammPoolFactoryLib.sol";
import "./interfaces/IBondingReClammPool.sol";

/**
 * @notice A token launch pool: a pump.fun-style bonding curve that graduates, in place, into a full-range pool.
 * @dev Two tokens, the launch token and a quote token. The pool is initialized with launch tokens only and sells them
 * along a constant-product curve with fixed virtual balances (`(Rt + Vt)(Rq + Vq) = k`), from `initialPrice` to
 * `graduationPrice`. Buys and sells both run on the curve, and liquidity is locked.
 *
 * When a buy takes the launch balance to the graduation balance, the curve is complete. Nothing trades for the rest
 * of that block; the first interaction in a later block graduates the pool: the virtual balances are re-solved, at the
 * current price, for a range of `GRADUATED_PRICE_RATIO` (1e12x: from a millionth to a million times the graduation
 * price). That makes the virtual balances tiny next to the real ones, so the graduated pool trades like a full-range
 * constant-product (50/50) pool, within ~0.1% on depth, while keeping the price exactly at graduation. (Zero virtual
 * balances would be a true full range, but could not keep the price when the pool graduates slightly unbalanced, as
 * fees and overshooting buys leave it, and ReClamm's maths needs them non-zero.)
 *
 * After graduation the virtual balances never change with time: the range does not move, narrow or re-center. They
 * only scale with proportional adds and removes (keeping the price), which are open after graduation.
 *
 * The one-block freeze: graduating swaps the curve's large virtual reserves for tiny ones, which changes the depth
 * around the price (here it gets shallower). Freezing for the rest of the completing block keeps any trade from
 * spanning both shapes in one transaction (e.g., a flash loan that buys out the curve, graduates and trades back).
 *
 * Fees: the pool is its own pool creator, and sets the creator share of the swap fee to the 99.999% maximum when it is
 * initialized, for good. The Vault takes the protocol and creator shares out of every trade before crediting the pool,
 * so (but for the 0.001% left) no fee stays in the pool: the bonding curve stays exact, the pool graduates balanced, and
 * the graduated range never widens. Creator fees go to `creatorFeeRecipient` (`withdrawCreatorFees`).
 *
 * The pool is its own hook (initialization and liquidity), like ReClammPool, and reuses ReClammMath for the swap maths.
 */
contract BondingReClammPool is
    IBondingReClammPool,
    BushPoolToken,
    PoolInfo,
    Version,
    BaseHooks
{
    using FixedPoint for uint256;
    using SafeCast for *;
    using SafeERC20 for IERC20;

    /// @notice The creator share of the swap fee: the fee controller's maximum, set once at initialization.
    uint256 public constant CREATOR_FEE_PERCENTAGE = 99.999e16;

    /// @notice The width the graduated virtual balances are solved for: max price / min price = 1e12.
    uint256 public constant GRADUATED_PRICE_RATIO = 1e12 * 1e18;

    // sqrt(GRADUATED_PRICE_RATIO), as the graduation solve takes it.
    uint256 internal constant _GRADUATED_SQRT_PRICE_RATIO = 1e6 * 1e18;

    /**
     * @notice How far past the graduation balance the buy that completes the curve may go, as a fraction of that balance:
     * 0.1%. An overshooting buy leaves the pool quote-heavy at graduation, and keeping the price then takes a larger
     * virtual launch balance, which lowers the top of the graduated range (1% fee: ~123,000x above the graduation
     * price with no overshoot, ~92,000x at 0.1%, ~17,000x at 1%, ~38x at 30%). pump.fun caps its last buy the same way.
     */
    uint256 public constant MAX_GRADUATION_OVERSHOOT = 0.1e16;

    // Same bounds as ReClammPool. A bonding curve usually charges much more (pump.fun: 1%).
    uint256 internal constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint256 internal constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%

    IERC20 internal immutable _LAUNCH_TOKEN;
    uint256 internal immutable _LAUNCH_TOKEN_INDEX;

    uint256 internal immutable _INITIAL_PRICE;
    uint256 internal immutable _GRADUATION_PRICE;

    address internal immutable _CREATOR_FEE_RECIPIENT;

    // The virtual balances: the bonding curve's (fixed) until graduation, then the graduated ones (fixed but for
    // proportional adds and removes).
    uint128 internal _virtualBalanceA;
    uint128 internal _virtualBalanceB;

    // Bonding state.
    uint128 internal _graduationLaunchBalance;
    uint32 internal _bondingCompletedAt;
    bool internal _graduated;

    modifier onlyWhenInitialized() {
        require(_vault.isPoolInitialized(address(this)), PoolNotInitialized());
        _;
    }

    constructor(
        BondingReClammPoolParams memory params,
        IVault vault
    )
        BushPoolToken(vault, params.name, params.symbol)
        PoolInfo(vault)
        Version(params.version)
    {
        BondingReClammPoolFactoryLib.validateCurveParams(params.curve);
        if (
            params.launchTokenIndex > 1 ||
            address(params.launchToken) == address(0)
        ) {
            revert InvalidLaunchToken();
        }
        if (params.creatorFeeRecipient == address(0)) {
            revert InvalidCreatorFeeRecipient();
        }
        _CREATOR_FEE_RECIPIENT = params.creatorFeeRecipient;

        _LAUNCH_TOKEN = params.launchToken;
        _LAUNCH_TOKEN_INDEX = params.launchTokenIndex;

        _INITIAL_PRICE = params.curve.initialPrice;
        _GRADUATION_PRICE = params.curve.graduationPrice;
    }

    /********************************************************
                    Base Pool Functions
    ********************************************************/

    /// @inheritdoc IBasePool
    function computeInvariant(
        uint256[] memory balancesScaled18,
        Rounding rounding
    ) public view returns (uint256) {
        return
            ReClammMath.computeInvariant(
                balancesScaled18,
                _virtualBalanceA,
                _virtualBalanceB,
                rounding
            );
    }

    /// @inheritdoc IBasePool
    function computeBalance(
        uint256[] memory,
        uint256,
        uint256
    ) external pure returns (uint256) {
        // The pool does not allow unbalanced adds and removes, so this function does not need to be implemented.
        revert NotImplemented();
    }

    /// @inheritdoc IBasePool
    function onSwap(
        PoolSwapParams memory request
    ) public onlyVault returns (uint256 amountCalculatedScaled18) {
        if (_graduated == false && _bondingCompletedAt != 0) {
            // The curve completed in an earlier block (`_graduate` reverts if it was this one).
            _graduate(request.balancesScaled18);
        }

        uint256 launchAmountOut;
        if (request.kind == SwapKind.EXACT_IN) {
            amountCalculatedScaled18 = ReClammMath.computeOutGivenIn(
                request.balancesScaled18,
                _virtualBalanceA,
                _virtualBalanceB,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
            );
            launchAmountOut = amountCalculatedScaled18;
        } else {
            amountCalculatedScaled18 = ReClammMath.computeInGivenOut(
                request.balancesScaled18,
                _virtualBalanceA,
                _virtualBalanceB,
                request.indexIn,
                request.indexOut,
                request.amountGivenScaled18
            );
            launchAmountOut = request.amountGivenScaled18;
        }

        // While bonding: a buy that takes the launch balance to the graduation balance completes the curve. The launch
        // token is never charged a fee on the way out (the Vault takes fees from the amount in), so the balance it
        // leaves is exact. It may go past the graduation balance by at most MAX_GRADUATION_OVERSHOOT of it.
        if (
            _bondingCompletedAt == 0 && request.indexOut == _LAUNCH_TOKEN_INDEX
        ) {
            uint256 launchBalanceAfter = request.balancesScaled18[
                _LAUNCH_TOKEN_INDEX
            ] - launchAmountOut;
            if (launchBalanceAfter <= _graduationLaunchBalance) {
                uint256 minLaunchBalance = _minLaunchBalance();
                if (launchBalanceAfter < minLaunchBalance) {
                    revert GraduationBuyTooLarge(
                        request.balancesScaled18[_LAUNCH_TOKEN_INDEX] -
                            minLaunchBalance
                    );
                }

                _bondingCompletedAt = block.timestamp.toUint32();
                emit BondingCurveCompleted(launchBalanceAfter);
            }
        }
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMinimumSwapFeePercentage() external pure returns (uint256) {
        return _MIN_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc ISwapFeePercentageBounds
    function getMaximumSwapFeePercentage() external pure returns (uint256) {
        return _MAX_SWAP_FEE_PERCENTAGE;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMinimumInvariantRatio() external pure returns (uint256) {
        // Required by `IBasePool`, but unused: liquidity can only be added or removed proportionally.
        return 0;
    }

    /// @inheritdoc IUnbalancedLiquidityInvariantRatioBounds
    function getMaximumInvariantRatio() external pure returns (uint256) {
        // Required by `IBasePool`, but unused: liquidity can only be added or removed proportionally.
        return 0;
    }

    /// @inheritdoc IRateProvider
    function getRate() public pure override returns (uint256) {
        revert BondingReClammPoolBptRateUnsupported();
    }

    /********************************************************
                        Hook Functions
    ********************************************************/

    /// @inheritdoc IHooks
    function getHookFlags()
        public
        pure
        override
        returns (HookFlags memory hookFlags)
    {
        hookFlags.shouldCallBeforeInitialize = true;
        hookFlags.shouldCallAfterInitialize = true;
        hookFlags.shouldCallBeforeAddLiquidity = true;
        hookFlags.shouldCallBeforeRemoveLiquidity = true;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenConfig,
        LiquidityManagement calldata liquidityManagement
    ) public view override returns (bool) {
        // Only for this pool, so that no other pool can register these state-changing hooks (see ReClammPool).
        return
            pool == address(this) &&
            tokenConfig.length == 2 &&
            tokenConfig[_LAUNCH_TOKEN_INDEX].token == _LAUNCH_TOKEN &&
            liquidityManagement.disableUnbalancedLiquidity &&
            liquidityManagement.enableDonation == false;
    }

    /// @inheritdoc IHooks
    function onBeforeInitialize(
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        if (_vault.isPoolInitialized(address(this))) {
            revert PoolAlreadyInitialized();
        }

        // The curve starts with no quote: every quote token in the pool was paid by a buyer.
        if (balancesScaled18[1 - _LAUNCH_TOKEN_INDEX] != 0) {
            revert QuoteBalanceNotZero();
        }

        uint256 launchBalance = balancesScaled18[_LAUNCH_TOKEN_INDEX];
        (
            uint256 virtualLaunch,
            uint256 virtualQuote,
            uint256 graduationLaunchBalance
        ) = BondingReClammMath.computeBondingCurve(
                launchBalance,
                _INITIAL_PRICE,
                _GRADUATION_PRICE
            );

        _graduationLaunchBalance = graduationLaunchBalance.toUint128();
        if (_LAUNCH_TOKEN_INDEX == a) {
            _setVirtualBalances(virtualLaunch, virtualQuote);
        } else {
            _setVirtualBalances(virtualQuote, virtualLaunch);
        }

        emit BondingCurveStarted(launchBalance, graduationLaunchBalance);

        return true;
    }

    /**
     * @inheritdoc IHooks
     * @dev Sets the creator fee (the pool is its own pool creator: the factory registers it so). It has to be here, not
     * in `onBeforeInitialize`: the Vault stores the pool config it loaded before that hook when it marks the pool
     * initialized, which would silently undo the change. Nothing has been traded yet, so the fee controller has no fees
     * to collect, and the call doesn't touch the Vault's reentrancy-guarded paths.
     */
    function onAfterInitialize(
        uint256[] memory,
        uint256,
        bytes memory
    ) public override onlyVault returns (bool) {
        _vault.getProtocolFeeController().setPoolCreatorSwapFeePercentage(
            address(this),
            CREATOR_FEE_PERCENTAGE
        );
        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeAddLiquidity(
        address,
        address pool,
        AddLiquidityKind,
        uint256[] memory,
        uint256 exactBptAmountOut,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        require(pool == address(this), InvalidPoolArgument(pool));
        _ensureGraduated(balancesScaled18);

        // As in ReClammPool: scale the virtual balances with the real ones, keeping the price. Rounding down favors
        // the Vault in swaps; proportional adds do not use the virtual balances.
        uint256 poolTotalSupply = _vault.totalSupply(pool);
        uint256 newPoolTotalSupply = exactBptAmountOut + poolTotalSupply;
        _setVirtualBalances(
            (uint256(_virtualBalanceA) * newPoolTotalSupply) / poolTotalSupply,
            (uint256(_virtualBalanceB) * newPoolTotalSupply) / poolTotalSupply
        );

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind,
        uint256 exactBptAmountIn,
        uint256[] memory,
        uint256[] memory balancesScaled18,
        bytes memory
    ) public override onlyVault returns (bool) {
        require(pool == address(this), InvalidPoolArgument(pool));
        _ensureGraduated(balancesScaled18);

        // As in ReClammPool (including the note there on the round-trip fee after an add in the same transaction).
        uint256 poolTotalSupply = _vault.totalSupply(pool);
        uint256 remainingSupply = poolTotalSupply - exactBptAmountIn;
        uint256 virtualBalanceA = (uint256(_virtualBalanceA) *
            remainingSupply) / poolTotalSupply;
        uint256 virtualBalanceB = (uint256(_virtualBalanceB) *
            remainingSupply) / poolTotalSupply;

        // A zero virtual balance would let the price reach 0 or infinity and leave the pool unable to quote one side.
        if (virtualBalanceA == 0 || virtualBalanceB == 0) {
            revert ZeroVirtualBalance();
        }

        _setVirtualBalances(virtualBalanceA, virtualBalanceB);

        return true;
    }

    /********************************************************
                        Graduation
    ********************************************************/

    /// @inheritdoc IBondingReClammPool
    function graduate() external onlyWhenInitialized {
        if (_graduated || _bondingCompletedAt == 0) {
            revert NotReadyToGraduate();
        }

        _graduate(_vault.getCurrentLiveBalances(address(this)));
    }

    /// @inheritdoc IBondingReClammPool
    function withdrawCreatorFees() external {
        IProtocolFeeController controller = _vault.getProtocolFeeController();
        controller.collectAggregateFees(address(this));
        controller.withdrawPoolCreatorFees(
            address(this),
            _CREATOR_FEE_RECIPIENT
        );

        // The pool holds no tokens of its own (the Vault holds its balances), so anything here is creator fees paid to
        // the pool as pool creator.
        IERC20[] memory tokens = _vault.getPoolTokens(address(this));
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 balance = tokens[i].balanceOf(address(this));
            if (balance > 0) {
                tokens[i].safeTransfer(_CREATOR_FEE_RECIPIENT, balance);
            }
        }
    }

    /********************************************************
                        Getters
    ********************************************************/

    /// @inheritdoc IBondingReClammPool
    function getMaxBuyAmount() external view onlyWhenInitialized returns (uint256) {
        uint256 launchBalance = _vault.getCurrentLiveBalances(address(this))[_LAUNCH_TOKEN_INDEX];

        if (_bondingCompletedAt == 0) {
            uint256 minLaunchBalance = _minLaunchBalance();
            return launchBalance > minLaunchBalance ? launchBalance - minLaunchBalance : 0;
        }
        if (_graduated == false && block.timestamp <= _bondingCompletedAt) {
            return 0;
        }
        return launchBalance;
    }

    /// @inheritdoc IBondingReClammPool
    function getCreatorFeeRecipient() external view returns (address) {
        return _CREATOR_FEE_RECIPIENT;
    }

    /// @inheritdoc IBondingReClammPool
    function getBondingPhase() public view returns (BondingPhase) {
        if (_graduated) {
            return BondingPhase.GRADUATED;
        }
        return
            _bondingCompletedAt == 0
                ? BondingPhase.BONDING
                : BondingPhase.COMPLETED;
    }

    /// @inheritdoc IBondingReClammPool
    function getLaunchToken() external view returns (IERC20, uint256) {
        return (_LAUNCH_TOKEN, _LAUNCH_TOKEN_INDEX);
    }

    /// @inheritdoc IBondingReClammPool
    function getBondingCompletedAt() external view returns (uint256) {
        return _bondingCompletedAt;
    }

    /// @inheritdoc IBondingReClammPool
    function getGraduationLaunchBalance() external view returns (uint256) {
        return _graduationLaunchBalance;
    }

    /// @inheritdoc IBondingReClammPool
    function getVirtualBalances() external view returns (uint256, uint256) {
        return (_virtualBalanceA, _virtualBalanceB);
    }

    /// @inheritdoc IBondingReClammPool
    function computeCurrentLaunchTokenPrice()
        external
        view
        onlyWhenInitialized
        returns (uint256)
    {
        uint256[] memory balancesScaled18 = _vault.getCurrentLiveBalances(
            address(this)
        );
        uint256 totalA = balancesScaled18[a] + _virtualBalanceA;
        uint256 totalB = balancesScaled18[b] + _virtualBalanceB;

        // The price of A in B is totalB / totalA.
        return
            _LAUNCH_TOKEN_INDEX == a
                ? totalB.divDown(totalA)
                : totalA.divDown(totalB);
    }

    /// @inheritdoc IBondingReClammPool
    function getBondingReClammPoolDynamicData()
        external
        view
        returns (BondingReClammPoolDynamicData memory data)
    {
        data.balancesLiveScaled18 = _vault.getCurrentLiveBalances(
            address(this)
        );
        data.staticSwapFeePercentage = _vault.getStaticSwapFeePercentage(
            address(this)
        );
        data.totalSupply = totalSupply();
        data.isPoolInitialized = _vault.isPoolInitialized(address(this));

        data.phase = getBondingPhase();
        data.bondingCompletedAt = _bondingCompletedAt;
        data.graduationLaunchBalance = _graduationLaunchBalance;

        data.virtualBalances = new uint256[](2);
        data.virtualBalances[a] = _virtualBalanceA;
        data.virtualBalances[b] = _virtualBalanceB;
    }

    /// @inheritdoc IBondingReClammPool
    function getBondingReClammPoolImmutableData()
        external
        view
        returns (BondingReClammPoolImmutableData memory data)
    {
        data.tokens = _vault.getPoolTokens(address(this));
        (data.decimalScalingFactors, ) = _vault.getPoolTokenRates(
            address(this)
        );
        data.launchToken = _LAUNCH_TOKEN;
        data.launchTokenIndex = _LAUNCH_TOKEN_INDEX;
        data.initialPrice = _INITIAL_PRICE;
        data.graduationPrice = _GRADUATION_PRICE;
        data.graduatedPriceRatio = GRADUATED_PRICE_RATIO;
        data.creatorFeeRecipient = _CREATOR_FEE_RECIPIENT;
        data.creatorFeePercentage = CREATOR_FEE_PERCENTAGE;
        data.minSwapFeePercentage = _MIN_SWAP_FEE_PERCENTAGE;
        data.maxSwapFeePercentage = _MAX_SWAP_FEE_PERCENTAGE;
    }

    /********************************************************
                        Internal Helpers
    ********************************************************/

    /// @dev The lowest launch balance a buy may leave while bonding: the graduation balance, less the overshoot allowed.
    function _minLaunchBalance() internal view returns (uint256) {
        uint256 graduationLaunchBalance = _graduationLaunchBalance;
        return
            graduationLaunchBalance -
            graduationLaunchBalance.mulDown(MAX_GRADUATION_OVERSHOOT);
    }

    /// @dev Liquidity operations are only open once graduated; a completed curve graduates here if it can.
    function _ensureGraduated(uint256[] memory balancesScaled18) internal {
        if (_graduated) {
            return;
        }
        if (_bondingCompletedAt == 0) {
            revert LiquidityLockedUntilGraduation();
        }
        _graduate(balancesScaled18);
    }

    /**
     * @dev Re-solves the virtual balances at the current price for a range of `GRADUATED_PRICE_RATIO`, so that the
     * swap or liquidity operation running this sees them. The balances are those the completing buy left, plus
     * nothing: swaps and liquidity are frozen until graduation, and donations are disabled.
     */
    function _graduate(uint256[] memory balancesScaled18) internal {
        require(block.timestamp > _bondingCompletedAt, GraduationPending());

        (uint256 virtualBalanceA, uint256 virtualBalanceB) = BondingReClammMath
            .computeGraduationVirtualBalances(
                balancesScaled18,
                _virtualBalanceA,
                _virtualBalanceB,
                _GRADUATED_SQRT_PRICE_RATIO
            );

        _graduated = true;
        _setVirtualBalances(virtualBalanceA, virtualBalanceB);

        emit Graduated(virtualBalanceA, virtualBalanceB, GRADUATED_PRICE_RATIO);
        _vault.emitAuxiliaryEvent(
            "Graduated",
            abi.encode(virtualBalanceA, virtualBalanceB, GRADUATED_PRICE_RATIO)
        );
    }

    function _setVirtualBalances(
        uint256 virtualBalanceA,
        uint256 virtualBalanceB
    ) internal {
        _virtualBalanceA = virtualBalanceA.toUint128();
        _virtualBalanceB = virtualBalanceB.toUint128();

        emit VirtualBalancesUpdated(virtualBalanceA, virtualBalanceB);
        _vault.emitAuxiliaryEvent(
            "VirtualBalancesUpdated",
            abi.encode(virtualBalanceA, virtualBalanceB)
        );
    }
}
