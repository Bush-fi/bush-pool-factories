import pytest

from bush_maths.common.types import SwapInput, SwapKind
from bush_maths.pools.buffer.buffer_data import BufferState
from bush_maths.vault.vault import Vault

WRAPPED = "0xd4fa2d31b7968e448877f69a96de69f5de8cd23e"
UNDERLYING = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

vault = Vault()


def buffer():
    return BufferState(
        pool_address=WRAPPED,
        tokens=[WRAPPED, UNDERLYING],
        rate=1122761623535914092,
        max_deposit=1900471418535512,
        max_mint=1692675790387594,
    )


def test_wraps_when_below_max_deposit():
    amount = vault.swap(
        swap_input=SwapInput(
            amount_raw=100000000,
            swap_kind=SwapKind.GIVENIN,
            token_in=WRAPPED,
            token_out=UNDERLYING,
        ),
        pool_state=buffer(),
    )
    assert amount == 112276162


def test_throws_when_above_max_deposit():
    pool = buffer()
    with pytest.raises(
        ValueError, match="ERC4626ExceededMaxDeposit 1900471418535513 1900471418535512"
    ):
        vault.swap(
            swap_input=SwapInput(
                amount_raw=pool.max_deposit + 1,
                swap_kind=SwapKind.GIVENIN,
                token_in="0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
                token_out="0xb19382073c7A0aDdbb56Ac6AF1808Fa49e377B75",
            ),
            pool_state=pool,
        )


def test_wraps_when_below_max_mint():
    amount = vault.swap(
        swap_input=SwapInput(
            amount_raw=100000000,
            swap_kind=SwapKind.GIVENOUT,
            token_in=WRAPPED,
            token_out=UNDERLYING,
        ),
        pool_state=buffer(),
    )
    assert amount == 89066101


def test_throws_when_above_max_mint():
    pool = buffer()
    with pytest.raises(
        ValueError, match="ERC4626ExceededMaxMint 1692675790387595 1692675790387594"
    ):
        vault.swap(
            swap_input=SwapInput(
                amount_raw=pool.max_mint + 1,
                swap_kind=SwapKind.GIVENOUT,
                token_in="0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
                token_out="0xb19382073c7A0aDdbb56Ac6AF1808Fa49e377B75",
            ),
            pool_state=pool,
        )


def test_throws_when_below_minimum_wrap_amount():
    with pytest.raises(ValueError, match="wrapAmountTooSmall"):
        vault.swap(
            swap_input=SwapInput(
                amount_raw=999,
                swap_kind=SwapKind.GIVENIN,
                token_in=UNDERLYING,
                token_out=WRAPPED,
            ),
            pool_state=buffer(),
        )
