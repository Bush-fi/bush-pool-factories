// Resolve the `paths` aliases from tsconfig.json (`@helpers/*`, `@typechain/*`, `@bush.fi/maths`) at runtime;
// Hardhat's ts-node doesn't on its own.
import 'tsconfig-paths/register';

import { WarningRule } from 'hardhat-ignore-warnings/dist/type-extensions';

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
  // Mocks (ours and the ones pulled in through contracts/test/Imports.sol) may exceed the deployable code size; we
  // don't care about that in tests.
  'contracts/test/**/*': { 'code-size': 'off' as WarningRule },
  '@bush.fi/**/*': { 'code-size': 'off' as WarningRule },
  '*': {
    'code-size': 'warn' as WarningRule,
    'unused-param': 'warn' as WarningRule,
    'shadowing-opcode': 'off' as WarningRule,
    'transient-storage': 'off' as WarningRule,
    'initcode-size': 'off' as WarningRule,
    default: 'error' as WarningRule,
  },
};

export const overrides: Record<string, SolcConfig> = Object.fromEntries(
  Object.entries(contractSettings).map(([contract, { version, runs }]) => [contract, solcSettings(version, runs)])
);
