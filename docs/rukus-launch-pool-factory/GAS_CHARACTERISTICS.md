# Gas Characteristics

Total transaction gas, measured end to end by the Hardhat test (`test/hardhat/rukus-launch/rukusLaunchPool.test.ts`)
through the real `Router`, paying in ETH (`wethIsEth`), on the 5 ETH preset (1B tokens, 800M on the curve, 1% fee,
99.999% creator fee share).

| Operation | Gas |
| --- | --- |
| `create`, with a 0.1 ETH initial buy (token, pool, register, initialize, burn the BPT, set the creator fee, buy) | ~5.41M |
| Bonding buy, ETH in | ~164k–181k |
| Bonding sell, for ETH | ~196k |
| Buy that completes the curve (exact out, sized with `getMaxBuyAmount`) | ~175k |
| First buy after completion (graduates, then swaps) | ~192k |
| Graduated buy, ETH in | ~163k |
| Graduated sell, for ETH | ~179k |
| `withdrawCreatorFees` (collect from the Vault, pay the recipient) | ~257k |

## What drives the cost

- **Swaps** are ReClamm's swap formula on stored virtual balances, in every phase. Nothing is time-adjusted, so a swap
  costs the same whenever it happens. Each swap also books the protocol and creator fee share in the Vault. Only the
  buy that completes the curve writes pool state (the completion timestamp and an event).
- **Graduation** costs ~26k on top of a swap: the solve (two square roots) and one write of the virtual balances, with
  two events and a Vault auxiliary event. It runs once in the pool's life, paid by whoever trades first after
  completion (or calls `graduate()`).
- **Proportional adds and removes** also rescale and store the virtual balances (keeping the price).
- **Sizes.** `RukusLaunchPool` is 19.5 KB of runtime code and the factory 13.2 KB at the repo's default optimizer
  settings (9,999 runs, via-IR), under the 24 KB limit.
