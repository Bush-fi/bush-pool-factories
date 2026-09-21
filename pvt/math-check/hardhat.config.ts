import { HardhatUserConfig } from 'hardhat/config';

import '@nomicfoundation/hardhat-ethers';

import { compilers, warnings } from '@bush.fi/v3-common/hardhat-base-config';

// No contracts of its own: the harness deploys pools from the factory packages' artifacts and pvt/deps.
const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  solidity: { compilers },
  warnings,
};

export default config;
