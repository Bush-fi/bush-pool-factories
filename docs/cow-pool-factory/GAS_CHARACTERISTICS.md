# CowPoolFactory — Gas Characteristics

**No gas benchmark data was available for this factory.** Unlike `stable-pool-factory`
and `stable-surge-pool-factory`, this package has no `test/gas/` benchmark suite or
`.hardhat-snapshots`. The numbers in this document are qualitative observations
derived from reading `contracts/CowPoolFactory.sol`, `contracts/CowPool.sol`, and
`contracts/CowRouter.sol` — they are **not** measured gas figures, and should not be
treated as such. Anyone needing real numbers should add a `test/gas/` benchmark and
generate a snapshot.

## Qualitative cost drivers

**Pool creation (`CowPoolFactory.create`)**
- Deploys a full `CowPool` (a `WeightedPool` subclass) via `BasePoolFactory._create`
  (CREATE3), then registers it with the Vault. This is comparable in shape to any other
  weighted-pool factory deployment, plus the extra `MinTokenBalanceLib.computeMinTokenBalances`
  loop (O(n) over tokens) and the `_setTrustedCowRouter` storage write in the `CowPool`
  constructor. Expect costs in the same broad range as a standard `WeightedPoolFactory`
  deployment (CREATE3 proxy + full pool bytecode), likely several hundred thousand gas,
  but this was not measured here.

**Swaps**
- Every swap on a `CowPool` triggers `onBeforeSwap`, an extra external-call-free storage
  read (`_trustedCowRouter`) and an address comparison — a small, roughly constant
  overhead (a single warm `SLOAD` plus a comparison) on top of whatever the underlying
  `WeightedPool` swap math costs. Swaps from any router other than the trusted CoW router
  revert immediately in the hook, before the AMM math executes, so failed/invalid-router
  swaps are comparatively cheap (they fail fast).

**Add liquidity**
- `onBeforeAddLiquidity` is called for every add; it's cheap (one storage read, one
  enum comparison, one address comparison) except that the factory disables all
  non-proportional add/remove liquidity (`disableUnbalancedLiquidity = true`), so in
  practice only proportional adds and router-initiated donations are possible. A
  donation add (`AddLiquidityKind.DONATION`) is additionally checked against the
  trusted router.

**`CowRouter.swapExactInAndDonateSurplus` / `swapExactOutAndDonateSurplus`**
- The most gas-intensive user-facing entry points in this factory's ecosystem: each
  call performs a full Vault `unlock` (flash-accounting session), a Vault `swap`, a
  loop over all pool tokens to split each donation amount into a donated portion and a
  protocol fee (`_donateToPool`), a conditional `_vault.addLiquidity` (donation) call,
  and a second per-token loop to settle credits/debts and transfer tokens
  (`_settleSwapAndDonation` → `_settleDonation`). Gas scales roughly linearly with the
  number of pool tokens (two O(n) loops plus one AMM swap), on top of the underlying
  `WeightedPool` swap cost.

**`CowRouter.donate`**
- Cheaper than the swap+donate path: skips the Vault `swap` call entirely, but still
  performs the same O(n) fee-split and O(n) settlement loops.

**`CowRouter.withdrawCollectedProtocolFees`**
- A single storage read/write (zeroing `_collectedProtocolFees[token]`) plus one
  `safeTransfer`; cheap and roughly constant per call.

## Recommendation

If accurate gas numbers are required for integration or fee-estimation purposes, run
the Foundry/Hardhat tests in `test/foundry/cow/` and `test/hardhat/cow/` (copied from the upstream `pool-cow` package) against a local
fork with `forge test --gas-report` or an equivalent Hardhat gas reporter, since no
pre-computed snapshot exists for this pool type.
