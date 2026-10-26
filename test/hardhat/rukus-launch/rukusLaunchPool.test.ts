import { ethers } from 'hardhat';
import { expect } from 'chai';
import { Contract, ContractTransactionResponse } from 'ethers';
import { deploy, deployedAt } from '@helpers/contract';
import { sharedBeforeEach } from '@helpers/sharedBeforeEach';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { fp } from '@helpers/numbers';
import { MAX_UINT256, MAX_UINT160, MAX_UINT48, ZERO_BYTES32 } from '@helpers/constants';
import * as VaultDeployer from '@helpers/models/vault/VaultDeployer';
import TypesConverter from '@helpers/models/types/TypesConverter';
import { advanceTime, MONTH } from '@helpers/time';
import * as expectEvent from '@helpers/test/expectEvent';
import { deployPermit2 } from '@helpers/Permit2Deployer';

// End to end through the real Router, paying in ETH: a launch with the creator's initial buy, buys and sells for ETH,
// the buy that completes the curve (sized with getMaxBuyAmount), graduation on the next trade, trading after, and
// creator fees. Uses the 5 ETH preset: 1B tokens, 800M sold on the curve, 200M left for the pool, graduating at 5 ETH.
// Logs the gas of each step (total transaction gas).
describe('RukusLaunchPool (Router, ETH)', function () {
  const ROUTER_VERSION = 'Router v11';
  const SUPPLY = 10n ** 27n; // 1B, 18 decimals
  const INITIAL_PRICE = 1_562_500_000n; // 0.0000000015625 ETH
  const GRADUATION_PRICE = 25_000_000_000n; // 0.000000025 ETH
  const SWAP_FEE = fp(0.01);
  const PHASE = { BONDING: 0n, COMPLETED: 1n, GRADUATED: 2n };

  let vault: Contract;
  let router: Contract;
  let weth: Contract;
  let factory: Contract;
  let pool: Contract;
  let launch: Contract;
  let creator: SignerWithAddress;
  let bob: SignerWithAddress;
  let feeRecipient: SignerWithAddress;
  let rukusFeeRecipient: SignerWithAddress;
  const gas: Record<string, bigint> = {};

  const record = async (label: string, tx: Promise<ContractTransactionResponse>) => {
    const receipt = await (await tx).wait();
    gas[label] = receipt!.gasUsed;
    return receipt!;
  };

  const launchParams = (minInitialBuyAmountOut = 0n) => ({
    name: 'Launch',
    symbol: 'LAUNCH',
    creatorFeeRecipient: feeRecipient.address,
    metadataURI: 'ipfs://launch',
    minInitialBuyAmountOut,
    graduatedSwapFeePercentage: fp(0.005),
    graduatedCreatorFeePercentage: fp(0.5), // creator share of the swap fee after graduation (the rest stays in the pool)
  });

  before('setup signers', async () => {
    [, creator, bob, feeRecipient, rukusFeeRecipient] = await ethers.getSigners();
  });

  sharedBeforeEach('deploy vault, router, WETH and factory, and launch', async () => {
    vault = (await TypesConverter.toIVaultMock(await VaultDeployer.deployMock())) as unknown as Contract;
    weth = (await deploy('v3-solidity-utils/WETHTestToken')) as unknown as Contract;
    const permit2 = await deployPermit2();
    router = (await deploy('v3-vault/Router', { args: [vault, weth, permit2, ROUTER_VERSION] })) as unknown as Contract;
    factory = (await deploy('RukusLaunchPoolFactory', {
      // The factory fixes every launch's supply and curve (the 5 ETH preset).
      args: [
        vault,
        MONTH * 12,
        weth,
        rukusFeeRecipient.address,
        fp(0.0025), // Rukus's cut of every trade (the 1% swap fee covers it)
        fp(0.1), // the lowest creator share of the swap fee after graduation a launch may choose
        SUPPLY,
        { initialPrice: INITIAL_PRICE, graduationPrice: GRADUATION_PRICE },
        'factory v1',
        'pool v1',
      ],
    })) as unknown as Contract;

    // The creator launches with a 0.1 ETH initial buy, in the same transaction.
    const receipt = await record(
      'create, with a 0.1 ETH initial buy',
      factory.connect(creator).create(launchParams(1n), SWAP_FEE, ZERO_BYTES32, { value: fp(0.1) })
    );
    const event = expectEvent.inReceipt(receipt, 'RukusLaunchCreated');
    pool = (await deployedAt('RukusLaunchPool', event.args.pool)) as unknown as Contract;
    launch = (await deployedAt('RukusLaunchToken', event.args.launchToken)) as unknown as Contract;
    expect(event.args.metadataURI).to.equal('ipfs://launch');
    expect(await launch.contractURI()).to.equal('ipfs://launch');
    expect(event.args.initialBuyAmountIn).to.equal(fp(0.1));
    expect(await launch.balanceOf(creator.address)).to.equal(event.args.initialBuyAmountOut);

    // Selling launch tokens through the Router takes a Permit2 approval.
    await launch.connect(bob).approve(permit2, MAX_UINT256);
    await permit2.connect(bob).approve(launch, router, MAX_UINT160, MAX_UINT48);
  });

  const buyWithEth = (signer: SignerWithAddress, eth: bigint) =>
    router.connect(signer).swapSingleTokenExactIn(pool, weth, launch, eth, 0n, MAX_UINT256, true, '0x', { value: eth });

  it('runs a launch from creation to graduation, paying in ETH', async () => {
    expect(await pool.getBondingPhase()).to.equal(PHASE.BONDING);
    expect(await pool.getCreatorFeeRecipient()).to.equal(feeRecipient.address);
    expect(await pool.getRukusFeeRecipient()).to.equal(rukusFeeRecipient.address);

    // Buy and sell for ETH while bonding.
    await record('bonding buy, 1 ETH in', buyWithEth(bob, fp(1)));
    await record('bonding buy, 0.5 ETH in', buyWithEth(bob, fp(0.5)));
    const held: bigint = await launch.balanceOf(bob.address);
    const ethBefore = await ethers.provider.getBalance(bob.address);
    await record(
      'bonding sell, for ETH',
      router.connect(bob).swapSingleTokenExactIn(pool, launch, weth, held / 2n, 0n, MAX_UINT256, true, '0x')
    );
    expect(await ethers.provider.getBalance(bob.address)).to.be.gt(ethBefore - fp(0.01)); // got ETH back (less gas)

    // Complete the curve: buy exactly getMaxBuyAmount (the overshoot limit), with ETH; the Router refunds the rest.
    const maxOut: bigint = await pool.getMaxBuyAmount();
    await record(
      'buy that completes the curve (exact out)',
      router.connect(bob).swapSingleTokenExactOut(pool, weth, launch, maxOut, fp(10), MAX_UINT256, true, '0x', { value: fp(10) })
    );
    expect(await pool.getBondingPhase()).to.equal(PHASE.COMPLETED);
    expect(await pool.getMaxBuyAmount()).to.equal(0n);

    // 5 ETH of real reserves, 200M (less the 0.1% overshoot) launch tokens left, at the graduation price.
    const { balancesLiveScaled18 } = await pool.getRukusLaunchPoolDynamicData();
    const [launchIndex, wethIndex] = (await launch.getAddress()).toLowerCase() < (await weth.getAddress()).toLowerCase() ? [0, 1] : [1, 0];
    expect(balancesLiveScaled18[launchIndex]).to.equal((SUPPLY / 5n) - SUPPLY / 5n / 1000n);
    const reserves = balancesLiveScaled18[wethIndex];
    expect(reserves).to.be.gt(fp(5)).and.lt(fp(5.01));

    // The next trade, in a later block, graduates the pool first.
    await advanceTime(1);
    await record('first buy after completion (graduates)', buyWithEth(bob, fp(0.1)));
    expect(await pool.getBondingPhase()).to.equal(PHASE.GRADUATED);
    await record('graduated buy, 0.1 ETH in', buyWithEth(bob, fp(0.1)));
    await record(
      'graduated sell, for ETH',
      router.connect(bob).swapSingleTokenExactIn(pool, launch, weth, (await launch.balanceOf(bob.address)) / 10n, 0n, MAX_UINT256, true, '0x')
    );

    // Creator fees: paid in WETH (buys) and launch tokens (sells), to the recipient.
    await record('withdrawCreatorFees', pool.connect(bob).withdrawCreatorFees());
    expect(await weth.balanceOf(feeRecipient.address)).to.be.gt(0n);
    expect(await launch.balanceOf(feeRecipient.address)).to.be.gt(0n);
    expect(await weth.balanceOf(rukusFeeRecipient.address)).to.be.gt(0n);
    expect(await launch.balanceOf(rukusFeeRecipient.address)).to.be.gt(0n);
    expect(await weth.balanceOf(await pool.getAddress())).to.equal(0n);
  });

  it('rejects a completing buy past the overshoot limit, and an initial buy below its minimum', async () => {
    const maxOut: bigint = await pool.getMaxBuyAmount();
    await expect(
      router.connect(bob).swapSingleTokenExactOut(pool, weth, launch, maxOut + 1n, fp(10), MAX_UINT256, true, '0x', { value: fp(10) })
    ).to.be.revertedWithCustomError(pool, 'GraduationBuyTooLarge');

    await expect(
      factory.connect(creator).create(launchParams(SUPPLY), SWAP_FEE, ZERO_BYTES32, { value: fp(0.1) })
    ).to.be.reverted;
  });

  after('gas', () => {
    console.log('\n      Gas (total transaction gas):');
    for (const [label, used] of Object.entries(gas)) {
      console.log(`        ${label.padEnd(44)} ${used.toLocaleString('en-US')}`);
    }
  });
});
