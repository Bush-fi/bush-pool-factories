# Governance

This document describes how a new pool factory gets added to `bush-factories`, and how existing
entries are maintained.

## Submission process

1. Fork the repo and add the factory following [CONTRIBUTING.md](./CONTRIBUTING.md).
2. Open a PR using [.github/PULL_REQUEST_TEMPLATE.md](./.github/PULL_REQUEST_TEMPLATE.md).
3. On approval, the maintainer adds the factory to the table in the root [README.md](./README.md); deployed
   addresses are recorded in the Bush deployment repo.

## What passes review

(The step-by-step guide to producing all of this is [CONTRIBUTING.md](./CONTRIBUTING.md).)

- Contracts and tests are copied verbatim from an auditable source (or accompanied by an audit
  report for net-new code), with an `SPDX-License-Identifier` header on every file.
- The pool type is implemented in at least one of the maths packages under `maths/` (TypeScript, Python or
  Rust), the factory has an adapter in `maths/check/adapters/`, and `npm run maths:check` passes for every
  language it is implemented in: every swap, add and remove queried from a pool deployed through the factory
  matches the maths exactly. The other languages can follow in later PRs.
- `docs/<factory>/PARAMETERS.md` documents every pool-creation parameter, its valid range, and its default.
- `docs/<factory>/GAS_CHARACTERISTICS.md` documents gas costs for pool creation, swap, add-liquidity, and
  remove-liquidity, sourced from the test suite (e.g. `test/hardhat/gas/` benchmarks and snapshots).
- `docs/<factory>/README.md` explains the pool type and gives an integration example.

## What fails review

- Contracts that diverge from the audited source without a linked audit covering the diff.
- Maths that disagree with the deployed pool.
- Missing or inaccurate parameter documentation (wrong ranges, undocumented validation rules).
- Factories for pool types that duplicate an existing entry without a meaningful behavioral
  difference.

## After approval

- The factory is deployed and its address recorded in the Bush deployment repo.
- Any subsequent contract change requires a new PR and re-review.
- Deprecated or superseded factories are marked `"status": "deprecated"` rather than removed, so
  integrators with existing references retain history.
