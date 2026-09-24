from dataclasses import dataclass, fields
from typing import List

from bush_maths.common.base_pool_state import BasePoolState


@dataclass
class ReClammMutable:
    """ReClammPoolDynamicData, minus the fields BasePoolState already carries, plus the timestamp the state is
    evaluated at (the virtual balances are time-dependent)."""

    last_virtual_balances: List[int]
    daily_price_shift_base: int
    last_timestamp: int
    centeredness_margin: int
    start_fourth_root_price_ratio: int
    end_fourth_root_price_ratio: int
    price_ratio_update_start_time: int
    price_ratio_update_end_time: int
    current_timestamp: int


@dataclass
class ReClammState(BasePoolState, ReClammMutable):
    def __init__(self, **kwargs):
        kwargs["pool_type"] = "RECLAMM"
        base_fields = {f.name for f in fields(BasePoolState)}
        super().__init__(**{k: v for k, v in kwargs.items() if k in base_fields})
        for field in fields(ReClammMutable):
            if field.name in kwargs:
                setattr(self, field.name, kwargs[field.name])
