import { TokenConfigStruct } from '@typechain/@bush.fi/v3-interfaces/contracts/vault/IVault';
import { TokenType } from '@helpers/models/types/types';
import { ZERO_ADDRESS } from '@helpers/constants';

export function buildTokenConfig(tokens: string[], withRate?: boolean): TokenConfigStruct[] {
  const result: TokenConfigStruct[] = [];
  withRate = withRate ?? false;

  tokens.map((token, i) => {
    result[i] = {
      token: token,
      tokenType: withRate ? TokenType.WITH_RATE : TokenType.STANDARD,
      rateProvider: withRate ? token : ZERO_ADDRESS,
      paysYieldFees: withRate,
    };
  });

  return result;
}
