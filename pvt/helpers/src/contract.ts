import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { Artifacts } from 'hardhat/internal/artifacts';
import { Artifact } from 'hardhat/types';
import path from 'path';
import { Dictionary } from 'lodash';

/* eslint-disable @typescript-eslint/no-explicit-any */

export type ContractDeploymentParams = {
  from?: SignerWithAddress;
  args?: Array<unknown>;
  libraries?: Dictionary<string>;
};

// Deploys a contract, with optional `from` address and arguments.
// Local contracts are deployed by simply passing the contract name. Contracts from the published `@bush.fi/v3-*`
// packages must be prefixed by the package name, without the @bush scope; their artifacts come from the shared
// `pvt/deps` build (see `getArtifact`). Note that the full path is never required.
//
// For example, to deploy a factory's own WeightedPool.sol, use `deploy('WeightedPool')`. To deploy the Vault from
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

export function getArtifact(contract: string): Artifact {
  let artifactsPath: string;
  if (!contract.includes('/')) {
    artifactsPath = path.resolve('./artifacts');
  } else {
    // The npm packages don't ship artifacts; `@bush.fi/v3-deps` compiles all of them into one artifacts tree.
    const depsPath = path.dirname(require.resolve('@bush.fi/v3-deps/package.json'));
    artifactsPath = path.join(depsPath, 'artifacts');
  }

  const artifacts = new Artifacts(artifactsPath);
  return artifacts.readArtifactSync(contract.split('/').slice(-1)[0]);
}
