// Math-check adapter: creates an LBPool through its factory and reports the fields the maths need.
// See maths/check/README.md.
//
// Only seeded LBPs (no reserve virtual balance) are generated: the maths libraries don't model seedless LBPs yet.

import { FactoryAdapter } from '../src/types';

const ONE = 10n ** 18n;
const HOUR = 3600;
const DAY = 24 * HOUR;

const adapter: FactoryAdapter = {
  // `progress` is how far through the sale the pool is queried (0 = start, 1 = end); the weights are interpolated
  // between the start and end weights at that point. `blockProjectTokenSwapsIn` is the pool option that forbids
  // selling the project token back into the pool.
  variants: {
    'mid-sale': { description: '40% through the sale, selling project tokens back allowed', decimals: [18, 6], progress: 0.4, blockProjectTokenSwapsIn: false },
    'mid-sale-blocked': { description: '70% through the sale, selling project tokens back blocked', decimals: [18, 18], progress: 0.7, blockProjectTokenSwapsIn: true },
  },

  async createPool(ctx) {
    const [projectToken, reserveToken] = await ctx.createTokens(ctx.variant.decimals as number[]);

    // The sale must start at least INITIALIZATION_PERIOD (1h) after creation; the pool is initialized before the
    // start (liquidity can only be added then) and queried part-way through the sale.
    const startTime = (await ctx.now()) + 2 * HOUR;
    const endTime = startTime + 30 * DAY;
    const projectStart = ctx.fp(0.9);
    const projectEnd = ctx.fp(0.3);

    // LBP factories require the trusted router to be the one used for initialization.
    const factory = await ctx.deploy('LBPoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1', ctx.router]);
    const tx = await factory.create(
      {
        name: 'LBPool',
        symbol: 'LBP',
        owner: ctx.admin,
        projectToken: projectToken.address,
        reserveToken: reserveToken.address,
        startTime,
        endTime,
        blockProjectTokenSwapsIn: ctx.variant.blockProjectTokenSwapsIn as boolean,
      },
      {
        projectTokenStartWeight: projectStart,
        reserveTokenStartWeight: ONE - projectStart,
        projectTokenEndWeight: projectEnd,
        reserveTokenEndWeight: ONE - projectEnd,
        reserveTokenVirtualBalance: 0n,
      },
      ctx.fp(0.01),
      ctx.ZERO_BYTES32,
      ctx.ZERO_ADDRESS
    );
    const pool = await ctx.attach('LBPool', ctx.poolCreated(await tx.wait()));

    return {
      pool,
      poolType: 'LIQUIDITY_BOOTSTRAPPING',
      queryTimestamp: startTime + Math.floor((endTime - startTime) * (ctx.variant.progress as number)),
      poolData: async () => {
        const immutable = await pool.getLBPoolImmutableData();
        const dynamic = await pool.getLBPoolDynamicData();
        return {
          startWeights: [...immutable.startWeights].map(String),
          endWeights: [...immutable.endWeights].map(String),
          startTime: immutable.startTime.toString(),
          endTime: immutable.endTime.toString(),
          projectTokenIndex: Number(immutable.projectTokenIndex),
          isProjectTokenSwapInBlocked: immutable.isProjectTokenSwapInBlocked,
          weights: [...(await pool.getNormalizedWeights())].map(String),
          minTokenBalances: [...(await pool.getMinTokenBalances())].map(String),
          isSwapEnabled: dynamic.isSwapEnabled,
        };
      },
    };
  },
};

export default adapter;
