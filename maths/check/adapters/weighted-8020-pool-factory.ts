// Math-check adapter: creates a WeightedPool through the 80/20 factory and reports the fields the maths need.
// See maths/check/README.md.

import { FactoryAdapter } from '../src/types';

const adapter: FactoryAdapter = {
  variants: {
    'decimals-18-6': { description: '80/20 pool; tokens with 18 and 6 decimals', decimals: [18, 6] },
    'decimals-18-18': { description: '80/20 pool; both tokens 18 decimals', decimals: [18, 18] },
  },

  async createPool(ctx) {
    // Always two tokens; the factory fixes the weights at 80% / 20%.
    const [tokenA, tokenB] = await ctx.createTokens(ctx.variant.decimals as number[]);
    const [highConfig, lowConfig] = ctx.tokenConfig([tokenA, tokenB]);

    const factory = await ctx.deploy('WeightedPool8020Factory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      highConfig,
      lowConfig,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01)
    );
    const pool = await ctx.attach('WeightedPool', ctx.poolCreated(await tx.wait()));

    return {
      pool,
      poolType: 'WEIGHTED_8020',
      poolData: async () => ({
        weights: [...(await pool.getNormalizedWeights())].map(String),
        minTokenBalances: [...(await pool.getMinTokenBalances())].map(String),
      }),
    };
  },
};

export default adapter;
