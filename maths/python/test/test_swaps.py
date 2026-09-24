from test.utils.map_pool_state import (
    map_pool_and_hook_state,
    transform_strings_to_ints,
)
from test.utils.read_test_data import read_test_data

from bush_maths.common.types import SwapInput, SwapKind
from bush_maths.vault.vault import Vault

test_data = read_test_data()


def test_swaps():
    vault = Vault()
    for swap_test in test_data["swaps"]:
        print(swap_test["test"])
        if swap_test["test"] not in test_data["pools"]:
            raise ValueError(f"Pool not in test data: {swap_test['test']}")
        pool = test_data["pools"][swap_test["test"]]
        # note any amounts must be passed as ints not strings
        pool_with_ints = transform_strings_to_ints(pool)
        pool_state, hook_state = map_pool_and_hook_state(pool_with_ints)
        calculated_amount = vault.swap(
            swap_input=SwapInput(
                amount_raw=int(swap_test["amountRaw"]),
                token_in=swap_test["tokenIn"],
                token_out=swap_test["tokenOut"],
                swap_kind=SwapKind(swap_test["swapKind"]),
            ),
            pool_state=pool_state,
            hook_state=hook_state,
        )
        assert calculated_amount == int(swap_test["outputRaw"]), swap_test

