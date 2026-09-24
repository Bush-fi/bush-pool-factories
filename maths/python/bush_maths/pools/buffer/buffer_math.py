from typing import Optional

from bush_maths.common.maths import (
    Rounding,
    div_down_fixed,
    div_up_fixed,
    mul_down_fixed,
    mul_up_fixed,
)
from bush_maths.common.types import SwapKind
from bush_maths.pools.buffer.enums import WrappingDirection


# See VaultExtension for SC code.
# Instead of manually adding support for each ERC4626 implementation (e.g. stata with Ray maths)
# we always use an 18 decimal scaled rate and do 18 decimal maths to convert.
# We may end up loosing 100% accuracy but thats acceptable.
def calculate_buffer_amounts(
    direction: WrappingDirection,
    kind: SwapKind,
    amount_raw: int,
    rate: int,
    max_deposit: Optional[int] = None,
    max_mint: Optional[int] = None,
) -> int:
    if direction == WrappingDirection.WRAP:
        # Amount in is underlying tokens, amount out is wrapped tokens
        if kind.value == SwapKind.GIVENIN.value:
            # previewDeposit
            if max_deposit is not None and amount_raw > max_deposit:
                raise ValueError(f"ERC4626ExceededMaxDeposit {amount_raw} {max_deposit}")
            return _convert_to_shares(amount_raw, rate, Rounding.ROUND_DOWN)
        # previewMint
        if max_mint is not None and amount_raw > max_mint:
            raise ValueError(f"ERC4626ExceededMaxMint {amount_raw} {max_mint}")
        return _convert_to_assets(amount_raw, rate, Rounding.ROUND_UP)

    # Amount in is wrapped tokens, amount out is underlying tokens
    if kind.value == SwapKind.GIVENIN.value:
        # previewRedeem
        return _convert_to_assets(amount_raw, rate, Rounding.ROUND_DOWN)
    # previewWithdraw
    return _convert_to_shares(amount_raw, rate, Rounding.ROUND_UP)


def _convert_to_shares(assets: int, rate: int, rounding: Rounding) -> int:
    if rounding.value == Rounding.ROUND_UP.value:
        return div_up_fixed(assets, rate)
    return div_down_fixed(assets, rate)


def _convert_to_assets(shares: int, rate: int, rounding: Rounding) -> int:
    if rounding.value == Rounding.ROUND_UP.value:
        return mul_up_fixed(shares, rate)
    return mul_down_fixed(shares, rate)
