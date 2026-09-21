import type { StableState } from '@/stable/data';
import type { WeightedState } from '@/weighted/data';
import type { LiquidityBootstrappingState } from '@/liquidityBootstrapping';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { FixedPriceLBPState } from '@/fixedPriceLBP';
import { ReClammState } from '@/reClamm';
import { type HookState } from '../../src/hooks/types';
import { mapHookState } from './mapHookState';
import { Vault } from '@/vault/vault';

type HookData = {
    address: string;
    type: string;
    enableHookAdjustedAmounts: boolean;
    shouldCallAfterSwap: boolean;
    shouldCallBeforeSwap: boolean;
    shouldCallAfterInitialize: boolean;
    shouldCallBeforeInitialize: boolean;
    shouldCallAfterAddLiquidity: boolean;
    shouldCallBeforeAddLiquidity: boolean;
    shouldCallAfterRemoveLiquidity: boolean;
    shouldCallBeforeRemoveLiquidity: boolean;
    shouldCallComputeDynamicSwapFee: boolean;
    dynamicData?: Record<string, string>;
};

type PoolBase = {
    chainId: number;
    blockNumber: number;
    poolAddress: string;
    hookType?: string;
    hook?: HookState;
};

type WeightedPool = PoolBase & WeightedState;

type StablePool = PoolBase & StableState;





type LiquidityBootstrappingPool = PoolBase & LiquidityBootstrappingState;


type FixedPriceLBPPool = PoolBase & FixedPriceLBPState;

type ReClammPool = PoolBase & ReClammState;

type SupportedPools =
    | WeightedPool
    | StablePool
    | LiquidityBootstrappingPool
    | FixedPriceLBPPool
    | ReClammPool;

type PoolsMap = Map<string, SupportedPools>;

type Swap = {
    swapKind: number;
    amountRaw: bigint;
    outputRaw: bigint;
    tokenIn: string;
    tokenOut: string;
    test: string;
};

type Add = {
    kind: number;
    inputAmountsRaw: bigint[];
    bptOutRaw: bigint;
    test: string;
};

type Remove = {
    kind: number;
    amountsOutRaw: bigint[];
    bptInRaw: bigint;
    test: string;
};

type TestData = {
    swaps: Swap[];
    adds: Add[];
    pools: PoolsMap;
    removes: Remove[];
};

// Reads all json test files and parses to relevant swap/pool bigint format
export function readTestData(directoryPath: string): TestData {
    const pools: PoolsMap = new Map<string, SupportedPools>();
    const swaps: Swap[] = [];
    const adds: Add[] = [];
    const removes: Remove[] = [];
    const testData: TestData = {
        swaps,
        adds,
        pools,
        removes,
    };

    // Resolve the directory path relative to the current file's directory
    const absoluteDirectoryPath = path.resolve(__dirname, directoryPath);

    // Read all files in the directory
    const files = fs.readdirSync(absoluteDirectoryPath);

    // Iterate over each file
    for (const file of files) {
        // Check if the file ends with .json
        if (file.endsWith('.json')) {
            // Read the file content
            const fileContent = fs.readFileSync(
                path.join(absoluteDirectoryPath, file),
                'utf-8',
            );

            // Parse the JSON content
            try {
                const jsonData = JSON.parse(fileContent);
                // A pool type this package has no maths for yet (maths may land one language at a time).
                if (!new Vault().supportsPoolType(jsonData.pool.poolType)) {
                    console.warn(`${file}: pool type ${jsonData.pool.poolType} not implemented in TypeScript, skipped`);
                    continue;
                }
                if (jsonData.swaps)
                    swaps.push(
                        ...jsonData.swaps.map((swap) => ({
                            ...swap,
                            swapKind: Number(swap.swapKind),
                            amountRaw: BigInt(swap.amountRaw),
                            outputRaw: BigInt(swap.outputRaw),
                            test: file,
                        })),
                    );
                if (jsonData.adds)
                    adds.push(
                        ...jsonData.adds.map((add) => ({
                            ...add,
                            kind: add.kind === 'Unbalanced' ? 0 : 1,
                            inputAmountsRaw: add.inputAmountsRaw.map((a) =>
                                BigInt(a),
                            ),
                            bptOutRaw: BigInt(add.bptOutRaw),
                            test: file,
                        })),
                    );
                if (jsonData.removes)
                    removes.push(
                        ...jsonData.removes.map((remove) => ({
                            ...remove,
                            kind: mapRemoveKind(remove.kind),
                            amountsOutRaw: remove.amountsOutRaw.map((a) =>
                                BigInt(a),
                            ),
                            bptInRaw: BigInt(remove.bptInRaw),
                            test: file,
                        })),
                    );

                pools.set(file, mapPool(jsonData.pool));
            } catch (error) {
                console.error(`Error parsing JSON file ${file}:`, error);
            }
        }
    }

    return testData;
}

/**
 * The `pool` block of a test-data file → the pool state the Vault expects. Generic: every decimal string becomes a
 * bigint (recursively, so hook data is covered too); addresses, booleans and JSON numbers (token indices) pass
 * through; the hook block, if any, becomes the hook state. A new pool type therefore needs no changes here — the
 * generator writes the fields its maths reads (`getReClammPoolDynamicData()`, `weights`, `amp`, …) and the pool
 * class receives them under the same names.
 */
function mapPool(pool: Record<string, unknown>): SupportedPools {
    const state = toBigints(pool) as Record<string, unknown>;
    // The generator writes the pool's setting; older hand-made files may lack it.
    state.supportsUnbalancedLiquidity = pool.supportsUnbalancedLiquidity ?? true;
    // Time-dependent pools read the timestamp the queries were made at; files without one are timeless.
    state.currentTimestamp = state.currentTimestamp ?? BigInt(Date.now());

    if (pool.hook) {
        const hookState = mapHookState(pool.hook as HookData, {
            tokens: pool.tokens as string[],
            amp: state.amp as bigint | undefined,
        });
        state.hookType = hookState.hookType;
        state.hook = hookState;
    }
    return state as unknown as SupportedPools;
}

// Decimal strings → bigint, recursively. Matches what maths/check's runners do with the same data.
function toBigints(x: unknown): unknown {
    if (Array.isArray(x)) return x.map(toBigints);
    if (x && typeof x === 'object')
        return Object.fromEntries(
            Object.entries(x).map(([k, v]) => [k, toBigints(v)]),
        );
    if (typeof x === 'string' && /^[0-9]+$/.test(x)) return BigInt(x);
    return x;
}

function mapRemoveKind(kind: string): number {
    if (kind === 'Proportional') return 0;
    else if (kind === 'SingleTokenExactIn') return 1;
    else if (kind === 'SingleTokenExactOut') return 2;
    else throw new Error(`Unsupported RemoveKind: ${kind}`);
}
