// Math-check adapter: creates a StablePool + StableSurgeHook through the surge factory and reports the fields the
// maths need. See pvt/math-check/README.md.

import { FactoryAdapter } from '@bush.fi/v3-math-check/src/types';

const adapter: FactoryAdapter = {
  // `amplification` is the stable pool's "A" parameter, the StablePool's curve parameter (see stable-pool-factory). It sets how flat the price
  // curve is around 1:1: a high A (e.g. 1000+) behaves almost like a fixed 1:1 exchange until the pool gets very
  // unbalanced; a low A (e.g. 10) curves more, like a weighted pool. Typical values: 100–2000 for like-kind assets
  // (stablecoins, LSTs). The number here is the human-readable value; on-chain it is stored multiplied by
  // AMP_PRECISION (1000), which is what the maths receives as `amp`.
  variants: {
    '2-tokens-A200': { description: '2 tokens (18 and 6 decimals), amplification 200', decimals: [18, 6], amplification: 200 },
    '3-tokens-A500': { description: '3 tokens (18, 18, 6 decimals), amplification 500', decimals: [18, 18, 6], amplification: 500 },
  },

  async createPool(ctx) {
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);

    const hook = await ctx.deploy('StableSurgeHook', [ctx.vault, ctx.fp(0.95), ctx.fp(0.3), 'hook v1']);
    const factory = await ctx.deploy('StableSurgePoolFactory', [await hook.getAddress(), ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      'Stable Surge Pool',
      'SSP',
      ctx.tokenConfig(tokens),
      ctx.variant.amplification as number,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.001),
      false,
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('StablePool', ctx.poolCreated(await tx.wait()));
    const poolAddress = await pool.getAddress();

    // The surge hook charges an extra fee when a swap makes the pool *more* unbalanced beyond a threshold. Start the
    // pool unbalanced (3:1) so that some of the generated swaps trigger it and some don't.
    const initialAmounts = tokens.map((t, i) => BigInt(i === 0 ? 3000 : 1000) * 10n ** BigInt(t.decimals));

    return {
      pool,
      poolType: 'STABLE',
      poolData: async () => ({ amp: (await pool.getAmplificationParameter())[0].toString() }),
      hook: {
        contract: hook,
        type: 'STABLE_SURGE',
        dynamicData: async () => ({
          surgeThresholdPercentage: (await hook.getSurgeThresholdPercentage(poolAddress)).toString(),
          maxSurgeFeePercentage: (await hook.getMaxSurgeFeePercentage(poolAddress)).toString(),
        }),
      },
      initialAmounts,
    };
  },
};

export default adapter;
