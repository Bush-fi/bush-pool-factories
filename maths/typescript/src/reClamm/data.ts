import { BasePoolState } from '@/vault/types';

type PoolType = 'RECLAMM';

/**
 * State of a ReClamm pool: `getReClammPoolDynamicData()` plus the timestamp the query is evaluated at. The pool
 * state is time-dependent (the virtual balances move while the pool is out of range or a price ratio update is in
 * progress), so `currentTimestamp` is part of the state, like an LBP's.
 */
export type ReClammState = BasePoolState & {
    poolType: PoolType;
    currentTimestamp: bigint;
} & ReClammMutable;

/** ReClammPoolDynamicData, minus the fields BasePoolState already carries. */
export type ReClammMutable = {
    /** [virtualBalanceA, virtualBalanceB] as last stored by the pool. */
    lastVirtualBalances: bigint[];
    /** 1 - tau: the per-second decay applied to the overvalued virtual balance while out of range. */
    dailyPriceShiftBase: bigint;
    /** When the virtual balances were last stored. */
    lastTimestamp: bigint;
    /** The pool is in its target range while centeredness >= this margin. */
    centerednessMargin: bigint;
    startFourthRootPriceRatio: bigint;
    endFourthRootPriceRatio: bigint;
    priceRatioUpdateStartTime: bigint;
    priceRatioUpdateEndTime: bigint;
};
