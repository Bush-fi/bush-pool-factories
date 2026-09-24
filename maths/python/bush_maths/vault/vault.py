from typing import Dict, Optional, Type

from bush_maths.common.pool_base import PoolBase
from bush_maths.common.types import (
    AddLiquidityInput,
    AddLiquidityResult,
    PoolState,
    RemoveLiquidityInput,
    RemoveLiquidityResult,
    SwapInput,
)
from bush_maths.hooks.default_hook import DefaultHook
from bush_maths.hooks.stable_surge.stable_surge_hook import StableSurgeHook
from bush_maths.hooks.types import HookBase, HookState
from bush_maths.pools.buffer.buffer_data import BufferState
from bush_maths.pools.buffer.erc4626_buffer_wrap_or_unwrap import (
    erc4626_buffer_wrap_or_unwrap,
)
from bush_maths.pools.fixed_price_lbp.fixed_price_lbp import FixedPriceLBP
from bush_maths.pools.liquidity_bootstrapping.liquidity_bootstrapping import (
    LiquidityBootstrapping,
)
from bush_maths.pools.reclamm.reclamm import ReClamm
from bush_maths.pools.stable.stable import Stable
from bush_maths.pools.weighted.weighted import Weighted
from bush_maths.vault.add_liquidity import add_liquidity
from bush_maths.vault.remove_liquidity import remove_liquidity
from bush_maths.vault.swap import swap


class Vault:
    def __init__(
        self,
        custom_pool_classes: Optional[Dict[str, Type[PoolBase]]] = None,
        custom_hook_classes: Optional[Dict[str, Type[HookBase]]] = None,
    ):
        default_pool_classes: Dict[str, Type[PoolBase]] = {
            "WEIGHTED": Weighted,
            # WeightedPool8020Factory and CowPoolFactory deploy WeightedPool; the CoW-specific
            # logic lives in the CowRouter (see bush_maths/cow), not in the pool.
            "WEIGHTED_8020": Weighted,
            "COW": Weighted,
            "STABLE": Stable,
            "LIQUIDITY_BOOTSTRAPPING": LiquidityBootstrapping,
            "FIXED_PRICE_LBP": FixedPriceLBP,
            "RECLAMM": ReClamm,
        }
        default_hook_classes: Dict[str, Type[HookBase]] = {
            "StableSurge": StableSurgeHook,
        }
        self.pool_classes = {**default_pool_classes, **(custom_pool_classes or {})}
        self.hook_classes = {**default_hook_classes, **(custom_hook_classes or {})}

    def swap(
        self,
        *,
        swap_input: SwapInput,
        pool_state: PoolState | BufferState,
        hook_state: HookState | object | None = None,
    ) -> int:
        if swap_input.amount_raw == 0:
            return 0

        # Buffers aren't pools: an ERC4626 wrap/unwrap is priced by the wrapper's rate alone
        if isinstance(pool_state, BufferState):
            return erc4626_buffer_wrap_or_unwrap(swap_input, pool_state)

        pool_class = self._get_pool(pool_state=pool_state)
        hook_class = self._get_hook(
            hook_name=pool_state.hook_type, hook_state=hook_state
        )
        return swap(swap_input, pool_state, pool_class, hook_class, hook_state)

    def add_liquidity(
        self,
        *,
        add_liquidity_input: AddLiquidityInput,
        pool_state: PoolState,
        hook_state: HookState | object | None = None,
    ) -> AddLiquidityResult:
        pool_class = self._get_pool(pool_state=pool_state)
        hook_class = self._get_hook(
            hook_name=pool_state.hook_type, hook_state=hook_state
        )
        return add_liquidity(
            add_liquidity_input, pool_state, pool_class, hook_class, hook_state
        )

    def remove_liquidity(
        self,
        *,
        remove_liquidity_input: RemoveLiquidityInput,
        pool_state: PoolState,
        hook_state: HookState | object | None = None,
    ) -> RemoveLiquidityResult:
        pool_class = self._get_pool(pool_state=pool_state)
        hook_class = self._get_hook(
            hook_name=pool_state.hook_type, hook_state=hook_state
        )
        return remove_liquidity(
            remove_liquidity_input, pool_state, pool_class, hook_class, hook_state
        )

    def supports_pool_type(self, pool_type: str) -> bool:
        """Whether this Vault has maths for `pool_type` (built in or passed as `custom_pool_classes`)."""
        return pool_type in self.pool_classes

    def _get_pool(self, *, pool_state: PoolState) -> PoolBase:
        pool_class = self.pool_classes[pool_state.pool_type]
        if pool_class is None:
            raise SystemError("Unsupported Pool Type: ", pool_state.pool_type)

        return pool_class(pool_state)

    def _get_hook(
        self, *, hook_name: str | None, hook_state: HookState | object | None
    ) -> HookBase:
        if hook_name is None:
            return DefaultHook()
        hook_class = self.hook_classes.get(hook_name, None)
        if hook_class is None:
            raise SystemError("Unsupported Hook Type:", hook_name)
        if hook_state is None:
            raise SystemError("No state for Hook:", hook_name)
        return hook_class()
