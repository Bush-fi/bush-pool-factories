// Maths implementation for weighted-pool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Weighted } from './weightedPool';

export * from './weightedMath';
export * from './weightedPool';

/** The `poolType` written by pkg/weighted-pool-factory/math-check/pool.ts. */
export const poolType = 'WEIGHTED';

/** Builds the pool maths from the `pool` block of a test-data file (numeric strings already converted to bigint). */
export function createPool(pool: { weights: bigint[]; minTokenBalances?: bigint[]; scalingFactors: bigint[] }): PoolBase {
    return new Weighted(pool);
}
