// Checks this repo against the contracts deployed on a live chain: `npm run live:check`.
//
// 1. Bytecode. For every active contract in the deployments file that has an artifact here (this repo's contracts
//    first, then the @bush.fi packages compiled through contracts/test/Imports.sol; `MockXPool` is checked against
//    `XPool`), fetch the live runtime code and compare it with the compiled code. Immutables (constructor-set values)
//    and linked-library addresses are masked, since they differ by deployment; the metadata hash at the end of the
//    code is compared separately, since it changes with comments and file paths but not with behaviour.
// 2. Behaviour. On a fork of the chain, for every live factory with a maths/check adapter: create pools through the
//    *live* factory, Vault and Router (the adapter's variants), query swaps / adds / removes, and replay the results
//    through the maths in every language (`maths:check`). This checks the deployed contracts behave like the maths
//    says, end to end, not just that the code matches.
//
// Environment:
//   LIVE_RPC_URL=https://...    the chain (default: Robinhood Chain mainnet); the npm script forks it for part 2
//   ADDRESSES=<path or URL>     deployments file (default: Bush-fi/bush-deployments addresses/robinhoodchain.json)
//   PARTS=bytecode,behaviour    run only some parts
//   FACTORIES=a,b               behaviour: only these adapters (e.g. weighted-pool-factory)
//   LANGS=typescript,python     behaviour: only these languages
//
//   PARTS=bytecode               no fork needed: just compare the code
//
// Reports: maths/check/out/live/bytecode.md, and the usual maths:check report (maths/check/out/report.md) for the
// behaviour part, whose generated test data stays in maths/check/out/live/testData/ (never in maths/testData/).

import { ethers, network } from 'hardhat';
import { Contract, JsonRpcProvider } from 'ethers';
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';

import { getArtifact } from '@helpers/contract';

import { blockTimestamp, Chain, initializePool, makeContext, mineTo, queryOperations, readPoolState } from '../../maths/check/src/harness';
import { ADAPTERS, REPO, ROOT as CHECK_ROOT } from '../../maths/check/src/paths';
import { makeRng } from '../../maths/check/src/rng';
import { FactoryAdapter } from '../../maths/check/src/types';

const DEFAULT_RPC = 'https://rpc.mainnet.chain.robinhood.com';
const DEFAULT_ADDRESSES = 'https://raw.githubusercontent.com/Bush-fi/bush-deployments/main/addresses/robinhoodchain.json';
const OUT = path.join(CHECK_ROOT, 'out', 'live');

interface Deployed {
  task: string;
  name: string;
  address: string;
}

/***************************************************************************
                              Deployments file
***************************************************************************/

async function loadDeployments(): Promise<Deployed[]> {
  const source = process.env.ADDRESSES ?? DEFAULT_ADDRESSES;
  const text = /^https?:/.test(source) ? await (await fetch(source)).text() : fs.readFileSync(source, 'utf8');
  const tasks: Record<string, { contracts: { name: string; address: string }[]; status: string }> = JSON.parse(text);

  const seen = new Set<string>();
  const deployed: Deployed[] = [];
  for (const [task, { contracts, status }] of Object.entries(tasks)) {
    if (status !== 'ACTIVE') continue;
    for (const { name, address } of contracts) {
      // Tasks re-list contracts they depend on (e.g. the Vault under two tasks); check each address once.
      if (!address || seen.has(address.toLowerCase())) continue;
      seen.add(address.toLowerCase());
      deployed.push({ task, name, address });
    }
  }
  return deployed;
}

/***************************************************************************
                                  Bytecode
***************************************************************************/

interface Compiled {
  artifactPath: string;
  deployedBytecode: string; // hex, no 0x
  immutableReferences: Record<string, { start: number; length: number }[]>;
  linkReferences: Record<string, Record<string, { start: number; length: number }[]>>;
  compiler: string;
}

const artifactIndex = new Map<string, string[]>();

/** Every artifact under artifacts/ by contract name (skipping .dbg.json and build-info). */
function indexArtifacts(dir = path.join(REPO, 'artifacts')): void {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== 'build-info') indexArtifacts(full);
    } else if (entry.name.endsWith('.json') && !entry.name.endsWith('.dbg.json')) {
      const name = entry.name.slice(0, -'.json'.length);
      artifactIndex.set(name, [...(artifactIndex.get(name) ?? []), full]);
    }
  }
}

/** This repo's artifact first, then a package's; `MockXPool` falls back to `XPool` (the task's example pool). */
function findArtifact(name: string): { file: string; note?: string } | { error: string } {
  const candidates = [name, ...(name.startsWith('Mock') ? [name.slice('Mock'.length)] : [])];
  for (const candidate of candidates) {
    const files = (artifactIndex.get(candidate) ?? []).filter((f) => !/[/\\]test[/\\]/.test(path.relative(REPO, f)));
    if (files.length === 0) continue;
    const ours = files.filter((f) => path.relative(REPO, f).startsWith(path.join('artifacts', 'contracts')));
    const pick = ours.length > 0 ? ours : files;
    if (pick.length > 1) return { error: `ambiguous: ${pick.map((f) => path.relative(REPO, f)).join(', ')}` };
    const note = candidate !== name ? `as ${candidate}` : undefined;
    return { file: pick[0], note };
  }
  return { error: 'no artifact here' };
}

const buildInfoCache = new Map<string, any>();

function compiled(artifactFile: string): Compiled {
  const artifact = JSON.parse(fs.readFileSync(artifactFile, 'utf8'));
  const dbg = JSON.parse(fs.readFileSync(artifactFile.replace(/\.json$/, '.dbg.json'), 'utf8'));
  const buildInfoFile = path.resolve(path.dirname(artifactFile), dbg.buildInfo);
  if (!buildInfoCache.has(buildInfoFile)) buildInfoCache.set(buildInfoFile, JSON.parse(fs.readFileSync(buildInfoFile, 'utf8')));
  const buildInfo = buildInfoCache.get(buildInfoFile);
  const output = buildInfo.output.contracts[artifact.sourceName][artifact.contractName];
  const settings = buildInfo.input.settings;
  return {
    artifactPath: path.relative(REPO, artifactFile),
    deployedBytecode: artifact.deployedBytecode.replace(/^0x/, ''),
    immutableReferences: output.evm.deployedBytecode.immutableReferences ?? {},
    linkReferences: artifact.deployedLinkReferences ?? {},
    compiler: `solc ${buildInfo.solcLongVersion}, ${settings.viaIR ? 'viaIR, ' : ''}optimizer ${settings.optimizer?.enabled ? `${settings.optimizer.runs} runs` : 'off'}`,
  };
}

/** Splits off the CBOR metadata (its length is in the code's last two bytes). */
function splitMetadata(hex: string): { code: string; metadata: string } {
  const length = parseInt(hex.slice(-4), 16);
  const cut = hex.length - (length + 2) * 2;
  if (!Number.isFinite(length) || cut < 0) return { code: hex, metadata: '' };
  return { code: hex.slice(0, cut), metadata: hex.slice(cut) };
}

type BytecodeVerdict = 'identical' | 'same code, different metadata' | 'DIFFERENT' | 'no code on chain' | 'not compared';

interface BytecodeResult extends Deployed {
  verdict: BytecodeVerdict;
  detail: string;
}

function compare(live: string, local: Compiled): { verdict: BytecodeVerdict; detail: string } {
  const liveHex = live.replace(/^0x/, '').toLowerCase();
  let localHex = local.deployedBytecode.toLowerCase();
  if (liveHex.length !== localHex.length) {
    return {
      verdict: 'DIFFERENT',
      detail: `${liveHex.length / 2} bytes live vs ${localHex.length / 2} compiled (${local.compiler})`,
    };
  }

  // Immutables are zero in the compiled code and set at deployment; library links are placeholders. Take both
  // from the live code, then compare the rest byte for byte.
  const masks: { start: number; length: number }[] = [
    ...Object.values(local.immutableReferences).flat(),
    ...Object.values(local.linkReferences).flatMap((libs) => Object.values(libs).flat()),
  ];
  for (const { start, length } of masks) {
    localHex = localHex.slice(0, start * 2) + liveHex.slice(start * 2, (start + length) * 2) + localHex.slice((start + length) * 2);
  }

  const a = splitMetadata(liveHex);
  const b = splitMetadata(localHex);
  if (a.code !== b.code) {
    let first = 0;
    while (first < a.code.length && a.code[first] === b.code[first]) first++;
    let differing = 0;
    for (let i = 0; i < a.code.length; i += 2) if (a.code.slice(i, i + 2) !== b.code.slice(i, i + 2)) differing++;
    return {
      verdict: 'DIFFERENT',
      detail: `${differing} of ${a.code.length / 2} bytes differ, first at byte ${Math.floor(first / 2)} (${local.compiler})`,
    };
  }
  const masked = `${masks.length} immutable/link slot(s) masked`;
  return a.metadata === b.metadata
    ? { verdict: 'identical', detail: masked }
    : { verdict: 'same code, different metadata', detail: `${masked}; metadata hash differs (source comments or paths changed)` };
}

async function checkBytecode(deployed: Deployed[], rpcUrl: string): Promise<boolean> {
  console.log(`\n1. Bytecode: ${deployed.length} active contracts at ${rpcUrl}\n`);
  const provider = new JsonRpcProvider(rpcUrl);
  indexArtifacts();

  const results: BytecodeResult[] = [];
  for (const d of deployed) {
    const found = findArtifact(d.name);
    let result: BytecodeResult;
    if ('error' in found) {
      result = { ...d, verdict: 'not compared', detail: found.error };
    } else {
      const live = await provider.getCode(d.address);
      const local = compiled(found.file);
      result =
        live === '0x'
          ? { ...d, verdict: 'no code on chain', detail: '' }
          : { ...d, ...compare(live, local) };
      result.detail = [`vs ${local.artifactPath}${found.note ? ` (${found.note})` : ''}`, result.detail].filter(Boolean).join('; ');
    }
    results.push(result);
    const icon = { identical: '✅', 'same code, different metadata': '✅', DIFFERENT: '❌', 'no code on chain': '❌', 'not compared': '⚪' }[result.verdict];
    console.log(`  ${icon} ${d.name.padEnd(28)} ${result.verdict}`);
  }

  fs.mkdirSync(OUT, { recursive: true });
  const lines = [
    '# Live bytecode check',
    '',
    `RPC: ${rpcUrl}`,
    '',
    '| Contract | Address | Task | Result | Detail |',
    '| --- | --- | --- | --- | --- |',
    ...results.map((r) => `| ${r.name} | \`${r.address}\` | ${r.task} | ${r.verdict} | ${r.detail} |`),
    '',
  ];
  fs.writeFileSync(path.join(OUT, 'bytecode.md'), lines.join('\n'));

  const compared = results.filter((r) => r.verdict !== 'not compared');
  const bad = results.filter((r) => r.verdict === 'DIFFERENT' || r.verdict === 'no code on chain');
  console.log(
    `\n  ${compared.length - bad.length}/${compared.length} compared contracts match; ` +
      `${results.length - compared.length} have no artifact here (not compared). Details: ${path.relative(REPO, path.join(OUT, 'bytecode.md'))}`
  );
  return bad.length === 0;
}

/***************************************************************************
                                  Behaviour
***************************************************************************/

function kebab(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();
}

async function liveChain(deployed: Deployed[]): Promise<Chain> {
  const [admin] = await ethers.getSigners();
  const at = (name: string) => {
    const d = deployed.find((x) => x.name === name);
    if (!d) throw new Error(`no ${name} in the deployments file`);
    return d.address;
  };
  const vault = (await ethers.getContractAt(getArtifact('v3-interfaces/IVault').abi, at('Vault'), admin)) as unknown as Contract;
  const router = (await ethers.getContractAt(getArtifact('v3-vault/Router').abi, at('Router'), admin)) as unknown as Contract;
  const permit2 = (await ethers.getContractAt(getArtifact('permit2/IPermit2').abi, await router.getPermit2(), admin)) as unknown as Contract;
  return { vault, router, permit2, admin: admin.address };
}

async function checkBehaviour(deployed: Deployed[]): Promise<boolean> {
  const wanted = process.env.FACTORIES?.split(',');
  const factories = deployed
    .filter((d) => d.name.endsWith('PoolFactory'))
    .map((d) => ({ ...d, adapter: kebab(d.name) }))
    .filter((f) => fs.existsSync(path.join(ADAPTERS, `${f.adapter}.ts`)))
    .filter((f) => !wanted || wanted.includes(f.adapter));

  const forkedNetwork = await ethers.provider.getNetwork();
  const forkBlock = await ethers.provider.getBlockNumber();
  console.log(`\n2. Behaviour: ${factories.length} live factories with a maths/check adapter, on a fork at block ${forkBlock}\n`);
  if (factories.length === 0) return true;

  // Calls at the fork block itself run as "historical" and need hardfork data Hardhat lacks for this chain; one
  // local block on top and everything executes locally, against the forked state.
  await network.provider.send('evm_mine', []);
  const chain = await liveChain(deployed);
  const dataDir = path.join(OUT, 'testData');
  fs.rmSync(dataDir, { recursive: true, force: true });
  fs.mkdirSync(dataDir, { recursive: true });
  const sizes = (process.env.SIZES ?? '0.001,0.01,0.1').split(',').map(Number);

  let ok = true;
  for (const f of factories) {
    const adapter: FactoryAdapter = (await import(path.join(ADAPTERS, `${f.adapter}.ts`))).default;
    const live = (await ethers.getContractAt(getArtifact(f.name).abi, f.address, (await ethers.getSigners())[0])) as unknown as Contract;
    console.log(`  ${f.name} ${f.address} (${await live.version().catch(() => 'no version()')})`);

    for (const [variantName, variant] of Object.entries(adapter.variants)) {
      process.stdout.write(`    [${variantName}] creating through the live factory`);
      try {
        const rng = makeRng(Number(process.env.SEED ?? 1));
        const ctx = await makeContext(chain, rng, variant);
        // The adapter "deploys" its factory: hand it the live one instead. Everything else (test tokens, hooks)
        // is deployed on the fork as usual.
        const deploy = ctx.deploy;
        ctx.deploy = async (contract, args) => (contract === f.name ? live : deploy(contract, args));

        const setup = await adapter.createPool(ctx);
        process.stdout.write(', initializing');
        await initializePool(chain, setup);
        if (setup.afterInitialize) await setup.afterInitialize();
        if (setup.queryTimestamp) await mineTo(setup.queryTimestamp);

        process.stdout.write(', querying');
        const ops = await queryOperations(chain, setup, rng, sizes);
        const pool = await readPoolState(chain, setup);
        pool.currentTimestamp = String(await blockTimestamp());
        pool.liveChainId = String(forkedNetwork.chainId);
        pool.forkBlock = String(forkBlock);

        const file = `31337-${f.adapter}-${variantName}.json`;
        fs.writeFileSync(path.join(dataDir, file), JSON.stringify({ ...ops, pool }, null, 4));
        console.log(` → ${ops.swaps.length} swaps, ${ops.adds.length} adds, ${ops.removes.length} removes`);
      } catch (e: any) {
        ok = false;
        console.log(`\n      ❌ ${e.shortMessage ?? e.message?.split('\n')[0] ?? e}`);
      }
    }
  }

  // Replay through the maths in every language (the same check as `maths:check`, on this data).
  console.log('\n  Replaying through the maths:');
  const r = spawnSync('npm', ['run', '--silent', 'maths:check'], {
    cwd: REPO,
    stdio: 'inherit',
    env: { ...process.env, MATHS_DATA_DIR: path.relative(REPO, dataDir), FACTORIES: factories.map((f) => f.adapter).join(',') },
  });
  return ok && r.status === 0;
}

/***************************************************************************
                                    Main
***************************************************************************/

async function main() {
  const parts = (process.env.PARTS ?? 'bytecode,behaviour').split(',');
  const rpcUrl = process.env.LIVE_RPC_URL ?? DEFAULT_RPC;
  const deployed = await loadDeployments();

  let ok = true;
  if (parts.includes('bytecode')) ok = (await checkBytecode(deployed, rpcUrl)) && ok;
  if (parts.includes('behaviour')) {
    if (!process.env.FORK_URL) {
      console.log('\n2. Behaviour: skipped (needs a fork: run through `npm run live:check`, which sets FORK_URL)');
    } else {
      ok = (await checkBehaviour(deployed)) && ok;
    }
  }
  console.log(ok ? '\n✅ live check passed' : '\n❌ live check found differences (see above)');
  process.exitCode = ok ? 0 : 1;
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
