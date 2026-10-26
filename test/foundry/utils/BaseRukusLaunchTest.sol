// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { console2 } from "forge-std/console2.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IVaultMock } from "@bush.fi/v3-interfaces/contracts/test/IVaultMock.sol";
import { WETHTestToken } from "@bush.fi/v3-solidity-utils/contracts/test/WETHTestToken.sol";
import { RouterMock } from "@bush.fi/v3-vault/contracts/test/RouterMock.sol";
import { BaseVaultTest } from "@bush.fi/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { RukusLaunchPool } from "../../../contracts/rukus-launch/RukusLaunchPool.sol";
import { RukusLaunchPoolFactory } from "../../../contracts/rukus-launch/RukusLaunchPoolFactory.sol";
import {
    RukusLaunchCurveParams,
    RukusLaunchPoolParams
} from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPool.sol";
import { RukusLaunchParams } from "../../../contracts/rukus-launch/interfaces/IRukusLaunchPoolFactory.sol";

/**
 * @notice Launches a token through the RukusLaunch factory, which deploys the token, creates the pool, initializes
 * it with the whole supply and burns the initial BPT, all in `create`. The quote token is always WETH. By default the
 * launch token sorts first; set `_launchTokenIndex = 1` in a constructor to make it sort second (the salt is searched
 * until the new token's address lands on that side of WETH).
 *
 * The default curve has round numbers (pump.fun's shape, ~16x instead of ~14.7x): 100M tokens, priced from 0.0001 to
 * 0.0016 quote. With r = sqrt(16) = 4, the curve's virtual launch balance is 100M / 15, it completes with
 * 100M / 5 = 20M tokens left, and raises 0.0016 * 20M = 32,000 quote (before fees).
 *
 * No test account starts with any launch tokens: like on mainnet, the only way to get them is to buy from the pool.
 *
 * Fork mode: with FORK_URL set (and optionally FORK_BLOCK), every test runs on a fork of Robinhood Chain, against its
 * live Vault, Router, Permit2, WETH and protocol fee controller (and its real protocol fee), instead of local mocks.
 * The few tests that need mock-only controls (pausing the Vault, forcing a 0% fee, granting governance roles) skip
 * there, saying why. `npm run test:rukus-launch:fork`.
 */
interface IRouterWithPermit2 {
    function getPermit2() external view returns (IPermit2);
}

contract BaseRukusLaunchTest is BaseVaultTest {
    // Robinhood Chain deployments (Bush-fi/bush-deployments addresses/robinhoodchain.json).
    address internal constant _LIVE_VAULT = 0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85;
    address internal constant _LIVE_ROUTER = 0xa93179c0cd90B9D1569Cf20FD403a9A67540Ea4d;
    address internal constant _LIVE_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    bool internal onFork;

    using FixedPoint for uint256;

    uint256 internal constant _SWAP_FEE = 1e16; // 1%, as on pump.fun
    string internal constant _POOL_VERSION = "RukusLaunch Pool v1";
    address internal constant _BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant _CREATOR_FEE_RECIPIENT = address(0xFEE5);
    address internal constant _RUKUS_FEE_RECIPIENT = address(0x2B5);
    // Rukus's cut of every trade: small enough for the 1% test fee to cover locally (0% protocol fee) and on the fork
    // (30%). Production uses 1% with a higher swap fee.
    uint256 internal constant _RUKUS_FEE_PERCENTAGE = 0.25e16;
    // From graduation on: the same swap fee, and fees still leave the pool (tests of other values set their own).
    uint256 internal constant _GRADUATED_SWAP_FEE = _SWAP_FEE;
    uint256 internal constant _GRADUATED_CREATOR_FEE_PERCENTAGE = 99.999e16;
    // The factory's floor on the graduated creator fee a launch may choose.
    uint256 internal constant _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE = 10e16;

    uint256 internal constant _LAUNCH_SUPPLY = 100e6 * 1e18;
    uint256 internal constant _INITIAL_PRICE = 0.0001e18;
    uint256 internal constant _GRADUATION_PRICE = 0.0016e18;

    uint256 internal _launchTokenIndex = 0;
    uint256 internal _quoteTokenIndex = 1;

    RukusLaunchPoolFactory internal factory;
    IERC20[] internal sortedTokens;
    IERC20 internal launchToken;
    IERC20 internal quoteToken;

    uint256 private _saltNumber;

    function setUp() public virtual override {
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length > 0) {
            uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
            if (forkBlock == 0) {
                vm.createSelectFork(forkUrl);
            } else {
                vm.createSelectFork(forkUrl, forkBlock);
            }
            onFork = true;
        }
        super.setUp();
    }

    /// @dev On a fork: swap the local Vault, Router, Permit2 and WETH for the live ones, and fund the test accounts with
    /// live WETH (approved to the live Router by the base setup right after this).
    function onAfterDeployMainContracts() internal virtual override {
        if (onFork == false) return;

        IERC20 localWeth = IERC20(address(weth));
        vault = IVaultMock(_LIVE_VAULT);
        router = RouterMock(payable(_LIVE_ROUTER));
        permit2 = IRouterWithPermit2(_LIVE_ROUTER).getPermit2();
        weth = WETHTestToken(payable(_LIVE_WETH));
        feeController = vault.getProtocolFeeController();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == localWeth) tokens[i] = IERC20(_LIVE_WETH);
        }

        address[6] memory accounts = [address(admin), lp, alice, bob, hacker, broke];
        for (uint256 i = 0; i < accounts.length; ++i) {
            deal(_LIVE_WETH, accounts[i], DEFAULT_BALANCE);
        }
    }

    /// @dev Skips a test that needs a local-mock control the live chain doesn't have.
    function _skipOnFork(string memory reason) internal {
        if (onFork) {
            console2.log("Skipped on the live-chain fork:", reason);
            vm.skip(true);
        }
    }

    function createPoolFactory() internal virtual override returns (address) {
        factory = _deployFactory(_LAUNCH_SUPPLY, _defaultCurve());
        vm.label(address(factory), "RukusLaunch Factory");
        return address(factory);
    }

    function createPool() internal virtual override returns (address newPool, bytes memory poolArgs) {
        (newPool, launchToken) = _launch(_launchTokenIndex);
        vm.label(newPool, "rukusLaunchPool");
        vm.label(address(launchToken), "launchToken");

        quoteToken = IERC20(address(weth));
        _quoteTokenIndex = 1 - _launchTokenIndex;
        delete sortedTokens;
        IERC20[] memory tokens = vault.getPoolTokens(newPool);
        sortedTokens.push(tokens[0]);
        sortedTokens.push(tokens[1]);

        poolArgs = abi.encode(
            RukusLaunchPoolParams({
                name: "Launch Rukus Launch Pool",
                symbol: "LAUNCH-RUKUS",
                version: _POOL_VERSION,
                launchToken: launchToken,
                launchTokenIndex: _launchTokenIndex,
                creatorFeeRecipient: _CREATOR_FEE_RECIPIENT,
                rukusFeeRecipient: _RUKUS_FEE_RECIPIENT,
                rukusFeeShare: factory.computeRukusFeeShare(_SWAP_FEE),
                graduatedSwapFeePercentage: _GRADUATED_SWAP_FEE,
                graduatedCreatorFeePercentage: _GRADUATED_CREATOR_FEE_PERCENTAGE,
                curve: _defaultCurve()
            }),
            vault
        );
    }

    /// @dev The factory already initialized the pool with the whole supply.
    function initPool() internal virtual override {}

    /***************************************************************************
                                    Helpers
    ***************************************************************************/

    /// @dev A factory whose launches all have this supply and curve (the factory fixes them; launchers can't).
    function _deployFactory(
        uint256 supply,
        RukusLaunchCurveParams memory curve
    ) internal returns (RukusLaunchPoolFactory newFactory) {
        newFactory = new RukusLaunchPoolFactory(
            vault,
            365 days,
            IWETH(address(weth)),
            _RUKUS_FEE_RECIPIENT,
            _RUKUS_FEE_PERCENTAGE,
            _MIN_GRADUATED_CREATOR_FEE_PERCENTAGE,
            supply,
            curve,
            "RukusLaunch Factory v1",
            _POOL_VERSION
        );
    }

    /// @dev Switches to a factory with this supply and curve, launches from it, and points the helpers at the launch.
    function _useFactory(uint256 supply, RukusLaunchCurveParams memory curve) internal {
        factory = _deployFactory(supply, curve);
        (pool, launchToken) = _launch(_launchTokenIndex);
    }

    /// @dev Creates a launch whose token sorts at `launchIndex` against WETH, and approves it for every test account.
    function _launch(
        uint256 launchIndex
    ) internal returns (address newPool, IERC20 newToken) {
        return _launch(launchIndex, _SWAP_FEE);
    }

    /// @dev As `_launch`, with this swap fee.
    function _launch(
        uint256 launchIndex,
        uint256 swapFeePercentage
    ) internal returns (address newPool, IERC20 newToken) {
        return _launch(launchIndex, swapFeePercentage, _launchParams());
    }

    /// @dev As `_launch`, with this swap fee and these launch params.
    function _launch(
        uint256 launchIndex,
        uint256 swapFeePercentage,
        RukusLaunchParams memory params
    ) internal returns (address newPool, IERC20 newToken) {
        bytes32 salt;
        while (true) {
            salt = bytes32(_saltNumber++);
            address predicted = factory.getLaunchTokenAddress(params, address(this), salt);
            if ((predicted < address(weth) ? 0 : 1) == launchIndex) break;
        }

        (newPool, newToken) = factory.create(params, swapFeePercentage, salt);
        _approveLaunchToken(newToken);
    }

    function _launchParams() internal pure returns (RukusLaunchParams memory) {
        return
            RukusLaunchParams({
                name: "Launch",
                symbol: "LAUNCH",
                creatorFeeRecipient: _CREATOR_FEE_RECIPIENT,
                metadataURI: "ipfs://launch",
                minInitialBuyAmountOut: 0,
                graduatedSwapFeePercentage: _GRADUATED_SWAP_FEE,
                graduatedCreatorFeePercentage: _GRADUATED_CREATOR_FEE_PERCENTAGE
            });
    }

    function _approveLaunchToken(IERC20 token) internal {
        address[6] memory accounts = [address(admin), lp, alice, bob, hacker, broke];
        for (uint256 i = 0; i < accounts.length; ++i) {
            vm.startPrank(accounts[i]);
            token.approve(address(permit2), type(uint256).max);
            permit2.approve(address(token), address(router), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    function _defaultCurve() internal pure returns (RukusLaunchCurveParams memory) {
        return RukusLaunchCurveParams({ initialPrice: _INITIAL_PRICE, graduationPrice: _GRADUATION_PRICE });
    }

    function _roleAccounts() internal view returns (PoolRoleAccounts memory) {
        // No pool creator: the factory makes the pool its own.
        return PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: admin, poolCreator: address(0) });
    }

    function _initAmounts(uint256 launchAmount) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[_launchTokenIndex] = launchAmount;
    }

    function _brc() internal view returns (RukusLaunchPool) {
        return RukusLaunchPool(pool);
    }

    /// @dev The stored virtual balances as (launch, quote).
    function _virtualLaunchAndQuote() internal view returns (uint256 virtualLaunch, uint256 virtualQuote) {
        (uint256 virtualA, uint256 virtualB) = _brc().getVirtualBalances();
        (virtualLaunch, virtualQuote) = _launchTokenIndex == 0 ? (virtualA, virtualB) : (virtualB, virtualA);
    }

    function _liveBalances() internal view returns (uint256 launchBalance, uint256 quoteBalance) {
        uint256[] memory balances = vault.getCurrentLiveBalances(pool);
        return (balances[_launchTokenIndex], balances[_quoteTokenIndex]);
    }

    function _buyExactIn(address buyer, uint256 quoteIn) internal returns (uint256 launchOut) {
        vm.prank(buyer);
        launchOut = router.swapSingleTokenExactIn(pool, quoteToken, launchToken, quoteIn, 0, MAX_UINT256, false, "");
    }

    function _buyExactOut(address buyer, uint256 launchOut) internal returns (uint256 quoteIn) {
        vm.prank(buyer);
        quoteIn = router.swapSingleTokenExactOut(pool, quoteToken, launchToken, launchOut, MAX_UINT128, MAX_UINT256, false, "");
    }

    function _sellExactIn(address seller, uint256 launchIn) internal returns (uint256 quoteOut) {
        vm.prank(seller);
        quoteOut = router.swapSingleTokenExactIn(pool, launchToken, quoteToken, launchIn, 0, MAX_UINT256, false, "");
    }

    /// @dev Buys exactly down to the graduation balance, completing the curve.
    function _completeCurve(address buyer) internal returns (uint256 quoteIn) {
        (uint256 launchBalance, ) = _liveBalances();
        quoteIn = _buyExactOut(buyer, launchBalance - _brc().getGraduationLaunchBalance());
    }

    /// @dev Launch tokens for tests that need some without moving the pool (stands in for tokens bought earlier).
    function _giveLaunchTokens(address to, uint256 amount) internal {
        deal(address(launchToken), to, launchToken.balanceOf(to) + amount);
    }
}
