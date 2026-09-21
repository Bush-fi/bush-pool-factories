## Summary

<!-- What factory / pool type does this PR add or change, and why? -->

## Before opening this PR

A factory PR includes the contracts, their tests, the maths in at least one language, and the adapter that
proves the maths against the contracts. Everything must be green locally first
(see [CONTRIBUTING.md](../CONTRIBUTING.md) for the walkthrough):

- [ ] Contracts in `contracts/<family>/`, tests in `test/foundry/<family>/` (and `test/hardhat/<family>/` if any)
- [ ] Maths in at least one of `maths/typescript`, `maths/python`, `maths/rust`; adapter in
      `maths/check/adapters/`; regenerated `maths/testData/` files included
- [ ] Docs in `docs/<factory>/` and a row in the root `README.md` table
- [ ] All green: `npm run test:forge`, `npm run test:hardhat`, `npm run maths:all`
- [ ] Audit linked, if this adds new contract code or a new maths model

## Test output

<!-- Paste the summary lines from `npm run maths:all` (the ✅ per language/variant, and "every result matches"). -->
