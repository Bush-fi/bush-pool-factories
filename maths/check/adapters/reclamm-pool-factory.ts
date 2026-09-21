// Math-check adapter: creates a ReClammPool through its factory and reports the fields the maths need.
// See maths/check/README.md.
//
// A ReClamm pool's virtual balances only move when the pool is outside its target range or a price ratio update
// is in progress, so the variants set those situations up after initialization (`afterInitialize`) and query
// some time later.

import { ethers } from 'hardhat';
import { FactoryAdapter } from '../src/types';
import { getArtifact } from '@helpers/contract';

const HOUR = 3600;
const DAY = 24 * HOUR;

const adapter: FactoryAdapter = {
  variants: {
    'in-range': { description: 'pool at its target price, queried a day later (virtual balances unchanged)', decimals: [18, 18], scenario: 'none', elapsed: DAY },
    'out-of-range': { description: 'swapped out of the target range, queried 6h later (price range shifting)', decimals: [18, 6], scenario: 'swap', elapsed: 6 * HOUR },
    'price-ratio-update': { description: 'price ratio doubling over 2 days, queried half way', decimals: [6, 18], scenario: 'ratio', elapsed: DAY },
  },

  async createPool(ctx) {
    const tokens = await ctx.createTokens(ctx.variant.decimals as number[]);

    // Price of token A in token B: range [1, 4], starting at 2 (centered). The pool is in range while its
    // centeredness stays above the margin (20%).
    const helper = await ctx.deploy('ReClammPoolHelper', [ctx.vault]);
    const factory = await ctx.deploy('ReClammPoolFactory', [ctx.vault, await helper.getAddress(), ctx.MONTH * 12, 'factory v1', 'pool v1']);
    const tx = await factory.create(
      'ReClammPool',
      'RECLAMM',
      ctx.tokenConfig(tokens),
      { pauseManager: ctx.ZERO_ADDRESS, swapFeeManager: ctx.ZERO_ADDRESS, poolCreator: ctx.ZERO_ADDRESS },
      ctx.fp(0.01),
      { initialMinPrice: ctx.fp(1), initialMaxPrice: ctx.fp(4), initialTargetPrice: ctx.fp(2), tokenAPriceIncludesRate: false, tokenBPriceIncludesRate: false },
      ctx.fp(0.5), // dailyPriceShiftExponent: 50% (the factory maximum)
      ctx.fp(0.2), // centerednessMargin
      ctx.ZERO_BYTES32
    );
    const pool = await ctx.attach('ReClammPool', ctx.poolCreated(await tx.wait()));

    // Initial balances must sit at the target price: the pool computes them from a reference amount of token A.
    const initialAmounts = [...(await pool.computeInitialBalancesRaw(tokens[0].address, 1000n * 10n ** BigInt(tokens[0].decimals)))].map(BigInt);

    let queryTimestamp: number | undefined;

    return {
      pool,
      poolType: 'RECLAMM',
      initialAmounts,
      afterInitialize: async () => {
        const [admin] = await ethers.getSigners();
        const scenario = ctx.variant.scenario as string;
        if (scenario === 'swap') {
          // Sell enough token A to push the pool below its centeredness margin. initializePool left the admin's
          // Permit2 approvals in place; just mint more.
          const router = await ethers.getContractAt(getArtifact('v3-vault/Router').abi, ctx.router, admin);
          const tokenA = await ethers.getContractAt(getArtifact('v3-solidity-utils/ERC20TestToken').abi, tokens[0].address, admin);
          // 80% of the swap that would take the whole token B balance: Ai = Rb * (Ra + Va) / Vb (see computeOutGivenIn).
          const { balancesLiveScaled18: balances } = await pool.getReClammPoolDynamicData();
          const [virtualA, virtualB] = await pool.getLastVirtualBalances();
          const maxInScaled18 = (balances[1] * (balances[0] + virtualA)) / virtualB;
          const amountIn = (maxInScaled18 * 8n) / 10n / 10n ** BigInt(18 - tokens[0].decimals);
          await tokenA.mint(admin.address, amountIn);
          await router.swapSingleTokenExactIn(await pool.getAddress(), tokens[0].address, tokens[1].address, amountIn, 0n, (await ctx.now()) + HOUR, false, '0x');
        } else if (scenario === 'ratio') {
          // Double the price ratio (4 -> 8) over 2 days, starting now.
          await ctx.grantPermission(pool, 'startPriceRatioUpdate');
          const start = (await ctx.now()) + 1;
          await pool.startPriceRatioUpdate(ctx.fp(8), start, start + 2 * DAY);
        }
        queryTimestamp = (await ctx.now()) + (ctx.variant.elapsed as number);
      },
      get queryTimestamp() {
        return queryTimestamp;
      },
      poolData: async () => {
        const dynamic = await pool.getReClammPoolDynamicData();
        return {
          lastVirtualBalances: [...dynamic.lastVirtualBalances].map(String),
          dailyPriceShiftBase: dynamic.dailyPriceShiftBase.toString(),
          lastTimestamp: dynamic.lastTimestamp.toString(),
          centerednessMargin: dynamic.centerednessMargin.toString(),
          startFourthRootPriceRatio: dynamic.startFourthRootPriceRatio.toString(),
          endFourthRootPriceRatio: dynamic.endFourthRootPriceRatio.toString(),
          priceRatioUpdateStartTime: dynamic.priceRatioUpdateStartTime.toString(),
          priceRatioUpdateEndTime: dynamic.priceRatioUpdateEndTime.toString(),
        };
      },
    };
  },
};

export default adapter;
