// Maths implementation for cow-pool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import { Weighted } from './weightedPool';

export * from './weightedPool';
// The CoW-specific arithmetic lives in CowRouter, not the pool.
export * from './cowRouter';


/** The `poolType` written by pkg/cow-pool-factory/math-check/pool.ts. */
export const poolType = 'COW';

export function createPool(pool: { weights: bigint[]; minTokenBalances?: bigint[]; scalingFactors: bigint[] }): PoolBase {
    return new Weighted(pool);
}
