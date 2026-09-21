// On-chain side of the generator: deploys Vault + Router, builds the adapter context, initializes the pool, reads
// the generic pool state and queries swaps / adds / removes through the Router. Nothing here is pool-type specific.

import { ethers, network } from 'hardhat';
import { Contract } from 'ethers';
import fs from 'fs';
import path from 'path';
import { Artifacts } from 'hardhat/internal/artifacts';

import * as VaultDeployer from '@helpers/models/vault/VaultDeployer';
import TypesConverter from '@helpers/models/types/TypesConverter';
import { buildTokenConfig } from '@helpers/models/tokens/tokenConfig';
import { MAX_UINT256, MAX_UINT160, MAX_UINT48, ZERO_ADDRESS, ZERO_BYTES32 } from '@helpers/constants';
import { MONTH } from '@helpers/time';
import { fp } from '@helpers/numbers';
import * as expectEvent from '@helpers/test/expectEvent';
import { actionId } from '@helpers/models/misc/actions';
import { deployPermit2 } from '@helpers/Permit2Deployer';

import { PoolContext, PoolSetup, Rng, Token } from './types';
import { REPO } from './paths';

const ROUTER_VERSION = 'router v1';

const depsArtifacts = new Artifacts(path.join(REPO, 'pvt/deps/artifacts'));

function artifactsFor(factoryDir: string, contract: string) {
  if (contract.includes('/')) return { artifacts: depsArtifacts, name: contract.split('/').pop()! };
  // A factory package may compile both its own copy of a contract and the npm one; prefer its own.
  const artifacts = new Artifacts(path.join(factoryDir, 'artifacts'));
  const local = fs.existsSync(path.join(factoryDir, 'artifacts', 'contracts', `${contract}.sol`, `${contract}.json`))
    ? `contracts/${contract}.sol:${contract}`
    : undefined;
  return { artifacts, name: local ?? contract };
}

export interface Chain {
  vault: Contract;
  router: Contract;
  permit2: Contract;
  admin: string;
}

export async function deployChain(): Promise<Chain> {
  const [admin] = await ethers.getSigners();
  const vault = await TypesConverter.toIVaultMock(await VaultDeployer.deployMock());
  const weth = await deployFrom(depsArtifacts, 'WETHTestToken', []);
  // deployPermit2 installs the canonical bytecode and returns a provider-bound contract; re-attach it to the signer.
  const permit2Address = await (await deployPermit2()).getAddress();
  const permit2 = (await ethers.getContractAt(depsArtifacts.readArtifactSync('IPermit2').abi, permit2Address, admin)) as unknown as Contract;
  const router = await deployFrom(depsArtifacts, 'Router', [await vault.getAddress(), await weth.getAddress(), permit2Address, ROUTER_VERSION]);
  return { vault: vault as unknown as Contract, router, permit2, admin: admin.address };
}

async function deployFrom(artifacts: Artifacts, name: string, args: unknown[]): Promise<Contract> {
  const [admin] = await ethers.getSigners();
  const factory = await ethers.getContractFactoryFromArtifact(artifacts.readArtifactSync(name), admin);
  const instance = await factory.deploy(...args);
  await instance.waitForDeployment();
  return instance as unknown as Contract;
}

export async function blockTimestamp(): Promise<number> {
  return (await ethers.provider.getBlock('latest'))!.timestamp;
}

export async function mineTo(timestamp: number): Promise<void> {
  if (timestamp > (await blockTimestamp())) await network.provider.send('evm_mine', [timestamp]);
}

export async function makeContext(chain: Chain, factoryDir: string, rng: Rng, variant: Record<string, unknown>): Promise<PoolContext> {
  const deploy = async (contract: string, args: unknown[] = []) => {
    const { artifacts, name } = artifactsFor(factoryDir, contract);
    return deployFrom(artifacts, name, args);
  };
  const attach = async (contract: string, address: string): Promise<Contract> => {
    const { artifacts, name } = artifactsFor(factoryDir, contract);
    const [admin] = await ethers.getSigners();
    return (await ethers.getContractAt(artifacts.readArtifactSync(name).abi, address, admin)) as unknown as Contract;
  };
  const createTokens = async (decimals: number[]): Promise<Token[]> => {
    const tokens: Token[] = [];
    for (const [i, d] of decimals.entries()) {
      const token = await deployFrom(depsArtifacts, 'ERC20TestToken', [`Token ${i}`, `TK${i}`, d]);
      tokens.push({ address: await token.getAddress(), decimals: d });
    }
    return tokens.sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1));
  };

  return {
    vault: await chain.vault.getAddress(),
    router: await chain.router.getAddress(),
    admin: chain.admin,
    variant,
    deploy,
    attach,
    createTokens,
    tokenConfig: (tokens) => buildTokenConfig(tokens.map((t) => t.address)),
    poolCreated: (receipt) => expectEvent.inReceipt(receipt as any, 'PoolCreated').args.pool,
    now: blockTimestamp,
    grantPermission: async (instance, method) => {
      const [admin] = await ethers.getSigners();
      const authorizer = await ethers.getContractAt(depsArtifacts.readArtifactSync('BasicAuthorizerMock').abi, await chain.vault.getAuthorizer(), admin);
      await authorizer.grantRole(await actionId(instance, method), admin.address);
    },
    rng,
    fp,
    ZERO_ADDRESS,
    ZERO_BYTES32,
    MONTH,
  };
}

/** Mints, approves (via Permit2) and initializes the pool through the Router, as the factory tests do. */
export async function initializePool(chain: Chain, setup: PoolSetup): Promise<void> {
  const [admin] = await ethers.getSigners();
  const pool = await setup.pool.getAddress();
  const tokens: string[] = [...(await chain.vault.getPoolTokens(pool))];
  const amounts = setup.initialAmounts ?? (await Promise.all(tokens.map(async (t) => 1000n * 10n ** BigInt(await decimalsOf(t)))));

  for (const [i, t] of tokens.entries()) {
    const token = await ethers.getContractAt(depsArtifacts.readArtifactSync('ERC20TestToken').abi, t, admin);
    await token.mint(admin.address, amounts[i]);
    await token.approve(await chain.permit2.getAddress(), MAX_UINT256);
    await chain.permit2.approve(t, await chain.router.getAddress(), MAX_UINT160, MAX_UINT48);
  }
  await chain.router.initialize(pool, tokens, amounts, 0n, false, '0x');
}

export async function decimalsOf(token: string): Promise<number> {
  const erc20 = await ethers.getContractAt(['function decimals() view returns (uint8)'], token);
  return Number(await erc20.decimals());
}

/** The pool-agnostic part of the `pool` block of a test-data file, read from the Vault. */
export async function readPoolState(chain: Chain, setup: PoolSetup) {
  const pool = await setup.pool.getAddress();
  const [tokens] = await chain.vault.getPoolTokenInfo(pool);
  const [scalingFactors, tokenRates] = await chain.vault.getPoolTokenRates(pool);
  const config = await chain.vault.getPoolConfig(pool);
  const hooks = await chain.vault.getHooksConfig(pool);
  const str = (xs: bigint[]) => xs.map((x) => x.toString());

  const state: Record<string, unknown> = {
    chainId: String((await ethers.provider.getNetwork()).chainId),
    blockNumber: String(await ethers.provider.getBlockNumber()),
    poolType: setup.poolType,
    poolAddress: pool,
    tokens: [...tokens],
    scalingFactors: str([...scalingFactors]),
    swapFee: (await chain.vault.getStaticSwapFeePercentage(pool)).toString(),
    totalSupply: (await chain.vault.totalSupply(pool)).toString(),
    balancesLiveScaled18: str([...(await chain.vault.getCurrentLiveBalances(pool))]),
    tokenRates: str([...tokenRates]),
    aggregateSwapFee: config.aggregateSwapFeePercentage.toString(),
    supportsUnbalancedLiquidity: !config.liquidityManagement.disableUnbalancedLiquidity,
    ...(await setup.poolData()),
  };

  if (setup.hook) {
    state.hook = {
      address: await setup.hook.contract.getAddress(),
      type: setup.hook.type,
      enableHookAdjustedAmounts: hooks.enableHookAdjustedAmounts,
      shouldCallAfterSwap: hooks.shouldCallAfterSwap,
      shouldCallBeforeSwap: hooks.shouldCallBeforeSwap,
      shouldCallAfterInitialize: hooks.shouldCallAfterInitialize,
      shouldCallBeforeInitialize: hooks.shouldCallBeforeInitialize,
      shouldCallAfterAddLiquidity: hooks.shouldCallAfterAddLiquidity,
      shouldCallBeforeAddLiquidity: hooks.shouldCallBeforeAddLiquidity,
      shouldCallAfterRemoveLiquidity: hooks.shouldCallAfterRemoveLiquidity,
      shouldCallBeforeRemoveLiquidity: hooks.shouldCallBeforeRemoveLiquidity,
      shouldCallComputeDynamicSwapFee: hooks.shouldCallComputeDynamicSwapFee,
      dynamicData: await setup.hook.dynamicData(),
    };
  }
  return state;
}

// Router queries run through Vault.quote, which requires a static call from the zero address.
const QUERY = { from: ZERO_ADDRESS };

export interface SwapResult { swapKind: 0 | 1; amountRaw: string; tokenIn: string; tokenOut: string; outputRaw: string }
export interface AddResult { kind: 'Unbalanced' | 'SingleToken'; inputAmountsRaw: string[]; bptOutRaw: string }
export interface RemoveResult { kind: 'Proportional' | 'SingleTokenExactIn' | 'SingleTokenExactOut'; amountsOutRaw: string[]; bptInRaw: string }

async function attempt<T>(f: () => Promise<T>): Promise<T | undefined> {
  try {
    return await f();
  } catch {
    // The pool rejects this operation (e.g. max swap ratio, LBP restrictions); the maths would throw too, and the
    // test-data format only records successful operations.
    return undefined;
  }
}

/**
 * Queries a spread of swaps, adds and removes for the pool: every ordered token pair, both swap kinds, and several
 * sizes relative to the pool balances. Operations the pool reverts on are skipped.
 */
export async function queryOperations(chain: Chain, setup: PoolSetup, rng: Rng, sizes: number[]) {
  // A signer-bound contract refuses a different `from`; bind the Router to the bare provider for queries.
  const router = chain.router.connect(ethers.provider) as Contract;
  const pool = await setup.pool.getAddress();
  const tokens: string[] = [...(await chain.vault.getPoolTokens(pool))];
  const [, , balancesRaw] = await chain.vault.getPoolTokenInfo(pool);
  const totalSupply: bigint = await chain.vault.totalSupply(pool);
  const raw = (balance: bigint, fraction: number) => (balance * rng.fp(fraction)) / 10n ** 18n;

  const swaps: SwapResult[] = [];
  for (const [i, tokenIn] of tokens.entries()) {
    for (const [j, tokenOut] of tokens.entries()) {
      if (i === j) continue;
      for (const size of sizes) {
        const amountIn = raw(balancesRaw[i], size);
        const out = setup.querySwap
          ? await setup.querySwap('EXACT_IN', tokenIn, tokenOut, amountIn)
          : await attempt(() => router.querySwapSingleTokenExactIn.staticCall(pool, tokenIn, tokenOut, amountIn, ZERO_ADDRESS, '0x', QUERY));
        if (out !== undefined && amountIn > 0n) swaps.push({ swapKind: 0, amountRaw: amountIn.toString(), tokenIn, tokenOut, outputRaw: out.toString() });

        const amountOut = raw(balancesRaw[j], size);
        const inp = setup.querySwap
          ? await setup.querySwap('EXACT_OUT', tokenIn, tokenOut, amountOut)
          : await attempt(() => router.querySwapSingleTokenExactOut.staticCall(pool, tokenIn, tokenOut, amountOut, ZERO_ADDRESS, '0x', QUERY));
        if (inp !== undefined && amountOut > 0n) swaps.push({ swapKind: 1, amountRaw: amountOut.toString(), tokenIn, tokenOut, outputRaw: inp.toString() });
      }
    }
  }

  const adds: AddResult[] = [];
  for (const size of sizes) {
    const amountsIn = balancesRaw.map((b: bigint, k: number) => raw(b, size * rng.num(0.5, 1.5)).toString());
    const bptOut = await attempt(() => router.queryAddLiquidityUnbalanced.staticCall(pool, amountsIn, ZERO_ADDRESS, '0x', QUERY));
    if (bptOut !== undefined) adds.push({ kind: 'Unbalanced', inputAmountsRaw: amountsIn, bptOutRaw: bptOut.toString() });

    for (const [i, tokenIn] of tokens.entries()) {
      const exactBptOut = raw(totalSupply, size);
      const amountIn = await attempt(() => router.queryAddLiquiditySingleTokenExactOut.staticCall(pool, tokenIn, exactBptOut, ZERO_ADDRESS, '0x', QUERY));
      if (amountIn !== undefined) {
        const inputAmountsRaw = tokens.map((_, k) => (k === i ? amountIn.toString() : '0'));
        adds.push({ kind: 'SingleToken', inputAmountsRaw, bptOutRaw: exactBptOut.toString() });
      }
    }
  }

  const removes: RemoveResult[] = [];
  for (const size of sizes) {
    const bptIn = raw(totalSupply, size);
    const amountsOut = await attempt(() => router.queryRemoveLiquidityProportional.staticCall(pool, bptIn, ZERO_ADDRESS, '0x', QUERY));
    if (amountsOut !== undefined) removes.push({ kind: 'Proportional', amountsOutRaw: [...amountsOut].map(String), bptInRaw: bptIn.toString() });

    for (const [i, tokenOut] of tokens.entries()) {
      const amountOut = await attempt(() => router.queryRemoveLiquiditySingleTokenExactIn.staticCall(pool, bptIn, tokenOut, ZERO_ADDRESS, '0x', QUERY));
      if (amountOut !== undefined) {
        removes.push({ kind: 'SingleTokenExactIn', amountsOutRaw: tokens.map((_, k) => (k === i ? amountOut.toString() : '0')), bptInRaw: bptIn.toString() });
      }
      const exactOut = raw(balancesRaw[i], size);
      const bptNeeded = await attempt(() => router.queryRemoveLiquiditySingleTokenExactOut.staticCall(pool, tokenOut, exactOut, ZERO_ADDRESS, '0x', QUERY));
      if (bptNeeded !== undefined) {
        removes.push({ kind: 'SingleTokenExactOut', amountsOutRaw: tokens.map((_, k) => (k === i ? exactOut.toString() : '0')), bptInRaw: bptNeeded.toString() });
      }
    }
  }

  return { swaps, adds, removes };
}
