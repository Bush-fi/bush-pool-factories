// Math-check adapter: creates a BondingReClammPool through its factory and reports the fields the maths need.
// See maths/check/README.md.
//
// The pool's maths depends on its phase, so there is one variant per phase, each set up after initialization
// (`afterInitialize`): part way along the bonding curve; curve completed (exactly, and with a buy overshooting by the
// most allowed, which graduates slightly unbalanced) and queried a block later, so every query graduates the pool first; and graduated, pushed
// hard and queried a month later (the graduated pool doesn't move with time, so this must price as if right away).

import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import { FactoryAdapter } from '../src/types';
import { getArtifact } from '@helpers/contract';

const HOUR = 3600;
const DAY = 24 * HOUR;


// 1B launch tokens (18 decimals, minted by the factory), priced from 0.00003 to 0.00048 quote (16x, so r = 4): the
// curve completes with 200M tokens left, having raised ~96,000 quote.
const LAUNCH_SUPPLY = 1_000_000_000;

const adapter: FactoryAdapter = {
  // The factory deploys the launch token itself (18 decimals) and always quotes in WETH (18 decimals; a test token
  // stands in for it here), so the variants pick which side of WETH the launch token sorts on (by searching the salt).
  variants: {
    bonding: {
      description: 'part way along the bonding curve (30,000 quote bought)',
      quoteDecimals: 18,
      launchIndex: 0,
      scenario: 'bonding',
    },
    completed: {
      description: 'curve completed, queried an hour later: every query graduates the pool first',
      quoteDecimals: 18,
      launchIndex: 1,
      scenario: 'completed',
    },
    overshot: {
      description: 'curve completed by a buy 0.1% past the graduation balance (the most allowed), queried an hour later',
      quoteDecimals: 18,
      launchIndex: 1,
      scenario: 'overshot',
    },
    graduated: {
      description: 'graduated, then 95% of its launch tokens bought, queried 30 days later (nothing moves with time)',
      quoteDecimals: 18,
      launchIndex: 0,
      scenario: 'graduated',
    },
  },

  async createPool(ctx) {
    const [quote] = await ctx.createTokens([ctx.variant.quoteDecimals as number]);
    const launchIndex = ctx.variant.launchIndex as number;

    // The factory fixes every launch's supply and curve.
    const factory = await ctx.deploy('BondingReClammPoolFactory', [
      ctx.vault,
      ctx.MONTH * 12,
      quote.address,
      BigInt(LAUNCH_SUPPLY) * 10n ** 18n,
      { initialPrice: ctx.fp(0.00003), graduationPrice: ctx.fp(0.00048) },
      'factory v1',
      'pool v1',
    ]);
    const launchParams = {
      name: 'Launch',
      symbol: 'LAUNCH',
      creatorFeeRecipient: ctx.admin,
      metadataURI: 'ipfs://launch',
      minInitialBuyAmountOut: 0n,
    };

    // Search the salt until the new token sorts on the side of the quote token the variant asks for.
    let salt = 0n;
    let launchAddress: string;
    for (;; salt++) {
      launchAddress = await factory.getLaunchTokenAddress(launchParams, ctx.admin, ethers.toBeHex(salt, 32));
      if ((launchAddress.toLowerCase() < quote.address.toLowerCase() ? 0 : 1) === launchIndex) break;
    }
    const launch = { address: launchAddress, decimals: 18 };

    // One call deploys the token, creates the pool and initializes it with the whole supply (BPT burned); the pool
    // makes itself the pool creator and sets the creator fee share to 99.999% (so fees leave the pool).
    const tx = await factory.create(
      launchParams,
      ctx.fp(0.01), // 1% swap fee
      ethers.toBeHex(salt, 32)
    );
    const pool = await ctx.attach('BondingReClammPool', ctx.poolCreated(await tx.wait()));

    let queryTimestamp: number | undefined;

    return {
      pool,
      poolType: 'BONDING_RECLAMM',
      initializedByFactory: true,
      afterInitialize: async () => {
        const [admin] = await ethers.getSigners();
        // Mint quote to buy with, and approve it through Permit2 (the generator did not initialize this pool).
        const router = await ethers.getContractAt(getArtifact('v3-vault/Router').abi, ctx.router, admin);
        const quoteToken = await ethers.getContractAt(getArtifact('v3-solidity-utils/ERC20TestToken').abi, quote.address, admin);
        await quoteToken.mint(admin.address, 10_000_000n * 10n ** BigInt(quote.decimals));
        const permit2 = await ethers.getContractAt(getArtifact('permit2/IPermit2').abi, await router.getPermit2(), admin);
        await quoteToken.approve(await permit2.getAddress(), 2n ** 256n - 1n);
        await permit2.approve(quote.address, ctx.router, 2n ** 160n - 1n, 2n ** 48n - 1n);
        const deadline = async () => (await ctx.now()) + HOUR;
        const buyExactOut = async (launchOutRaw: bigint) =>
          router.swapSingleTokenExactOut(await pool.getAddress(), quote.address, launch.address, launchOutRaw, 2n ** 128n, await deadline(), false, '0x');

        const scenario = ctx.variant.scenario as string;
        if (scenario === 'bonding') {
          const quoteInRaw = 30_000n * 10n ** BigInt(quote.decimals);
          await router.swapSingleTokenExactIn(await pool.getAddress(), quote.address, launch.address, quoteInRaw, 0n, await deadline(), false, '0x');
        } else {
          // Buy down to the graduation balance (rounding the raw amount up, so the balance left is at most it), or as far
          // past it as allowed (MAX_GRADUATION_OVERSHOOT, 0.1% of it; the launch token has 18 decimals).
          const toGraduation = await launchToGraduationRaw(pool, launchIndex, launch.decimals);
          if (scenario === 'overshot') {
            const { graduationLaunchBalance } = await pool.getBondingReClammPoolDynamicData();
            await buyExactOut(toGraduation + (graduationLaunchBalance * 10n ** 15n) / 10n ** 18n - 1n);
          } else {
            await buyExactOut(toGraduation);
          }
          if (scenario === 'graduated') {
            // A later block: graduate, buy 95% of the launch tokens left, and query a month later.
            await pool.graduate();
            const launchBalanceRaw = await launchBalanceRawOf(pool, launchIndex, launch.decimals);
            await buyExactOut((launchBalanceRaw * 95n) / 100n);
            queryTimestamp = (await ctx.now()) + 30 * DAY;
            return;
          }
        }
        queryTimestamp = (await ctx.now()) + HOUR;
      },
      get queryTimestamp() {
        return queryTimestamp;
      },
      poolData: async () => {
        const dynamic = await pool.getBondingReClammPoolDynamicData();
        const immutable = await pool.getBondingReClammPoolImmutableData();
        return {
          launchTokenIndex: immutable.launchTokenIndex.toString(),
          graduatedPriceRatio: immutable.graduatedPriceRatio.toString(),
          phase: dynamic.phase.toString(),
          bondingCompletedAt: dynamic.bondingCompletedAt.toString(),
          graduationLaunchBalance: dynamic.graduationLaunchBalance.toString(),
          virtualBalances: [...dynamic.virtualBalances].map(String),
        };
      },
    };
  },
};

/** The launch token's live balance, in raw units (live balances are scaled18; the test tokens have no rate). */
async function launchBalanceRawOf(pool: Contract, launchIndex: number, decimals: number): Promise<bigint> {
  const { balancesLiveScaled18 } = await pool.getBondingReClammPoolDynamicData();
  return balancesLiveScaled18[launchIndex] / 10n ** BigInt(18 - decimals);
}

/** Raw launch tokens to buy so the balance left is at most the graduation balance. */
async function launchToGraduationRaw(pool: Contract, launchIndex: number, decimals: number): Promise<bigint> {
  const scale = 10n ** BigInt(18 - decimals);
  const { balancesLiveScaled18, graduationLaunchBalance } = await pool.getBondingReClammPoolDynamicData();
  return (balancesLiveScaled18[launchIndex] - graduationLaunchBalance + scale - 1n) / scale;
}

export default adapter;
