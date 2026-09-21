// Math-check adapter: creates a WeightedPool through its factory and reports the fields the maths need.
// See pvt/math-check/README.md.

import { FactoryAdapter } from '@bush.fi/v3-math-check/src/types';

const ONE = 10n ** 18n;

const adapter: FactoryAdapter = {
  // Each variant creates one pool and one test-data file. Token decimals matter because the Vault scales every
  // balance to 18 decimals; weights are drawn at random from the seed.
  variants: {
    '2-tokens': { description: '2 tokens (18 and 6 decimals), random weights', decimals: [18, 6] },
    '3-tokens': { description: '3 tokens (18, 8, 6 decimals), random weights', decimals: [18, 8, 6] },
    '5-tokens': { description: '5 tokens with mixed decimals, random weights', decimals: [18, 18, 6, 18, 8] },
  },

  async createPool(ctx) {
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);

    // Random normalized weights summing exactly to 1e18 (the factory enforces the sum and a 1% minimum).
    const raw = tokens.map(() => ctx.rng.num(1, 10));
    const total = raw.reduce((a, b) => a + b, 0);
    const weights = raw.map((r) => ctx.fp(r / total));
    weights[0] += ONE - weights.reduce((a, b) => a + b, 0n);

    const factory = await ctx.deploy('WeightedPoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      'Weighted Pool',
      'WP',
      ctx.tokenConfig(tokens),
      weights,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01),
      ctx.ZERO_ADDRESS,
      false, // enableDonation
      false, // disableUnbalancedLiquidity
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('WeightedPool', ctx.poolCreated(await tx.wait()));

    return {
      pool,
      poolType: 'WEIGHTED',
      poolData: async () => ({
        weights: [...(await pool.getNormalizedWeights())].map(String),
        minTokenBalances: [...(await pool.getMinTokenBalances())].map(String),
      }),
    };
  },
};

export default adapter;
