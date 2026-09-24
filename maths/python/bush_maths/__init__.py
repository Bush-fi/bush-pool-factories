"""
Bush Maths (Python)

Exact fixed-point reference maths for Bush Protocol pools. Ported from balancer-maths (MIT).
"""

__version__ = "0.1.0"

from .common.types import (
    AddLiquidityInput,
    AddLiquidityKind,
    RemoveLiquidityInput,
    RemoveLiquidityKind,
    SwapInput,
    SwapKind,
)
from .cow.cow_router import (
    MAX_PROTOCOL_FEE_PERCENTAGE,
    DonationSplit,
    split_donation_amounts,
    split_donation_and_protocol_fee,
    validate_protocol_fee_percentage,
)
from .hooks.stable_surge.stable_surge_hook import StableSurgeHook
from .pools.buffer.buffer_data import BufferState
from .pools.fixed_price_lbp.fixed_price_lbp import FixedPriceLBP
from .pools.liquidity_bootstrapping.liquidity_bootstrapping import (
    LiquidityBootstrapping,
)
from .pools.stable.stable import Stable
from .pools.weighted.weighted import Weighted
from .vault.vault import Vault

__all__ = [
    "Vault",
    "BufferState",
    "Weighted",
    "Stable",
    "LiquidityBootstrapping",
    "FixedPriceLBP",
    "StableSurgeHook",
    "SwapInput",
    "SwapKind",
    "AddLiquidityInput",
    "AddLiquidityKind",
    "RemoveLiquidityInput",
    "RemoveLiquidityKind",
    "MAX_PROTOCOL_FEE_PERCENTAGE",
    "DonationSplit",
    "split_donation_and_protocol_fee",
    "split_donation_amounts",
    "validate_protocol_fee_percentage",
]
