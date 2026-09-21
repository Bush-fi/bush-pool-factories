# @bush.fi/v3-deps

The published `@bush.fi/v3-*` packages ship Solidity sources only. The Hardhat tests in `pkg/*` expect each of
those packages to also carry compiled `artifacts/` and `typechain-types/`.

This workspace fills that gap: `contracts/Imports.sol` imports every contract from those packages, so a single
`hardhat compile` here produces artifacts and typechain types for all of them.

- `pvt/helpers/src/contract.ts` reads package artifacts (`deploy('v3-vault/Vault')`) from `pvt/deps/artifacts`.
- The root `tsconfig.json` maps imports such as `@bush.fi/v3-vault/typechain-types` onto `pvt/deps/typechain-types`
  (resolved at runtime by `tsconfig-paths`, which Hardhat loads automatically).
- `Permit2Deployer.ts` installs the canonical Permit2 bytecode at its mainnet address on the Hardhat network.

Run `npm run compile -w pvt/deps` once (or `npm run build` at the root) before running any `test:hardhat` script.
Re-run `npm run generate-imports -w pvt/deps` after bumping a package version.
