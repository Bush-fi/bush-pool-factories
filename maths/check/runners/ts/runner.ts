/* eslint-disable @typescript-eslint/no-var-requires, @typescript-eslint/no-explicit-any */
// Runs a factory package's TypeScript maths implementation against one bush-maths test-data file, through the
// bush-maths Vault flow, and prints the outcomes as JSON.
//
// Usage: ts-node -r tsconfig-paths/register runner.ts <implementation-dir> <test-data-file.json>
//
// The implementation (`<factory>/math-implementations/typescript/index.ts`) exports:
//   poolType: string                                   the poolType in the test data this implementation handles
//   createPool(pool: PoolData): PoolBase               the pool maths, built from the `pool` block of the test data
//   hookType?: string; createHook?(pool): { hook: HookBase; hookState: unknown }   when the pool has a hook
// PoolData is the `pool` block with every numeric string converted to bigint.

import fs from 'fs';
import path from 'path';
import { AddKind, RemoveKind, SwapKind, Vault } from '@bush.fi/maths';

interface Outcome {
  kind: 'swap' | 'add' | 'remove';
  index: number;
  expected: string[];
  actual?: string[];
  error?: string;
}

// Decimal strings → bigint, recursively; addresses, booleans and type names are left alone.
function toBigints(x: any): any {
  if (Array.isArray(x)) return x.map(toBigints);
  if (x && typeof x === 'object') return Object.fromEntries(Object.entries(x).map(([k, v]) => [k, toBigints(v)]));
  if (typeof x === 'string' && /^[0-9]+$/.test(x)) return BigInt(x);
  return x;
}

function main() {
  const [implDir, dataFile] = process.argv.slice(2);
  const impl = require(path.resolve(implDir));
  const data = JSON.parse(fs.readFileSync(dataFile, 'utf8'));
  const pool = toBigints(data.pool);
  if (impl.poolType !== data.pool.poolType) {
    throw new Error(`implementation handles poolType ${impl.poolType}, test data is ${data.pool.poolType}`);
  }

  // Plug the implementation into the Vault under its pool type (and hook type, if any).
  class PoolWrapper {
    constructor(state: unknown) {
      return impl.createPool(state) as any;
    }
  }
  let hookState: unknown;
  let hookClasses: Record<string, any> = {};
  if (impl.createHook && pool.hook) {
    const made = impl.createHook(pool);
    hookState = made.hookState;
    class HookWrapper {
      constructor() {
        return made.hook as any;
      }
    }
    hookClasses = { [impl.hookType]: HookWrapper };
  }
  const vault = new Vault({ customPoolClasses: { [impl.poolType]: PoolWrapper as any }, customHookClasses: hookClasses });
  const poolState = { ...pool, hookType: impl.createHook && pool.hook ? impl.hookType : undefined };

  const outcomes: Outcome[] = [];
  const run = (kind: Outcome['kind'], index: number, expected: string[], f: () => string[]) => {
    try {
      outcomes.push({ kind, index, expected, actual: f() });
    } catch (e: any) {
      outcomes.push({ kind, index, expected, error: e?.message ?? String(e) });
    }
  };

  (data.swaps ?? []).forEach((s: any, i: number) =>
    run('swap', i, [s.outputRaw], () => [
      vault
        .swap(
          { amountRaw: BigInt(s.amountRaw), tokenIn: s.tokenIn, tokenOut: s.tokenOut, swapKind: s.swapKind === 0 ? SwapKind.GivenIn : SwapKind.GivenOut },
          poolState,
          hookState
        )
        .toString(),
    ])
  );
  (data.adds ?? []).forEach((a: any, i: number) =>
    run('add', i, [a.bptOutRaw, ...a.inputAmountsRaw], () => {
      const r = vault.addLiquidity(
        {
          pool: pool.poolAddress,
          maxAmountsInRaw: a.inputAmountsRaw.map(BigInt),
          minBptAmountOutRaw: BigInt(a.bptOutRaw),
          kind: a.kind === 'Unbalanced' ? AddKind.UNBALANCED : AddKind.SINGLE_TOKEN_EXACT_OUT,
        },
        poolState,
        hookState
      );
      return [r.bptAmountOutRaw.toString(), ...r.amountsInRaw.map(String)];
    })
  );
  (data.removes ?? []).forEach((r: any, i: number) =>
    run('remove', i, [r.bptInRaw, ...r.amountsOutRaw], () => {
      const res = vault.removeLiquidity(
        {
          pool: pool.poolAddress,
          minAmountsOutRaw: r.amountsOutRaw.map(BigInt),
          maxBptAmountInRaw: BigInt(r.bptInRaw),
          kind: r.kind === 'Proportional' ? RemoveKind.PROPORTIONAL : r.kind === 'SingleTokenExactIn' ? RemoveKind.SINGLE_TOKEN_EXACT_IN : RemoveKind.SINGLE_TOKEN_EXACT_OUT,
        },
        poolState,
        hookState
      );
      return [res.bptAmountInRaw.toString(), ...res.amountsOutRaw.map(String)];
    })
  );

  process.stdout.write(JSON.stringify(outcomes));
}

main();
