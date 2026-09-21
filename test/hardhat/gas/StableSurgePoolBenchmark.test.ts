/* eslint-disable @typescript-eslint/no-non-null-assertion */
import { BaseContract } from 'ethers';
import { deploy, deployedAt } from '@helpers/contract';
import { fp } from '@helpers/numbers';
import { ZERO_BYTES32, ZERO_ADDRESS } from '@helpers/constants';
import { MONTH } from '@helpers/time';
import * as expectEvent from '@helpers/test/expectEvent';
import { StableSurgeHook, StableSurgePoolFactory } from '@typechain';
import { PoolRoleAccountsStruct } from '@typechain/@bush.fi/v3-vault/contracts/Vault';
import { buildTokenConfig } from '@helpers/models/tokens/tokenConfig';
import { Benchmark, PoolTag, PoolInfo } from '@helpers/benchmark/PoolBenchmark.behavior';

class StableSurgePoolBenchmark extends Benchmark {
  AMPLIFICATION_PARAMETER = 200n;

  constructor(dirname: string) {
    super(dirname, 'StableSurgePool', {
      disableNestedPoolTests: true,
      disableUnbalancedLiquidityTests: true, // Reverts if the pool surges
    });
  }

  override async deployPool(tag: PoolTag, poolTokens: string[], withRate: boolean): Promise<PoolInfo> {
    const stableSurgeHook = (await deploy('v3-pool-hooks/StableSurgeHook', {
      args: [await this.vault.getAddress(), fp(0.9), fp(0), ''],
    })) as unknown as StableSurgeHook;

    const factory = (await deploy('v3-pool-hooks/StableSurgePoolFactory', {
      args: [await stableSurgeHook.getAddress(), MONTH * 12, '', ''],
    })) as unknown as StableSurgePoolFactory;

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
      enableDonation,
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

describe('StableSurgePool Gas Benchmark', function () {
  new StableSurgePoolBenchmark(__dirname).itBenchmarks();
});
