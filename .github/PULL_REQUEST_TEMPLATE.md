## Summary

<!-- What factory/pool type does this PR add or change, and why? -->

## Checklist

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the walkthrough.


- [ ] Code follows the Bush factory interface (`IBasePoolFactory` / `BasePoolFactory`)
- [ ] Contracts are copied verbatim from an auditable source, or a linked audit covers any new code
- [ ] Tests are copied verbatim from the source repo (or added, for net-new code) and pass locally
- [ ] Pool type supported in `bush-maths/typescript`, `bush-maths/python` **and** `bush-maths/rust`
- [ ] `math-check/pool.ts` adapter added; `npm run maths:check` passes and the regenerated
      `bush-maths/testData/` files are included
- [ ] `docs/PARAMETERS.md` documents every pool-creation parameter, its range, and its default
- [ ] `docs/GAS_CHARACTERISTICS.md` documents gas costs for creation, swap, add-liquidity, and
      remove-liquidity
- [ ] Factory `README.md` explains the pool type and gives an integration example
- [ ] `registry.json` entry added/updated (address left as `0x0…0` until deployed)
- [ ] Security audit linked, if this introduces a new math model or Tier 3 change (see
      [GOVERNANCE.md](../GOVERNANCE.md))

## Review tier requested

- [ ] Tier 1 — new deployment of an existing, already-listed pool type
- [ ] Tier 2 — parameter or hook variant of an existing pool type
- [ ] Tier 3 — new pool type / math model

## Test plan

<!-- How did you verify the contracts, tests, and math ports? -->
