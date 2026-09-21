/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { deploy, deployedAt } from '@helpers/contract';
import { fp } from '@helpers/numbers';
import { ZERO_BYTES32, ZERO_ADDRESS } from '@helpers/constants';
import { MONTH } from '@helpers/time';
import * as expectEvent from '@helpers/test/expectEvent';
import { WeightedPoolFactory } from '@typechain';
import { PoolRoleAccountsStruct } from '@typechain/@bush.fi/v3-vault/contracts/Vault';
import { buildTokenConfig } from '@helpers/models/tokens/tokenConfig';
import { Benchmark, PoolTag, PoolInfo } from '@helpers/benchmark/PoolBenchmark.behavior';

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
