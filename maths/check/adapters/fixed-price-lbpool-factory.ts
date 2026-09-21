// Math-check adapter: creates a FixedPriceLBPool through its factory and reports the fields the maths need.
// See maths/check/README.md.

import { FactoryAdapter } from '../src/types';

const HOUR = 3600;
const DAY = 24 * HOUR;

const adapter: FactoryAdapter = {
  // `rate` is the fixed price: how many reserve tokens one project token costs.
  variants: {
    'rate-1': { description: '1 project token = 1 reserve token; 18 and 6 decimals', decimals: [18, 6], rate: 1 },
    'rate-0.25': { description: '1 project token = 0.25 reserve tokens; both 18 decimals', decimals: [18, 18], rate: 0.25 },
    'rate-1500': { description: '1 project token = 1500 reserve tokens; 8 and 6 decimals', decimals: [8, 6], rate: 1500 },
  },

  async createPool(ctx) {
    const [projectToken, reserveToken] = await ctx.createTokens(ctx.variant.decimals as number[]);

    const startTime = (await ctx.now()) + 2 * HOUR;
    const endTime = startTime + 30 * DAY;

    const factory = await ctx.deploy('FixedPriceLBPoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1', ctx.router]);
    const tx = await factory.create(
      {
        name: 'Fixed Price LBPool',
        symbol: 'FPLBP',
        owner: ctx.admin,
        projectToken: projectToken.address,
        reserveToken: reserveToken.address,
        startTime,
        endTime,
        blockProjectTokenSwapsIn: true, // the pool only supports this mode
      },
      ctx.fp(ctx.variant.rate as number), // reserve tokens per project token
      ctx.fp(0.01),
      ctx.ZERO_BYTES32,
      ctx.ZERO_ADDRESS
    );
    const pool = await ctx.attach('FixedPriceLBPool', ctx.poolCreated(await tx.wait()));

    // The pool must be initialized with project tokens only (reserve amount must be zero).
    const projectIsFirst = projectToken.address.toLowerCase() < reserveToken.address.toLowerCase();
    const projectAmount = 1_000_000n * 10n ** BigInt(projectToken.decimals);
    const initialAmounts = projectIsFirst ? [projectAmount, 0n] : [0n, projectAmount];

    return {
      pool,
      poolType: 'FIXED_PRICE_LBP',
      initialAmounts,
      queryTimestamp: startTime + 10 * DAY,
      poolData: async () => {
        const immutable = await pool.getFixedPriceLBPoolImmutableData();
        const dynamic = await pool.getFixedPriceLBPoolDynamicData();
        return {
          startTime: immutable.startTime.toString(),
          endTime: immutable.endTime.toString(),
          projectTokenIndex: Number(immutable.projectTokenIndex),
          reserveTokenIndex: Number(immutable.reserveTokenIndex),
          projectTokenRate: immutable.projectTokenRate.toString(),
          isSwapEnabled: dynamic.isSwapEnabled,
        };
      },
    };
  },
};

export default adapter;
