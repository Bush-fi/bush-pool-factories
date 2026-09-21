// TEMPLATE: the entry point pvt/math-check loads. See pvt/math-check/README.md.

import type { PoolBase } from '@bush.fi/maths/vault/types';
import { ConstantSum } from './constantSumPool';

export * from './constantSumPool';

/** Must equal the `poolType` returned by math-check/pool.ts. */
export const poolType = 'CONSTANT_SUM';

/** Builds the pool maths from the `pool` block of a test-data file (numeric strings already converted to bigint). */
export function createPool(pool: { rate: bigint }): PoolBase {
    return new ConstantSum(pool);
}

// For a pool with a hook, also export:
//   export const hookType = 'MyHook';
//   export function createHook(pool): { hook: HookBase; hookState: unknown } { ... }
