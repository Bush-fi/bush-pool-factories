/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { deploy, deployedAt } from '@bush.fi/v3-helpers/src/contract';
import { fp } from '@bush.fi/v3-helpers/src/numbers';
import { ZERO_BYTES32, ZERO_ADDRESS } from '@bush.fi/v3-helpers/src/constants';
import { MONTH } from '@bush.fi/v3-helpers/src/time';
import * as expectEvent from '@bush.fi/v3-helpers/src/test/expectEvent';
import { WeightedPoolFactory } from '@bush.fi/v3-pool-weighted/typechain-types';
import { PoolRoleAccountsStruct } from '@bush.fi/v3-vault/typechain-types/contracts/Vault';
import { buildTokenConfig } from '@bush.fi/v3-helpers/src/models/tokens/tokenConfig';
import { Benchmark, PoolTag, PoolInfo } from '@bush.fi/v3-benchmarks/src/PoolBenchmark.behavior';

class WeightedPoolBenchmark extends Benchmark {
  WEIGHTS = [fp(0.5), fp(0.5)];

  constructor(dirname: string) {
    super(dirname, 'WeightedPool', {
      disableNestedPoolTests: true,
    });
  }

  override async deployPool(tag: PoolTag, poolTokens: string[], withRate: boolean): Promise<PoolInfo> {
    const factory = (await deploy('v3-pool-weighted/WeightedPoolFactory', {
      args: [await this.vault.getAddress(), MONTH * 12, '', ''],
    })) as unknown as WeightedPoolFactory;

    const poolRoleAccounts: PoolRoleAccountsStruct = {
      pauseManager: ZERO_ADDRESS,
      swapFeeManager: ZERO_ADDRESS,
      poolCreator: ZERO_ADDRESS,
    };

    const enableDonation = true;

    const tx = await factory.create(
      'WeightedPool',
      'Test',
      buildTokenConfig(poolTokens, withRate),
      this.WEIGHTS,
      poolRoleAccounts,
      fp(0.1),
      ZERO_ADDRESS,
      enableDonation,
      false, // keep support to unbalanced add/remove liquidity
      ZERO_BYTES32
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    const pool = (await deployedAt('v3-pool-weighted/WeightedPool', event.args.pool)) as unknown as BaseContract;
    return {
      pool: pool,
      poolTokens: poolTokens,
    };
  }
}

describe('WeightedPool Gas Benchmark', function () {
  new WeightedPoolBenchmark(__dirname).itBenchmarks();
});
