"""Runs the Python that Dafny made from proofs/ (docs/proofs.md).

Reads one JSON request per line on stdin and writes one JSON answer per
line on stdout, in the same order. spec/support/proven.rb starts it once
and sends it every input of a spec. The requests:

  {"split": [total, [weight, ...]]}
      -> {"shares": [share, ...]} or {"refused": true}

  {"round": [cent, [[id, units], ...]]}
      -> {"balances": [[id, units], ...]} or {"refused": true}

  {"dinner": {"cooks": [[resident_id, units, no_cost], ...],
              "eaters": [[resident_id, guest, row_id, multiplier], ...],
              "cap": units or null, "cancelled": true or false}}
      -> {"credits": [[resident_id, units], ...],
          "charges": [[resident_id, guest, row_id, multiplier, units], ...]}
         or {"refused": true}

Amounts are whole units of 10^-8 dollars. A charge is a positive number;
the line in the ledger is that number negated.

Every answer comes from EntryPoints in proofs/EntryPoints.dfy, which
checks its inputs and refuses one that no proof covers. This file only
turns JSON into Dafny values and back, and must not compute anything.

Run it with python3 -I -B. -I keeps anything outside the generated folder
from being imported in place of a module the generated code imports. -B
keeps Python from writing __pycache__ folders into the generated folder,
which bin/dafny-verify compares with what Dafny makes.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated-py"))
sys.setrecursionlimit(100_000)

import _dafny  # noqa: E402
import EntryPoints  # noqa: E402

E = EntryPoints.default__


def seq(items):
    return _dafny.SeqWithoutIsStrInference(items)


def split(total, weights):
    answer = E.Split(total, seq(weights))
    if answer.is_Refused:
        return {"refused": True}
    return {"shares": list(answer.value)}


def round_(cent, rows):
    answer = E.Round(cent, seq([EntryPoints.Balance_Balance(id_, units) for id_, units in rows]))
    if answer.is_Refused:
        return {"refused": True}
    return {"balances": [[b.id_, b.units] for b in answer.value]}


def dinner(request):
    cooks = seq([EntryPoints.Cook_Cook(rid, units, no_cost) for rid, units, no_cost in request["cooks"]])
    eaters = seq([EntryPoints.Eater_Eater(rid, guest, row, mult) for rid, guest, row, mult in request["eaters"]])
    cap = request["cap"]
    answer = E.Dinner(cooks, eaters, cap is not None, 0 if cap is None else cap, request["cancelled"])
    if answer.is_Refused:
        return {"refused": True}
    lines = answer.value
    return {
        "credits": [[c.residentId, units] for c, units in zip(lines.cooks, lines.credits)],
        "charges": [
            [e.residentId, e.guest, e.rowId, e.multiplier, units] for e, units in zip(lines.eaters, lines.charges)
        ],
    }


def answer(request):
    if "split" in request:
        return split(*request["split"])
    if "round" in request:
        return round_(*request["round"])
    if "dinner" in request:
        return dinner(request["dinner"])
    raise ValueError(f"unknown request: {request}")


def main():
    for line in sys.stdin:
        sys.stdout.write(json.dumps(answer(json.loads(line))) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
