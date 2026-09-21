<p align="center">
  <img src=".github/BushTransparent.png" alt="Bush" width="160">
</p>

<h1 align="center">bush-pool-factories</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/@bush.fi/maths"><img src="https://img.shields.io/npm/v/@bush.fi/maths?label=%40bush.fi%2Fmaths&color=2fb02d" alt="@bush.fi/maths on npm"></a>
  <a href="./maths/typescript/LICENSE"><img src="https://img.shields.io/badge/maths-MIT-2fb02d" alt="maths license"></a>
</p>

The approved Bush Protocol pool factories: their contracts and tests, exact off-chain maths for integrators
(TypeScript, Python, Rust), and the tooling that proves the maths matches the deployed pools. Deployed addresses
live in the Bush deployment repo.

> The off-chain maths in [maths/](./maths) is exact integer fixed-point and is verified bit-for-bit against
> pools deployed through these factories on a local chain (see [maths/check](./maths/check)).
>
> **Want to add a factory?** Start with [CONTRIBUTING.md](./CONTRIBUTING.md) and the template
> ([contracts/_template](./contracts/_template), [docs/_template-pool-factory](./docs/_template-pool-factory)).

## Approved factories

| Factory | Pool Type | Hook | Contracts | Docs |
| --- | --- | --- | --- | --- |
| WeightedPoolFactory | WEIGHTED | — | [contracts/weighted](./contracts/weighted) | [weighted-pool-factory](./docs/weighted-pool-factory) |
| WeightedPool8020Factory | WEIGHTED_8020 | — | [contracts/weighted](./contracts/weighted) | [weighted-8020-pool-factory](./docs/weighted-8020-pool-factory) |
| LBPoolFactory | LIQUIDITY_BOOTSTRAPPING | — | [contracts/lbp](./contracts/lbp) | [lbpool-factory](./docs/lbpool-factory) |
| FixedPriceLBPoolFactory | FIXED_PRICE_LBP | — | [contracts/lbp](./contracts/lbp) | [fixed-price-lbpool-factory](./docs/fixed-price-lbpool-factory) |
| StablePoolFactory | STABLE | — | [contracts/stable](./contracts/stable) | [stable-pool-factory](./docs/stable-pool-factory) |
| StableSurgePoolFactory | STABLE | StableSurge | [contracts/stable-surge](./contracts/stable-surge) | [stable-surge-pool-factory](./docs/stable-surge-pool-factory) |
| CowPoolFactory | COW | — | [contracts/cow](./contracts/cow) | [cow-pool-factory](./docs/cow-pool-factory) |

## Layout

```
contracts/                 # Solidity, one directory per pool family (one Hardhat + Foundry project)
├─ weighted/               #   WeightedPool + WeightedPoolFactory + WeightedPool8020Factory
├─ lbp/                    #   LBPool, FixedPriceLBPool and their factories
├─ stable/                 #   StablePool + StablePoolFactory
├─ stable-surge/           #   StableSurgeHook + StableSurgePoolFactory
├─ cow/                    #   CowPool, CowPoolFactory, CowRouter
├─ _template/              #   ConstantSumPool: the example a new factory starts from
└─ test/                   #   mocks (+ generated Imports.sol, which compiles the @bush.fi/v3-* packages)
test/
├─ foundry/<family>/       # Foundry tests, mirroring contracts/; shared bases and deployers in utils/
├─ hardhat/<family>/       # Hardhat tests; gas benchmarks and snapshots in gas/
└─ helpers/                # TypeScript helpers for the Hardhat tests and maths/check (@helpers/*)
maths/                     # Off-chain reference maths for integrators
├─ typescript/             #   @bush.fi/maths (bigint)
├─ python/                 #   bush-maths (int)
├─ rust/                   #   bush-maths (U256)
├─ testData/               #   generated from the factories; consumed by all three test suites
└─ check/                  #   generates testData and checks the three maths against it
   └─ adapters/            #     one file per factory: how to create its pool and which fields the maths need
docs/<factory>/            # README, PARAMETERS.md and GAS_CHARACTERISTICS.md per factory
scripts/                   # generate-imports.js (run on compile), stablesurge-calculator.ts
```

## Commands

```
npm install
npm run compile            # hardhat compile: this repo's contracts + the @bush.fi/v3-* packages (artifacts, typechain)

npm run test:forge         # all Foundry tests           (forge test)
npm run test:hardhat       # all Hardhat tests           (hardhat test; needs `npm run compile` first)
npm run test:stable        # one family: weighted | lbp | stable | stable-surge | cow | template
npm run gas                # Hardhat gas benchmarks (writes test/hardhat/gas/.hardhat-snapshots/)

npm run maths:all          # generate test data from the factories, check the maths against it, run the maths suites
```

`maths:all` deploys every factory on a local Hardhat chain, creates pools through them, queries swaps / adds /
removes through the real Router, writes the results to `maths/testData/`, runs the TypeScript, Python and Rust
maths against that data through the `Vault` flow, and runs each language's own test suite on it. Every value
must match exactly. See [maths/check](./maths/check) for the pieces (`maths:generate`, `maths:check`,
`maths:test`) and the contributor workflow.

## Integration

Aggregators and routers should consume the [maths](./maths) package for their language rather than re-deriving
swap/join/exit math from the Solidity source. The `Vault` class in each language reproduces the full Vault flow
(scaling, rates, swap fees, hooks) on top of the pool maths, so its results are the raw amounts the on-chain
Router returns. See [maths/README.md](./maths/README.md).

## Contributing a new factory

Start with [CONTRIBUTING.md](./CONTRIBUTING.md) — a full walkthrough with a working template to copy. See
[GOVERNANCE.md](./GOVERNANCE.md) for the review process and
[.github/PULL_REQUEST_TEMPLATE.md](./.github/PULL_REQUEST_TEMPLATE.md) for the submission checklist.

## Licensing

- **Maths** (`maths/`, the packages integrators install): [MIT](./maths/typescript/LICENSE).
- **Contracts and tests**: each file's `SPDX-License-Identifier` header is authoritative. The factories here
  today are `GPL-3.0-or-later`, as they derive from Balancer's GPL code and inherit the GPL `@bush.fi/v3-*`
  packages; the root [LICENSE](./LICENSE) carries that text. A contributed factory may use a different license
  where its code is independent, stated in its headers and in its `docs/<factory>/README.md`.
