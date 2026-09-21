// Maths implementation for stable-pool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Stable } from './stablePool';

export * from './stableMath';
export * from './stablePool';

/** The `poolType` written by pkg/stable-pool-factory/math-check/pool.ts. */
export const poolType = 'STABLE';

/** `amp` is the raw, AMP_PRECISION-scaled amplification parameter, as `getAmplificationParameter()` returns it. */
export function createPool(pool: { amp: bigint }): PoolBase {
    return new Stable(pool);
}
