# RukusLaunch Pool Factory

A token launch pool. It sells a new token along a pump.fun-style bonding curve, and when the curve sells out it
graduates **in place** into a (practically) full-range pool that trades like a 50/50 constant-product pool. There's
no migration step and no second pool: the same address, balances and BPT carry on.

## Pool Type

RUKUS_LAUNCH

## Overview

`RukusLaunchPoolFactory.create` launches a token in one transaction, like pump.fun:

1. It deploys a new **launch token** (`RukusLaunchToken`): a plain ERC20, 18 decimals, fixed supply, no owner and
   no mint.
2. It creates a 2-token `RukusLaunchPool` between the launch token and **WETH** (always WETH, set when the factory
   is deployed, so no launch can be paired with a look-alike token). Buyers can pay in ETH through the Router.
3. It initializes the pool with the **whole supply** and no quote, and mints the initial BPT to the burn address
   `0x…dEaD`.
4. The pool is registered as its **own pool creator**, and when initialized it fixes the creator share of the swap fee
   at 99.999% (the fee controller's maximum) while bonding. There is no pause manager, and the pool is its own swap
   fee manager: nobody else (governance included) can change the fee rate.
5. If ETH is sent with `create`, it makes the **creator's initial buy** in the same transaction (tokens to the caller,
   at least `minInitialBuyAmountOut`), so no one can buy ahead of the creator.

`RukusLaunchCreated` carries the pool, the token, the creator, the supply, the `metadataURI` and the initial buy.

The `metadataURI` (a JSON with the image, description and links, ideally on IPFS or Arweave) is also stored in the
launch token as its ERC-7572 `contractURI()`, set once at `create` and fixed for good, as on pump.fun: the token has
no owner and no setter, so the image and description can't be swapped after people buy. The pool returns the token
(`getLaunchToken()`), so a frontend reads the metadata from there.

So every launch token in circulation was bought from the curve, nobody holds BPT that could withdraw the raise, and
nobody else can initialize the pool first. `getLaunchTokenAddress(launch, creator, salt)` predicts the token's address
(and so its sort order) before `create`.

The pool has three phases (`getBondingPhase()`):

| Phase | Swaps | Liquidity | Virtual balances |
| --- | --- | --- | --- |
| `BONDING` | Buy and sell on the curve | Locked (adds and removes revert `LiquidityLockedUntilGraduation`) | Fixed |
| `COMPLETED` | Revert `GraduationPending` for the rest of the block | Same as swaps | Fixed until graduation |
| `GRADUATED` | Full range (ReClamm's swap maths) | Proportional adds and removes | Tiny and fixed (scale with adds and removes only) |

**Bonding.** The curve is `(Rt + Vt)(Rq + Vq) = k`: constant product with virtual reserves, exactly pump.fun's, and
also exactly ReClamm's swap formula with the virtual balances held fixed. The **factory** fixes the supply and two
prices for every launch, when it is deployed: the `initialPrice` and the `graduationPrice`. Launchers never set them
(`create` takes neither); a different shape is a different factory. The pool sets the virtual balances so that it
reaches the graduation price when the ETH raised equals the value of the launch tokens left. With
`r = sqrt(graduationPrice / initialPrice)`, that happens when `supply / (r + 1)` launch tokens are left.

**Completion.** When a buy takes the launch balance to the graduation balance or below, the curve is complete. Nothing
can trade for the rest of that block. The completing buy may go past the graduation balance by at most
`MAX_GRADUATION_OVERSHOOT` (0.1% of it); a bigger buy reverts with `GraduationBuyTooLarge(maxLaunchAmountOut)`, which
says how much can be bought. Like pump.fun's capped last buy, this keeps the graduated range's top high (below).
Frontends should size the final buy with `getMaxBuyAmount()` (the most launch tokens a buy can take right now) as an
exact-out buy.

**Graduation.** The first swap, add or remove in a later block (or anyone calling `graduate()`) graduates the pool. The
virtual balances are re-solved, keeping the current price, for a range of `GRADUATED_PRICE_RATIO` = 1e12 (max price /
min price): from a millionth to a million times the graduation price. The virtual balances come out at about 0.1% of
the real ones, so the pool trades like a 50/50 constant-product pool (within ~0.1% on depth). They can't be zero: the
pool graduates slightly unbalanced (the fee stays on the quote side; a final buy can overshoot), and non-zero virtual
balances are what let graduation keep the price exactly.

**After graduation nothing moves with time.** No range shift, no re-centering, no narrowing: the virtual balances only
scale with proportional adds and removes (which keep the price). So the price only ever moves with trades.

Why 1e12 and not wider: the graduation solve stays exact far beyond it, but for unbalanced graduations one virtual
balance shrinks toward rounding size as the width grows (about 1e36x is where it breaks). 1e12x keeps it ~1e6x above
rounding for any launch the factory accepts (`testGraduationAtFullRangeNeverReverts__Fuzz`), and wider would change
nothing in practice.

**The top of the range depends on how the curve completes.** With exact completion and a 1% fee, the range runs to
about 120,000x above the graduation price. A completing buy that overshoots the graduation balance leaves the pool
quote-heavy, and keeping the price then needs a larger virtual launch balance, which lowers the top. That is why the
overshoot is capped at 0.1% (top ~92,000x); for reference, what larger overshoots would have done:

| Completing buy past the graduation balance | 0 | 0.1% | 1% | 5% | 10% | 30% | 50% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Top of the range (x graduation price) | 123,000 | 92,000 | 17,000 | 1,300 | 356 | 38 | 11 |

Above the top, the pool has no launch tokens left to sell until holders sell some back.

Why the one-block freeze: graduation swaps the curve's large virtual reserves for tiny ones, which changes the depth
around the price (it gets shallower). The freeze keeps any trade from spanning both shapes in one transaction.

**Fees leave the pool.** The Vault takes the protocol and creator shares out of every trade before crediting the pool,
and with a 99.999% creator share that is all but 0.001% of the fee. So the curve stays exactly on its prices however
much is traded while bonding, the pool graduates balanced (at exactly the configured graduation price and reserves),
and the graduated range never widens. Creator fees are paid to the launch's `creatorFeeRecipient` (a user or a
contract) by `withdrawCreatorFees()`, which anyone can call. The creator share changes exactly once, at graduation, to
the launch's `graduatedCreatorFeePercentage` (at least the factory's `minGraduatedCreatorFeePercentage`); nothing else
can change it: only the pool creator can, and the pool has no other function that does. The protocol's share (set by governance) comes first; the
creator gets the rest.

The 5 ETH preset (a factory deployed with these values; `testLaunchPreset5Eth`): 1B tokens, 800M sold on the curve and
200M left for the pool, graduating at 5 ETH of real reserves. Tokens left at graduation are `supply / (r + 1)` with `r = sqrt(graduationPrice /
initialPrice)`, so 200M of 1B means `r = 4` and a 16x curve: `graduationPrice` = 5 ETH / 200M = 0.000000025 ETH and
`initialPrice` = 0.0000000015625 ETH (market cap 1.5625 ETH at launch, 25 ETH at graduation).

### Trust assumptions

- **The raise is permanent liquidity.** The initial BPT is burned, so neither the creator nor anyone else can withdraw
  the quote raised, before or after graduation, including through recovery mode. After graduation, anyone can add
  liquidity proportionally and later withdraw their own share (and only that).
- **No pause manager.** The factory never sets one. Governance can still pause during the factory's pause window; with no
  BPT holder, a recovery-mode exit has nobody to pay out.
- **The fee rate** is set at launch, within [0.001%, 5%], and the pool is its own swap fee manager, so nobody can
  change it. At graduation the pool sets the Vault's static swap fee to the launch's `graduatedSwapFeePercentage`
  itself: there is no dynamic fee hook, so `getStaticSwapFeePercentage(pool)` is the fee charged in every phase, and
  aggregators can quote the pool from it. (The swap that graduates the pool still pays the bonding fee: the Vault loads
  a swap's fee before the hook that graduates it.) Graduation can't happen while the pool is paused.
- **No price drift.** Because nothing moves with time, pushing the price and waiting gains nothing (tested: push-and-hold
  loses for any push and hold of up to a year). Earlier designs with a moving or narrowing range were exploitable this
  way when the pool is the token's only market.
- **The bottom of the range is out of reach.** The whole supply starts in the pool, so the most that can ever be sold
  back is every circulating token; at graduation that can't come near a floor a million times below the price.

## Key Files

- Contracts: [`contracts/rukus-launch/`](../../contracts/rukus-launch) (the pool, the factory, and
  `RukusLaunchToken`). The swap maths is [`ReClammMath`](../../contracts/reclamm/lib/ReClammMath.sol),
  unchanged; `lib/RukusLaunchMath.sol` adds the curve setup and the graduation solve.
- Tests: [`test/foundry/rukus-launch/`](../../test/foundry/rukus-launch), including attack scenarios
  (`RukusLaunchAttacks.t.sol`) and a volatility simulation (`RukusLaunchVolatilitySim.t.sol`, run with
  `FOUNDRY_GAS_LIMIT=9000000000 RUN_SIM=true`)
- Maths: [`maths/`](../../maths) (TypeScript, Python, Rust; checked against the deployed pool by
  `npm run maths:check -- rukus-launch-pool-factory`)
- How to run the tests: [TESTING.md](./TESTING.md); latest results: [TEST_REPORT.md](./TEST_REPORT.md)
- Parameters: [PARAMETERS.md](./PARAMETERS.md)
- Gas costs: [GAS_CHARACTERISTICS.md](./GAS_CHARACTERISTICS.md)
- License: GPL-3.0-or-later (derived from ReClammPool and the `@bush.fi/v3-*` contracts)

## Integration (For Aggregators)

Use the [maths](../../maths) package for your language. Its `Vault` reproduces the on-chain result (scaling, fees)
for this pool type in every phase. That includes a `COMPLETED` pool queried in a later block, where the maths runs
the graduation first, as the contract does:

```typescript
import { Vault, SwapKind } from '@bush.fi/maths';

const amountOut = new Vault().swap({ amountRaw, tokenIn, tokenOut, swapKind: SwapKind.GivenIn }, poolState);
```

`poolState` is `getRukusLaunchPoolDynamicData()`, plus `graduatedPriceRatio` from
`getRukusLaunchPoolImmutableData()` and the `currentTimestamp` to price at (only used to tell whether a `COMPLETED`
pool would graduate) (see
`maths/testData/*rukus-launch-pool-factory*.json` for the exact shape). Points to handle in routing:

- While `BONDING`, sells can only pay out quote that buyers put in (`AmountOutGreaterThanBalance`).
- In the block a buy completes the curve, every swap reverts. Skip the pool until the next block.
- While `BONDING`, a buy can take the launch balance down to at most 0.1% below `graduationLaunchBalance`
  (`GraduationBuyTooLarge`); the maths package's `getMaxSwapAmount` stops there.
