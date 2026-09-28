// Pool kit: everything a new pool or hook needs, in one import.
//
//     import { MathSol, Rounding, SwapKind, type PoolBase, type SwapParams } from '../poolKit';
//
// A pool under src/<pool>/ imports from this file and from its own folder, nothing else. If a pool needs something
// that is not here, add it here (in a PR a maintainer reviews) rather than importing it from elsewhere.

// Fixed-point arithmetic: ports of Solidity's FixedPoint / LogExpMath / OpenZeppelin Math. Integers only.
export { WAD, RAY, TWO_WAD, FOUR_WAD, HUNDRED_WAD, abs, min, max, _require, MathSol, LogExpMath } from './utils/math';
export type { FixedPointFunction } from './utils/math';
export { sqrt } from './utils/ozMath';
export { MAX_UINT256, MAX_BALANCE } from './constants';

// The interface a pool implements, and the types the Vault passes to it.
export { SwapKind, Rounding, AddKind, RemoveKind } from './vault/types';
export type { PoolBase, SwapParams, MaxSwapParams, MaxSingleTokenRemoveParams, BasePoolState } from './vault/types';

// Raw <-> scaled18 conversions (token decimals and rates), for the max-swap / max-remove helpers.
export {
    toScaled18ApplyRateRoundDown,
    toScaled18ApplyRateRoundUp,
    toRawUndoRateRoundDown,
    toRawUndoRateRoundUp,
} from './vault/utils';

// Ports of the existing pools' maths libraries, to reuse instead of re-porting (CONTRIBUTING.md, Step 5, rule 5).
// Namespaced because they share constant names (_MIN_INVARIANT_RATIO, ...).
export * as WeightedMath from './weighted/weightedMath';
export * as StableMath from './stable/stableMath';
export * as LiquidityBootstrappingMath from './liquidityBootstrapping/liquidityBootstrappingMath';
export * as ReClammMath from './reClamm/reClammMath';

// Hooks: the interface, and a no-op hook to spread and override (`{ ...defaultHook, shouldCallAfterSwap: true, ... }`).
export { defaultHook } from './hooks/constants';
export type { HookBase, HookStateBase, AfterSwapParams } from './hooks/types';
