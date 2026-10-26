import type { BasePoolState } from '../poolKit';

type PoolType = 'BONDING_RECLAMM';

/**
 * State of a BondingReClamm pool: `getBondingReClammPoolDynamicData()`, the graduated price ratio from
 * `getBondingReClammPoolImmutableData()`, and the timestamp the query is evaluated at (a completed pool graduates on the
 * first operation in a later block).
 */
export type BondingReClammState = BasePoolState & {
    poolType: PoolType;
    currentTimestamp: bigint;
} & BondingReClammMutable;

export type BondingReClammMutable = {
    /** IBondingReClammPool.BondingPhase: 0 BONDING, 1 COMPLETED, 2 GRADUATED. */
    phase: bigint;
    /** Timestamp of the buy that completed the curve (0 while bonding). */
    bondingCompletedAt: bigint;
    /** The launch token's index in the pool's (sorted) tokens. */
    launchTokenIndex: bigint;
    /** The launch token balance (scaled18) at which the curve completes. */
    graduationLaunchBalance: bigint;
    /** The width the graduated virtual balances are solved for (BondingReClammPool.GRADUATED_PRICE_RATIO). */
    graduatedPriceRatio: bigint;
    /** [virtualBalanceA, virtualBalanceB]: the bonding curve's until graduation, the graduated ones after. */
    virtualBalances: bigint[];
};
