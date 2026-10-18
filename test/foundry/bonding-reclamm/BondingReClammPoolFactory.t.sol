// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { PoolRoleAccounts, TokenInfo, TokenType } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BondingReClammPool } from "../../../contracts/bonding-reclamm/BondingReClammPool.sol";
import { BondingReClammPoolFactory } from "../../../contracts/bonding-reclamm/BondingReClammPoolFactory.sol";
import {
    IBondingReClammPool,
    BondingPhase,
    BondingReClammCurveParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";
import {
    IBondingReClammPoolFactory,
    BondingLaunchParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPoolFactory.sol";
import { BondingReClammPoolFactoryLib } from "../../../contracts/bonding-reclamm/lib/BondingReClammPoolFactoryLib.sol";

import { BaseBondingReClammTest } from "../utils/BaseBondingReClammTest.sol";

contract BondingReClammPoolFactoryTest is BaseBondingReClammTest {
    function testCreatePool() public view {
        assertTrue(factory.isPoolFromFactory(pool), "Not from factory");
        assertEq(factory.getPoolVersion(), _POOL_VERSION, "Pool version");
        assertEq(BondingReClammPool(pool).version(), _POOL_VERSION, "Version on the pool");

        assertEq(vault.getHooksConfig(pool).hooksContract, pool, "The pool should be its own hook");
        assertTrue(vault.getPoolConfig(pool).liquidityManagement.disableUnbalancedLiquidity, "Unbalanced enabled");
        assertFalse(vault.getPoolConfig(pool).liquidityManagement.enableDonation, "Donation enabled");
        assertEq(IERC20Metadata(pool).name(), "Launch Bonding Pool", "Pool name");
        assertEq(IERC20Metadata(pool).symbol(), "LAUNCH-BRECLAMM", "Pool symbol");
    }

    /// @dev One call: a new token, all of it in the pool, the pool initialized and bonding, the BPT burned.
    function testCreateLaunchesTokenAndInitializesPool() public view {
        IERC20Metadata token = IERC20Metadata(address(launchToken));
        assertEq(token.name(), "Launch", "Token name");
        assertEq(token.symbol(), "LAUNCH", "Token symbol");
        assertEq(token.decimals(), 18, "Token decimals");
        assertEq(token.totalSupply(), _LAUNCH_SUPPLY, "Token supply");

        assertTrue(vault.isPoolInitialized(pool), "Not initialized");
        (uint256 launchBalance, uint256 quoteBalance) = _liveBalances();
        assertEq(launchBalance, _LAUNCH_SUPPLY, "Whole supply not in the pool");
        assertEq(quoteBalance, 0, "Quote in the pool");
        assertEq(uint256(BondingReClammPool(pool).getBondingPhase()), uint256(BondingPhase.BONDING), "Phase");

        assertEq(IERC20(pool).balanceOf(_BURN), IERC20(pool).totalSupply() - POOL_MINIMUM_TOTAL_SUPPLY, "BPT burned");

        (IERC20 poolLaunchToken, uint256 index) = BondingReClammPool(pool).getLaunchToken();
        assertEq(address(poolLaunchToken), address(launchToken), "Pool launch token");
        assertEq(index, _launchTokenIndex, "Launch index");

        (TokenType[] memory types, ) = _tokenTypes();
        assertEq(uint256(types[0]), uint256(TokenType.STANDARD), "Token 0 type");
        assertEq(uint256(types[1]), uint256(TokenType.STANDARD), "Token 1 type");
    }

    function testCreateEmitsLaunchCreated() public {
        BondingLaunchParams memory params = _launchParams();
        bytes32 salt = bytes32(uint256(0xbeef));
        address predicted = factory.getLaunchTokenAddress(params, address(this), salt);

        vm.expectEmit(false, true, true, true, address(factory));
        emit IBondingReClammPoolFactory.BondingLaunchCreated(
            address(0),
            IERC20(predicted),
            address(this),
            _LAUNCH_SUPPLY,
            "ipfs://launch",
            0,
            0
        );
        (, IERC20 token) = factory.create(params, _SWAP_FEE, salt);
        assertEq(address(token), predicted, "Predicted address");
    }

    /// @dev Different creators get different addresses for the same salt (no squatting someone else's launch).
    function testSaltIsPerCreator() public view {
        BondingLaunchParams memory params = _launchParams();
        assertTrue(
            factory.getLaunchTokenAddress(params, alice, bytes32(0)) !=
                factory.getLaunchTokenAddress(params, bob, bytes32(0)),
            "Same address for two creators"
        );
    }

    function testCreateBothLaunchTokenOrders() public {
        for (uint256 i = 0; i < 2; ++i) {
            (address newPool, IERC20 token) = _launch(i);
            (, uint256 index) = BondingReClammPool(newPool).getLaunchToken();
            assertEq(index, i, "Launch index");
            assertEq(address(vault.getPoolTokens(newPool)[i]), address(token), "Token order");
            assertEq(vault.getCurrentLiveBalances(newPool)[i], _LAUNCH_SUPPLY, "Supply in the pool");
        }
    }

    function testLaunchHookOnlyVault() public {
        BondingReClammPoolFactory.LaunchState memory state;
        state.pool = pool;
        state.launchToken = launchToken;
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, address(this)));
        factory.launchHook(state, _LAUNCH_SUPPLY);
    }

    /// @dev Roles are fixed: no pause manager, no swap fee manager (only governance can change the fee rate), and the
    /// pool is its own pool creator.
    function testRolesAreFixed() public view {
        PoolRoleAccounts memory roles = vault.getPoolRoleAccounts(pool);
        assertEq(roles.pauseManager, address(0), "Pause manager");
        assertEq(roles.swapFeeManager, address(0), "Swap fee manager");
        assertEq(roles.poolCreator, pool, "Pool creator");
    }

    /// @dev The quote token is always WETH: the launch can't be paired with a look-alike.
    function testQuoteTokenIsWeth() public view {
        assertEq(address(factory.getWeth()), address(weth), "Factory WETH");
        assertEq(address(quoteToken), address(weth), "Pool quote");
        IERC20[] memory tokens = vault.getPoolTokens(pool);
        assertTrue(address(tokens[0]) == address(weth) || address(tokens[1]) == address(weth), "WETH not in the pool");
    }

    function testConstructorRejectsZeroWeth() public {
        vm.expectRevert(IBondingReClammPoolFactory.InvalidWeth.selector);
        new BondingReClammPoolFactory(vault, 365 days, IWETH(address(0)), _LAUNCH_SUPPLY, _defaultCurve(), "f", "p");
    }

    /***************************************************************************
                              Creator's initial buy
    ***************************************************************************/

    /// @dev ETH sent to `create` buys launch tokens for the caller, in the same transaction as the launch.
    function testInitialBuyWithEth() public {
        uint256 ethIn = 1_000e18;
        vm.deal(bob, ethIn);
        uint256 snapshot = vm.snapshotState();

        // What a buy of 1,000 right after launch gets, for comparison.
        (address refPool, IERC20 refToken) = _launch(0);
        vm.prank(bob);
        uint256 expectedOut = router.swapSingleTokenExactIn(refPool, quoteToken, refToken, ethIn, 0, MAX_UINT256, false, "");
        vm.revertToState(snapshot);

        vm.prank(bob);
        (address newPool, IERC20 newToken) = factory.create{ value: ethIn }(_launchParams(), _SWAP_FEE, "buy");

        assertEq(newToken.balanceOf(bob), expectedOut, "Initial buy amount");
        assertEq(bob.balance, 0, "ETH not spent");
        assertEq(newToken.balanceOf(address(factory)), 0, "Factory kept tokens");
        assertEq(weth.balanceOf(address(factory)), 0, "Factory kept WETH");
        uint256 launchBalance = vault.getCurrentLiveBalances(newPool)[newToken < quoteToken ? 0 : 1];
        assertEq(launchBalance, _LAUNCH_SUPPLY - expectedOut, "Pool balance");
    }

    function testInitialBuyRespectsMinimumOut() public {
        BondingLaunchParams memory params = _launchParams();
        params.minInitialBuyAmountOut = type(uint256).max;
        vm.deal(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert();
        factory.create{ value: 1e18 }(params, _SWAP_FEE, "min");
    }

    /// @dev The initial buy is a normal buy: it can't go past the overshoot limit either.
    function testInitialBuyCannotOvershoot() public {
        vm.deal(bob, 1_000_000e18);
        vm.prank(bob);
        vm.expectRevert();
        factory.create{ value: 1_000_000e18 }(_launchParams(), _SWAP_FEE, "big");
    }

    /// @dev The factory fixes the supply and curve of every launch; `create` takes neither.
    function testLaunchConfigIsTheFactorys() public view {
        (uint256 supply, BondingReClammCurveParams memory curve) = factory.getLaunchConfig();
        assertEq(supply, _LAUNCH_SUPPLY, "Supply");
        assertEq(curve.initialPrice, _INITIAL_PRICE, "Initial price");
        assertEq(curve.graduationPrice, _GRADUATION_PRICE, "Graduation price");
        assertEq(launchToken.totalSupply(), _LAUNCH_SUPPLY, "Launch supply");
        assertEq(_brc().getBondingReClammPoolImmutableData().initialPrice, _INITIAL_PRICE, "Pool initial price");
        assertEq(_brc().getBondingReClammPoolImmutableData().graduationPrice, _GRADUATION_PRICE, "Pool graduation price");
    }

    function testConstructorRejectsInvalidSupply() public {
        vm.expectRevert(IBondingReClammPoolFactory.InvalidLaunchSupply.selector);
        _deployFactory(0, _defaultCurve());

        uint256 max = factory.MAX_LAUNCH_SUPPLY();
        vm.expectRevert(IBondingReClammPoolFactory.InvalidLaunchSupply.selector);
        _deployFactory(max + 1, _defaultCurve());

        // The bound itself is accepted, and launches.
        factory = _deployFactory(max, _defaultCurve());
        factory.create(_launchParams(), _SWAP_FEE, "max");
    }

    function testConstructorRejectsInvalidPrices() public {
        BondingReClammCurveParams memory curve = _defaultCurve();
        curve.initialPrice = 0;
        vm.expectRevert(IBondingReClammPool.InvalidBondingPrices.selector);
        _deployFactory(_LAUNCH_SUPPLY, curve);

        curve = _defaultCurve();
        curve.graduationPrice = curve.initialPrice;
        vm.expectRevert(IBondingReClammPool.InvalidBondingPrices.selector);
        _deployFactory(_LAUNCH_SUPPLY, curve);
    }

    function testConstructorRejectsBondingPriceRatioOutOfBounds() public {
        BondingReClammCurveParams memory curve = _defaultCurve();
        curve.graduationPrice = (curve.initialPrice * 1.005e18) / 1e18;
        vm.expectRevert(abi.encodeWithSelector(IBondingReClammPool.BondingPriceRatioOutOfBounds.selector, 1.005e18));
        _deployFactory(_LAUNCH_SUPPLY, curve);

        curve.graduationPrice = curve.initialPrice * 2e6;
        vm.expectRevert(abi.encodeWithSelector(IBondingReClammPool.BondingPriceRatioOutOfBounds.selector, 2e6 * 1e18));
        _deployFactory(_LAUNCH_SUPPLY, curve);

        // The bounds themselves are accepted, and launch.
        curve.graduationPrice = (curve.initialPrice * BondingReClammPoolFactoryLib.MIN_BONDING_PRICE_RATIO) / 1e18;
        _deployFactory(_LAUNCH_SUPPLY, curve).create(_launchParams(), _SWAP_FEE, "min");
        curve.graduationPrice = (curve.initialPrice * BondingReClammPoolFactoryLib.MAX_BONDING_PRICE_RATIO) / 1e18;
        _deployFactory(_LAUNCH_SUPPLY, curve).create(_launchParams(), _SWAP_FEE, "max");
    }

    function _tokenTypes() internal view returns (TokenType[] memory types, IERC20[] memory tokens) {
        TokenInfo[] memory info;
        (tokens, info, , ) = vault.getPoolTokenInfo(pool);
        types = new TokenType[](2);
        types[0] = info[0].tokenType;
        types[1] = info[1].tokenType;
    }
}
