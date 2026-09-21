// Resolve the `paths` aliases from the root tsconfig at runtime (Hardhat's ts-node doesn't on its own). The tests
// import typechain types from the published @bush.fi/v3-* packages, which are mapped onto the pvt/deps build.
import 'tsconfig-paths/register';

import { WarningRule } from 'hardhat-ignore-warnings/dist/type-extensions';
import './skipFoundryTests';

type SolcConfig = {
  version: string;
  settings: {
    viaIR: boolean;
    evmVersion: string;
    optimizer: {
      enabled: boolean;
      runs?: number;
      details: { yulDetails: { optimizerSteps: string } };
    };
  };
};

// The coverage report doesn't work well with via-ir flags, so we disable it.
const viaIR = !(process.env.COVERAGE === 'true');

export const DEFAULT_OPTIMIZER_STEPS =
  'dhfoDgvulfnTUtnIf [ xa[r]EscLM cCTUtTOntnfDIul Lcul Vcul [j] Tpeul xa[rul] xa[r]cL gvif CTUca[r]LSsTFOtfDnca[r]Iulc ] jmul[jul] VcTOcul jmul : fDnTOcmu';

const optimizerSteps = process.env.COVERAGE === 'true' ? ':' : DEFAULT_OPTIMIZER_STEPS;

const solcSettings = (version: string, runs = 9999): SolcConfig => ({
  version,
  settings: {
    viaIR,
    evmVersion: 'cancun',
    optimizer: { enabled: true, runs, details: { yulDetails: { optimizerSteps } } },
  },
});

export const compilers: SolcConfig[] = [solcSettings('0.8.26'), solcSettings('0.8.27')];

// The Vault is deployed with a lower optimizer run count to stay under the contract size limit.
const contractSettings: Record<string, { version: string; runs: number | undefined }> = {
  '@bush.fi/v3-vault/contracts': { version: '0.8.26', runs: 9999 },
  '@bush.fi/v3-vault/contracts/Vault.sol': { version: '0.8.26', runs: 500 },
  '@bush.fi/v3-vault/contracts/VaultExtension.sol': { version: '0.8.26', runs: 500 },
};

export const warnings = {
  // Mocks may exceed the deployable code size; we don't care about that in tests.
  'contracts/test/**/*': { 'code-size': 'off' as WarningRule },
  '*': {
    'code-size': 'warn' as WarningRule,
    'unused-param': 'warn' as WarningRule,
    'shadowing-opcode': 'off' as WarningRule,
    'transient-storage': 'off' as WarningRule,
    'initcode-size': 'off' as WarningRule,
    default: 'error' as WarningRule,
  },
};

export const overrides = (packageName: string): Record<string, SolcConfig> => {
  const result: Record<string, SolcConfig> = {};

  for (const contract of Object.keys(contractSettings)) {
    result[contract.replace(`${packageName}/`, '')] = solcSettings(
      contractSettings[contract].version,
      contractSettings[contract].runs
    );
  }

  return result;
};

export const hardhatBaseConfig = { compilers, overrides, warnings };
