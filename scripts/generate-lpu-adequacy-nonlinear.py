"""Generate evaluation/lpu-adequacy-v1/lpu-adequacy-nonlinear-wires.json.

Each row is an `lpu_adequacy` request over a nonlinear model plus an
independent Monte Carlo (MCM) coverage check of the same model, computed here
with Python's Mersenne Twister and the JCGM 101 symmetric-interval rule.
The expected_wire of each row is NOT computed here: it is the exact reply of
plurimath-numeric and is merged in with `--wires <file>` (id -> wire string).
Without `--wires` the rows carry an empty expected_wire (a draft).

Usage: python3 -I scripts/generate-lpu-adequacy-nonlinear.py [--wires FILE] OUT
"""

import json
import math
import random
import sys

SAMPLES = 1_000_000
SEED = 20261126


def var(n):
    return {"type": "variable", "name": n}


def num(t):
    return {"type": "number", "text": t}


def bin_(op, left, right):
    return {"type": "binary", "operator": op, "left": left, "right": right}


def call(n, a):
    return {"type": "call", "name": n, "argument": a}


# id, ast, inputs [(name, estimate, uncertainty)], k, threshold, budget,
# python model, gradient
CASES = [
    ("square-wide-inadequate", bin_("^", var("x"), num("2")), [("x", 1.0, 1.0)], 1.96, 0.05, 256,
     lambda x: x[0] ** 2, lambda x: [2 * x[0]]),
    ("exp-wide-inadequate", call("exp", var("x")), [("x", 0.0, 1.0)], 1.96, 0.05, 256,
     lambda x: math.exp(x[0]), lambda x: [math.exp(x[0])]),
    ("product-wide-inadequate", bin_("*", var("x"), var("y")), [("x", 1.0, 1.0), ("y", 1.0, 1.0)], 1.96, 0.05, 256,
     lambda x: x[0] * x[1], lambda x: [x[1], x[0]]),
    ("reciprocal-inadequate", bin_("/", num("1"), var("x")), [("x", 10.0, 1.0)], 1.96, 0.05, 256,
     lambda x: 1 / x[0], lambda x: [-1 / x[0] ** 2]),
    ("square-narrow-adequate", bin_("^", var("x"), num("2")), [("x", 10.0, 0.1)], 1.96, 0.05, 256,
     lambda x: x[0] ** 2, lambda x: [2 * x[0]]),
    ("product-narrow-adequate", bin_("*", var("x"), var("y")), [("x", 10.0, 0.1), ("y", 10.0, 0.1)], 1.96, 0.05, 256,
     lambda x: x[0] * x[1], lambda x: [x[1], x[0]]),
    ("square-one-box-inconclusive", bin_("^", var("x"), num("2")), [("x", 1.0, 1.0)], 1.0, 0.5, 1,
     lambda x: x[0] ** 2, lambda x: [2 * x[0]]),
]


def mcm(model, grad, inputs, k, index):
    rng = random.Random(SEED + index)
    c = [e for _, e, _ in inputs]
    u = [s for _, _, s in inputs]
    p = math.erf(k / math.sqrt(2))
    ys = sorted(model([rng.gauss(ci, ui) for ci, ui in zip(c, u)]) for _ in range(SAMPLES))
    lo = ys[max(int(SAMPLES * (1 - p) / 2 + 0.5) - 1, 0)]
    hi = ys[min(int(SAMPLES * (1 + p) / 2 + 0.5) - 1, SAMPLES - 1)]
    y = model(c)
    uc = math.sqrt(sum((g * ui) ** 2 for g, ui in zip(grad(c), u)))
    # JCGM 101 7.2.5: tolerance is half a unit in the last of 2 significant digits of u(y)
    tol = 0.5 * 10 ** (math.floor(math.log10(uc)) - 1)
    guf = [y - k * uc, y + k * uc]
    ok = abs(guf[0] - lo) <= tol and abs(guf[1] - hi) <= tol
    r = lambda v: float(f"{v:.9g}")
    return {
        "samples": SAMPLES, "seed": SEED + index, "generator": "python-random-mt19937-gauss",
        "probability": r(p), "mcm_interval": [r(lo), r(hi)], "guf_interval": [r(guf[0]), r(guf[1])],
        "tolerance": r(tol), "symbol": "validated" if ok else "not_validated",
    }


def main(argv):
    wires = {}
    if argv[0] == "--wires":
        wires = json.load(open(argv[1]))
        argv = argv[2:]
    rows = []
    for index, (cid, ast, inputs, k, thr, budget, model, grad) in enumerate(CASES):
        params = {
            "ast": ast,
            "budget": budget,
            "coverage_factor": k,
            "inputs": [{"name": n, "estimate": e, "uncertainty": s} for n, e, s in inputs],
            "threshold": thr,
        }
        request = {"method": "lpu_adequacy", "parameters": params, "schema": "plurimath.evaluate.gum/1"}
        rows.append({
            "id": cid,
            "profile": "lpu_adequacy",
            "request_json": json.dumps(request, sort_keys=True, separators=(",", ":")),
            "expected_wire": wires.get(cid, ""),
            "mcm": mcm(model, grad, inputs, k, index),
        })
    with open(argv[0], "w", encoding="utf-8") as out:
        json.dump({"abi": 1, "cases": rows}, out, indent=2, ensure_ascii=False)
        out.write("\n")
    for r in rows:
        print(r["id"], r["mcm"]["symbol"], r["mcm"]["mcm_interval"], r["mcm"]["guf_interval"], r["mcm"]["tolerance"])


if __name__ == "__main__":
    main(sys.argv[1:] or ["/dev/stdout"])
