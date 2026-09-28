"""Pool kit: everything a new pool or hook needs, in one import.

    from bush_maths.pool_kit import PoolBase, Rounding, SwapKind, SwapParams, mul_down_fixed

A pool under bush_maths/pools/<pool>/ imports from this module and from its own package, nothing else. If a pool
needs something that is not here, add it here (in a PR a maintainer reviews) rather than importing it from elsewhere.
"""
# pylint: disable=unused-import

# Fixed-point arithmetic: ports of Solidity's FixedPoint / LogExpMath / OpenZeppelin Math. Integers only.
from bush_maths.common.constants import FOUR_WAD, MAX_POW_RELATIVE_ERROR, RAY, TWO_WAD, WAD
from bush_maths.common.log_exp_math import LogExpMath
from bush_maths.common.maths import (
    Rounding,
    complement_fixed,
    div_down_fixed,
    div_up,
    div_up_fixed,
    mul_div_up_fixed,
    mul_down_fixed,
    mul_up_fixed,
    pow_down_fixed,
    pow_up_fixed,
)
from bush_maths.common.oz_math import sqrt
from bush_maths.common.utils import MAX_UINT256

# The interface a pool implements, and the types the Vault passes to it.
from bush_maths.common.pool_base import PoolBase
from bush_maths.common.swap_params import SwapParams
from bush_maths.common.types import AddLiquidityKind, RemoveLiquidityKind, SwapKind

# Raw <-> scaled18 conversions (token decimals and rates).
from bush_maths.common.utils import (
    _to_raw_undo_rate_round_down as to_raw_undo_rate_round_down,
    _to_raw_undo_rate_round_up as to_raw_undo_rate_round_up,
    _to_scaled_18_apply_rate_round_down as to_scaled_18_apply_rate_round_down,
    _to_scaled_18_apply_rate_round_up as to_scaled_18_apply_rate_round_up,
)

# Ports of the existing pools' maths libraries, to reuse instead of re-porting (CONTRIBUTING.md, Step 5, rule 5).
# Used as modules because they share constant names (_MIN_INVARIANT_RATIO, ...): `weighted_math.compute_invariant_down`.
from bush_maths.pools.weighted import weighted_math
from bush_maths.pools.stable import stable_math
from bush_maths.pools.liquidity_bootstrapping import liquidity_bootstrapping_math
from bush_maths.pools.reclamm import reclamm_math

# Hooks: the interface and its result types, and a no-op hook to subclass (override only what the hook does).
from bush_maths.hooks.default_hook import DefaultHook
from bush_maths.hooks.types import (
    AfterAddLiquidityResult,
    AfterRemoveLiquidityResult,
    AfterSwapParams,
    AfterSwapResult,
    BeforeAddLiquidityResult,
    BeforeRemoveLiquidityResult,
    BeforeSwapResult,
    DynamicSwapFeeResult,
    HookBase,
)
