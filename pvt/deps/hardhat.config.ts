import { HardhatUserConfig } from 'hardhat/config';

import '@nomicfoundation/hardhat-toolbox';
import '@nomicfoundation/hardhat-ethers';
import '@typechain/hardhat';

import 'hardhat-ignore-warnings';

import { compilers, overrides, warnings } from '@bush.fi/v3-common/hardhat-base-config';

const config: HardhatUserConfig = {
  solidity: {
    compilers,
    overrides: overrides('@bush.fi/v3-deps'),
  },
  warnings,
};

export default config;
