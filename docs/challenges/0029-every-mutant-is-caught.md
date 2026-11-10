---
id: 29
title: A test catches every code change
area: proof
status: open
opened: 2026-11-07
reviewed: 2026-11-10
watches:
  - docs/mutation-testing.md
---

# A test catches every code change

## The challenge

For every small change mutant makes to the code, some test fails, or there is a written reason why no test can.

## The case that breaks it

mutant changes `>=` to `>` in a money rule, and every test still passes. That line can then be broken by a real edit, and nothing would fail.

## Where we stand

- `bin/mutant` runs one class or one stage, and the Mutant workflow runs every class (`docs/mutation-testing.md`). The results and the open survivors are recorded there.
- A timeout counts as a survivor (`coverage_criteria` in `.mutant.yml`).
- The money rules: on 2026-11-10 mutant ran `LargestRemainderSplit`, `MealLedger` and the cent rounding in `Settlement`. 20 of 1,204 changes survived, and `docs/mutation-testing.md` says for each one why no test can catch it. The rules themselves are also proven for every input (challenge 27).
- Not checked: whether every stage was run again after the last change to how survivors are counted, so that the recorded rates are the true ones.

## Options

1. Run every stage again, and record the rates with the date.
2. For each survivor: a test that catches it, or a line in `docs/mutation-testing.md` saying why it cannot be caught.
3. Make the money classes a gate: their survivors must be zero for `bin/check` to pass.

## History

- 2026-11-07: Opened.
- 2026-11-10: Added the mutant run on the money rules.
