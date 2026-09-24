"""Runs the Python maths (maths/python) against one test-data file, through the Vault flow, and prints the
outcomes as JSON. The pool and hook classes are looked up by type in ./pools.py.

Usage: python3 runner.py <test-data-file.json>
"""
import json
import os
import re
import sys

MATHS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(MATHS, "python"))
sys.path.insert(0, os.path.dirname(__file__))

from bush_maths.common.base_pool_state import pool_state_from_json  # noqa: E402
from bush_maths.common.types import (  # noqa: E402
    AddLiquidityInput,
    AddLiquidityKind,
    RemoveLiquidityInput,
    RemoveLiquidityKind,
    SwapInput,
    SwapKind,
)
from bush_maths.vault.vault import Vault  # noqa: E402

from pools import HOOKS, POOLS  # noqa: E402


def to_ints(x):
    if isinstance(x, list):
        return [to_ints(v) for v in x]
    if isinstance(x, dict):
        return {k: to_ints(v) for k, v in x.items()}
    if isinstance(x, str) and re.fullmatch(r"[0-9]+", x):
        return int(x)
    return x


def main():
    data_file = sys.argv[1]
    with open(data_file) as f:
        data = json.load(f)
    pool = to_ints(data["pool"])
    create_pool = POOLS.get(pool["poolType"])
    if create_pool is None:
        raise SystemExit(f"no Python maths registered for poolType {pool['poolType']} (runners/python/pools.py)")

    hook_state = None
    hook_classes = {}
    hook_type = None
    if pool.get("hook"):
        create_hook = HOOKS.get(pool["hook"]["type"])
        if create_hook is None:
            raise SystemExit(f"no Python maths registered for hook type {pool['hook']['type']} (runners/python/pools.py)")
        hook, hook_state = create_hook(pool_state_from_json(pool))
        hook_type = hook_state.hook_type
        hook_classes[hook_type] = lambda: hook
    state = pool_state_from_json(pool, hook_type)
    vault = Vault(custom_pool_classes={pool["poolType"]: create_pool}, custom_hook_classes=hook_classes)

    outcomes = []

    def run(kind, index, expected, f):
        try:
            outcomes.append({"kind": kind, "index": index, "expected": expected, "actual": f()})
        except Exception as e:  # noqa: BLE001 - any failure is a reportable outcome
            outcomes.append({"kind": kind, "index": index, "expected": expected, "error": f"{type(e).__name__}: {e}"})

    for i, s in enumerate(data.get("swaps", [])):
        run("swap", i, [s["outputRaw"]], lambda s=s: [str(vault.swap(
            swap_input=SwapInput(amount_raw=int(s["amountRaw"]), token_in=s["tokenIn"], token_out=s["tokenOut"], swap_kind=SwapKind(s["swapKind"])),
            pool_state=state, hook_state=hook_state))])

    for i, a in enumerate(data.get("adds", [])):
        def add(a=a):
            r = vault.add_liquidity(
                add_liquidity_input=AddLiquidityInput(
                    pool=pool["poolAddress"],
                    max_amounts_in_raw=[int(x) for x in a["inputAmountsRaw"]],
                    min_bpt_amount_out_raw=int(a["bptOutRaw"]),
                    kind=AddLiquidityKind.UNBALANCED if a["kind"] == "Unbalanced" else AddLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
                ),
                pool_state=state, hook_state=hook_state)
            return [str(r.bpt_amount_out_raw)] + [str(x) for x in r.amounts_in_raw]
        run("add", i, [a["bptOutRaw"]] + list(a["inputAmountsRaw"]), add)

    kinds = {"Proportional": RemoveLiquidityKind.PROPORTIONAL, "SingleTokenExactIn": RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN, "SingleTokenExactOut": RemoveLiquidityKind.SINGLE_TOKEN_EXACT_OUT}
    for i, r in enumerate(data.get("removes", [])):
        def remove(r=r):
            res = vault.remove_liquidity(
                remove_liquidity_input=RemoveLiquidityInput(
                    pool=pool["poolAddress"],
                    min_amounts_out_raw=[int(x) for x in r["amountsOutRaw"]],
                    max_bpt_amount_in_raw=int(r["bptInRaw"]),
                    kind=kinds[r["kind"]],
                ),
                pool_state=state, hook_state=hook_state)
            return [str(res.bpt_amount_in_raw)] + [str(x) for x in res.amounts_out_raw]
        run("remove", i, [r["bptInRaw"]] + list(r["amountsOutRaw"]), remove)

    json.dump(outcomes, sys.stdout)


if __name__ == "__main__":
    main()
