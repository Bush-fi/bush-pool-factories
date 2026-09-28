import { HardhatUserConfig } from 'hardhat/config';

import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-ethers';
import '@typechain/hardhat';

import 'hardhat-ignore-warnings';
import 'hardhat-gas-reporter';
import 'hardhat-contract-sizer';

import { compilers, overrides, warnings } from './hardhat-base-config';

const config: HardhatUserConfig = {
  paths: {
    sources: 'contracts',
    tests: 'test/hardhat',
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
      // `npm run live:check` forks a live chain (FORK_URL); everything else runs on a fresh local chain. Hardhat
      // doesn't know the hardfork history of chains outside its list, so give Robinhood Chain's.
      ...(process.env.FORK_URL
        ? { forking: { url: process.env.FORK_URL }, chains: { 4663: { hardforkHistory: { cancun: 0 } } } }
        : {}),
    },
  },
  solidity: {
    compilers,
    overrides,
  },
  warnings,
};

export default config;
