# Parameters

Two levels of parameters. The **factory** fixes the supply and the bonding curve of every launch when it is deployed;
a launcher never sets them. The **launch** (`create`) only chooses the token's name and symbol, the creator fee
recipient, the metadata, the fee rate and an optional initial buy. Amounts below use the 5 ETH preset: 1B tokens, 800M
sold on the curve and 200M left for the pool, graduating at 5 ETH.

Values and bounds are read from `contracts/bonding-reclamm/BondingReClammPoolFactory.sol`,
`contracts/bonding-reclamm/lib/BondingReClammPoolFactoryLib.sol` and `contracts/bonding-reclamm/BondingReClammPool.sol`.
Prices are 18-decimal fixed point: the price of one whole launch token in ETH.

## Factory (constructor): fixed for every launch

`new BondingReClammPoolFactory(vault, pauseWindowDuration, weth, launchSupply, curve, factoryVersion, poolVersion)`.
Read back with `getLaunchConfig()` and `getWeth()`. A different supply or curve is a different factory deployment.

| Name | Type | 5 ETH preset | Min | Max | Description | Validation |
| --- | --- | --- | --- | --- | --- | --- |
| `vault` | `IVault` | — | — | — | The Vault. | — |
| `pauseWindowDuration` | `uint32` | — | — | — | How long governance can pause this factory's pools. With the BPT burned, a pause can halt trading but not drain anything. | `BasePoolFactory`. |
| `weth` | `IWETH` | WETH | — | — | The quote token of every launch. Buyers can pay in ETH through the Router. | Non-zero, or `InvalidWeth()`. |
| `launchSupply` | `uint256` | `1_000_000_000e18` (1B) | > 0 | `1e12 * 1e18` | Every launch token's whole supply (18 decimals), all of it put in the pool. | `InvalidLaunchSupply()`. |
| `curve.initialPrice` | `uint256` | `0.0000000015625e18` ETH | > 0 | — | Price when the pool holds no ETH. | `> 0`, or `InvalidBondingPrices()`. |
| `curve.graduationPrice` | `uint256` | `0.000000025e18` ETH (16x) | `initialPrice * 1.01` | `initialPrice * 1e6` | Price at which the curve completes. The pool is then balanced: ETH raised = `graduationPrice` × launch tokens left. | `> initialPrice`, or `InvalidBondingPrices()`; `graduationPrice / initialPrice` in [`MIN_BONDING_PRICE_RATIO`, `MAX_BONDING_PRICE_RATIO`], or `BondingPriceRatioOutOfBounds(ratio)`. |
| `factoryVersion`, `poolVersion` | `string` | — | — | — | Version strings. | — |

What the supply and the two prices give, with `S` the supply and `r = sqrt(graduationPrice / initialPrice)`:

| | Formula | 5 ETH preset (r = 4) |
| --- | --- | --- |
| Launch tokens left at graduation | `S / (r + 1)` | 200M (20%); 800M sold on the curve |
| ETH raised at graduation | `graduationPrice × S / (r + 1)` | 0.000000025 × 200M = 5 ETH |
| Market cap at launch / at graduation | `initialPrice × S` / `graduationPrice × S` | 1.5625 ETH / 25 ETH |
| Virtual launch balance | `S × initialPrice / (graduationPrice − initialPrice)` | `S / 15` ≈ 66.7M |
| Virtual ETH balance | `initialPrice × (S + Vt)` | 0.0000000015625 × 1.0667B ≈ 1.67 ETH |
| Graduated pool | — | 200M tokens + 5 ETH at 0.000000025 ETH (unchanged by graduation) |

To design a different preset: the share left for the pool fixes the curve (`S / (r + 1)`, so 20% left means `r = 4`, a
16x curve), and the raise then sets the graduation price (raise ÷ tokens left).

## Launch (`create`): chosen per launch

`create(launch, swapFeePercentage, salt)` (payable) returns `(pool, launchToken)`. Roles are fixed: no pause manager,
no swap fee manager, and the pool is its own pool creator.

| Name | Type | Default | Min | Max | Description | Validation |
| --- | --- | --- | --- | --- | --- | --- |
| `launch.name` | `string` | — | — | — | Launch token name. The BPT is named `<name> Bonding Pool`. | None. |
| `launch.symbol` | `string` | — | — | — | Launch token symbol. The BPT symbol is `<symbol>-BRECLAMM`. | None. |
| `launch.creatorFeeRecipient` | `address` | — | — | — | Where creator fees are paid (a user or a contract). Fixed for good. | Non-zero, or `InvalidCreatorFeeRecipient()`. |
| `launch.metadataURI` | `string` | — | — | — | Off-chain metadata (image, description, links). Emitted in `BondingLaunchCreated`, not stored. | None. |
| `launch.minInitialBuyAmountOut` | `uint256` | `0` | — | — | With ETH sent: the fewest launch tokens the creator's initial buy accepts. | The Vault's swap limit. |
| `msg.value` | ETH | `0` | — | — | The creator's initial buy, made in the same transaction; launch tokens go to the caller. Subject to the overshoot cap like any buy. | `GraduationBuyTooLarge` past the cap. |
| `swapFeePercentage` | `uint256` | — | `0.001e16` (0.001%) | `10e16` (10%) | Static swap fee rate; only governance can change it afterwards (1% is typical). The protocol takes its share first (30% on Robinhood Chain today); 99.999% of the rest goes to the creator; 0.001% stays in the pool. | Enforced by the Vault against `getMinimum/MaximumSwapFeePercentage()`. |
| `salt` | `bytes32` | — | — | — | CREATE2 salt for the token and the pool, combined with the caller and chain id. `getLaunchTokenAddress(launch, creator, salt)` predicts the token address. | `BasePoolFactory`. |

## Initialization

Done by the factory inside `create`: the whole launch supply, no ETH, BPT minted to `0x…dEaD`, and the creator fee share
set to 99.999% in the pool's after-initialize hook.

| Constraint | Check |
| --- | --- |
| The quote amount is 0 | `QuoteBalanceNotZero()` from `onBeforeInitialize` (also guards pools deployed outside the factory). |
| The supply and prices give non-zero virtual balances | `ZeroVirtualBalance()`. This happens only with dust supplies or prices. |

## Fixed / structural constraints

| Constraint | Value | Source |
| --- | --- | --- |
| Tokens | The launch token and WETH, STANDARD, no rate providers | Factory, `onRegister` |
| Liquidity management | `disableUnbalancedLiquidity = true`, `enableDonation = false` | Factory; `onRegister` refuses anything else. |
| Hooks | The pool itself (before and after initialize, before add, before remove) | Factory registers `pool` as its hook. |
| Creator fee share | 99.999% (`CREATOR_FEE_PERCENTAGE`), set once at initialization; nothing can change it | `onAfterInitialize` |
| Liquidity while bonding | Locked: adds and removes revert `LiquidityLockedUntilGraduation()` | `onBeforeAdd/RemoveLiquidity` |
| Completion | A buy leaving `launchBalance <= graduationLaunchBalance` | `onSwap` |
| Overshoot cap | The completing buy may leave no less than `graduationLaunchBalance` less `MAX_GRADUATION_OVERSHOOT` (0.1%) of it, or `GraduationBuyTooLarge(maxLaunchAmountOut)`; `getMaxBuyAmount()` gives the limit | `onSwap` |
| Freeze after completion | Everything reverts `GraduationPending()` until `block.timestamp > bondingCompletedAt` | `_graduate` |
| Graduated range | Solved once, at graduation, for `GRADUATED_PRICE_RATIO` = 1e12 (constant); never moves with time. No setters. | `BondingReClammPool._graduate` |
| BPT rate | Unsupported (`getRate` reverts), as in ReClamm | `getRate` |
