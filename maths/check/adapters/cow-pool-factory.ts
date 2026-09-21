// Math-check adapter: creates a CowPool through its factory and reports the fields the maths need.
// See maths/check/README.md.
//
// CowPool is a WeightedPool that only accepts swaps from its trusted CowRouter, so swaps are queried by simulating
// `CowRouter.swapExactInAndDonateSurplus` / `swapExactOutAndDonateSurplus` (with no donation) instead of the
// standard Router. The donation / protocol-fee arithmetic is covered by the `cow` module of the maths.

import { FactoryAdapter } from '../src/types';

const ONE = 10n ** 18n;

const adapter: FactoryAdapter = {
  variants: {
    'decimals-18-6': { description: '2 tokens (18 and 6 decimals), random weights', decimals: [18, 6] },
  },

  async createPool(ctx) {
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);
    const w = ctx.fp(ctx.rng.num(0.2, 0.8));
    const weights = [w, ONE - w];

    const cowRouter = await ctx.deploy('CowRouter', [ctx.vault, ctx.fp(0.1), ctx.admin]);
    const factory = await ctx.deploy('CowPoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1', await cowRouter.getAddress()]);
    const tx = await factory.create(
      'Cow Pool',
      'CP',
      ctx.tokenConfig(tokens),
      weights,
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01),
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('CowPool', ctx.poolCreated(await tx.wait()));
    const poolAddress = await pool.getAddress();

    // The CowRouter swap functions are permissioned; grant them to the admin, who also holds the token approvals.
    await ctx.grantPermission(cowRouter, 'swapExactInAndDonateSurplus');
    await ctx.grantPermission(cowRouter, 'swapExactOutAndDonateSurplus');
    const noDonation = tokens.map(() => 0n);
    const deadline = 2n ** 255n;

    return {
      pool,
      poolType: 'COW',
      poolData: async () => ({
        weights: [...(await pool.getNormalizedWeights())].map(String),
        minTokenBalances: [...(await pool.getMinTokenBalances())].map(String),
      }),
      async querySwap(kind, tokenIn, tokenOut, amount) {
        // The CowRouter settles against tokens the sender has already transferred to the Vault (`transferAmountHints`),
        // so stage that transfer for real, then simulate the swap. The simulated call never settles, so the staged
        // tokens stay as unsettled Vault reserves and don't touch the pool balances.
        const hint = amount * 2n;
        const hints = tokens.map((t) => (t.address === tokenIn ? hint : 0n));
        const token = await ctx.attach('v3-solidity-utils/ERC20TestToken', tokenIn);
        await token.mint(ctx.admin, hint);
        await token.transfer(ctx.vault, hint);
        try {
          return kind === 'EXACT_IN'
            ? await cowRouter.swapExactInAndDonateSurplus.staticCall(poolAddress, tokenIn, tokenOut, amount, 0n, deadline, noDonation, hints, '0x')
            : await cowRouter.swapExactOutAndDonateSurplus.staticCall(poolAddress, tokenIn, tokenOut, amount * 2n, amount, deadline, noDonation, hints, '0x');
        } catch {
          return undefined;
        }
      },
    };
  },
};

export default adapter;
