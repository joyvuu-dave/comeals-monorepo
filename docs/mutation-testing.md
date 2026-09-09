# Mutation testing on the money path

Line and branch coverage say every line ran under some test. They do
not say a test would fail if the line were wrong. Mutation testing
checks that. Mutant changes one thing in a method (an operator, a
constant, a branch, a call), runs the examples for that method, and
reports every change that no example failed on. Each survivor is a line
that runs under the suite but that no assertion pins down.

Added 2026-09-08. The tool is the `mutant` gem (free on public
open-source projects; this repository is public under MIT).

## Running it

```bash
bin/mutant                                   # every subject in .mutant.yml
bin/mutant -- Settlement.allocate_to_cents   # one method
bin/mutant -- 'MealLedger*'                  # one class
MUTANT_JOBS=8 bin/mutant                     # more workers (default 4)
```

It is not part of `bin/check`. A full run takes tens of minutes. Run it
after a change to a money file, and after a batch of merges the way a
bug hunt runs (`.claude/skills/bug-hunt/SKILL.md`).

`bin/mutant` migrates the test database, then copies it once per worker
(`comeals_test<suffix>_0`, `_1`, ...). Workers cannot share one
database: every example runs at SERIALIZABLE inside a transaction, and
two workers writing the same `lower(name)` would block each other on the
unique index, or abort each other with a serialization failure, and an
abort counts as a kill. The hook that points each worker at its own
copy is `config/mutant/hooks.rb`.

## What is mutated

The subjects in `.mutant.yml`: every method of `MealLedger`,
`Settlement` (which holds `allocate_to_cents`), `Reconciliation`, and
`BalanceRecalculation`. Those are the classes that turn bills and
attendance into an amount a person is told to pay.

Two kinds of node are skipped (`ignore_patterns` in `.mutant.yml`):
`T.must(...)` and `T.let(...)`. Both are no-ops at runtime, so the
mutation "remove the call" can never fail a test, and every one would
be a survivor that means nothing.

## Which examples run for a subject

Mutant chooses examples by the first word of their description.
`describe Settlement` examples run for every `Settlement` method, and
nothing else does. Most examples that check settlement arithmetic are
described by a sentence (`'Settlement contract'`,
`'billing:recalculate correctness'`) or by a class the arithmetic runs
through (`Reconciliation`, `LedgerVerification`). Left alone, mutant
never ran them: the first run selected 12 examples for
`Settlement.truncate_toward_zero`, none of which read its result, and
"drop the rounding" survived.

`spec/support/mutant_selection.rb` is the fix. It lists each such spec
file with the classes it proves, and tags its examples so mutant runs
them for every method of those classes. When you write a spec that
checks money arithmetic under a sentence description, add a row.

Mutant runs the examples with `--fail-fast`, so a killed mutation stops
at the first failing example. Only a survivor pays for the whole list.

## Reading a survivor

Mutant prints a diff for each one. Three kinds:

1. **A missing assertion.** The original code is right and no example
   checks that part of it. Add the example. This is the normal case,
   and the reason to run the tool.
2. **Dead or redundant code.** The mutation is right too: the original
   line did nothing the rest of the method did not already do. Remove
   the line, or find the case that needs it and test that case.
3. **Noise.** The change cannot be seen from outside the method (a
   different but equal way to write the same thing). If the same shape
   keeps coming back, add an `ignore_patterns` entry with a comment
   saying why, the way the Sorbet calls are ignored. Do not ignore a
   whole method to make a report clean.

A survivor in this code is never "fine as it is". Every method here is
on the path to a number on a settlement statement.

## Results

### 2026-09-08, first full run

44 methods, 1873 mutations, 4 workers, 2 hours 17 minutes (a health
check ran on the same machine for the first hour). 1734 killed, 139
alive, 27 of the 139 by timeout. `MealLedger` and `BalanceRecalculation`
had no survivor. Every survivor is in `Settlement` or `Reconciliation`.

The 27 timeouts were load, not code: the unchanged "neutral" version of
`Settlement.adjust!` also timed out, at 597 seconds, while the browser
suites ran. The four methods with timeouts were rerun on an idle
machine afterwards (see the entry below).

### 2026-09-08, rerun of the four methods with timeouts

`Settlement.adjust!`, `Settlement.allocate_to_cents`,
`Reconciliation#unit_balances`, `BalanceRecalculation#call`: 433
mutations, 6 workers, 16 minutes, no timeouts. 402 killed. The 27
former timeouts: 20 killed, 7 alive, all seven in `allocate_to_cents`
and all equivalent rewrites (`.to_int` for `.to_i`, `Integer(...)`,
`.sum` without a start value, and so on). That puts the first run at
119 alive out of 1873, 21 of them in the search whitelist that is now
excluded. The lists below are the other 98.

### 2026-09-08, after the survivor branch

The branch after the first run answered the survivors below marked
"done". What it added: `spec/services/settlement_rounding_spec.rb`
pins which resident gets each penny; the input guard now has a
negative-imbalance example; the preview's skipped-meal list has an
example with every filter live; the contested-claim example names
`Settlement::Contested`. What it removed: the hand-set timestamps and
empty-list guard in `persist_charges!`, the `.round` on the penny
count, and the `community:` argument of `Settlement.run!` (and of the
`settle!` spec helper, which passed it through).

Confirmed by rerunning the seven touched methods: 509 mutations, 472
killed, 37 alive, down from 55 on the same methods in the first run.
`Settlement.run!` and `persist_charges!` went to zero (the `.to_s` in
`persist_charges!` is kept on purpose). Every survivor left in
`allocate_to_cents` is one of the equivalent rewrites listed under
noise below.

One caveat. `skipped_by` orders by date and the new example asserts
that order, but dropping the `order` still survives: without ORDER BY,
Postgres happened to return the rows in date order for that data. The
assertion is real; mutant cannot prove it bites.

### 2026-09-09, with the oracle comparison selected

`spec/services/meal_ledger_against_plain_ledger_spec.rb` (MODELS.md, "The
plain ledger is the stronger oracle") now runs for every `MealLedger`
method and for `Settlement`. Every `MealLedger` method and
`truncate_toward_zero` rerun: 737 mutations, no survivor in `MealLedger`
at all, and `allocate_to_cents` at its 18 documented equivalents.

One survivor moved from "missing assertion" to "noise":
`assert_candidates_cover_pennies!` with `<` for `<=`. The equal case
cannot happen for a balanced input: every remainder is under a cent,
so the pennies needed are always fewer than the candidates.

**Missing assertions** (the reason to run the tool):

- Done. `Settlement.allocate_to_cents`: sorting candidates by `[id]` instead
  of `[r, id]` survives, and so does `[r, nil]`. No spec pins which
  resident gets a leftover penny. CLAUDE.md rule 5 says the largest
  remainder first, ties to the lowest resident id, and the property
  spec checks only that the result sums to zero and stays within a
  cent, which both orders satisfy. Needs a spec with three or more
  residents where the two orders disagree, and one with a tie.
- Done. `Settlement.truncate_toward_zero`: `raw >= 0` becoming `raw >= 1`
  survives. No spec has a positive balance under one dollar with a
  fractional cent.
- Done. `Settlement.assert_balanced_input!`: dropping `.abs` survives. The
  guard is never tested with a sum that is too positive.
- Noise, see above. `Settlement.assert_candidates_cover_pennies!`: `<=` becoming `<`
  survives. The case where every candidate is needed is untested.
- Done, except the "before today" filter, which the preview's own
  cutoff check makes redundant. `Settlement.skipped_by`: dropping `unreconciled`, the cutoff, or the
  "before today" filter all survive. The preview's list of skipped
  meals is only tested on data where those filters do nothing.
- Done. `Settlement#assign_meals`: `raise Contested` becoming a plain `raise`
  survives. The API rescues `Contested` by name, and no spec checks the
  class.
- `Settlement#forget_cached_meals`: removing the live-update push
  survives. The live-update contract spec covers it but was not in the
  selection list; it is now.
- `Settlement#rewrite!`: every mutation survives, because its one
  caller (the settled-balance trigger spec) was not selected; it is
  now, for that method only.
- `Reconciliation#unique_cooks`: every mutation survives, including
  `raise`. Its one caller is the cooking-slot-links task, whose spec
  was not selected; it is now.
- `Reconciliation#unit_balances`: dropping `order(:name)` survives.
  The order of units on the statement is not pinned.
- `Reconciliation#must_settle_at_least_one_meal`: removing the blank
  end date guard survives. No spec validates a reconciliation with a
  blank end date.

**Dead or redundant code:**

- Done, except `.to_s`, kept because it is explicit. `Settlement#persist_charges!`: `created_at: now, updated_at: now`
  can go. `insert_all` fills both timestamps itself. `return if
lines.empty?` can go too: `insert_all([])` returns an empty result
  without a query (checked in a console). `line.kind.to_s` can be
  `line.kind`.
- Done. `Settlement.run!`: the `community:` argument only reaches
  `Reconciliation.new`, where `BelongsToTheCommunity` fills the column
  anyway. CLAUDE.md says never to pass it. The parameter can go, and
  with it the argument that `spec/support/settle.rb` passes.
- Done, removed. `Settlement.allocate_to_cents`: `.round` on the penny count does
  nothing. The residual is a sum of two-decimal values, so it is always
  a whole number of cents. Either remove it or turn it into a check
  that raises when the residual is not whole, which is stronger.
- `Reconciliation#eligible_meals`: the `today:` argument makes no
  difference in any spec, because the end-date validation already
  refuses a date that is not in the past.

**Noise** (changes no test could see):

- Every `preload` and `with_attendees` removal in `settlement_ledger`
  and `skipped_by`: goldiloader loads the associations anyway, so the
  query count does not change.
- The `elsif pennies.negative?` mutations: with `pennies` at zero the
  branch runs `0.times` and changes nothing; with it positive the first
  branch already ran.
- Removing the `select` before each `sort_by`: the sort puts the same
  entries first; the `select` only makes the assertion after it
  meaningful.
- `Reconciliation.ransackable_attributes`: an admin search whitelist,
  now excluded from the subjects.
- `count` to `size`, `to_a` to `to_ary`, `self.end_date` to
  `end_date()`, `T.cast` type arguments, the `order(:id)` on the row
  lock (it prevents deadlocks, which no single-process test can see),
  and dropping the nested transaction in `write_ledger!` (the caller's
  transaction already covers it; `rewrite!` relies on the caller
  opening one too).
