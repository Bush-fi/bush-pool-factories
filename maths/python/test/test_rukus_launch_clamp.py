"""The overshoot clamp: while bonding, the buy that completes the curve may go at most 0.1% past the graduation balance
(BondingReClammPool.MAX_GRADUATION_OVERSHOOT). The generated test data only records swaps the chain accepted, so the
rejection is checked here."""

from types import SimpleNamespace

import pytest

from bush_maths.common.swap_params import SwapParams
from bush_maths.common.types import SwapKind
from bush_maths.pools.bonding_reclamm.bonding_reclamm import BondingPhase, BondingReClamm

E18 = 10**18
GRADUATION_BALANCE = 20_000_000 * E18
MIN_LAUNCH_BALANCE = GRADUATION_BALANCE - GRADUATION_BALANCE // 1000
BALANCES = [GRADUATION_BALANCE + 1_000 * E18, 31_998 * E18]
MAX_OUT = BALANCES[0] - MIN_LAUNCH_BALANCE


def _pool(phase):
    return BondingReClamm(
        SimpleNamespace(
            phase=int(phase),
            launch_token_index=0,
            graduation_launch_balance=GRADUATION_BALANCE,
            bonding_completed_at=0,
            graduated_price_ratio=10**30,
            virtual_balances=[6_666_666_666_666_666_666_666_666, 10_666_666_666_666_666_666_666],
            current_timestamp=1_000_000,
        )
    )


def _buy(kind, amount):
    return SwapParams(swap_kind=kind, balances_live_scaled18=BALANCES, index_in=1, index_out=0, amount_given_scaled18=amount)


def test_buy_down_to_the_limit_is_accepted():
    assert _pool(BondingPhase.BONDING).on_swap(_buy(SwapKind.GIVENOUT, MAX_OUT)) > 0


def test_one_wei_past_the_limit_is_rejected():
    with pytest.raises(ValueError, match="GraduationBuyTooLarge"):
        _pool(BondingPhase.BONDING).on_swap(_buy(SwapKind.GIVENOUT, MAX_OUT + 1))


def test_exact_in_past_the_limit_is_rejected():
    with pytest.raises(ValueError, match="GraduationBuyTooLarge"):
        _pool(BondingPhase.BONDING).on_swap(_buy(SwapKind.GIVENIN, 100_000 * E18))


def test_no_clamp_once_graduated():
    assert _pool(BondingPhase.GRADUATED).on_swap(_buy(SwapKind.GIVENOUT, MAX_OUT * 100)) > 0
