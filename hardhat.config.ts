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
    },
  },
  solidity: {
    compilers,
    overrides,
  },
  warnings,
};

export default config;
