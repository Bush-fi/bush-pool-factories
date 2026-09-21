// TEMPLATE math-check adapter: tells maths/check how to create this pool through its factory, and which
// pool-specific values the off-chain maths needs. See maths/check/README.md.
//
// The generator (`npm run maths:generate`) calls `createPool` once per variant on a fresh local chain that already
// has a Vault and Router, initializes the pool, queries swaps / adds / removes through the Router and writes the
// results to a test-data file. `npm run maths:check` then replays that file through the maths in maths/<lang>.

import { FactoryAdapter } from '../src/types';

const adapter: FactoryAdapter = {
  // One test-data file is generated per variant. Cover whatever changes a code path in the maths: token decimals
  // (exercises the Vault's scaling), and every pool parameter (here: the rate).
  variants: {
    'rate-2-decimals-18-6': { description: '1 token0 = 2 token1; tokens with 18 and 6 decimals', decimals: [18, 6], rate: 2 },
    'rate-0.5-decimals-18-18': { description: '1 token0 = 0.5 token1; both tokens 18 decimals', decimals: [18, 18], rate: 0.5 },
  },

  async createPool(ctx) {
    // ctx.createTokens deploys ERC20 test tokens and returns them address-sorted, which is the order the Vault
    // registers them in. Everything else in the test data (balances, weights, ...) uses this order.
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);

    // Deploy the factory (artifact name from this package's contracts/) and create the pool exactly as a user would.
    const factory = await ctx.deploy('ConstantSumPoolFactory', [ctx.vault, ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      'Constant Sum Pool',
      'CSP',
      ctx.tokenConfig(tokens),
      ctx.fp(ctx.variant.rate as number), // ctx.fp: number -> 18-decimal fixed point bigint
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01), // 1% swap fee
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('ConstantSumPool', ctx.poolCreated(await tx.wait()));

    return {
      pool,
      // A name for this pool type. The maths/check registries build the pool from this string; for an approved
      // factory it is also a poolType the maths' Vault knows.
      poolType: 'CONSTANT_SUM',
      // Pool-specific fields for the test-data file. Read them back from the chain, never echo the create() args:
      // this is what an integrator would read, and what your maths gets as input.
      poolData: async () => ({ rate: (await pool.getConstantSumRate()).toString() }),
    };
  },
};

export default adapter;
