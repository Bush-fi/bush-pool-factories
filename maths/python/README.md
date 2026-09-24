# bush-maths

Exact fixed-point reference maths for Bush Protocol pools, in Python (`int`). Given a pool's on-chain state, it
returns the same amounts the Bush Vault would — to the wei — for swaps, adds and removes.

Every pool type here is verified bit-for-bit against a pool deployed through its factory on a local chain (see
[maths/check](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/check)); the same maths ships for
[TypeScript](https://www.npmjs.com/package/@bush.fi/maths) and
[Rust](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/rust).

## Install

```
pip install bush-maths
```

## Usage

```python
from bush_maths import Vault, SwapInput, SwapKind
from bush_maths.common.base_pool_state import pool_state_from_json

vault = Vault()

# The pool's state, in the same shape as the `pool` block of a testData/ file (numbers as int).
pool_state = pool_state_from_json(pool)

# Raw token amounts in, raw token amounts out — exactly what the Router returns.
amount_out = vault.swap(
    swap_input=SwapInput(
        amount_raw=1_000_000,
        swap_kind=SwapKind.GIVENIN,
        token_in=token_in,
        token_out=token_out,
    ),
    pool_state=pool_state,
)
```

`vault.add_liquidity(...)` and `vault.remove_liquidity(...)` work the same way. The `Vault` reproduces the whole
on-chain flow — token scaling, rates, swap fees, hooks — on top of the pool maths.

How to read each pool type's state from the chain is described in the
[TypeScript package's README](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/typescript#building-the-pool-state);
the fields are the same, in snake_case. The
[`testData/`](https://github.com/Bush-fi/bush-pool-factories/tree/main/maths/testData) files show the exact
shape for every pool type.

### ERC4626 buffers

Wrapping or unwrapping through a Vault buffer is priced by the wrapper's rate alone. Pass a `BufferState`
(`pool_address` is the wrapped token, `rate` its scaled-18 rate) to `vault.swap`:

```python
from bush_maths import BufferState

buffer = BufferState(pool_address=wrapped, tokens=[wrapped, underlying], rate=rate)
```

## Pool types

| `pool_type` | Factory |
| --- | --- |
| `WEIGHTED`, `WEIGHTED_8020`, `COW` | WeightedPoolFactory, WeightedPool8020Factory, CowPoolFactory |
| `STABLE` (+ `StableSurge` hook) | StablePoolFactory, StableSurgePoolFactory |
| `LIQUIDITY_BOOTSTRAPPING` | LBPoolFactory |
| `FIXED_PRICE_LBP` | FixedPriceLBPoolFactory |
| `RECLAMM` | ReClammPoolFactory |

Derived from [balancer-maths](https://github.com/balancer/balancer-maths) (MIT).
