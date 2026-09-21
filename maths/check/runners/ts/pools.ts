// The pool types (and hook types) `maths:check` knows how to build from the `pool` block of a test-data file.
//
// Add your pool here after porting its maths into maths/typescript/src/<pool>/: the key is the `poolType` your
// adapter (maths/check/adapters/<factory>.ts) reports, the value builds the maths from the recorded pool fields
// (numeric strings already converted to bigint).

import type { HookBase } from '@bush.fi/maths/hooks/types';
import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Weighted } from '@bush.fi/maths/weighted';
import { Stable } from '@bush.fi/maths/stable';
import { LiquidityBootstrapping } from '@bush.fi/maths/liquidityBootstrapping';
import { FixedPriceLBP } from '@bush.fi/maths/fixedPriceLBP';
import { HookStateStableSurge, StableSurgeHook } from '@bush.fi/maths/hooks/stableSurgeHook';
import { ConstantSum } from '@bush.fi/maths/constantSum';

/* eslint-disable @typescript-eslint/no-explicit-any */

export const pools: Record<string, (pool: any) => PoolBase> = {
    WEIGHTED: (pool) => new Weighted(pool),
    WEIGHTED_8020: (pool) => new Weighted(pool),
    // The CoW-specific arithmetic lives in CowRouter, not the pool.
    COW: (pool) => new Weighted(pool),
    // `amp` is the raw, AMP_PRECISION-scaled amplification parameter, as `getAmplificationParameter()` returns it.
    STABLE: (pool) => new Stable(pool),
    LIQUIDITY_BOOTSTRAPPING: (pool) => new LiquidityBootstrapping(pool),
    FIXED_PRICE_LBP: (pool) => new FixedPriceLBP(pool),
    // Template example.
    CONSTANT_SUM: (pool) => new ConstantSum(pool),
};

// Keyed by the hook `type` the adapter reports. Returns the hook maths and the state the Vault hands it on every call.
export const hooks: Record<string, (pool: any) => { hook: HookBase; hookState: unknown }> = {
    STABLE_SURGE: (pool) => {
        const hookState: HookStateStableSurge = {
            hookType: 'StableSurge',
            amp: pool.amp,
            surgeThresholdPercentage: pool.hook.dynamicData.surgeThresholdPercentage,
            maxSurgeFeePercentage: pool.hook.dynamicData.maxSurgeFeePercentage,
        };
        return { hook: new StableSurgeHook(hookState), hookState };
    },
};
