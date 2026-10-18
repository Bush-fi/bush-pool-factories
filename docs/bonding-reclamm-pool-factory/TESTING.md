# Testing the BondingReClamm launch pool

Run everything and get a report: `npm run test:bonding-reclamm:report` (about 15 minutes). It writes
[TEST_REPORT.md](./TEST_REPORT.md), listing every test with what it checks, its result and the numbers it logs.

## Before you start

- Install dependencies: `npm install`.
- Build once: `npm run compile` (Hardhat; Foundry builds on demand).
- Foundry (`forge`) for the Solidity tests; Python 3 and Rust (`cargo`) for the maths checks.
- The live-chain fork runs need network access to the chain's RPC (default `https://rpc.mainnet.chain.robinhood.com`).

## Commands

| Command | What it runs | Time |
| --- | --- | --- |
| `npm run test:bonding-reclamm` | All Foundry suites locally, then the Hardhat end-to-end test | ~1 min |
| `npm run test:bonding-reclamm:fork` | All Foundry suites on a fork of the live chain (light fuzzing) | ~10 min |
| `npm run test:bonding-reclamm:report` | Both of the above, the volatility simulation, and the maths check; writes `TEST_REPORT.md` | ~15 min |
| `forge test --match-path 'test/foundry/bonding-reclamm/*'` | All Foundry suites locally | ~1 min |
| `forge test --match-contract BondingReClammAttacksTest -vv` | One suite, with its logged output (`-vv`) | seconds |
| `forge test --match-test testRun5000xThenEveryoneSellsBack -vv` | One test | seconds |
| `npx hardhat test test/hardhat/bonding-reclamm/bondingReClammPool.test.ts` | The end-to-end test through the real Router, paying in ETH, with a gas table | ~20 s |
| `npm run maths:check -- bonding-reclamm-pool-factory` | The TypeScript, Python and Rust maths against the deployed pool | seconds |
| `FACTORIES=bonding-reclamm-pool-factory npm run maths:generate` | Regenerates the maths test data (after a contract change) | ~30 s |

Add `-vv` to any `forge test` to see the numbers tests print: the graduation snapshot table, the price chart, the
5,000x run, push-and-hold results, invariant coverage.

## Settings (environment variables)

| Variable | Effect |
| --- | --- |
| `FORK_URL` | Run the Foundry suites on a fork of this chain instead of local mocks: the live Vault, Router, Permit2, WETH and protocol fee controller. Also runs `BondingReClammForkTest`. |
| `FORK_BLOCK` | Pin the fork to a block (all tests see the same state; the RPC caches it). The public RPC only keeps recent history, so use a recent block. |
| `LIVE_RPC_URL` | The RPC the npm fork script uses (default Robinhood Chain). |
| `FOUNDRY_FUZZ_RUNS`, `FOUNDRY_INVARIANT_RUNS`, `FOUNDRY_INVARIANT_DEPTH` | Fuzzing effort. Locally: 10,000 / 128 / 64 (`foundry.toml`). The fork script uses 256 / 16 / 32: the fork is about the live contracts, not more random inputs. |
| `RUN_SIM=true` | Run the volatility simulation (`BondingReClammVolatilitySim`). It also needs `FOUNDRY_GAS_LIMIT=9000000000`. |

Examples:

```sh
# The simulation, with its table
FOUNDRY_GAS_LIMIT=9000000000 RUN_SIM=true forge test --match-contract BondingReClammVolatilitySim -vv

# One suite on the live chain
FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract BondingReClammCreatorFeeTest -vv
```

## What the suites cover

All in `test/foundry/bonding-reclamm/`, on `test/foundry/utils/BaseBondingReClammTest.sol` (which launches through the
real factory and switches to the live chain when `FORK_URL` is set).

| Suite | Covers |
| --- | --- |
| `BondingReClammPool.t.sol` | The pool: curve, completion, the overshoot cap, graduation, the graduated pool, hooks, getters. Runs twice, with the launch token sorting first and second. |
| `BondingReClammPoolFactory.t.sol` | The factory: one-call launch, fixed supply and curve, fixed roles, WETH only, the creator's initial buy, validation. |
| `BondingReClammCreatorFee.t.sol` | The creator fee: set at creation, unchangeable, paid to the recipient; the curve stays exact under heavy volume; the 5 ETH preset. |
| `BondingReClammAttacks.t.sol` | Attack scenarios: late LPs, liquidity locks, recovery mode, sell-backs, premines, flash buyouts, push-and-hold, JIT liquidity, fee control. |
| `BondingReClammInvariants.t.sol` | Stateful invariants over random sequences of buys, sells, waits, graduation, adds, removes and fee withdrawals. |
| `BondingReClammExtremeMoves.t.sol` | A 5,000x run and every holder selling back; a crash far past the real supply. |
| `BondingReClammGraduationSnapshot.t.sol` | A before/after table and a price chart proving graduation doesn't move the price. |
| `BondingReClammMath.t.sol` | The curve setup and the graduation solve, fuzzed over every supply and price the factory accepts. |
| `BondingReClammVolatilitySim.t.sol` | 45-day price paths (15% days, a 2000% day, a 200x run, a dump): stuck time, LP value, push-and-hold. On demand (`RUN_SIM`). |
| `BondingReClammFork.t.sol` | One full launch on the live chain's contracts, logging the live fee split. On demand (`FORK_URL`). |

On the fork, a few tests skip because they need a local-mock control the live chain doesn't have (pausing the Vault,
forcing a 0% fee); the report lists them with the reason.
