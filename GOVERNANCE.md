# Governance

This document describes how a new pool factory gets added to `bush-factories`, and how existing
entries are maintained.

## Submission process

1. Fork the repo and add a new `<name>-pool-factory/` directory following the structure in the
   root [README.md](./README.md).
2. Open a PR using [.github/PULL_REQUEST_TEMPLATE.md](./.github/PULL_REQUEST_TEMPLATE.md).
3. A maintainer assigns a review tier (below) based on the factory's novelty and risk.
4. On approval, the maintainer adds an entry to [registry.json](./registry.json) with
   `"status": "approved"` and the on-chain factory address once deployed.

## Review tiers

| Tier | Applies to | What's reviewed | Timeline |
| --- | --- | --- | --- |
| **Tier 1** | A new deployment of an already-audited, already-listed pool type (e.g. another `WeightedPoolFactory` instance) | Deployment parameters, registry metadata, math port parity with the existing entry | 1–3 business days |
| **Tier 2** | A parameter or hook variant of an existing pool type (e.g. a new surge hook on an existing math library) | Full contract diff review, hook interaction with the base pool, updated docs and math ports | 1–2 weeks |
| **Tier 3** | A wholly new pool type / math model not already represented in this repo | Full contract + math audit (external audit required for mainnet-bound factories), fuzz/invariant test coverage, cross-language math parity, security review | 3–6 weeks |

## What passes review

(The step-by-step guide to producing all of this is [CONTRIBUTING.md](./CONTRIBUTING.md).)

- Contracts and tests are copied verbatim from an auditable source (or accompanied by an audit
  report for net-new code).
- The pool type is supported by the TypeScript, Python **and** Rust packages under `bush-maths/`, the
  factory ships a `math-check/pool.ts` adapter, and `npm run maths:check` passes: every swap, add
  and remove queried from a pool deployed through the factory matches the maths exactly.
- `docs/PARAMETERS.md` documents every pool-creation parameter, its valid range, and its default.
- `docs/GAS_CHARACTERISTICS.md` documents gas costs for pool creation, swap, add-liquidity, and
  remove-liquidity, sourced from the test suite (e.g. `test/gas/*` benchmarks and snapshots).
- A `README.md` explains the pool type and gives an integration example.

## What fails review

- Contracts that diverge from the audited source without a linked audit covering the diff.
- Maths that disagree with the deployed pool, or a pool type missing from one of the languages.
- Missing or inaccurate parameter documentation (wrong ranges, undocumented validation rules).
- Factories for pool types that duplicate an existing entry without a meaningful behavioral
  difference (submit a Tier 1 deployment entry instead).

## After approval

- The factory's `registry.json` entry is updated with its deployed address and
  `"status": "approved"`.
- Any subsequent contract change requires a new PR and re-review at the appropriate tier — the
  registry entry is not edited in place for behavioral changes.
- Deprecated or superseded factories are marked `"status": "deprecated"` rather than removed, so
  integrators with existing references retain history.
