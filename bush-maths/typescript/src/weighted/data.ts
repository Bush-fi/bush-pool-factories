import { BasePoolState } from '@/vault/types';

// WeightedPool8020Factory and CowPoolFactory deploy the same WeightedPool contract.
type PoolType = 'WEIGHTED' | 'WEIGHTED_8020' | 'COW';
export type WeightedImmutable = {
    weights: bigint[];
    /**
     * Per-token minimum live balance (scaled 18) enforced by WeightedPool: max(1e6, 10^(18 - decimals)).
     * Read from `getMinTokenBalances()`. Defaults from the scaling factors when omitted.
     */
    minTokenBalances?: bigint[];
};

export type WeightedState = BasePoolState & {
    poolType: PoolType;
} & WeightedImmutable;
