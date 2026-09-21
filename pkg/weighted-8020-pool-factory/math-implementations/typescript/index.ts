// Maths implementation for weighted-8020-pool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Weighted } from './weightedPool';

export * from './weightedPool';

/** The `poolType` written by pkg/weighted-8020-pool-factory/math-check/pool.ts. */
export const poolType = 'WEIGHTED_8020';

export function createPool(pool: { weights: bigint[]; minTokenBalances?: bigint[]; scalingFactors: bigint[] }): PoolBase {
    return new Weighted(pool);
}
