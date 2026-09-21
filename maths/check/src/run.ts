// Entry point: `npm run generate` (hardhat run src/run.ts).
//
// For every factory package with a `math-check/pool.ts` adapter, and every variant it declares: deploy a Vault and
// Router, create the pool through its factory, initialize it, query swaps / adds / removes through the Router and
// write a test-data file to bush-maths/testData/. The maths test suites (`npm run check`) then replay that data.
//
// Environment:
//   FACTORIES=weighted-pool-factory,...   subset of factory packages (default: all with an adapter)
//   SEED=1                                PRNG seed for pool parameters and amounts (default 1)
//   SIZES=0.001,0.01,0.1                  operation sizes as a fraction of pool balance / supply

import fs from 'fs';
import path from 'path';

import { blockTimestamp, deployChain, initializePool, makeContext, mineTo, queryOperations, readPoolState } from './harness';
import { discoverFactories, REPO, TEST_DATA, testDataDirFor } from './paths';
import { makeRng } from './rng';
import { FactoryAdapter } from './types';

async function main() {
  const wanted = process.env.FACTORIES?.split(',');
  const all = discoverFactories(wanted !== undefined);
  const factories = wanted ? all.filter((f) => wanted.includes(f.name)) : all;
  for (const w of wanted ?? []) if (!all.some((f) => f.name === w)) throw new Error(`no math-check/pool.ts adapter in pkg/${w}`);
  const seed = Number(process.env.SEED ?? 1);
  const sizes = (process.env.SIZES ?? '0.001,0.01,0.1').split(',').map(Number);

  fs.mkdirSync(TEST_DATA, { recursive: true });
  const written: string[] = [];

  for (const factory of factories) {
    const adapter: FactoryAdapter = (await import(path.join(factory.dir, 'math-check/pool.ts'))).default;
    const outDir = testDataDirFor(factory.name);
    fs.mkdirSync(outDir, { recursive: true });
    // Regenerate this factory's files from scratch so files for removed variants don't linger.
    for (const f of fs.readdirSync(outDir)) if (f.startsWith(`31337-${factory.name}-`)) fs.unlinkSync(path.join(outDir, f));
    for (const [variantName, variant] of Object.entries(adapter.variants)) {
      const label = typeof variant.description === 'string' ? ` — ${variant.description}` : '';
      process.stdout.write(`${factory.name} [${variantName}]${label}: deploying`);
      const rng = makeRng(seed);
      const chain = await deployChain();
      const ctx = await makeContext(chain, factory.dir, rng, variant);
      const setup = await adapter.createPool(ctx);

      process.stdout.write(', initializing');
      await initializePool(chain, setup);
      if (setup.queryTimestamp) await mineTo(setup.queryTimestamp);

      process.stdout.write(', querying');
      const ops = await queryOperations(chain, setup, rng, sizes);
      const pool = await readPoolState(chain, setup);
      pool.currentTimestamp = String(await blockTimestamp());

      const file = `31337-${factory.name}-${variantName}.json`;
      fs.writeFileSync(path.join(outDir, file), JSON.stringify({ ...ops, pool }, null, 4));
      written.push(path.relative(REPO, path.join(outDir, file)));
      console.log(` → ${ops.swaps.length} swaps, ${ops.adds.length} adds, ${ops.removes.length} removes`);
    }
  }

  console.log(`\nWrote ${written.length} file(s):\n  ${written.join('\n  ')}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
