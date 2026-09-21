// Math-check adapter: creates a StablePool through its factory and reports the fields the maths need.
// See maths/check/README.md.

import { FactoryAdapter } from '../src/types';

const adapter: FactoryAdapter = {
  // `amplification` is the stable pool's "A" parameter, the one knob a StablePool has. It sets how flat the price
  // curve is around 1:1: a high A (e.g. 1000+) behaves almost like a fixed 1:1 exchange until the pool gets very
  // unbalanced; a low A (e.g. 10) curves more, like a weighted pool. Typical values: 100–2000 for like-kind assets
  // (stablecoins, LSTs). The number here is the human-readable value; on-chain it is stored multiplied by
  // AMP_PRECISION (1000), which is what the maths receives as `amp`.
  variants: {
    '2-tokens-A200': { description: '2 tokens (18 and 6 decimals), amplification 200', decimals: [18, 6], amplification: 200 },
    '3-tokens-A1000': { description: '3 tokens (18, 6, 6 decimals), amplification 1000 — nearly flat curve', decimals: [18, 6, 6], amplification: 1000 },
    '5-tokens-A50': { description: '5 tokens with mixed decimals, amplification 50 — noticeably curved', decimals: [18, 18, 8, 6, 18], amplification: 50 },
  },

  async createPool(ctx) {
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);

    const factory = await ctx.deploy('StablePoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      'Stable Pool',
      'SP',
      ctx.tokenConfig(tokens),
      ctx.variant.amplification as number, // human-readable A; the pool multiplies it by AMP_PRECISION (1000)
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.001),
      ctx.ZERO_ADDRESS,
      false,
      false,
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('StablePool', ctx.poolCreated(await tx.wait()));

    return {
      pool,
      poolType: 'STABLE',
      // `amp` is the on-chain value (A * 1000), exactly as StableMath receives it: what the maths must use.
      poolData: async () => ({ amp: (await pool.getAmplificationParameter())[0].toString() }),
    };
  },
};

export default adapter;
