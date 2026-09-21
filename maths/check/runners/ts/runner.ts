/* eslint-disable @typescript-eslint/no-explicit-any */
// Runs the TypeScript maths (maths/typescript) against one test-data file, through the Vault flow, and prints
// the outcomes as JSON. The pool and hook classes are looked up by type in ./pools.ts.
//
// Usage: ts-node -r tsconfig-paths/register runner.ts <test-data-file.json>

import fs from 'fs';
import { AddKind, RemoveKind, SwapKind, Vault } from '@bush.fi/maths';
import { hooks, pools } from './pools';

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
  const [dataFile] = process.argv.slice(2);
  const data = JSON.parse(fs.readFileSync(dataFile, 'utf8'));
  const pool = toBigints(data.pool);
  const createPool = pools[pool.poolType];
  if (!createPool) throw new Error(`no TypeScript maths registered for poolType ${pool.poolType} (runners/ts/pools.ts)`);

  // Plug the maths into the Vault under its pool type (and hook type, if any).
  class PoolWrapper {
    constructor(state: unknown) {
      return createPool(state) as any;
    }
  }
  let hookType: string | undefined;
  let hookState: any;
  let hookClasses: Record<string, any> = {};
  if (pool.hook) {
    const createHook = hooks[pool.hook.type];
    if (!createHook) throw new Error(`no TypeScript maths registered for hook type ${pool.hook.type} (runners/ts/pools.ts)`);
    const made = createHook(pool);
    hookState = made.hookState;
    hookType = hookState.hookType;
    class HookWrapper {
      constructor() {
        return made.hook as any;
      }
    }
    hookClasses = { [hookType as string]: HookWrapper };
  }
  const vault = new Vault({ customPoolClasses: { [pool.poolType]: PoolWrapper as any }, customHookClasses: hookClasses });
  const poolState = { ...pool, hookType };

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
