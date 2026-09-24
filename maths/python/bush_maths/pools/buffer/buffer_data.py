from dataclasses import dataclass
from typing import List, Optional


@dataclass
class BufferState:
    # Immutable fields
    pool_address: str
    tokens: List[str]
    # Mutable fields
    rate: int
    max_deposit: Optional[int] = None
    max_mint: Optional[int] = None
    # Other fields
    pool_type: str = "Buffer"


def map_buffer_state(pool_state: dict) -> BufferState:
    return BufferState(
        pool_address=pool_state["poolAddress"],
        tokens=pool_state["tokens"],
        rate=pool_state["rate"],
        max_deposit=pool_state.get("maxDeposit"),
        max_mint=pool_state.get("maxMint"),
    )
