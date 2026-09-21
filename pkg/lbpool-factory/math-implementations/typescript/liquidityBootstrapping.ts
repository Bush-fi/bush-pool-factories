// Exact fixed-point port of Bush's LBPool.sol (pool-weighted/contracts/lbp/LBPool.sol): a two-token WeightedPool
// whose weights move linearly between a start and an end weight during the sale (GradualValueChange), with swaps
// only enabled during the sale and optionally blocked for selling the project token back in.
// The weighted maths is reused from bush-maths; the weight schedule is ported in ./liquidityBootstrappingMath.ts.
// Only seeded LBPs (no reserve virtual balance) are modelled. See pvt/math-check/README.md.

import { SwapParams } from '@bush.fi/maths/vault/types';
import { Weighted } from '@bush.fi/maths/weighted/weightedPool';

import type { LiquidityBootstrappingState } from '@bush.fi/maths/liquidityBootstrapping/data';

import { getNormalizedWeights } from './liquidityBootstrappingMath';

export class LiquidityBootstrapping extends Weighted {
    lbpState: LiquidityBootstrappingState;

    constructor(poolState: LiquidityBootstrappingState) {
        const projectTokenStartWeight =
            poolState.startWeights[poolState.projectTokenIndex];
        const projectTokenEndWeight =
            poolState.endWeights[poolState.projectTokenIndex];

        const currentTime = poolState.currentTimestamp;

        // calculate weights from the pool state
        const weights = getNormalizedWeights(
            poolState.projectTokenIndex,
            currentTime,
            poolState.startTime,
            poolState.endTime,
            projectTokenStartWeight,
            projectTokenEndWeight,
        );

        // weighted pool only requires weights
        super({
            weights,
            minTokenBalances: poolState.minTokenBalances,
            scalingFactors: poolState.scalingFactors,
        });

        this.lbpState = poolState;
    }

    onSwap(swapParams: SwapParams): bigint {
        // swap is enabled during the weight change only
        if (!this.lbpState.isSwapEnabled) {
            throw new Error('Swap is not enabled');
        }

        // a custom setting set during pool deployment
        if (
            this.lbpState.isProjectTokenSwapInBlocked &&
            swapParams.indexIn === this.lbpState.projectTokenIndex
        ) {
            // regardless of the swap kind, the indexIn is the token going into the pool (being sold)
            throw new Error('Project token swap in is blocked');
        }

        // process the swap request
        return super.onSwap(swapParams);
    }
}
