# bush-maths

Exact fixed-point reference maths for Bush Protocol pools, in Rust (`U256`). Given a pool's on-chain state, it
returns the same amounts the Bush Vault would — to the wei — for swaps, adds and removes.

Every pool type here is verified bit-for-bit against a pool deployed through its factory on a local chain (see
[maths/check](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/check)); the same maths ships for
[TypeScript](https://www.npmjs.com/package/@bush.fi/maths) and
[Python](https://pypi.org/project/bush-maths/).

## Usage

```rust
use alloy_primitives::U256;
use bush_maths::common::types::SwapInput;
use bush_maths::{SwapKind, Vault};

let vault = Vault::new();

// Raw token amounts in, raw token amounts out — exactly what the Router returns.
let amount_out = vault.swap(
    &SwapInput {
        amount_raw: U256::from(1_000_000u64),
        swap_kind: SwapKind::GivenIn,
        token_in,
        token_out,
    },
    &pool_state, // bush_maths::PoolState
    None,        // hook state, for pools with a hook
)?;
```

`vault.add_liquidity(...)` and `vault.remove_liquidity(...)` work the same way. `bush_maths::pools::state_from_json`
builds a `PoolState` from the `pool` block of a
[`testData/`](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/testData) file, which shows the exact
fields for every pool type. How to read them from the chain is described in the
[TypeScript package's README](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/typescript#building-the-pool-state).

ERC4626 buffer wraps/unwraps are priced with `vault.swap_buffer(&swap_input, &buffer_state)`.

## Pool types

| `poolType` | Factory |
| --- | --- |
| `WEIGHTED`, `WEIGHTED_8020`, `COW` | WeightedPoolFactory, WeightedPool8020Factory, CowPoolFactory |
| `STABLE` (+ `StableSurge` hook) | StablePoolFactory, StableSurgePoolFactory |
| `LIQUIDITY_BOOTSTRAPPING` | LBPoolFactory |
| `FIXED_PRICE_LBP` | FixedPriceLBPoolFactory |
| `RECLAMM` | ReClammPoolFactory |

Derived from [balancer-maths](https://github.com/balancer/balancer-maths) (MIT).
