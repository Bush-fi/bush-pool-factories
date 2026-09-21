// Maths implementation for lbpool-factory. See pvt/math-check/README.md for the interface.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import type { LiquidityBootstrappingState } from '@bush.fi/maths/liquidityBootstrapping/data';
import { LiquidityBootstrapping } from './liquidityBootstrapping';

export * from './liquidityBootstrappingMath';
export * from './liquidityBootstrapping';

/** The `poolType` written by pkg/lbpool-factory/math-check/pool.ts. */
export const poolType = 'LIQUIDITY_BOOTSTRAPPING';

export function createPool(pool: LiquidityBootstrappingState): PoolBase {
    return new LiquidityBootstrapping(pool);
}
