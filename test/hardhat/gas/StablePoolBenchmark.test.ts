/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { deploy, deployedAt } from '@helpers/contract';
import { fp } from '@helpers/numbers';
import { ZERO_BYTES32, ZERO_ADDRESS } from '@helpers/constants';
import { MONTH } from '@helpers/time';
import * as expectEvent from '@helpers/test/expectEvent';
import { StablePoolFactory } from '@typechain';
import { PoolRoleAccountsStruct } from '@typechain/@bush.fi/v3-vault/contracts/Vault';
import { buildTokenConfig } from '@helpers/models/tokens/tokenConfig';
import { Benchmark, PoolTag, PoolInfo } from '@helpers/benchmark/PoolBenchmark.behavior';

class StablePoolBenchmark extends Benchmark {
  AMPLIFICATION_PARAMETER = 200n;

  constructor(dirname: string) {
    super(dirname, 'StablePool');
  }

  override async deployPool(tag: PoolTag, poolTokens: string[], withRate: boolean): Promise<PoolInfo> {
    const factory = (await deploy('v3-pool-stable/StablePoolFactory', {
      args: [await this.vault.getAddress(), MONTH * 12, '', ''],
    })) as unknown as StablePoolFactory;

    const poolRoleAccounts: PoolRoleAccountsStruct = {
      pauseManager: ZERO_ADDRESS,
      swapFeeManager: ZERO_ADDRESS,
      poolCreator: ZERO_ADDRESS,
    };

    const enableDonation = true;

    const tx = await factory.create(
      'StablePool',
      'Test',
      buildTokenConfig(poolTokens, withRate),
      this.AMPLIFICATION_PARAMETER,
      poolRoleAccounts,
      fp(0.1),
      ZERO_ADDRESS,
      enableDonation,
      false, // keep support to unbalanced add/remove liquidity
      ZERO_BYTES32
    );
    const receipt = await tx.wait();
    const event = expectEvent.inReceipt(receipt, 'PoolCreated');

    const pool = (await deployedAt('v3-pool-stable/StablePool', event.args.pool)) as unknown as BaseContract;
    return {
      pool: pool,
      poolTokens: poolTokens,
    };
  }
}

describe('StablePool Gas Benchmark', function () {
  new StablePoolBenchmark(__dirname).itBenchmarks();
});
