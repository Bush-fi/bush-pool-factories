"""Port of contracts/rukus-launch/RukusLaunchPool.sol, implementing the bush-maths `PoolBase` interface.

A RukusLaunch pool sells its launch token along a bonding curve (pump.fun's virtual-reserve curve) and then
graduates, in place, into a (practically) full-range pool. The swap maths is ReClamm's (constant product on real +
virtual balances) in both phases; what changes is the virtual balances it runs with:
  - BONDING:   the bonding curve's, which never move (and the buy completing the curve may go at most 0.1% past the
               graduation balance);
  - COMPLETED: the curve sold out. In the block it did, every operation reverts (GraduationPending). In a later block,
               the first operation graduates the pool: the virtual balances are re-solved at the current price for the
               graduated width (1e12x), and that operation runs on the result;
  - GRADUATED: the graduated ones, which never move with time (only proportional adds and removes scale them).
"""

from enum import IntEnum
from typing import List, Tuple

from bush_maths.pool_kit import PoolBase, Rounding, SwapKind, SwapParams, mul_down_fixed, reclamm_math
from bush_maths.pools.rukus_launch.rukus_launch_math import compute_graduation_virtual_balances

# RukusLaunchPool._MIN_SWAP_FEE_PERCENTAGE / _MAX_SWAP_FEE_PERCENTAGE (the same as ReClammPool's).
MIN_SWAP_FEE_PERCENTAGE = 1_000_000_000_000  # 0.001%
MAX_SWAP_FEE_PERCENTAGE = 100_000_000_000_000_000  # 10%

# RukusLaunchPool.MAX_GRADUATION_OVERSHOOT: 0.1% of the graduation balance.
MAX_GRADUATION_OVERSHOOT = 1_000_000_000_000_000


class BondingPhase(IntEnum):
    """IRukusLaunchPool.BondingPhase."""

    BONDING = 0
    COMPLETED = 1
    GRADUATED = 2


class RukusLaunch(PoolBase):
    def __init__(self, pool_state):
        """`pool_state` carries the adapter's poolData() fields as snake_case attributes, plus `current_timestamp`."""
        self.phase = BondingPhase(int(pool_state.phase))
        self.launch_token_index = int(pool_state.launch_token_index)
        self.graduation_launch_balance = pool_state.graduation_launch_balance
        self.bonding_completed_at = pool_state.bonding_completed_at
        self.graduated_price_ratio = pool_state.graduated_price_ratio
        self.virtual_balance_a, self.virtual_balance_b = pool_state.virtual_balances
        self.current_timestamp = pool_state.current_timestamp

    # The invariant ratio bounds are required by the interface but unused: liquidity is proportional only.
    def get_maximum_invariant_ratio(self) -> int:
        return 0

    def get_minimum_invariant_ratio(self) -> int:
        return 0

    def on_swap(self, swap_params: SwapParams) -> int:
        """RukusLaunchPool.onSwap."""
        balances = swap_params.balances_live_scaled18
        virtual_a, virtual_b = self.swap_virtual_balances(balances)
        given_in = swap_params.swap_kind.value == SwapKind.GIVENIN.value
        if given_in:
            amount_calculated = reclamm_math.compute_out_given_in(
                balances, virtual_a, virtual_b, swap_params.index_in, swap_params.index_out, swap_params.amount_given_scaled18
            )
        else:
            amount_calculated = reclamm_math.compute_in_given_out(
                balances, virtual_a, virtual_b, swap_params.index_in, swap_params.index_out, swap_params.amount_given_scaled18
            )

        # While bonding, the buy that completes the curve may go at most MAX_GRADUATION_OVERSHOOT past it.
        if self.phase == BondingPhase.BONDING and swap_params.index_out == self.launch_token_index:
            launch_out = amount_calculated if given_in else swap_params.amount_given_scaled18
            launch_balance_after = balances[swap_params.index_out] - launch_out
            if launch_balance_after <= self.graduation_launch_balance and launch_balance_after < self.min_launch_balance():
                raise ValueError("GraduationBuyTooLarge")
        return amount_calculated

    def min_launch_balance(self) -> int:
        """RukusLaunchPool._minLaunchBalance: the graduation balance less the overshoot allowed."""
        return self.graduation_launch_balance - mul_down_fixed(self.graduation_launch_balance, MAX_GRADUATION_OVERSHOOT)

    def compute_invariant(self, balances_live_scaled18: List[int], rounding: Rounding) -> int:
        """RukusLaunchPool.computeInvariant: a view, so a completed pool still uses the bonding virtual balances."""
        return reclamm_math.compute_invariant(
            balances_live_scaled18, self.virtual_balance_a, self.virtual_balance_b, rounding
        )

    def compute_balance(self, balances_live_scaled18: List[int], token_in_index: int, invariant_ratio: int) -> int:
        """RukusLaunchPool.computeBalance: reverts NotImplemented, the pool does not allow unbalanced liquidity."""
        raise NotImplementedError("NotImplemented")

    def swap_virtual_balances(self, balances_live_scaled18: List[int]) -> Tuple[int, int]:
        """The virtual balances `on_swap` runs with: the stored ones (they never change with time), except that a
        COMPLETED pool queried in a later block graduates first, as the contract does."""
        if self.phase == BondingPhase.COMPLETED:
            # RukusLaunchPool._graduate.
            if self.current_timestamp <= self.bonding_completed_at:
                raise ValueError("GraduationPending")
            return compute_graduation_virtual_balances(
                balances_live_scaled18,
                self.virtual_balance_a,
                self.virtual_balance_b,
                reclamm_math.sqrt_scaled18(self.graduated_price_ratio),
            )
        return self.virtual_balance_a, self.virtual_balance_b
