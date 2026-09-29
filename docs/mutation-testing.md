# Mutation testing

Line and branch coverage say every line ran under some test. They do
not say a test would fail if the line were wrong. Mutation testing
checks that. Mutant changes one thing in a method (an operator, a
constant, a branch, a call), runs the examples for that method, and
reports every change that no example failed on. Each survivor is a line
that runs under the suite but that no assertion pins down.

Added 2026-09-08 for the four money classes; widened to every class in
`app/` and `lib/` on 2026-09-12. The tool is the `mutant` gem (free on
public open-source projects; this repository is public under MIT).

## Running it

```bash
bin/mutant                                   # every subject in .mutant.yml (hours)
bin/mutant -- Settlement.allocate_to_cents   # one method
bin/mutant -- 'MealLedger*'                  # one class
MUTANT_JOBS=8 bin/mutant                     # more workers (default 4)
```

The whole app is about 19,500 mutations, so a full run is a night's
work and is usually run one stage at a time, each stage being the
subjects of one part of the app. The stages, and roughly what each
costs on six workers:

| Stage                                 | Subjects                                                        | Mutations | Time                                                         |
| ------------------------------------- | --------------------------------------------------------------- | --------- | ------------------------------------------------------------ |
| money                                 | `MealLedger* Settlement* Reconciliation* BalanceRecalculation*` | 2,080     | 2h10 (a survivor runs 600 to 800 examples)                   |
| services, jobs, mailers, helpers, lib | the classes under those directories, minus money                | 7,664     | 2h40 (some subjects run request specs)                       |
| models and concerns                   | `app/models/**`, minus money                                    | 5,874     | about 1h (11 loops that never end wait 5 min each)           |
| controllers and serializers           | `app/controllers/**`, `app/serializers/**`                      | 6,651     | 2h20 (an `ApiController` survivor runs 450 request examples) |

The exact subject list for a stage is the matching block of
`.mutant.yml`; pass it after `--`. It is not part of `bin/check`. Run
the stage a change touched after the change, and every stage after a
batch of merges the way a bug hunt runs
(`.claude/skills/bug-hunt/SKILL.md`). Never at the same time as
`bin/check` on the same machine: a mutation that times out under load
counts as not killed, and the browser suites are load.

Every run prints "parser/current is loading parser/ruby33 ... but you
are running 4.0.6". The line is noise. Mutant reads Ruby through
`unparser`, and on Ruby 3.5 and later `unparser` parses with Prism
(`Prism::Translation::Parser40` here), the same parser Ruby itself and
RuboCop use, so syntax newer than 3.3 is read correctly: the implicit
`it` block parameter parses and prints back (checked 2026-09-13). The
warning comes from one line in mutant that still requires
`parser/current` for the AST classes; the `parser` gem ships grammars
up to 3.3, notices the newer Ruby, and says so, but that grammar never
reads a file here. It goes away when mutant drops the require.

`bin/mutant` migrates the test database, then copies it once per worker
(`comeals_test<suffix>_0`, `_1`, ...). Workers cannot share one
database: every example runs at SERIALIZABLE inside a transaction, and
two workers writing the same `lower(name)` would block each other on the
unique index, or abort each other with a serialization failure, and an
abort counts as a kill. The hook that points each worker at its own
copy is `config/mutant/hooks.rb`.

## What is mutated

Every class in `app/` and `lib/`, listed by name in `.mutant.yml`. The
money classes came first — `MealLedger`, `Settlement` (which holds
`allocate_to_cents`), `Reconciliation`, `BalanceRecalculation`, the
ones that turn bills and attendance into an amount a person is told to
pay — and the rest followed. `Current` is left out: it declares
attributes and has no method to mutate.

Two kinds of node are skipped (`ignore_patterns` in `.mutant.yml`):
`T.must(...)` and `T.let(...)`. Both are no-ops at runtime, so the
mutation "remove the call" can never fail a test, and every one would
be a survivor that means nothing. And every model's admin search and
sort list (`ransackable_attributes`) is ignored by name: the spec for
those checks the rule, that every name is a column and none is a
secret, not the list.

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
checks a class under a sentence description — a request spec for a
controller, a task spec for a job — add a row. The same file gives an
empty list to the specs mutant must never run: the storms, the random
sequences, the query-count budget, the thread-safety probes, and the
runtime type-check specs (mutant reinserts a method without its `sig`,
so those fail on the unmutated code).

Mutant runs the examples with `--fail-fast`, so a killed mutation stops
at the first failing example. Only a survivor pays for the whole list.

Three rules about which examples reach a method, each learned from a
survivor and each pinned by `spec/config/mutant_selection_spec.rb`:

1. A row replaces mutant's own selection for its file, so it must name
   the class the file describes.
2. A `describe '#method'` group anywhere is the whole test set for that
   method. Nothing described by a sentence is added to it, and nothing
   from a mapped file either, because a row tags examples at class
   level. So every example that proves a method goes inside that
   method's group. A row that names the class turns its file's method
   groups into class-level examples too, so if a file with no row has a
   group for the same method, the mapped file's group never runs for
   it. Such a row names those methods one by one
   (`Community#affected_calendar_keys`), and the guard spec fails when
   one is missed.
3. A concern is proved through the models that include it, so a model
   spec's row names every concern the model includes.

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

A timeout counts as a survivor too (`coverage_criteria` in
`.mutant.yml`). Rerun its subject alone before reading it: under load a
slow kill can reach the limit. If it times out again, look at the
mutation. Some make a loop that never ends (`while true`, a counter that
never moves, `sleep` with no argument). Every example that reaches that
loop hangs, which is a failure mutant cannot count. Say so in the
results; it is not a missing assertion. Any other timeout is a finding.

A survivor on the money path is never "fine as it is": every method
there is on the path to a number on a settlement statement. Elsewhere
the same three kinds apply, and the third — noise — is more common:
a serializer's attribute order, a log line's wording, a `count` for a
`size`. Say which kind it is, in the results below, before ignoring
anything.

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

### 2026-09-10, Settlement and Reconciliation, three runs

The first run since a6605b6 changed Settlement: 31 methods, 1265
mutations, 6 workers. 1226 killed, 39 alive, 27 by timeout. Browser
suites ran on the same machine for the first half.

Reading the report showed that 13 Settlement methods had a "neutral
failure": the unmutated code's own test set failed in a quarter of a
second, on `Name is already used by the resident in unit ...`. A
resident named 'Cook' was already in the worker's database. The race
examples (`spec/db/settlement_race_spec.rb`) commit for real and clean
up in their own hooks, but a mutation that makes one of them wait
forever is killed at the timeout, and a killed process never reaches
its after hook. From then on, every example in that worker that
creates a 'Cook' fails before it checks anything, which mutant counts
as a kill. So the kills for those 13 methods meant nothing, in this run
and in the first full run of 2026-09-08. `config/mutant/hooks.rb` now
truncates the worker's tables before every mutation (hook 3), the same
TRUNCATE the suite itself uses.

The Reconciliation survivors that were real:

- Done. `Reconciliation#unit_balances`: dropping `order(:name)`. The
  spec now creates unit B before unit A and expects A first.
- Done. `Reconciliation#unique_cooks`: dropping `.uniq`. The spec now
  settles two meals by one cook and expects one cook.
- Done, removed. `Reconciliation#must_settle_at_least_one_meal`: the
  blank end-date guard. The presence validation is declared first, so
  a blank end date is already an `end_date` error when this runs, and
  the second guard returns. The blank-date example now also expects no
  base error.
- Done, removed. `Reconciliation#eligible_meals`: the `today:` argument.
  The scope's default reads the same value from the one community.

The second run, on an idle machine with those changes: 1220 killed, 31
alive, 13 of them the same neutral failures. The 18 others are all
noise from the list below: `count` to `length`, `to_a` to `to_ary`, the
preload and `with_attendees` removals in `settlement_ledger`, the
`T.cast` type arguments, `self.end_date` to `end_date()`,
`errors[:end_date].any?` to `errors.any?` (nothing else validates on
this model), and the `allocate_to_cents` equivalents.

The third run, with hook 3: 1232 killed, 19 alive, 89 timeouts, 1 hour
47 minutes. Two more things came out of it.

- Three "neutral failures" were left, and they were the runtime
  type-check specs (`settlement_types_spec.rb`,
  `reconciliation_types_spec.rb`). Mutant reinserts a method from its
  own copy of the source, without the `sig` block above it, so the
  unmutated method no longer raises `TypeError` and the example fails.
  `spec/support/mutant_selection.rb` now gives every `*_types_spec.rb`
  an empty expression list, so mutant never selects them.
- The 89 timeouts were kills whose cleanup hung. A race example whose
  rival thread still held a row lock when the example failed reported
  the failure, then waited forever in its own after-hook TRUNCATE, and
  was killed at the timeout. Postgres does not notice a killed client
  that is waiting on a lock, so the lock stayed, and the next
  mutation's TRUNCATE (hook 3) waited on it too. `Settlement.preview`
  alone took 76 minutes. Hook 3 now terminates every other session on
  the worker's database first; only dead processes own them.

The fourth run, with both: 1251 mutations, 1232 killed, 19 alive, no
neutral failure, 1 hour 43 minutes. The 19 are all noise, all in
Reconciliation: `count` to `size` (2), `to_a` to `to_ary` and the
preload and `with_attendees` removals in `settlement_ledger` (9), the
`T.cast` type arguments in `unit_balances` (2), `self.end_date` to
`end_date()`, `errors[:end_date].any?` to `errors.any?`, and the
default-argument rewrites of `settlement_balances` (4). (Only one of
those four was a default argument. Two dropped the reconciliation id
it passes to `allocate_to_cents`, and are killed since 2026-09-28; one
dropped the start value of a sum.) Settlement has
no survivor. This is the first run whose kills on Settlement mean
something (the earlier ones had the neutral failure).

The time went to 109 more timeouts, and they were kills too: a race
example that fails while its rival thread still holds a row lock hangs
in its own after-hook TRUNCATE until the mutation timeout, 120 seconds
for a kill that took 5. `Reconciliation#unit_balances` alone took 55
minutes. Hook 3 now also sets a 10-second lock timeout on the session
the examples run on, so that TRUNCATE gives up and the process exits
with the failure it already reported. Checked on that one method: 88 mutations, 86 killed, the same 2 noise
survivors, no timeout, under 10 minutes.

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

### 2026-09-12, every class in app/ and lib/, in three stages

The subjects went from the four money classes to every class, in
three stages on six workers. Each stage ran two or three times, with
specs written from the survivors between runs. The numbers, then what
the survivors taught.

| Stage                                    | Run                                                | Mutations | Killed | Alive         | Timeouts | Time                                  |
| ---------------------------------------- | -------------------------------------------------- | --------- | ------ | ------------- | -------- | ------------------------------------- |
| A: services, jobs, mailers, helpers, lib | 1                                                  | 6,968     | 5,032  | 1,936 (72.2%) |          | 40 min                                |
| A                                        | 2, rows fixed                                      | 6,968     | 6,047  | 921 (86.8%)   |          | 40 min                                |
| A                                        | 3, specs added                                     | 6,860     | 6,477  | 383 (94.4%)   | 20       | 47 min                                |
| B: models and concerns                   | 1                                                  | 5,378     | 4,410  | 968 (82.0%)   | 29       |                                       |
| B                                        | 2, rows and specs                                  | 5,378     | 5,005  | 373 (93.1%)   | 11       | 37 min                                |
| B                                        | 3, touched classes                                 | B3M       | B3K    | B3A (B3P%)    | B3T      | B3T2                                  |
| A                                        | 4, touched classes                                 | A4M       | A4K    | A4A (A4P%)    | A4T      | A4T2                                  |
| C: controllers and serializers           | 1                                                  | 6,719     | 5,313  | 1,406 (79.1%) | 194      | 1h20 awake (the laptop slept mid-run) |
| C                                        | 2, rows and specs                                  | 6,719     | 5,960  | 759 (88.7%)   | 2        | 2h07                                  |
| C                                        | 3, the 91 subjects the pass touched                | 4,206     | 3,793  | 413 (90.2%)   | 2        | 1h53                                  |
| C                                        | 3, the other 85 subjects                           | 2,513     | 2,382  | 131 (94.8%)   | 0        | 15 min                                |
| A                                        | 4, whole stage, after every later change           | 6,855     | 6,494  | 361 (94.7%)   | 20       | 49 min                                |
| B                                        | 3, whole stage, after every later change           | 5,263     | 5,053  | 210 (96.0%)   | 11       | 33 min                                |
| C                                        | 4, whole stage, after every later change           | 6,719     | 6,234  | 485 (92.8%)   | 78       | 4h33 (the laptop slept once)          |
| A                                        | 5, whole stage, with DEFERRABLE off in the workers | 6,872     | 6,516  | 356 (94.8%)   | 20       | 46 min, no neutral failure            |

**Three ways the selection was wrong.** Each one made a class look
tested when nothing ran for it, and each is now pinned by
`spec/config/mutant_selection_spec.rb`.

1. A row replaces mutant's own selection, so a row that names other
   classes and forgets the one the file describes turns that file off
   for it. `LedgerVerification` had 661 survivors with "tests: 0";
   eleven rows had the same hole.
2. Mutant takes the most specific group. When any file has
   `describe '.authenticate'` under `describe JwtAuth`, that group is the
   whole test set for the method: nothing described by a sentence is
   added, and neither is anything from a mapped file, because a row
   tags its examples at class level. `LiveUpdate.calendar_range` had one
   example in its group and deleting the method body survived;
   `ResidentMailer#new_rotation_email` had three, and an empty link
   survived while the example that checked the link sat in a group
   called "the links in the rotation emails"; a new
   `community_calendar_cache_spec.rb` with a row was never selected for
   `Community#affected_calendar_keys`, because `community_spec.rb` has a
   group of that name. Every example that proves a method now lives
   inside that method's group, a file that describes the class and
   holds method groups gets no row, and the rule is written at the top
   of `live_update_spec.rb`.
3. A concern is proved through the models that include it, and the
   rows for those model specs named `LiveUpdate` but not the concerns.
   `ReconciledMealImmutability` ran only under a few admin request
   specs; `bill_spec.rb` had the very example that proves its re-parent
   guard and was never selected for it. The guard now derives each
   model's concerns from the class and fails when a row leaves one out.

**One bug.** `Community#auto_create_rotations` ordered the meals by date
and then walked them with `find_each`, which ignores the order (Rails
says so in the log). Meals entered out of date order were grouped by
id. Only `db/seeds.rb` calls it. Fixed with `each`;
`community_spec.rb` has the case.

**Redundant code, removed.** The first `% weeks_count` in
`ScheduleWeekLabelHelper#schedule_week_rows` (the slot takes the
modulo again). `Rotation`'s `after_remove` callback: only `meal_ids=`
reached it, the form that used that is gone since #78, and with
`dependent: :destroy` a removed meal is destroyed and pushes its own
month anyway. `Rotation#capture_meal_dates_for_cache`: a destroyed
rotation's meals are destroyed by the cascade and each pushes its own
month, so the captured dates pushed the same months a second time.
The `.limit(1)` before each `pick` in `Meal#neighbour_ids`: `pick`
limits to one row itself, so every mutation of the limit survived.

**Redundant, left in place.** `MealIcalFeed#wall_clock`: icalendar
prints a zoned time by its local fields, so the DateTime it builds is
the same text (checked: both give `20260405T173000`). Kept because its
comment explains a real concern about offsets; a decision for the
owner.

**A subject mutant cannot reach.** `AppendOnly::ClassMethods#append_only`
is a class-body macro: it runs once when the four append-only models
load and registers their callbacks, and mutant inserts its mutated
copy after that. All 50 of its mutations survived, "register no
callback" included. It is now in the `ignore` list, with the reason;
the callbacks it registers are mutated through
`AppendOnly#append_only_refuse`, whose survivors went to zero once the
model specs were mapped to it.

**Specs written from the stage A survivors** (in `spec/services`,
`spec/jobs`, `spec/mailers`, `spec/helpers`, `spec/tasks`,
`spec/lib`): `LiveUpdate` rewritten as one file of method groups —
multi-month ranges, the community day for a time, the sender from
`Current`, first caller wins, a nested batch runs its block, the batch
closes on a raise, the push message; `JwtAuth` — the wrong-issuer
example used to pass with `verify_iss` off, and a token signed with
another algorithm or none is refused; `ReconciliationWarnings` (new
file) — a resident and a guest count together, a no-cost bill with an
amount left on it is not money; `SetMultipliersJob` (new file);
`PacedDelivery` — the cap counts everyone past it, the SMTP settings,
the counts when closing the session fails after the messages went out;
`RetryOnConflict` — the jitter bounds; `SettleAndNotify` — the refresh
gets the batch budget; `RecurringJob` — five tries from a quarter
second; `PasswordReset` — the failure report names the recipient;
both mailers — the links point at the configured root; `MealIcalFeed`
— VTIMEZONE, calendar name, descriptions; `MealCostSummary` — no-cost
bills, a guests-only meal, a settled meal that got no charges;
`LedgerVerification` — the summary string, a negative line sum, a
one-cent difference tolerated, the error recorded; `AuditDescription`
— exact strings and every fallback; `ResidentNameShortener`; the
helpers' exact markup.

**Specs written from the stage B survivors** (`spec/models`):
`concerns/locks_its_meal_first_spec.rb` (new) pins the lock statement
itself — `FOR KEY SHARE`, both meal ids in id order when a row moves,
before the write; `holidays_spec.rb` checks every day of 2000–2040
against a list written without the code (three Easters proved the
method once; the arithmetic has twenty steps); `MealSchedule` — the
scan limit by its message, dates from times; `Meal` — the scopes with
two meals (a correlation dropped from the EXISTS survived every
one-meal example), the rotation scoping of the third-cook check, the
closed-meal destroy guard, the neighbour pushes on create, move and
destroy, the audit order, no query when preloaded; `Rotation` —
`starting_within` at both ends, every clause of `touched_meals`, the
place values with `updated_at` and pushes, the hole guard's boundary
day, the months pushed on save and on recolor; `Community` — the
six-week windows day by day, the cache version (day, microsecond,
range edges, an event on the last day, the request's zone), settled
meals left out of both averages, rounding, orphan admins, ages, a cap
with a third decimal, mixed schedule weeks, the zone-change push, the
next rotation after the latest date; `Resident` — age around the
birthday, destroy of a fresh record; `Unit`, `Bill` (nil amount),
`MealResident` (nil resident), `MealCharge` (`credit?`,
`subsidized?`, the exact refusal messages), `LedgerCheckRun`
(`duration`, plain booleans, the messages), `AdminUser` (the last
superuser beside plain admins, bootstrap), `Event`,
`CommonHouseReservation`, `GuestRoomReservation` (the old months when
only one end moves).

**What is left alive, by kind.** Stage A, 383:

- `AuditDescription`, 106: `== true` to truthiness, `[]` to `.fetch`,
  `.instance_of?(Array)` to truthiness. The audited gem stores booleans
  and two-element arrays there, so no row can tell them apart.
- `LiveUpdate`, 42: `is_a?` to `instance_of?`, the `nil` guards, and
  dropping `first` from a range (the month start and `last` already
  reach every month `first` does).
- `LedgerVerification`, 38: `.to_s('F')` to `.to_s` — `BigDecimal#to_s`
  prints plain digits in this Ruby (bigdecimal 3); `.sort` on ids and
  `order(:id)` — Postgres returned them sorted anyway, the assertion is
  real and mutant cannot prove it; the `if` around a log line.
- `MealIcalFeed`, 25: the reference date the VTIMEZONE is built from,
  and `wall_clock` (above).
- `JwtAuth`, 18: the key-generator salt (a token is encoded and decoded
  in one process) and `Time.zone.at` for `Time.at` (instants compare
  equal in any zone).
- `PacedDelivery`, 18, and the rest: `.to_a`, `.fetch`, `.key?`,
  `count` for `size`, default arguments the specs always pass, and the
  `if` around every log line (the call is ignored, the branch is not).
- Six "neutral failures" (the unmutated code failing its own tests, so
  its kills mean nothing): `NotifyCooksJob#perform` and three
  `RecurringJob` methods, and `AssetCacheControl`, whose spec wrote one
  fixture file from six processes and needed a built `index.html`. The
  spec now names its fixture by process id and writes a placeholder
  page when there is no build, and the whole-stage rerun below found
  26 real survivors in the middleware (the `/vite-assets/` prefix, the
  body, and "no-cache" leaking to every 200), answered by three more
  examples; rerun alone (its spec is selected for nothing else): 155
  mutations, 139 killed, 16 left, all `.fetch` and `&&`-to-`||`
  rewrites the two paths cannot tell apart. The four job ones were still
  there in the rerun, on an idle machine: two lock-budget examples
  (`SettleAndNotify ... keeps trying past a request's three attempts`,
  `RecurringJob ... waits with the batch budget`) hit the 10 s statement
  timeout inside `BalanceRecalculation#call`, only inside a mutant
  worker; they pass in mutant's order on their own. Explained on
  2026-09-13 with a watchdog that logged every session once a second
  through a whole-stage run: the query was not waiting on a lock but on
  `SafeSnapshot`. The balance refresh reads through `SnapshotRead`,
  which opens a SERIALIZABLE READ ONLY DEFERRABLE transaction, and a
  DEFERRABLE transaction waits until every serializable read-write
  transaction in the whole PostgreSQL instance has finished, in every
  database (checked with two psql sessions on two databases: the
  deferrable one waited the full length of the other's transaction).
  Six workers in six databases never stop writing, and a sibling's hung
  mutation holds a transaction open for up to two minutes, so the read
  starved. `config/mutant/hooks.rb` now turns
  `config.x.snapshot_reads_deferrable` off in its workers, and
  `SnapshotRead`'s spec sets it back on for the example that checks the
  mode. The small runs never showed it because no sibling hung long
  enough while the two examples ran. The whole-stage rerun with the
  setting off had no neutral failure; `SnapshotRead.call` keeps four
  survivors, the rewrites of its isolation and mode line, which the
  workers cannot see with the setting off.

Stage B, 373 after the second run, 4 answered in a third pass and the rest read:

- `Holidays`, 53: every one in `easter?`, and every one gives the same
  Sunday for 2000–2040 (the century terms are constant inside one
  century). The spec now checks Gauss's algorithm for 1583–2499.
- `AppendOnly::ClassMethods`, 50: the class-body macro, above.
- `Community`, 83: `.fetch` for `[]`, `instance_of?` for `is_a?`,
  `size` for `count`, the preloads, and a new spec file that was mapped
  by a row and so lost to `community_spec.rb`'s method groups (the
  selection rule above; the row is gone).
- `Meal`, 53 and `Rotation`, 54: `neighbour_ids` with the `limit` that
  `pick` made redundant (removed) and the order and bound rewrites the
  unique date index makes equal; the `loaded?` branches of `multiplier`
  and `attendees_count`, which differ only in query shape; the date
  capture and `after_remove` (removed).
- The rest: `return true` in a validation (its value is ignored),
  `self.x` for `x()`, `.present?` for truthiness on an id.

The whole-stage rerun, after the third pass: 210. `Holidays` is down to
11, all in `easter?` and all giving the same Sunday for every year from
1583 to 2499 (a `- 15` under a `% 30`, and the `m` correction, which is
zero for every year in that range). `Community`, 68: the schedule and
dinner-time shape checks (`instance_of?` for `is_a?`, `lstrip` for
`strip`), `size` for `count`, and the preloads. `Meal`, 41: the
`loaded?` branches and the `neighbour_ids` rewrites the unique date
index makes equal. `Rotation`, 30: `recolor_remaining_rotations` and
`set_place_value` with `distinct` dropped or the batch opened
differently, which push the same months.

Stage C, 1,406 after the first run. Two holes, both wide:

- The base controllers. Every API request runs `ApiController`'s
  filters and rescues and every admin request `ApplicationController`'s,
  but only five rows named the first and four the second, so 269 and 46
  mutations survived — "answer nothing to an unknown path" among them.
  `MUTANT_SPECS` now adds the base controller to every request spec row
  (`MUTANT_SPEC_ROWS` holds the rows as written), and the guard spec
  pins it.
- The calendar chips. The contract spec pins each serializer's keys and
  `serializers_spec.rb` a few words, so the id the SPA dedups by, the
  type, the start and end the chip is placed by, the link and the
  colour were all free to change: 500 survivors across the seven chip
  serializers. `spec/serializers/calendar_chips_spec.rb` now holds the
  whole payload of each, value by value, and
  `calendar_serializer_spec.rb` puts a record one day outside each
  window edge beside one on it.
- The write messages: `{ message: 'Description updated.' }` could become
  `{}` and every status check passed.
  `spec/requests/api/v1/write_messages_spec.rb` pins each write's
  answer, the order `meals/next` picks by, the history's date and the
  sender's socket left out of the push.
- 194 timeouts: a mutation that makes a request spec wait (a retry
  loop that never ends) is killed at the 120 s limit; each costs the
  full limit.
- One neutral failure: `FallbackController#index` serves
  `public/index.html`, which only a build writes. `bin/mutant` now
  writes a placeholder when there is none and removes it after.
- `Api::V1::MealsController#update_bills`, 44: the branch that splits
  this method into `BillsPayload` replaces it; run mutant on
  `BillsPayload*` after that merge.

After the second run, 759. What was left and what a third pass answered:

- The shared answers: the 404 and 401 sentences, the reconciled
  fast-path sentence, the null id when there is no next meal, and the
  report's `context` (controller and action) on a conflict or an
  overloaded pool were not pinned. They are now, in
  `write_messages_spec.rb` and the two conflict specs.
- `set_community_timezone`: only the token-parameter path was proved;
  a Bearer-authenticated request now reads the community zone too.
- `CommunitiesController`: the hosts order and unit names, the month
  the birthdays are taken from (two weeks after the six-week grid's
  first Sunday), and the feed's "Sign up here" link under the
  configured root.
- `ResidentsController`: an email with spaces and capitals, the
  shortened name on the reset page when first names clash, the one-word
  reset error (a sentence since 2026-09-27: "Password reset link is
  incorrect or expired."), and only the resident's own cook slots in
  their feed.
- `MealFormSerializer`: the previous and next meal links, `reconciled`
  as a plain boolean, and one resident row value by value.
- `AuditSerializer` (new spec): a history row value by value.
- The neutral failure: the placeholder page lacked the `<div id="root">`
  the fallback spec looks for.
- Left as noise: `params.fetch` for `params[]`, `Date.iso8601` for
  `Date.parse`, `.to_i` on a parameter `Time.zone.local` converts
  anyway, `defined?` memo guards, `instance_of?` for `is_a?`, the
  `loaded?` branches of the rotation chip (same value either way),
  `update_bills` (44, replaced by the `BillsPayload` branch), and the
  `reject_if_reconciled` fast path — both "never reject" mutations
  survive because the model guard refuses the same write with a
  message that also says "reconciled"; the fast path is kept for its
  clearer sentence, which is now pinned. (Since 2026-09-27 both are
  killed: `write_messages_spec.rb` records the request's SQL and
  expects no `FOR UPDATE`, so a settled meal must be refused before
  the meal lock is taken.)

After the third pass, 413 on the subjects it touched (the table's
whole-stage rerun below is the number to quote). What the third pass
still showed, and a fourth pass answered:

- `ApiController#set_community_timezone`: every mutation survived,
  "never use the community zone" included, with 382 examples selected.
  Nothing in the API suite read a time in the request's zone: the
  month payload's `timezone` is the community column, not `Time.zone`.
  `write_messages_spec.rb` now creates an event at 19:00 in a Tokyo
  community, signed in by token and by header, and expects 10:00 UTC.
  This is the same class of bug as the admin zone wrapper the time
  hunt found on 2026-08-26.
- `CommunitiesController#calendar`: the six-week window's start and
  length were free (`beginning_of_week` could go, 41 could be 40 or 42) and so was the month the payload names; a request-level example
  now puts a meal on each edge and one day past it, and the cache key
  is checked in the store.
- `EventsController#update`: an update that did not mention `all_day`
  could turn an all-day event into a timed one.
- The exact "No resident with email", the expired reset token being
  cleared on use, the resident feed's "View here" link, retired
  residents left out of the birthdays.

Noise, left: `params.fetch` for `params[]`, `Date.iso8601` for
`Date.parse`, `.to_i` on a parameter `Time.zone.local` converts
anyway, `defined?` memo guards, `instance_of?` for `is_a?`, the
`includes`, `update_bills` (the `BillsPayload` branch replaces it),
and the `reject_if_reconciled` fast path (above; killed since
2026-09-27).

The one neutral failure in the third pass was the same placeholder
page again: a stale one, without the root element, was already there
from an earlier spec run, so `bin/mutant` left it alone.

The whole-stage rerun after the fourth pass: 485, no neutral failure.
`ApiController` 83 (38 of them the `.to_i` rewrites in
`parse_start_end_params`), `EventsController` 65 and the two
reservation controllers 43 (`params.fetch`, `.to_s` on a string), the
calendar serializer's query shapes 47, `MealsController` 67 (44 in
`update_bills`), and the resident and community endpoints' `.fetch`
and `Date.iso8601` rewrites. `EventsController#update` (37) went next, on 2026-09-13: an update
that turns a timed event all-day and one that turns it back, the
description and the hours of a created event, and a 400 with two
problems on one body each pinned. Update keeps 7, create 11, all
`.fetch` for `[]`, `.to_str` for `.to_s`, and an `all_day` default that
reads the same when the key is absent. Nothing on the controller and
serializer list is a missing assertion now. (That was not so: the
controllers and serializers stage of 2026-09-27 found 120.)

### 2026-09-21, the ledger grain (ADR 0008)

The first run after `MealLedger` was rewritten to allocate at the
ledger grain, with the new `LargestRemainderSplit`, the exact zero-sum
guard in `Settlement` and the exact line-item check in
`LedgerVerification`. Only the changed subjects, on six workers: 23
methods, 1,367 mutations, 1,350 killed, 17 alive, 106 timeouts, 1h07.
Timeouts count as kills in mutant's total; they were not looked at one
by one. (They should not have: see 2026-09-27 for why they did.)

Ten of the 17 were one neutral failure: `MealLedger#initialize`, whose
sig refuses a relation, and the "runtime type checks" group that proves
it sat inside `meal_ledger_spec.rb`, so it ran against the method with
its sig removed and failed on the unmutated code. The group is now
`spec/services/meal_ledger_types_spec.rb`, listed in
`MUTANT_SIG_CHECK_SPECS` like the others.

The other seven, and what each became:

- `MealLedger#credit_units`: `spent.map { 0 }` to `0` on a
  zero-multiplier meal. Invisible without the sig, because `0[index]`
  is the bit at that index, which is 0. Rewritten as
  `Array.new(spent.size, 0)`, whose mutations all die.
- `LargestRemainderSplit.call`: the early `return shares if
leftover.zero?` was redundant code; with nothing left over the
  ranking is built and `first(0)` uses none of it. Removed. Then
  `each_index.to_a.sort` to `each_index.sort`, the same: `to_a`
  removed.
- `LargestRemainderSplit.check!`: the number in a refusal message, and
  `weights.inspect` for `weights` (the same string for an Array). The
  specs now match each whole message, and `.inspect` is gone.
- `LedgerVerification#lines_do_not_balance`: `total.to_s('F')` to
  `total`. Noise, left: the JSON encoder writes a BigDecimal as the
  same plain decimal string (`-0.00000001`, `-40.0`), checked on four
  values, so the two are the same once the row is stored. The call
  stays because it says what the row must hold if the encoder ever
  changes.
- `LedgerVerification#line_item_check`: `.sum(BigDecimal('0'))` to
  `.sum`. Noise, left: an empty sum is then Integer 0, and `zero?`
  reads the same.
- `MealLedger.units`: `.to_i` to `.to_int`. Noise, left, the alias.
- `MealLedger#initialize`: the `@lines = T.let(nil, ...)` declaration
  removed. Noise, left: an instance variable is nil before assignment,
  and the line is there for Sorbet.

Rerun after the fixes: `LargestRemainderSplit*` 178 mutations, 178
killed; `MealLedger#initialize`, `#credit_units` and `#credit_lines`
with the type checks moved out, one alive (the `T.let` line above).

### 2026-09-25, the four bug-hunt fixes

Run after the fixes of the 2026-09-21 hunt merged: `LiveUpdate*`,
`Settlement*`, `SettleAndNotify*`, `ClosedMealAttendanceFreeze*`,
`ReconciledMealImmutability*` and `SetMultipliersJob*`, on six
workers: 50 subjects, 2,198 mutations, 2,029 killed (97 of them by
timeout, which mutant counted as kills; see 2026-09-27), 169 alive,
1h43.

Most of the 169 were one spec group. The fix for the refused cache
clear added a `describe '.flush'` group with a single example, and
under this suite's rule a `'.method'` group is the whole test set for
that method, so 104 of `flush`'s 110 mutations ran against that one
example. The group is described by a sentence now, and `flush` gets
every mapped request spec again. Lesson for the next fix: add an
example to a method's group only if the group is the method's whole
proof; otherwise describe it by a sentence.

Two lines were redundant and are gone: `calendar_range` kept the first
day on its own (its month's first day reaches every month it does),
and `community_date` special-cased a Date (a Date through
`in_time_zone` is the same Date). The freeze's validations returned
`true` or `false`, which a callback ignores; they return nothing now,
and `can_leave?` no longer re-tests `closed`, which its caller has
already ruled out.

New examples: a nil date, the community zone for a range's start and
its end (October 31 16:00 UTC is November 1 in Tokyo, and November
2026 starts on a Sunday, so the two readings mark different months), a
Date result from `community_date`, a refused cache delete reported with
its key, an empty batch that reads nothing, the attendance count being
this meal's only, the retry delays of both settlement budgets on both
retried steps, and the job spec under prosopite.

Rerun on the five subjects that had survivors (Settlement had none and
did not change), six workers, 200-second timeout: 1,212 mutations,
1,190 killed, 22 alive, 4 timeouts, 40 minutes. The 22, by kind:

- `ClosedMealAttendanceFreeze#attendees_in_database`, 6: `count` to
  `size` or `length` (the same number on an unloaded relation) and
  `where(meal_id: meal)` for `meal.id` (Rails reads the id).
- `ReconciledMealImmutability#previous_meal_reconciled?`, 3: dropping
  `will_save_change_to_meal_id?` reads the row's own meal a second time
  and answers the same; `.present?` for truthiness on an id.
- `LiveUpdate.flush`, 6: the `return if batch.blank?` shortcut. An
  empty batch then reads the community and does nothing; the new
  example pins that it reads nothing, so these should die on the next
  run.
- `LiveUpdate.note`, 2: the `return` after the no-transaction flush.
  Rewritten as one if/elsif/else, so there is no return to drop.
- `LiveUpdate.calendar_range`, 1: `<=` to `<` on the month loop. The
  last day is kept on its own and reaches its month, so the loop's last
  step is covered either way.
- `SetMultipliersJob#run`, 2: the `includes(:community)` preload. The
  job spec runs under prosopite now, but a job runs with the query
  cache on, and prosopite ignores a cached repeat.
- `SettleAndNotify.call` and `.refresh_balances`, 1 each: dropping
  `base_delay:`. The request budget's delay is RetryOnConflict's
  default, so only the batch budget can show it; both examples that use
  the batch budget now pin the first sleep.

Third pass, on the three subjects the answers changed (`LiveUpdate.flush`,
`LiveUpdate.note`, `SettleAndNotify*`): 295 mutations, 294 killed. The
one alive was the `base_delay:` drop again: "any sleep in the batch
range" is also true of the request delay's fifth and sixth doublings, so
the two batch examples now record every sleep and check the first.
Fourth pass, `SettleAndNotify*` alone: 111 mutations, 111 killed.

### 2026-09-26, the computed price band (#88)

Run after 8bad9ce7, on the four classes it touched, by name (`Resident
Community MealResident Meal`; `Class#*` matches nothing): 2,718
mutations, 2,576 killed, 142 alive, 1 timeout, 33 minutes on six
workers with a 200-second timeout.

Twenty of the 142 were in code this change added, and each was one of
three things:

- A missing assertion. A birthday of today (`<=` to `<` in
  `birthday_not_in_the_future`): a newborn is a child of age zero, now
  an example. The child-without-birthday sentence stacking with the
  "makes this person an adult" one when the `return` was dropped: the
  example now asserts the one sentence, exactly. A bad kind reaching
  the birthday check: the example asserts no birthday error.
- Redundant code. `birthday.present? && child?` in
  `kind_matches_birthday`: a blank birthday is never a child, so the
  first test did nothing; gone. `kind_stated?` as the `if:` of the
  validation duplicated the inclusion rule; the validation runs
  `if: :kind` and returns for a kind the inclusion rule refuses. The
  `unless row.multiplier == expected` around the re-stamp in
  `Meal#restamp_attendance_for_new_date`: `update!` with an unchanged
  value writes nothing, so the guard was a shortcut; gone.
- A line that did nothing. The `includes(:resident)` in the re-stamp
  survived every removal even through the admin form under prosopite
  (`spec/requests/admin/meal_move_spec.rb`, six rows): goldiloader loads
  the batch's residents in one query on its own, so the preload was
  redundant. Removed; the request example stays as the pin that the
  move makes no per-row read.

The other 122 are the ones the 2026-09-12 stage lists above:
`Community`, 66 (the schedule and dinner-time shape checks, `size` for
`count`, the preloads, `unreconciled_ave_*`) and `Meal`, 49 (the
`loaded?` branches, `neighbour_ids`, `total_audits`), plus
`Resident#name_unique_with_helpful_message`, 7 (`self.x` for `x()`,
`.present?` for truthiness) and a `self.birthday` for `birthday()` in
each new method. Not looked at again.

### 2026-09-28, calendar overlap and times the database cannot store

Run on the methods the two calendar fixes changed or added, by name:
`StorableTime*`, `StorableTimeValidator*`,
`CalendarSerializer#common_house_reservations_in_range`,
`ApiController#parse_start_end_params`, `ApiController#start_end_times`,
`GuestRoomReservation#storable_date?` and
`CommonHouseReservation#period_is_free`. 551 mutations, 529 killed, 22
alive, 17 minutes on four workers.

Four were missing assertions, and each now has an example:

- `.order(:id)` dropped from the common house query, or made
  `.order(nil)`, 2. Nothing had two bookings stored out of id order.
  `calendar_serializer_spec.rb` now moves the first booking to a later
  day, which stores its row again after the second, and expects the ids
  in order. (A title change is not enough: PostgreSQL keeps that row
  where the index finds it first. And a move is not always enough
  either: the new row can land before the second one. Since 2026-09-29
  the spec also reads the statement; see the controllers and
  serializers stage of 2026-09-27.)
- `1..12` to `2..12` for the month. No example took an event in
  January; one now starts on January 1.
- `0..23` to `1..23` for the end hour. No example ended an event in
  the hour after midnight; one now ends at 00:30.

The other 18 change nothing a caller can see:

- `self.start_date`, `self.end_date` and `self.date` for `start_date()`
  and the rest, 3, and `instance_of?` for `is_a?` in the validator, 1
  (no Date subclass reaches it: a datetime column gives a
  TimeWithZone).
- The preloads of the common house query, 4: goldiloader loads the
  residents and units in one query without them.
- In `start_end_times`, 10 that `Date.valid_date?` makes the same: a
  month of 0 or 13, a day of 0 or 32, and no upper end to either range,
  are all refused by it anyway. Dropping the `end_date: nil` key of an
  all-day event leaves `times[:end_date]` nil either way. These, and
  the month and hour above, were there before these fixes; they show
  under `start_end_times` because `parse_start_end_params` was split in
  two.

### 2026-09-27, the test review fixes

The branch with the fixes from the test review of 2026-09-27, run stage
by stage on 2026-09-28, on six workers.

**Money stage.** `MealLedger* Settlement* Reconciliation*
BalanceRecalculation*`. The branch changed only a comment in these
classes, but it changed many of the specs mutant runs for them, and the
factories.

| Run                                                      | Subjects | Mutations | Killed | Alive | Timeouts              | Time |
| -------------------------------------------------------- | -------- | --------- | ------ | ----- | --------------------- | ---- |
| 1                                                        | 51       | 2,132     | 2,080  | 52    | 140, counted as kills | 2h11 |
| 2, timeouts counted as alive, a 300-second limit         | 51       | 2,080     | 1,967  | 113   | 0                     | 2h11 |
| 3, the 15 methods the answers to run 2 changed or pinned | 15       | 904       | 869    | 35    | 0                     | 1h00 |

**Timeouts were counted as kills.** `.mutant.yml` says a mutation that
reaches the time limit counts as not killed (`coverage_criteria`,
`timeout: false`). Mutant 0.17 (in the Gemfile since 2026-09-17) drops
that setting whenever `MUTANT_JOBS` is in its environment: it reads the
variable into a config that carries the gem's own criteria, where a
timeout counts as a kill, and that config is merged over the file's.
`bin/mutant` exported `MUTANT_JOBS` on every run. So from 2026-09-17
every timeout was a kill, which is what the 2026-09-21 and 2026-09-25
entries above report. In run 1, every one of the 140 timeouts had passed
every example it reached; none had failed one. For 34 of the 51
subjects the unmutated code timed out too (34 of the 140). The time
limit caused them: a mutation that no example fails runs its whole list
of examples, one after another, and for a `MealLedger` method that list
is 620 examples, which took 113 to 118 seconds on six workers, against a
limit of 120.

`bin/mutant` now passes the count only as `--jobs` and unsets the
variable, the limit is 300 seconds, and `spec/config/mutant_timeout_spec.rb`
runs `bin/mutant` with stand-ins for `bundle`, `createdb` and `dropdb`
to check it. The same spec found that `bin/mutant` exited 1 even when
mutant killed everything (the last command of its exit trap was a
`[ ... ] && rm` whose test was false); that is fixed too. Run 2 had no
timeout, and 61 more survivors than run 1: the ones the timeouts had
hidden.

Run 1, 52 alive, by kind:

- Missing assertions (13), each now with an example that fails on it.
  `MealLedger#eaters`: dropping the rule that an attendee line comes
  before a guest line of the same resident (4). The example gave the
  attendance row the lower id, so the sort met it first anyway; the row
  now gets the higher id. `BalanceRecalculation#call`: dropping
  `with_attendees` or `joins(:bills)` (3), which only change which meals
  are read (a meal with no bill or nobody who ate gives only zero
  lines), and the four rewrites of `update_only` (4), three of which let
  each run overwrite `created_at`. `spec/services/balance_recalculation_spec.rb`
  is new. `Reconciliation#settlement_balances`: the reconciliation id it
  passes to `allocate_to_cents`, which only a refusal's message shows
  (2). The 2026-09-10 entry counted these two among "the
  default-argument rewrites".
- Redundant code, removed (18). `MealLedger#eaters`: `a.is_a?(Guest)`
  before comparing ids (5); two rows that tie on the resident and the
  kind are two guests, because a resident has one attendance row per
  meal. `MealLedger#debit_lines`: the early return for a meal nobody ate
  (6), which the zero-multiplier branch already covers, and
  `people.map { 0 }` (1), which could become `0`, and `0[index]` is 0.
  `BalanceRecalculation#call`: the hand-set `created_at` and
  `updated_at` (2) and the `if rows.any?` guard (4), since `upsert_all`
  fills the timestamps and returns without a query for an empty list.
  With them gone, `update_only: [:amount]` was what Rails does anyway,
  and it went too.
- A missing assertion answered after run 2 (2): `BalanceRecalculation#call`
  without the `guests` preload, below.
- Noise (19): `instance_of?` for `is_a?` in `MealLedger#debit_lines`
  (1); `to_a` to `to_ary` in `BalanceRecalculation#call` (1); the other
  17 `Reconciliation` survivors, as listed on 2026-09-10.

Run 2, 113 alive, by kind:

- Missing assertions (34), each now with an example that fails on it.
  `MealLedger#cooks`, the sort by resident id (2): every example entered
  the bills in resident id order; now three cooks share a capped credit,
  with their bills entered highest id first. `MealLedger#eaters`,
  comparing only one guest's id (2): the guests are now loaded both ways
  round. `MealLedger.units`, the amount in the refusal (4).
  `Settlement.preview`: the cutoff (1), the order the preview API reads
  its earliest and latest dates from (2), and the name "preview" in a
  refusal (3). `Settlement.held_by`: the cutoff (2), open meals only
  (1), the order (2), and the rule that today is never in a period (3).
  `Settlement.skipped_by`: the same rule (3), which the 2026-09-08 entry
  left as redundant because the preview's own cutoff check covers it;
  each list is now also asked directly, with a cutoff of today.
  `Settlement#assign_meals`: which rows the lock takes, and in what
  order (3); the example records the SQL.
  `Settlement#forget_cached_meals`: pushing every meal instead of the
  settled ones, leaving the asking browser out, and pushing a month once
  per meal instead of once (3). `Settlement#persist_balances!`: reading
  the meals a second time for the balances (1).
  `BalanceRecalculation#call`: the `guests` preload (2); the snapshot
  spec's concurrent edit now adds a guest, which only a read outside the
  snapshot sees. The preview, held and skipped examples are in
  `settlement_contract_spec.rb`; the lock, ledger, push and refusal
  examples are in the new `spec/services/settlement_spec.rb`.
- Redundant code, removed (5): `today:` passed from `Settlement.preview`
  to `settleable_by` (2), the same value the scope reads itself;
  `Settlement#settle!` returning the reconciliation, which no caller
  used (2); `[0] * people.size` in `MealLedger#debit_lines` (1), which
  could become `0 * people.size`. The weights are the shares when every
  multiplier is zero.
- Needs an owner decision, left (1): `MealLedger#financials_for` with
  `total_units: -1` for `0` in the zero-multiplier return. Issue #94 says
  that value is wrong (the summary should show what the cooks spent) and
  asks what "subsidized" means there.
- Noise (73):
  - `MealLedger` (12). `units`: `to_s` or the bare amount for
    `to_s('F')` (2), because ActiveSupport makes a BigDecimal's `to_s`
    plain digits too, and `.to_int` or `Integer()` for `.to_i` (2). The
    lines: `multiplier: nil` on a credit and `bill_amount: nil` on a
    debit dropped (2); a T::Struct fills a nilable field that is left
    out with nil. `instance_of?` for `is_a?` in `debit_lines` and
    `kind_rank` (2): no class inherits from Guest. `kind_rank` with 2 or
    167 for a guest, or -1 for an attendee (3): the order only needs the
    guest above the attendee. The `T.let` line of `initialize` (1).
  - `Settlement.preview` (10), `.held_by` (3) and `.skipped_by` (6):
    `to_a` to `to_ary`, and every preload removed (goldiloader loads the
    same rows in one query anyway).
  - `Settlement.skipped_by`, `order(nil)` (1; in run 3 also the order
    dropped). The example that checks the order fails on both under
    plain `rspec`, but not in a mutant worker, where each run starts
    from truncated tables and PostgreSQL returns these rows in date
    order anyway (the caveat of 2026-09-08).
  - `Settlement.allocate_to_cents` (17): the 14 equivalents listed on
    2026-09-08 and 2026-09-09, the default of `reconciliation_id` (1),
    which only the specs leave out, and a nil id in the message of the
    second guard (2), which only a broken first guard can reach.
  - Other `Settlement` methods (7): a sum's start value in
    `assert_balanced_input!`; `<` in `assert_candidates_cover_pennies!`;
    `raw > 0` for `raw >= 0` in `truncate_toward_zero`, because zero cut
    either way is zero; the `T.let` line of `initialize`; `pluck` with no
    column in `assign_meals`, because the lock is the rows it takes and
    the result is not read; the `.to_s` in `persist_charges!`; the nested
    transaction in `write_ledger!`.
  - `Reconciliation` (16), as listed on 2026-09-10 (the one left in
    `settlement_balances` is a sum's start value).
  - `BalanceRecalculation#call`, `to_a` to `to_ary` (1).

Run 3 reran the 15 methods whose code or examples the answers changed.
Its 35 alive are the noise above that belongs to those methods (34) and
the one left for #94. The whole suite afterwards: 2,818 examples, no
failure, 100% of lines and branches.

**Services, jobs, mailers, helpers and lib stage.** The `# services`
and `# jobs, mailers, helpers, lib` blocks of `.mutant.yml`. This
branch added `BillsPayload`, `LivePushJob` and `DeployConfigCheck` to
those blocks; none of the three had been in a stage run before.
`LivePushJob` and `DeployConfigCheck` had no survivor.

| Run                                                 | Subjects | Mutations | Killed | Alive | Timeouts             | Time   |
| --------------------------------------------------- | -------- | --------- | ------ | ----- | -------------------- | ------ |
| 1                                                   | 151      | 7,664     | 7,290  | 374   | 22, counted as alive | 2h40   |
| 2, the four methods with timeouts, alone            | 4        | 328       | 292    | 36    | the same 22          | 21 min |
| 3, the 11 classes and 4 methods the answers changed | 70       | 3,310     | 3,229  | 81    | 1, the endless range | 40 min |

The stage took 2h40, not the 45 minutes the table at the top used to
say. The time goes to the subjects whose example lists include request
specs. Each `AuditDescription` method has 105 examples, most of them
from the meals request spec, and the first 1,100 mutations took about
15 seconds each, kills included; some later ones took up to 50. The
rest of the stage ran at about 2 mutations a second. Why the same
subjects took 46 minutes on 2026-09-12 was not looked into.

Run 1, 374 alive, by kind:

- Missing assertions (71), each now with an example that fails on it
  (checked by making each change by hand).
  - `AuditDescription#cook_ids` (13). The describer that reads a meal's
    history in one query per table came with #84, three days after the
    last stage run, so its survivors were new. New examples in
    `audit_description_spec.rb`: a list with no update to a bill or an
    attendance row reads only the residents; when every updated row
    still exists it reads those rows by id, never the whole table, and
    no audit trail; a gone row's resident comes from a create audit of
    its own type, and from the create audit, not a later update; a live
    row's resident comes from the row, not its create audit.
  - `AuditDescription#describe` (4): a created row of another type that
    carries a vegetarian flag is not described as a guest.
  - `BillsPayload` (9): an invalid payload has no cook ids; a row with no
    `resident_id`, touched or not, is an unknown cook, not a `KeyError`;
    `write_to` takes cook ids as the strings a request sends (every
    service example passed integers); it reads the stored bills again,
    not a list the meal read before; and it does not save an untouched
    cook's bill again, which would run its callbacks and lock the meal.
  - `LedgerVerification` (10). `differences_between` (9): every mismatch
    example changed every resident's balance, so nothing showed that a
    resident whose amounts agree is left out; a third eater now keeps
    hers. `call` (1): dropping `SnapshotRead` survived. A group without
    a test transaction now records `now()` and `transaction_read_only`
    as each reconciliation is read, and expects one read-only
    transaction for both.
  - `AssetCacheControl` (14). The 2026-09-12 entry called its 16
    survivors `.fetch` and `&&`-to-`||` rewrites; 14 were not. The
    request examples only see answers the real stack gives, and never
    run `initialize`, which Rails runs once at boot. New examples wrap
    a stand-in app: an error under `/assets/` or `/vite-assets/` is not
    marked cacheable for a year, an error at a revalidated path is left
    alone, the app page with a charset is not cached, and an answer with
    no content type is.
  - `RecurringCatchUp#tasks` (6): the filter on `config/recurring.yml`
    skips a command entry, a blank class and a value that is not a
    table, but the real file has only a command entry. The example
    stubs one of each.
  - `MealCostSummary` (3): a settled no-cost meal people ate (zero
    debits, no credit line) and one nobody ate (no lines) both sum an
    empty list. Without the `BigDecimal` start value the sum is Integer
    0, which the `Summary` struct refuses.
  - `ScheduleWeekLabelHelper` (3). `current_sunday` (2): the admin form
    renders the unsaved bootstrap draft, which has no zone, and
    `ActiveSupport::TimeZone[nil]` raises, so the `.to_s` is needed; no
    example had a draft. `schedule_grid_data` (1): dropping the last
    `to_json` survived because the app's `JSON.parse` is Oj's
    (`config/initializers/oj.rb`), and Oj hands an Array back unchanged,
    so parsing could not tell text from an Array. The example now
    expects a String, as it did for the week labels.
  - `PacedDelivery::SessionDelivery#deliver!` (2): the SMTP session's
    message was matched with `anything`; it is now the encoded text.
  - `Healthcheck.ping_uri` (1): the examples compared `uri.to_s`, which
    a string passes; they compare with `URI(...)`.
  - `NotifyCooksJob#perform` (1): the mailer name only shows in a
    failure report, which no example checked.
  - `DatabasePoolCheck.verify!` (5), which was a bug. Rails reads a
    negative `max_connections` as no limit and gives nil; `verify!`
    counted that as a pool of 0 and refused to boot. It passes now.
- Redundant code, removed (24). `AuditDescription#cook_ids`: the two
  early returns for an empty list (12); Rails runs no query for an
  empty id list. `ScheduleWeekLabelHelper#schedule_week_rows`: the
  return for zero weeks (6); `Array.new(0)` builds no row, so the modulo
  never runs. `ReconciliationWarnings#initialize`: the defaults (4);
  only `.for` calls `new`, and it passes both. `NotifyCooksJob#perform`:
  the result at the end (2), which nothing reads.
- Loops that never end (22), the same 22 when rerun alone.
  `EnsureRotationsJob#run` (8): the `while` condition always true, or
  no rotation created inside it. `RetryOnConflict.call` (9): the
  attempt count that never grows, no `raise` at the last attempt, and
  `sleep` or `sleep(nil)`, which sleep forever. `LiveUpdate.calendar_range`
  (4) and `ScheduleWeekLabelHelper#schedule_grid_data` (1): a month
  loop or a range with no end. In the real code the rotation loop ends:
  `meals_per_rotation` is at least 1 (a CHECK) and
  `MealSchedule#upcoming_dates` raises on a schedule it cannot fill, so
  each pass adds a later meal.
- Noise (257):
  - `AuditDescription` (98). In the `describe_*` methods (87), the kinds
    listed on 2026-09-12, and three it did not name: the
    `action == 'update'` checks after create and destroy have returned
    (the audited gem writes no other action), a `return` before the
    same fallback the method ends with, and `present?` rewrites on a
    change the gem always stores as a two-element array. `named_resident_ids` (7): nil or
    repeated ids, and rows of other types, change the `IN` list but not
    which residents are found. `initialize` (2): `to_a`.
    `name_or_unknown` (1): `present?` for truthiness on a record.
    `cook_ids` (1): `.fetch('resident_id')` on a create audit, which
    always has one.
  - `LedgerVerification` (26): the kinds listed on 2026-09-12 and
    2026-09-21 (`to_s('F')`, the sorts and `order(:id)`, a sum's start
    value, the `if` around log lines), plus `date.to_s` in `detail` (the
    JSON column stores a Date as the same text) and `"#{error}"` for
    `"#{error.message}"`.
  - `MealIcalFeed` (25) and `SnapshotRead` (4), as on 2026-09-12.
  - `JwtAuth` (18). ruby-jwt 3.3 signs and accepts only HS256 when no
    algorithm is named, the same as `ALGORITHM`, so dropping it in
    `encode` or `decode` changes nothing (4; checked with a token signed
    HS512). The key's length and salt (6): a token is made and read by
    the same key. The blank-token return in `authenticate` (6):
    `JWT.decode` refuses a nil or blank token with a `DecodeError`,
    which `decode` rescues; kept, so the auth code says it. `.fetch` and
    `Time.zone.at` (2).
  - `PacedDelivery` (13): `.to_a`, `.fetch`, `.key?`, the `if` around the
    cap's log line, and `message.delivery_method` for
    `message.message.delivery_method` (ActionMailer hands the call to the
    Mail object).
  - `EnsureRotationsJob#run` (8): the `if` around the log line.
  - `BillsPayload` (7): `instance_of?` for `is_a?` (2); the `@residents`
    declaration (1), which nothing reads before `unknown_cook` sets it;
    leaving `amount: nil` or `no_cost: nil` out of a `T::Struct` (2);
    `.fetch('amount')` on the one path where the key is always there
    (1); `Integer()` for `.to_i` (1).
  - `Healthcheck` (7): the `if` around a log line and `instance_of?` in
    `ping` (5); the `else ''` in `ping_uri` (2).
  - `ResidentNameShortener` (7): the dropped `else nil`, `.to_s` on a
    side that is always a String, `slice(0)` and ActiveSupport's
    `String#at(0)` for `[0]`, `eql?` for `!=`.
  - `RecurringCatchUp` (7): the `now:` default (4), `.fetch` (2), and
    `instance_of?` for `is_a?` (1): the file's entries are plain Hashes.
  - `ApplicationHelper#price_category_label` (5): the `precision:`.
    Multipliers are whole numbers, so half of one has at most one
    decimal, and every precision of 1 or more prints the same.
  - `RecurringJob` (5): `::HEALTHCHECK` for `const_get`, `"#{e}"` for
    `"#{e.message}"`, the class for its name in a message, and
    truthiness or `instance_of?` for `is_a?(Hash)` (every job returns a
    Hash, and a failed one nil).
  - `MealCostSummary` (4): `MealLedger.new([])` or `[nil]` for `[meal]`
    (`summary_for` reads only the meal it is given), and `to_a`.
  - `RetryOnConflict.call` (4): `==`, `eql?` or `equal?` for `>=` (the
    count goes up by one from zero), and `self.rand`.
  - `ReconciliationWarnings#warning` (3): `.fetch` for `[]`. Keywords
    would need six parameters, over RuboCop's limit.
  - `BugsnagErrorSubscriber#report` (3): `:error` in the list gives
    `'error'`, and so does the fallback.
  - `MoneyFieldHelper#money_field_value` (3): `round(1)` for `round(2)`
    (both paths then print a two-decimal amount the same way), `to_s`
    for `to_s('F')`, and `self.number_to_rounded`.
  - `BalanceDisplayHelper#settlement_totals_tag` (2) and
    `MailDeliveryFailure.report` (2): a sum's start value, and nil for
    `''` inside a string.
  - `ThirdCookWarning` (2): `.sort` on the stored cooks, because the
    unique index on `(meal_id, resident_id)` returns them in resident
    order even when they were entered in reverse (checked), and `eql?`.
  - `AssetCacheControl#call` (2): `env.fetch('PATH_INFO')`.
  - `DatabasePoolCheck.verify!` (1): `Integer()` for `.to_i`.
  - `LiveUpdate.calendar_range` (1): `<` for `<=`, as on 2026-09-25.

Run 3 reran the 11 classes and the 4 `AuditDescription` methods whose
code or examples the answers changed. Its 81 alive are the noise above
that belongs to those subjects (80) and the range with no end in
`schedule_grid_data` (1). The whole suite afterwards: 2,841 examples,
no failure, 100% of lines and branches.

**Models and concerns stage.** The `# models and concerns` block of
`.mutant.yml`, passed as it is. In mutant 0.17 a pattern like `Meal*`
takes `Meal` and names under `Meal::` only, not `MealLedger` or
`MealSerializer` (`lib/mutant/expression/namespace.rb`; run 1 took no
subject from either). This branch changed `Community`'s dashboard
averages and cache version, `Meal`'s max rule and date move,
`ClosedMealAttendanceFreeze`'s price rule, `Unit#balance` and the
reservation checks, and added `StorableTime` and
`StorableTimeValidator` (the 2026-09-28 entry above).
`ClosedMealAttendanceFreeze#price_change_is_allowed`, `Unit#balance`,
`Meal#restamp_attendance_for_new_date` and `StorableTime` had no
survivor.

| Run                                                     | Subjects | Mutations | Killed | Alive | Timeouts             | Time   |
| ------------------------------------------------------- | -------- | --------- | ------ | ----- | -------------------- | ------ |
| 1                                                       | 135      | 5,874     | 5,639  | 235   | 11, counted as alive | 1h01   |
| 2, the three methods with timeouts, alone               | 3        | 241       | 225    | 16    | the same 11          | 11 min |
| 3, the eight classes the answers changed                | 77       | 3,409     | 3,290  | 119   | the same 11          | 42 min |
| 4, the three methods whose examples changed after run 3 | 3        | 154       | 152    | 2     | 0                    | 20 s   |

Run 1, 235 alive, by kind:

- Examples the selection kept out (5). `Community#affected_calendar_keys`
  survived `41` to `40` or `42`, `..` to `...`, `>>` to `<<`, and no
  `to_date`, although `community_calendar_cache_spec.rb` checks each
  edge. This branch gave that file a row naming `Community`, so it
  also runs for `CalendarSerializer`. The row made its
  `'#affected_calendar_keys'` group a class-level group, and the group
  of the same name in `community_spec.rb`, a file with no row, became
  the method's whole test set: 5 examples, none on the last day of a
  month's six weeks. The row now names
  `Community#affected_calendar_keys` and
  `Community#calendar_cache_version`, and the guard spec fails on this
  case (rule 2 above). All five are killed in run 3.
- Missing assertions (41), each now with an example that fails on it
  (checked by making each change by hand).
  - `Community` (16). The schedule writer and its check, `schedule=`
    (3), `normalize_schedule_week` (3) and `schedule_shape` (4): a
    six-letter string such as `'Monday'` passes the length check, so
    dropping either `is_a?(Array)` made it raise instead of report; a
    week that is not a list, and a day that cannot be read, stay as
    written for the validation to report, and nothing checked the
    value; 2.5 must not be read as Tuesday (`Integer(2.5)` is 2); a day
    stored as a decimal, and a list inside a week, which only a write
    that skips the writer can leave, and the second must give one
    error, not two. `dinner_start_times_shape` (5): a number, or seven
    numbers, where seven `HH:MM` times belong (`Regexp#match?` raises on
    a number). `auto_create_rotations` (1): a meal that already has a
    rotation stays in it.
  - `Meal` (12). `neighbour_ids` (5): the 2026-09-12 entry called its
    survivors rewrites the unique date index makes equal, and five of
    them are not. The examples had meals several days apart, entered
    in date order, so the query for the next meal could start two days
    on or one day back, or pick by id, and every example passed. New
    examples put a meal on the day before and the day after, and enter
    the next meal by date after a later one. `total_audits` (7): its
    comment says the time of each write decides the order and the id
    breaks a tie, but the example only checked that the times came out
    in order, which sorting by id alone also does. The new example
    gives the later write the lower id, and then gives two writes the
    same time.
  - `Resident#name_unique_with_helpful_message` (6): the blank-name
    example used `''`, which the clash query reads without trouble, so
    dropping the blank guard survived; with `nil` the query calls
    `nil.downcase`. The 2026-09-26 entry named these as `self.x` and
    `.present?` rewrites; only one of the seven is.
  - `MealSchedule` (7). `weeks_since_epoch` (2) could return a fraction
    of a week (the schedule still worked, because `Array#[]` cuts a
    fraction down, but the admin grid prints the number) or refuse a
    time. `dates_between` (1) could compare a Date with an evening end
    time, which is already the next day in UTC. The constructor (1):
    `'Mondays'` is refused by its length alone; `'Sunday'` is six
    letters. `upcoming_dates` (3): the message pins the scan limit but
    not where the count starts, so starting it at -1, 1 or 167
    survived; an example now finds a date on the last day the scan
    looks at, and gives up one day later.
- Redundant code, removed (25). `AdminUser#superuser?` and
  `#superuser_changed?(from:, to:)` (3): Rails makes both for the
  column. `Event#note_live_update` and
  `CommonHouseReservation#note_live_update` (12): the return when
  neither end moved; the old range is then the new one, and
  `LiveUpdate` keeps its dates in a set. `Meal#note_live_update` (2):
  the `if` before noting the old date; `LiveUpdate.calendar` notes
  nothing for nil, the way `GuestRoomReservation` already calls it.
  `Community#normalize_schedule_week` (6): the `is_a?(Integer)` branch,
  since `Integer(day.to_s)` gives an Integer day back unchanged (five
  mutations of the branch, and `to_str` for `to_s`, which only String
  days reached; it is killed now). `HasPhoneNumber#normalize_phone` (2): the
  `return` after a blank phone is cleared, since Phonelib finds nil
  invalid; the method is one if/else now.
- Loops that never end (11), the same 11 when rerun alone.
  `MealSchedule#upcoming_dates` (9): the scan-limit check removed, or
  its counter stopped or turned back. `MealSchedule#dates_between` and
  `Community#dinner_start_times=` (1 each): a range with no end.
- Answered in earlier entries, in code this branch did not change
  (76): `Holidays.easter?` (11), the `loaded?` branches of
  `Meal#attendees_count` and `#multiplier` (22), `Rotation` (30),
  `ClosedMealAttendanceFreeze#attendees_in_database` (6),
  `ReconciledMealImmutability#previous_meal_reconciled?` (3), and the
  `self.x` and `instance_of?` rewrites of the 2026-09-28 entry (4). One
  `Rotation` reason needs to be more exact: dropping the whole push
  from `recolor_remaining_rotations` survives because
  `recolor_community` saves each rotation it recolors with `update!`,
  and each save pushes that rotation's months (`Rotation#note_live_update`).
  So the method's own push sends those months a second time. It could
  be removed; this branch did not change `Rotation`, so it is left for
  the owner.
- Noise (77), changes no caller can see:
  - `self.x` for `x()` (13), `instance_of?` for `is_a?` (9), `size` or
    `length` for `count` (9), and `.fetch` or `.at` for `[]` (5), the
    kinds listed on 2026-09-12.
  - `Community#unreconciled_ave_cost` (10), a method this branch
    changed: `to_ary` (1), the preloads (7; goldiloader loads the same
    rows in one query), a sum's start value (1), and dropping
    `with_attendees` (1). A meal nobody ate has an effective cost of
    zero (the zero-multiplier return of `MealLedger#financials_for`),
    so reading it adds zero to both sums. The example "excludes bills
    from meals with no attendees" starts to fail on this mutation if
    #94 changes what that return gives.
  - `Community#unreconciled_ave_number_of_attendees` (4 besides the
    `count` rewrites): `where(meal_id: meals)` for
    `where(meal_id: meals.select(:id))`, and `select(nil)`; Rails
    selects the id for a relation used as a value either way.
  - `Community#calendar_cache_version` (3): `beginning_of_day` on a
    date string, which `Time.zone.parse` already reads as midnight (the
    one caller passes the month grid's first day); `today` for
    `today.to_s` and a nested array, since `join` calls `to_s` and
    flattens.
  - `Community#backfill_orphan_admin_users` (1): dropping
    `where(community_id: nil)`. It runs once, when the one community is
    created, and before that no admin can have a community.
  - `Community#cap` and `Meal#cap` (2): `super` for `read_attribute(:cap)`,
    the same read.
  - `Community#dinner_start_at` (2): the hour and minute as text;
    `Time.utc` reads `"19"` as 19 and `"08"` as 8 (checked).
  - `Community#normalize_schedule_week` (3): `lstrip` or `rstrip` for
    `strip`, and `all?` for `all?(Integer)`, since every day is then an
    Integer or nil.
  - `Meal#conditionally_set_closed_at` (4): `closed` for `closed == true`
    on a NOT NULL boolean, and clearing `closed_at` on a meal that was
    already open, where the CHECK `meals_closed_at_matches_closed`
    keeps it nil anyway.
  - `Meal#neighbour_ids` (7): the rewrites the unique date index does
    make equal (the bound at `day` itself, a second sort key after the
    date), and `where.not(id: nil)`: the meal can only be its own old
    date's neighbour when no meal lies between, and then the call for
    the new date tells the same meal.
  - `Meal#total_audits` (1): `[created_at, audit]`, since Rails compares
    two records by id.
  - `MealSchedule.weeks_since_epoch` (2): `to_int` and `Integer()` for
    `to_i`.
  - `Event#end_date_or_allday` (1): `end_date` for `end_date.present?`.
  - `HasPhoneNumber#normalize_phone` (1): `parsed` for `parsed.e164`;
    the column is written as `parsed.to_s`, which Phonelib makes the
    E.164 text (checked).

Run 3 reran the eight classes whose code or examples the answers
changed. Its 119 alive are the noise above that belongs to them (77,
with the two `self.x` rewrites of `period_is_free`), the `loaded?`
branches of `Meal` (22), the 11 loops, and 9 that the changes
uncovered:

- `CommonHouseReservation#note_live_update` (5) and
  `Event#note_live_update` (1). With the return gone, the second call
  covers a save that does not move the dates, so the first call
  matters only after a move, and every move example stayed inside the
  old range. A new example in each spec moves the booking or event
  from May 15 to an overnight stretch from February 28 to March 1.
  March 2026 starts on a Sunday, so its calendar begins on March 1,
  and only the new end tells March.
- `AdminUser#refuse_demoting_last_superuser` (3). Rails's
  `superuser_changed?` takes its keywords as options, where the
  removed method required them, so dropping both survived: the guard
  would then refuse any change to the flag while no other superuser
  exists, including the promotion that ends bootstrap. A new example
  promotes the first superuser. The other two, `from: true` alone and
  `to: false` alone, are noise: on a NOT NULL boolean a change from
  true is a change to false.

Run 4 reran those three methods: the two noise survivors are all that
is left. The whole suite afterwards: 2,858 examples, no failure, 100%
of lines and branches.

**Controllers and serializers stage.** The `# controllers and
serializers` block of `.mutant.yml`, passed as it is. This branch
changed `ApiController`'s date parser (`start_end_times` and the new
`whole_number_param`; the 2026-09-28 entry above), the birthdays
endpoint, the bills write's refusal, the settlement refusal's words,
the password reset answers, `SuperuserAdapter#authorized?`, the
calendar's birthday and common house queries, the common house chip's
times and `ResidentBirthdaySerializer`, and added the three edit-form
serializers, which have no method to mutate.
`ResidentBirthdaySerializer`, `SuperuserAdapter#authorized?`,
`ReconciliationsController#in_the_callers_words` and
`ResidentsController#refuse_for_the_row` had no survivor.

| Run                                                                                   | Subjects | Mutations | Killed | Alive | Timeouts                                        | Time                                  |
| ------------------------------------------------------------------------------------- | -------- | --------- | ------ | ----- | ----------------------------------------------- | ------------------------------------- |
| 1                                                                                     | 183      | 6,651     | 6,293  | 358   | 2, counted as alive                             | 2h19                                  |
| 2, the 36 methods the answers changed                                                 | 36       | 2,620     | 2,451  | 169   | 32, counted as alive; 30 while the laptop slept | 2h17 on the clock, about 50 min awake |
| 3, the three methods that timed out, and the three serializers whose examples changed | 36       | 1,144     | 1,093  | 51    | 0                                               | 19 min                                |
| 4, the two serializers whose examples changed after run 3                             | 19       | 535       | 512    | 23    | 0                                               | 10 min                                |

Most of the time goes to `ApiController`. Every API request spec runs
its filters and rescues, so each of its methods selects 450 examples,
and a survivor runs all of them. The first 400 mutations, most of them
in `ApiController`, went at 0.2 a second; the rest at about 1.

Run 1, 358 alive, by kind:

- Missing assertions (120), each now with an example that fails on it
  (checked by making each change by hand). Most are in code this branch
  did not change: the 2026-09-13 entry ends "Nothing on the controller
  and serializer list is a missing assertion now", and it was wrong.
  - `ResidentsController` (28). `token` (12): the sign-in answer's
    `username` and `timezone`, which the SPA keeps in its login cookie,
    were not checked; the example now checks the whole answer against
    the shape `public/api.md` shows. An email sent as a list
    (`email[]=...`) is a 400, not a 500, only because of the `.to_s`,
    at sign-in and at reset. `password_reset` (7): that, an email with
    spaces or capitals, and a blank one. `ical` (9): the Attend half of
    the resident's feed. Only this resident's sign-ups; a day someone
    else cooks is still listed; a day the resident cooks does not end
    the list (`next` for `break`); and the Attend event's description.
  - The two reservation controllers (21). The common house create
    refusal was checked by status only, so any body passed (8). No
    example had two problems at once, so joining them with no line
    break passed in every create and update of both (12), and so did
    dropping `resident_id` from the common house update (1). Each now
    has an example with an unknown resident and a taken time or day.
  - `CalendarSerializer` (15). The `ORDER BY id` of the meals, cook
    slots, guest room bookings, events, rotations and birthdays (13).
    `birthdays_in_range` is a method this branch changed. The first
    answer made each list's first row on a later day and saved it
    again, the way the 2026-09-28 entry did it for common house
    bookings; run 2 showed that this does not pin an `ORDER BY` (below),
    and the example now reads the statement that reads each list. And
    an event that starts or ends at the window's last instant (2).
  - `AuditSerializer#describer` (13). Its examples serialized one Meal
    row, which names no resident, so building the describer from
    nothing, from one row, or once a row all passed. One example now
    names a bill's cook, and one serializes a meal's whole history,
    where prosopite fails the example if the lookups run once a row
    (#84).
  - `CommunitiesController` (13). `calendar` (5): the year the payload
    names, at both ends of a year; January 2027's six weeks start on
    December 27, 2026. `cached_month` (7): the one-hour life of the
    cached month (CLAUDE.md, money rule 8), and the days the cache
    version is read for, which only `calendar_cache_race_spec.rb`
    shows; its row names the controller now. `birthdays` (1), a method
    this branch changed: `params.key?(:start)` for `params[:start]`.
    They differ for `?start` with no value, which is no start, as
    api.md's "Without `start`" says.
  - `MealsController` (7). Sign-ups and guests with `late` and
    `vegetarian` false were checked only for a row, so storing true
    passed (6); two examples now also post JSON with true and false,
    the way the SPA sends them. And an empty `max` on an open meal,
    which clears the cap (1).
  - `ApiController` and `ApplicationController` (6).
    `whole_number_param` (1), new on this branch: the "left out"
    examples sent each part with a nil value, so its key was still in
    the body; they now also leave the key out. `set_community_timezone`
    (1): without the `return`, the wrapper ran the action in the zone
    and then again. A sign-in check after the wrapper stopped the second
    run for most actions, but the community feed has none, so a
    signed-in request to it rendered twice and failed. `csrf_failed`
    (2): the session is reset, so an admin whose request did not come
    from their own page is signed out. `read_only_admin_token?` (2): an
    empty token is no key, even when the config var is empty.
  - `MealFormSerializer` (6): the previous and next links by date, not
    by the order the meals were made (4), and the residents by id (2),
    which the example now also checks in the statement, for the reason
    in run 2 below.
  - `FallbackController#index` (5): the page is sent with disposition
    `inline`. `send_file`'s own default is `attachment`, which makes a
    browser save the app as a file.
  - `EventsController` (3): every all-day example sent the text
    "true", and the SPA's forms send a JSON `true`, which only the
    `.to_s` turns into "true". (The 2026-09-13 entry counted `.to_str`
    for `.to_s` as noise; with a JSON `true` it is not.)
  - The chips (3): a common house title of `""`, which the SPA's form
    sends for no title (1), and a rotation's first and last day with
    its meals made out of date order (2). The first answer to the second
    was not enough; see run 2.
- Redundant code, removed (20). `.limit(1)` before `pick` in
  `MealFormSerializer#next_id` and `#prev_id` (10), as in
  `Meal#neighbour_ids` on 2026-09-12. `and return` at the end of
  `ApiController#not_authenticated_api` and `#not_found_api` (6): it
  returns from the helper, which is ending anyway, not from the action.
  `klass.respond_to?(:ancestors)` in `SuperuserAdapter#model_name` (4):
  every class has ancestors.
- Redundant code, left for the owner (19). This branch did not change
  these methods.
  - `ApiController#set_community_timezone`, the check for a token
    before reading the zone (10). With no token there is no resident,
    so no zone, and the action runs in the app zone either way.
    Removing it would also leave the memo in `bearer_token_from_header`
    with one reader, where its comment says two.
  - `ApplicationController#use_community_timezone`, the return for no
    zone (6). `Time.use_zone(nil)` keeps the app zone, so the method
    does the same without it. It says in code what happens before the
    community exists.
  - `ApiController#current_api_key`, its call to
    `resolve_current_session` (2). Its one caller runs after
    `authenticate`, which has resolved the session already.
  - `MealsController#bills_written`, the `reload` (1).
    `BillsPayload#write_to` leaves `meal.bills` loaded with the rows it
    wrote. The comment gives the reason to read the table again anyway.
- Answered on 2026-09-28 (10): the ranges in
  `ApiController#start_end_times` that `Date.valid_date?` makes the
  same.
- Loops that never end (2): `CommunitiesController#calendar` with the
  grid's last day dropped, an endless range.
- Missing assertions answered after run 3 (14): the preload of the
  rotations' meals in `CalendarSerializer#rotations_in_range` (2) and
  the `loaded?` branches of `RotationSerializer#start` and `#end` (12),
  below.
- Noise (173), changes no caller can see:
  - `.fetch` for `[]` on the params, the parsed times and the
    serializer params (49). A route segment is always there; a missing
    body key raises `ParameterMissing`, which Rails answers 400.
  - The memos in `ApiController` (20): the `defined?` guards and the
    memo flag of `bearer_token_from_header` and
    `resolve_current_session` (15); `.presence` on the token, the
    `@current_api_key = nil` that is nil already, and the `if token`
    before `Key.find_by` (5), since `keys.token` is NOT NULL and an
    empty token matches no key.
  - `ApiController#set_community_timezone` (5): `.presence` on the zone
    and the `ActiveSupport::TimeZone[tz]` check (3), since the column
    only takes a supported zone; the inner `if` made always true or
    dropped (2), since `Time.use_zone(nil)` keeps the app zone.
  - `Date.iso8601` and the other parsers for `Date.parse` (8), as on
    2026-09-12.
  - `CommunitiesController#calendar`'s grid arithmetic (9): `+ 41` and
    `+ 20` for `.days` (a Date adds days), 19 or 21 days for 20 (the
    grid starts at most six days before the 1st, so the month and year
    are the same), `.uniq` on the month list (a repeat in `IN` finds
    the same rows), and `...` for `..` (the grid's last day is never
    the 1st of a month). And the six `stale?` rewrites (6): Rack::ETag
    and Rack::ConditionalGet, in every Rails app's middleware, answer
    the same 304 with the same private Cache-Control; the call only
    skips encoding the JSON on a match. `cached_month` with the
    serializer params as the start (1): the first date in their text
    is the start date, and `Time.zone.parse` reads that one.
  - The query shapes of the calendar and the meal form (23): the
    `includes` and `joins` (18; goldiloader loads the same rows, and a
    `where` on `meals` joins the table anyway), the `IN` list and
    `to_a` rewrites of `rotations_in_range` (4; a `pluck` with no column
    puts the rotation ids in a longer list, and finds a wrong rotation
    only when its id equals another number in a meal row), and `..` for
    `...` before the window's first instant (1; the first clause takes
    that event).
  - `MealFormSerializer#next_id` and `#prev_id` (9): the same-day
    clause and the id as a second sort key, which the unique index on
    `meals.date` makes unreachable, as in `Meal#neighbour_ids`.
  - `ResidentsController#ical` (8): `.to_set` (an Array's `include?`
    answers the same), `resident` for `resident.id` (Rails reads the
    id) and the `includes`.
  - `BillSerializer` (8): `bill.date` and `bill.unit`, which `Bill`
    delegates to the same records.
  - `MealsController` (8): `AuditSerializer` without `.to_h` (Alba
    writes the same JSON), the join in `render_write_under_lock`, which
    no API write can reach with two problems (the settled-meal refusal
    comes before the lock), the `return` before the socket id in
    `set_meal` (the render already stops the chain), and in
    `update_bills` a nil status for `:ok` and the error for its
    message, which is how Rails writes an error in JSON.
  - `EventsController#create`'s `all_day` default (4), as on 2026-09-13.
  - `ReconciliationsController` (3): `.iso8601` on a Date, which JSON
    writes the same way, and the error for its message.
  - The rest (12): `.present?` for truthiness on a record and on a max
    (2); `.to_s` and `.to_str` on the configured read-only admin id
    (2); `layout: false` on the plain 404 (2), since there is no
    application layout; the `type:` of the app page (3), which
    `send_file` and Rails set to text/html from the file's name
    anyway; `instance_of?(Class)` in `SuperuserAdapter#model_name` (1);
    `beginning_of_day` in `CalendarSerializer#window_start` (1), which
    `Time.zone.parse` already gives for a date; and `+ 1` for
    `+ 1.day` in the rotation chip's end (1).

Run 2 reran the 36 methods whose code or examples the answers to run 1
changed. The laptop slept with its lid closed for 90 minutes of it, and
every mutation that was running then went past the 300-second limit:
30 of the 32 timeouts, in `EventsController#update` and both
`GuestRoomReservationsController` actions, each after 930 to 1,070
seconds with only a few examples run. Run 3 reran those three methods,
and all 30 were killed. The other two timeouts are the endless range
of run 1.

Run 2, 169 alive, by kind:

- Missing assertions the answers to run 1 did not pin (3), each now
  with an example that fails on it (checked by making each change by
  hand).
  - `CalendarSerializer#rotations_in_range`, the `ORDER BY` dropped or
    made `order(nil)` (2). The example made the first rotation, saved
    it again and expected it first. Alone, it failed on this change.
    Inside mutant's list of 86 examples it passed, and so did the whole
    suite run in file order. With no `ORDER BY` the rows come back in
    the order PostgreSQL stored them, and a row saved again is not
    always stored after the others: PostgreSQL puts the new version in
    the first free slot of its page, and a slot that an earlier
    example's row left free can come first. A resident is also written
    again right after it is made:
    `Resident#revoke_all_sessions_if_password_changed` sets
    `keys_valid_since` when the first password is set. Making the row
    with the higher id first did no better: the cook slots came back in
    the order of their meals, and the birthdays example passed once and
    failed once on the same code. No set of rows can show that a list
    is ordered every time, so the example now reads the statements the
    serializer runs, and expects every one that reads a list (the common
    house bookings too) to end with `ORDER BY` its id.
    `MealFormSerializer#residents` had the same kind of example, which
    run 2 happened to kill; it reads the statement now too.
  - `RotationSerializer#end`, `last` for `max_by(&:date)` (1). The meals
    were made so that neither the first nor the last one made was an
    end, but with three meals one of them has to be, and the last one
    made was the latest. The example now has four, and loads them in
    the order they were made (`eager_load` with `ORDER BY meals.id`),
    since with no order they come back in the order PostgreSQL stored
    them.
- Timeouts while the laptop slept (30), killed in run 3.
- Loops that never end (2), the same two as in run 1.
- Redundant code left for the owner (10), in `set_community_timezone`,
  as in run 1.
- Noise (124), all of kinds listed for run 1, in the same methods.

Run 3 showed that the new order example had lost two kills that the
examples it replaced made by chance: the preload of the rotations'
meals, dropped or made `preload(nil)`. Those examples had two
rotations, and without the preload each rotation's chip asks for the
MIN and the MAX of its meals' dates, which prosopite fails as a query
once a row. So the run 1 list above counted them as noise wrongly
(goldiloader does not help: the chip checks `loaded?` and never reads
the meals). The order example now makes two of every row. It also
finds a list's statements by the table and the list's `WHERE`, not by
the columns selected, so it does not depend on how a list preloads.

The same reasoning answers the `loaded?` branches of
`RotationSerializer#start` and `#end` (12), which the 2026-09-12 entry
counted as noise because both ways give the same chip. They do, and
the branch is there for the reads: the calendar preloads the meals,
and a chip on its own should not load every meal of its rotation to
find two dates. A new example in `calendar_chips_spec.rb` expects no
query for a rotation whose meals are loaded, and the meals still not
loaded after the chip of one whose meals are not. Every change to the
branch fails one of the two.

Run 4 reran the two serializers whose examples changed after run 3.
Its 23 alive are noise from the list above: the `includes` and `joins`
of the calendar lists (16), the `IN` list and `to_a` rewrites of
`rotations_in_range` (4), `..` before the window's first instant in
`events_in_range` (1), `beginning_of_day` in `window_start` (1) and
`+ 1` for `+ 1.day` in the rotation chip's end (1).

What is left alive in this stage, then: the redundant code left for
the owner (19 mutations, in `set_community_timezone` and three other
methods this branch did not change), the endless range (2), and the
noise. The whole suite afterwards: 2,884 examples, no failure, 100% of
lines and branches.
