import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { Artifact } from 'hardhat/types';
import fs from 'fs';
import path from 'path';
import { Dictionary } from 'lodash';

/* eslint-disable @typescript-eslint/no-explicit-any */

export type ContractDeploymentParams = {
  from?: SignerWithAddress;
  args?: Array<unknown>;
  libraries?: Dictionary<string>;
};

// Deploys a contract, with optional `from` address and arguments.
// Contracts from this repo are deployed by simply passing the contract name. Contracts from the published
// `@bush.fi/v3-*` packages must be prefixed by the package name, without the @bush scope (their artifacts are compiled
// through contracts/test/Imports.sol). Note that the full path is never required.
//
// For example, to deploy this repo's WeightedPool.sol, use `deploy('WeightedPool')`. To deploy the Vault from
// @bush.fi/v3-vault, use `deploy('v3-vault/Vault')`.
export async function deploy<T>(
  contract: string,
  { from, args, libraries }: ContractDeploymentParams = {}
): Promise<T> {
  if (!args) args = [];
  if (!from) from = (await ethers.getSigners())[0];

  const artifact = getArtifact(contract);

  const factory = await ethers.getContractFactoryFromArtifact(artifact, { signer: from, libraries });
  const instance = await factory.deploy(...args);

  return instance.waitForDeployment() as unknown as T;
}

// Creates a contract object for a contract deployed at a known address. The `contract` argument follows the same rules
// as in `deploy`.
export async function deployedAt(contract: string, address: string): Promise<Contract> {
  const artifact = getArtifact(contract);
  return ethers.getContractAt(artifact.abi, address);
}

// Several of this repo's contracts have the same name as a contract in the npm packages (WeightedPool, StablePool, ...),
// so a bare name is ambiguous within the single artifacts tree. The prefix decides which subtree is searched:
// `Name` -> artifacts/contracts/, `v3-<pkg>/Name` -> artifacts/@bush.fi/v3-<pkg>/, any other `<dir>/Name` ->
// artifacts/<dir>/ (e.g. `permit2/IPermit2`).
export function getArtifact(contract: string): Artifact {
  const segments = contract.split('/');
  const name = segments[segments.length - 1];
  const subtree = segments.length === 1 ? 'contracts' : segments[0].startsWith('v3-') ? path.join('@bush.fi', segments[0]) : segments[0];
  const root = path.resolve('artifacts', subtree);

  const matches = findArtifacts(root, `${name}.json`);
  if (matches.length === 0) throw new Error(`No artifact for ${contract} under ${root}; did you run 'npm run compile'?`);
  if (matches.length > 1) throw new Error(`Ambiguous artifact ${contract}: ${matches.join(', ')}`);

  return JSON.parse(fs.readFileSync(matches[0], 'utf8'));
}

function findArtifacts(dir: string, fileName: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? findArtifacts(full, fileName) : entry.name === fileName ? [full] : [];
  });
}
