// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IWETH } from "@bush.fi/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BondingReClammPool } from "../../../contracts/bonding-reclamm/BondingReClammPool.sol";
import { BondingReClammPoolFactory } from "../../../contracts/bonding-reclamm/BondingReClammPoolFactory.sol";
import {
    BondingPhase,
    BondingReClammCurveParams
} from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPool.sol";
import { BondingLaunchParams } from "../../../contracts/bonding-reclamm/interfaces/IBondingReClammPoolFactory.sol";

interface IRouterPermit2 {
    function getPermit2() external view returns (IPermit2);
}

/**
 * @notice A full launch against the live chain's own Vault, Router, WETH and protocol fee controller, on a fork: our
 * factory is deployed onto the fork and creates the 5 ETH preset. Skipped unless FORK_URL is set:
 * `FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract BondingReClammForkTest -vv`.
 * Addresses: Bush-fi/bush-deployments addresses/robinhoodchain.json.
 */
contract BondingReClammForkTest is Test {
    IVault internal constant VAULT = IVault(0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85);
    IRouter internal constant ROUTER = IRouter(0xa93179c0cd90B9D1569Cf20FD403a9A67540Ea4d);
    IWETH internal constant WETH = IWETH(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address internal constant FEE_CONTROLLER = 0xCC699Ad77Cdf45605C3eB776bF79599c1b80BF91;

    uint256 internal constant SUPPLY = 1e9 * 1e18;

    BondingReClammPoolFactory internal factory;
    BondingReClammPool internal pool;
    IERC20 internal launchToken;
    IERC20 internal weth = IERC20(address(WETH));
    address internal creator = makeAddr("creator");
    address internal trader = makeAddr("trader");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        // The 5 ETH preset factory: 1B tokens, 800M on the curve, 200M left for the pool.
        factory = new BondingReClammPoolFactory(
            VAULT,
            365 days,
            WETH,
            SUPPLY,
            BondingReClammCurveParams({ initialPrice: 0.0000000015625e18, graduationPrice: 0.000000025e18 }),
            "BondingReClamm Factory fork",
            "BondingReClamm Pool fork"
        );
        vm.deal(creator, 10 ether);
        vm.deal(trader, 100 ether);
    }

    function testLaunchOnTheLiveVault() public {
        assertEq(address(VAULT.getProtocolFeeController()), FEE_CONTROLLER, "Fee controller address");

        // Launch with a 0.1 ETH initial buy.
        vm.prank(creator);
        (address poolAddress, IERC20 token) = factory.create{ value: 0.1 ether }(
            BondingLaunchParams({
                name: "Fork Launch",
                symbol: "FORK",
                creatorFeeRecipient: feeRecipient,
                metadataURI: "ipfs://fork",
                minInitialBuyAmountOut: 1
            }),
            1e16,
            bytes32(0)
        );
        pool = BondingReClammPool(poolAddress);
        launchToken = token;
        assertGt(launchToken.balanceOf(creator), 0, "Initial buy");

        // Roles and fees on the real Vault and fee controller.
        PoolRoleAccounts memory roles = VAULT.getPoolRoleAccounts(poolAddress);
        assertEq(roles.poolCreator, poolAddress, "Pool creator");
        assertEq(roles.swapFeeManager, address(0), "Swap fee manager");
        assertEq(roles.pauseManager, address(0), "Pause manager");
        uint256 creatorFee = IProtocolFeeController(FEE_CONTROLLER).getPoolCreatorSwapFeePercentage(poolAddress);
        uint256 aggregate = VAULT.getPoolConfig(poolAddress).aggregateSwapFeePercentage;
        (uint256 protocolFee, ) = IProtocolFeeController(FEE_CONTROLLER).getPoolProtocolSwapFeeInfo(poolAddress);
        assertEq(creatorFee, 99.999e16, "Creator fee");
        assertGe(aggregate, 99.999e16, "Aggregate fee: fees would stay in the pool");

        // Trade through the live Router, in ETH.
        IPermit2 permit2 = IRouterPermit2(address(ROUTER)).getPermit2();
        vm.startPrank(trader);
        launchToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(launchToken), address(ROUTER), type(uint160).max, type(uint48).max);

        ROUTER.swapSingleTokenExactIn{ value: 1 ether }(poolAddress, weth, launchToken, 1 ether, 0, type(uint256).max, true, "");
        uint256 held = launchToken.balanceOf(trader);
        ROUTER.swapSingleTokenExactIn(poolAddress, launchToken, weth, held / 2, 0, type(uint256).max, true, "");

        // Complete the curve with exactly getMaxBuyAmount.
        uint256 maxOut = pool.getMaxBuyAmount();
        ROUTER.swapSingleTokenExactOut{ value: 10 ether }(poolAddress, weth, launchToken, maxOut, 10 ether, type(uint256).max, true, "");
        vm.stopPrank();
        assertEq(uint256(pool.getBondingPhase()), uint256(BondingPhase.COMPLETED), "Completed");

        uint256[] memory balances = VAULT.getCurrentLiveBalances(poolAddress);
        (, uint256 launchIndex) = pool.getLaunchToken();
        uint256 reserves = balances[1 - launchIndex];
        assertGe(reserves, 5 ether, "Below 5 ETH");
        assertLt(reserves, 5.01 ether, "Fees stayed in the pool");
        assertEq(balances[launchIndex], SUPPLY / 5 - SUPPLY / 5 / 1000, "Launch tokens left");

        // Next block: graduate (keeping the price), keep trading, pay the creator.
        uint256 priceAtCompletion = pool.computeCurrentLaunchTokenPrice();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        pool.graduate();
        assertEq(uint256(pool.getBondingPhase()), uint256(BondingPhase.GRADUATED), "Graduated");
        assertApproxEqRel(pool.computeCurrentLaunchTokenPrice(), priceAtCompletion, 1e6, "Graduation moved the price");
        assertApproxEqRel(priceAtCompletion, 0.000000025e18, 0.002e18, "Not at the graduation price");
        vm.prank(trader);
        ROUTER.swapSingleTokenExactIn{ value: 0.1 ether }(poolAddress, weth, launchToken, 0.1 ether, 0, type(uint256).max, true, "");

        pool.withdrawCreatorFees();
        assertGt(weth.balanceOf(feeRecipient), 0, "No WETH fees");
        assertGt(launchToken.balanceOf(feeRecipient), 0, "No launch token fees");

        console2.log("live fork: chain id", block.chainid);
        console2.log("  protocol swap fee % (1e18), creator %, aggregate %:", protocolFee, creatorFee, aggregate);
        console2.log("  reserves at completion (wei):", reserves);
        console2.log("  creator fee recipient WETH / launch tokens (wei):", weth.balanceOf(feeRecipient), launchToken.balanceOf(feeRecipient));
    }
}
