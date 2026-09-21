// Maths implementation for stable-surge-pool-factory. See pvt/math-check/README.md for the interface.

import type { HookBase } from '@bush.fi/maths/hooks/types';
import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Stable } from '@bush.fi/maths/stable';
import { HookStateStableSurge, StableSurgeHook } from './stableSurgeHook';

export * from './stableSurgeHook';

/** The `poolType` / hook written by pkg/stable-surge-pool-factory/math-check/pool.ts. */
export const poolType = 'STABLE';
export const hookType = 'StableSurge';

export function createPool(pool: { amp: bigint }): PoolBase {
    return new Stable(pool);
}

type PoolData = {
    amp: bigint;
    hook: { dynamicData: { surgeThresholdPercentage: bigint; maxSurgeFeePercentage: bigint } };
};

export function createHook(pool: PoolData): { hook: HookBase; hookState: HookStateStableSurge } {
    const hookState: HookStateStableSurge = {
        hookType: 'StableSurge',
        amp: pool.amp,
        surgeThresholdPercentage: pool.hook.dynamicData.surgeThresholdPercentage,
        maxSurgeFeePercentage: pool.hook.dynamicData.maxSurgeFeePercentage,
    };
    return { hook: new StableSurgeHook(hookState), hookState };
}
