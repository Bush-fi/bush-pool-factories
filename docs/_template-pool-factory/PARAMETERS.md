# ConstantSumPoolFactory — Parameters

`create(name, symbol, tokens, rate, roleAccounts, swapFeePercentage, salt)`

| Parameter | Type | Default | Min | Max | Meaning | Enforced by |
| --- | --- | --- | --- | --- | --- | --- |
| `name` / `symbol` | `string` | — | | | BPT name and symbol | — |
| `tokens` | `TokenConfig[]` | — | 2 | 2 | The two pool tokens, sorted by address | `create`: `ConstantSumPoolNeedsTwoTokens`; the Vault checks sorting and token config |
| `rate` | `uint256` (18 dec) | — | 1 wei | — | How many token1 one token0 is worth | `ConstantSumPool` constructor: `InvalidRate` if 0 |
| `roleAccounts` | `PoolRoleAccounts` | zero addresses | | | Pause manager, swap-fee manager, pool creator | Vault |
| `swapFeePercentage` | `uint256` (18 dec) | — | 0 | 10% (`10e16`) | Static swap fee | Vault, via the pool's `getMinimum/MaximumSwapFeePercentage` |
| `salt` | `bytes32` | — | | | CREATE2 salt | — |

Liquidity settings are the defaults: unbalanced add/remove allowed, donations disabled, no custom liquidity
operations. Unbalanced operations may move the invariant between 50% and 200% of its value
(`getMinimum/MaximumInvariantRatio`).
