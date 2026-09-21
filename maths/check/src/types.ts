// Contract between the generator and the per-factory adapters (`maths/check/adapters/<factory>.ts`).
//
// The generator deploys a Vault + Router, asks the adapter to create a pool through its factory, initializes it,
// queries swaps / adds / removes through the Router, and writes everything to `maths/testData/` in the format the
// `maths/{typescript,python,rust}` test suites consume. The adapter only has to know two things: how to create the
// pool, and which pool-specific fields the maths need.

import type { Contract } from 'ethers';

/** Pool type strings understood by the maths libraries (see maths/typescript/src/vault/vault.ts). */
export type PoolType = 'WEIGHTED' | 'WEIGHTED_8020' | 'COW' | 'STABLE' | 'LIQUIDITY_BOOTSTRAPPING' | 'FIXED_PRICE_LBP' | 'RECLAMM';

/** Hook type strings understood by the maths libraries' test readers. */
export type HookType = 'STABLE_SURGE';

/** Deterministic random source, so a run can be reproduced from its seed. */
export interface Rng {
  rand01(): number;
  num(lo: number, hi: number): number;
  logNum(lo: number, hi: number): number;
  int(lo: number, hi: number): number;
  pick<T>(xs: T[]): T;
  fp(x: number): bigint;
}

export interface Token {
  address: string;
  decimals: number;
}

export interface PoolContext {
  vault: string;
  /** The Router deployed by the generator. LBP factories need it as their trusted router. */
  router: string;
  /** Deployer / admin / pool owner signer address. */
  admin: string;
  /** Adapter-specific variant options (see FactoryAdapter.variants). */
  variant: Record<string, unknown>;
  /**
   * Deploy a contract by artifact name. Bare names (`'WeightedPoolFactory'`) resolve in the factory package's own
   * `artifacts/`; package-prefixed names (`'v3-vault/Router'`) resolve in the shared `pvt/deps` build.
   */
  deploy(contract: string, args?: unknown[]): Promise<Contract>;
  attach(contract: string, address: string): Promise<Contract>;
  /**
   * Deploy ERC20TestTokens with the given decimals and return them in Vault registration (address-sorted) order.
   * Different decimals exercise the scaling-factor paths of the maths.
   */
  createTokens(decimals: number[]): Promise<Token[]>;
  /** Standard TokenConfig[] (STANDARD token type, no rate provider). */
  tokenConfig(tokens: Token[]): unknown[];
  /** Address of the pool created in `receipt` (parses the factory's PoolCreated event). */
  poolCreated(receipt: unknown): string;
  /** Current block timestamp of the local chain. */
  now(): Promise<number>;
  /** Grant the admin permission to call `method` on `instance` through the Vault's authorizer. */
  grantPermission(instance: Contract, method: string): Promise<void>;
  rng: Rng;
  fp(x: number): bigint;
  ZERO_ADDRESS: string;
  ZERO_BYTES32: string;
  MONTH: number;
}

export interface PoolSetup {
  /** The pool, attached with its own ABI. */
  pool: Contract;
  poolType: PoolType;
  /**
   * Pool-type-specific fields for the `pool` block of the test-data file (e.g. `weights`, `amp`, LBP schedule), as
   * the maths libraries expect them. Read them back from the chain rather than echoing the create() arguments.
   */
  poolData(): Promise<Record<string, unknown>>;
  /** Hook attached to the pool, if any. */
  hook?: {
    contract: Contract;
    type: HookType;
    /** Hook parameters for `hook.dynamicData` (e.g. surge threshold / max fee). */
    dynamicData(): Promise<Record<string, string>>;
  };
  /**
   * Raw amounts to initialize the pool with, per token in registration order. Defaults to 1000 whole tokens each.
   */
  initialAmounts?: bigint[];
  /**
   * Runs after the pool is initialized and before `queryTimestamp` is mined to. For state that only exists on an
   * initialized pool: e.g. swapping to push a ReClamm pool out of its target range, or starting a price ratio update.
   */
  afterInitialize?(): Promise<void>;
  /** Timestamp to mine to after initialization and before querying (e.g. mid-sale for an LBP). */
  queryTimestamp?: number;
  /**
   * Pools that only accept swaps from their own router (CowPool) provide the swap query themselves. Returns the
   * calculated amount (out for EXACT_IN, in for EXACT_OUT), or undefined if the pool rejects the swap.
   */
  querySwap?(kind: 'EXACT_IN' | 'EXACT_OUT', tokenIn: string, tokenOut: string, amount: bigint): Promise<bigint | undefined>;
}

/** Default export of `maths/check/adapters/<factory>.ts`. */
export interface FactoryAdapter {
  /**
   * Named variants (token counts, decimals, pool parameters); one test-data file is generated per variant. The
   * name becomes part of the file name; a `description` field is printed when generating. Everything else is up
   * to the adapter and arrives as `ctx.variant`.
   */
  variants: Record<string, Record<string, unknown>>;
  /** Deploy the factory and create one pool through it, for the given variant. */
  createPool(ctx: PoolContext): Promise<PoolSetup>;
}
