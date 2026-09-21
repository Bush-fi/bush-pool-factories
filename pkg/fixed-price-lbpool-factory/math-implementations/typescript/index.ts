// Maths implementation for fixed-price-lbpool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import type { FixedPriceLBPState } from '@bush.fi/maths/fixedPriceLBP/data';
import { FixedPriceLBP } from './fixedPriceLBP';

export * from './fixedPriceLBP';

/** The `poolType` written by pkg/fixed-price-lbpool-factory/math-check/pool.ts. */
export const poolType = 'FIXED_PRICE_LBP';

export function createPool(pool: FixedPriceLBPState): PoolBase {
    return new FixedPriceLBP(pool);
}
