# Gas Characteristics

No gas snapshot suite exists for `WeightedPool8020Factory` in this package (`weighted-pool-factory`'s
benchmark covers the base `WeightedPool` contract rather than the 8020-specific factory). No numbers are fabricated here -- this document describes gas
characteristics qualitatively, based on reading the contract logic in `contracts/WeightedPool8020Factory.sol` and
`contracts/WeightedPool.sol`.

## Pool creation

`WeightedPool8020Factory.create()` is cheaper to call than `WeightedPoolFactory.create()` for the equivalent 2-token
case, for a few concrete reasons visible in the source:

- It takes only 4 parameters (`highWeightTokenConfig`, `lowWeightTokenConfig`, `roleAccounts`, `swapFeePercentage`)
  versus 9 for the general factory, so calldata is smaller.
- It always builds a fixed 2-element `TokenConfig[]` / weights array in `_calculateConstructorArgs`, avoiding any
  loop over a caller-supplied token array of variable length (up to 8 tokens in the general factory).
  `MinTokenBalanceLib.computeMinTokenBalances` is still called once per token (2 external `decimals()` calls), same
  as the general factory would incur for a 2-token pool.
- It calls `IERC20Metadata(token).symbol()` on both tokens to build the auto-generated `name`/`symbol` strings
  (`string.concat`), which the general factory does not do (name/symbol are passed directly by the caller) --
  this adds 2 extra external calls plus string-concatenation gas that `WeightedPoolFactory.create()` does not incur.
- It skips accepting `poolHooksContract`/`enableDonation`/`disableUnbalancedLiquidity`, always using
  `getDefaultPoolHooksContract()` and `getDefaultLiquidityManagement()`, which avoids a small amount of
  `LiquidityManagement` struct mutation.

Net effect: creation gas should be in a similar range to a 2-token `WeightedPoolFactory.create()` call, likely
slightly higher due to the two `symbol()` calls and string concatenation, and slightly lower due to less calldata
and no hooks/hooks-flag handling. No measured number is available; do not assume a specific gas figure without
benchmarking against the deployed bytecode.

## Swap / Add liquidity / Remove liquidity

Once deployed, an 80/20 pool is a standard 2-token `WeightedPool` -- its swap, add-liquidity, and remove-liquidity
gas costs are governed by the same `WeightedPool.sol` / `WeightedMath.sol` code as `weighted-pool-factory`, with no
8020-specific logic in the hot paths. The 2-token, "Standard" (no rate provider) rows from
`weighted-pool-factory/docs/GAS_CHARACTERISTICS.md` (sourced from that factory's real gas snapshots) are a
reasonable proxy, since the underlying `onSwap` / `computeInvariant` / `computeBalance` code paths are identical:

| Operation | Gas (approx, borrowed from weighted-pool-factory Standard/2-token snapshots) |
|---|---|
| Swap, single token, exact in, with fees — warm slots | ~151.0k |
| Add liquidity, proportional | ~179.4k |
| Add liquidity, unbalanced — warm slots | ~213.5k |
| Remove liquidity, proportional | ~166.2k |

These are borrowed estimates from a sibling pool sharing identical swap/liquidity logic, not measurements taken
against `WeightedPool8020Factory`-deployed pools -- treat them as directional only.
