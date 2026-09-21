# bush-factories

A registry of approved Bush Protocol pool factories: their contracts and tests, exact off-chain maths for
integrators (TypeScript, Python, Rust), and the tooling that proves the maths matches the deployed pools.

> The off-chain maths in [bush-maths/](./bush-maths) is exact integer fixed-point and is verified bit-for-bit
> against pools deployed through these factories on a local chain (see [pvt/math-check](./pvt/math-check)).
>
> **Want to add a factory?** Start with [CONTRIBUTING.md](./CONTRIBUTING.md) and the
> [template factory](./pkg/_template-pool-factory).

## Approved factories

| Factory | Pool Type | Hook | Directory |
| --- | --- | --- | --- |
| WeightedPoolFactory | WEIGHTED | — | [weighted-pool-factory](./pkg/weighted-pool-factory) |
| WeightedPool8020Factory | WEIGHTED_8020 | — | [weighted-8020-pool-factory](./pkg/weighted-8020-pool-factory) |
| LBPoolFactory | WEIGHTED_LBP | — | [lbpool-factory](./pkg/lbpool-factory) |
| FixedPriceLBPoolFactory | WEIGHTED_LBP_FIXED_PRICE | — | [fixed-price-lbpool-factory](./pkg/fixed-price-lbpool-factory) |
| StablePoolFactory | STABLE | — | [stable-pool-factory](./pkg/stable-pool-factory) |
| StableSurgePoolFactory | STABLE | StableSurge | [stable-surge-pool-factory](./pkg/stable-surge-pool-factory) |
| CowPoolFactory | COW | — | [cow-pool-factory](./pkg/cow-pool-factory) |

The machine-readable version of this table, including on-chain addresses once deployed, lives in
[registry.json](./registry.json).

## Directory structure

```
pkg/                          # One workspace per approved factory
├─ weighted-pool-factory/
├─ weighted-8020-pool-factory/
├─ lbpool-factory/
├─ fixed-price-lbpool-factory/
├─ stable-pool-factory/
├─ stable-surge-pool-factory/
└─ cow-pool-factory/
bush-maths/                        # Off-chain reference maths for integrators
├─ typescript/                # @bush.fi/maths (bigint)
├─ python/                    # bush-maths (int)
├─ rust/                      # bush-maths (U256)
└─ testData/                  # Generated from the factories; consumed by all three test suites
pvt/                          # Private, shared tooling (not published)
├─ common/                    # Shared Hardhat base config and test setup
├─ deps/                      # Compiles the @bush.fi/v3-* npm packages once (artifacts + typechain for tests)
├─ helpers/                   # TypeScript test helpers (deployers, math, matchers)
└─ math-check/                # Generates bush-maths/testData from the factories and runs the maths suites
```

The Hardhat tests import compiled artifacts and typechain types of the `@bush.fi/v3-*` packages, which those
npm packages don't ship. `pvt/deps` builds them once and the root `tsconfig.json` maps the
`@bush.fi/v3-*/typechain-types` imports onto it. Run `npm run compile` at the root before `npm run test:hardhat`.

Each `pkg/<name>-pool-factory/` directory is self-contained:

```
pkg/<name>-pool-factory/
├─ contracts/               # Solidity source: the factory, the pool and anything they need
├─ test/                    # Foundry and/or Hardhat tests for the contracts
├─ math-check/
│  └─ pool.ts               # Creates the pool through the factory for the maths check
├─ math-implementations/    # Exact fixed-point maths for this pool type, on the bush-maths interfaces
│  ├─ typescript/
│  ├─ python/
│  └─ rust/
├─ docs/
│  ├─ PARAMETERS.md          # Pool creation parameters, ranges, defaults
│  └─ GAS_CHARACTERISTICS.md # Gas costs for core operations
└─ README.md
```

## Integration

Aggregators and routers should consume the [bush-maths](./bush-maths) package for their language rather than
re-deriving swap/join/exit math from the Solidity source. The `Vault` class in each language
reproduces the full Vault flow (scaling, rates, swap fees, hooks) on top of the pool maths, so its
results are the raw amounts the on-chain Router returns. See [bush-maths/README.md](./bush-maths/README.md).

## Checking the maths

```
npm run maths:all
```

deploys every factory on a local Hardhat chain, creates pools through them, queries swaps / adds / removes
through the real Router, writes the results to `bush-maths/testData/`, runs every factory's
`math-implementations` against that data through the bush-maths Vault, and runs the bush-maths suites on it.
Every value must match exactly. See [pvt/math-check](./pvt/math-check) for the contributor workflow.

## Contributing a new factory

Start with [CONTRIBUTING.md](./CONTRIBUTING.md) — a full walkthrough with a working
[template factory](./pkg/_template-pool-factory) to copy. See [GOVERNANCE.md](./GOVERNANCE.md) for the review process and
[.github/PULL_REQUEST_TEMPLATE.md](./.github/PULL_REQUEST_TEMPLATE.md) for the submission
checklist.
