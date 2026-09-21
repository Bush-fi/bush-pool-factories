import { Contract } from 'ethers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/dist/src/signer-with-address';
import { HooksConfigStruct, LiquidityManagementStruct } from '@bush.fi/v3-vault/typechain-types/contracts/Vault';
import { ZERO_ADDRESS } from '../../constants';

export type NAry<T> = T | Array<T>;

export type Account = string | SignerWithAddress | Contract | { address: string };

export type TxParams = {
  from?: SignerWithAddress;
};

export enum TokenType {
  STANDARD = 0,
  WITH_RATE,
  ERC4626,
}

export type TokenConfig = {
  token: string;
  tokenType: TokenType;
  rateProvider: string;
  paysYieldFees: boolean;
};

export function defaultPoolHooks(): HooksConfigStruct {
  return {
    enableHookAdjustedAmounts: false,
    shouldCallBeforeInitialize: false,
    shouldCallAfterInitialize: false,
    shouldCallComputeDynamicSwapFee: false,
    shouldCallBeforeSwap: false,
    shouldCallAfterSwap: false,
    shouldCallBeforeAddLiquidity: false,
    shouldCallAfterAddLiquidity: false,
    shouldCallBeforeRemoveLiquidity: false,
    shouldCallAfterRemoveLiquidity: false,
    hooksContract: ZERO_ADDRESS,
  };
}

export function defaultLiquidityManagement(): LiquidityManagementStruct {
  return {
    disableUnbalancedLiquidity: false,
    enableAddLiquidityCustom: false,
    enableRemoveLiquidityCustom: false,
    enableDonation: false,
  };
}
