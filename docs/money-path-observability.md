# Money path observability — candidates, not decisions

Ideas for making a derived financial number explain itself. Nothing here is
decided or scheduled. This file exists so the thinking is not lost.

Written 2026-07-30, out of the correctness-testing design work.

## What is already solved

Worth writing down so nobody rebuilds it.

- **Who changed a row.** `config/initializers/audited.rb` sets
  `current_user_method = :audited_user`, resolved per controller — API requests
  attribute to the resident, ActiveAdmin requests to the admin user. The
  `audits` table records `user_id`, `username`, `remote_address`, and
  `request_uuid`.
- **Correlating one request's changes.** `audits.request_uuid` groups every row
  change made by a single request.
- **Settled data cannot change through normal paths.** The three triggers, the
  model concerns, and `Reconciliation#reject_update` / `#reject_destroy`.
- **Settled balances sum to zero.** `assert_balanced_input!` and
  `assert_candidates_cover_pennies!` in `Reconciliation`, and since
  `20260731120000` a deferred constraint trigger that makes PostgreSQL check
  it too, at every commit, for writes that never went through Ruby. That one
  has no bypass: `comeals.allow_settled_writes` does not turn it off.
- **Settled amounts cannot be rewritten.** `reconciliation_balances` refuses
  `UPDATE` and `DELETE` at the database level, the same way the settled
  meal's source rows do. This was a gap the list below did not name: the
  source rows were immutable but the amounts they produced were an ordinary
  table. Added 2026-07-31.
- **One implementation of the arithmetic.** `MealLedger`. Settlement and the
  running balance used to carry separate copies of the same rules.

## What is not solved

Five questions we cannot answer today about a stored number. Ordered by what
each teaches per unit of work.

### ~~A. Is any settled balance different today from what its source data says?~~ — built 2026-07-31

`LedgerVerification`, run nightly by `rake ledger:verify` at 05:00 UTC, after
`billing:recalculate`. The Heroku Scheduler entry was added 2026-08-03 — for
the first day after the 2026-08-02 deploy the code was live but nothing ran
it, and `ledger_check_runs` shows the gap: one manual run, then nothing until
the schedule took over. For every reconciliation it recomputes the settlement
from that reconciliation's own meals, bills, attendance and guests, and
compares the result to the amounts stored at settlement. Everything is read
inside one `SnapshotRead`, so a settlement committing halfway through cannot
produce a mismatch that never existed.

A difference raises, and `Healthcheck.monitor` turns that into an email.

This is what a bank calls a control: not a guard that prevents a bad write, but
a check that proves the numbers still tie out. It would have caught issue #43 in
production rather than only in a test.

**Every run is recorded, pass or fail**, in `ledger_check_runs` — start, finish,
how many reconciliations were checked, how many disagreed, and what disagreed.
That table is the actual deliverable. A check that only speaks up on failure
cannot answer the question an auditor asks, which is not "would you have
noticed?" but "show me that you looked". A silent night and a night the job
never ran look identical without it. The rows are append-only, guarded the same
way the balances are, because a check record that can be edited afterwards is
not evidence. `admin/ledger_check_runs` shows the history.

There are three outcomes, not two. A run that could not finish is recorded with
its error and is neither passed nor failed: it says nothing about the books,
which is different from saying they are right.

Two things this control does **not** prove, both worth keeping straight:

- It recomputes with `MealLedger`, which is what wrote the stored values. So it
  proves a stored balance still follows from its source rows; it cannot prove
  the arithmetic is right, because the same mistake would be made twice and
  agree with itself. The `Resident#calc_balance` oracle is what covers that.
- If the settlement arithmetic is ever changed on purpose, this check will
  disagree with every reconciliation settled before the change, every night,
  forever. That alarm is correct — the past no longer reproduces — but it needs
  a deliberate answer rather than being switched off. See "still open" below.

One design note that has not bitten yet: recomputing every reconciliation gets
slower as history grows. The settlement benchmark runs 200 meals in 0.14s, so a
decade of history is under a minute. Do not optimize this until it matters. If
it ever does, check the most recent N plus a rotating sample of older ones.

### ~~B. What is this number made of?~~ — built 2026-08-02

`meal_charges`, written once inside the settlement transaction from the same
`MealLedger` pass that produces the balances. One row per source row: one
credit per bill, one debit per attendance, one per guest. Each carries the
meal, the resident, the kind, the signed full-precision amount, the multiplier
(debits) and what the cook actually spent before any cap (credits).

Immutable, guarded the same way the balances are. No `reconciliation_id` — the
meal already says which settlement it belongs to, and two answers to one
question can disagree.

**The tie-out is not equality, and the original proposal here was wrong about
that.** The lines are full precision and the balances are rounded to cents, so
a resident's lines sum to within one cent of their balance, never to exactly
it. One cent is precisely what largest-remainder allocation is allowed to
move, so that is the whole tolerance. `LedgerVerification` runs this nightly as
a second check alongside the recompute, and it is the stronger of the two:
two tables, written by different code at settlement, compared with no Ruby
arithmetic at all.

A second thing the first draft got wrong: the lines cannot be required to sum
to _exactly_ zero either. `BigDecimal` division carries finite precision, so
$100 split three ways leaves a tail thirty digits down. The check uses
`Reconciliation::ZERO_SUM_EPSILON`, which exists for this. Only the rounded
balances can be held to exact zero, and the database already does that.

Still to build on top of this, and the reason it was worth doing:

- **A statement instead of a number.** The rows are there; no screen shows them
  yet. That is the next piece of work — an endpoint and a page where a resident
  can see "2026-07-03, you plus one child, $4.28" instead of a single total.
- **Backfill, or not.** Reconciliations settled before 2026-08-02 have no
  lines, and the nightly check skips the line-item half for them. Writing lines
  for them now would record today's belief as though it were what happened
  then. Left undone deliberately; it is a decision, not an oversight.

The old proposal follows, for the reasoning about rule 8.

### B (original proposal). What is this number made of?

`Reconciliation#settlement_balances` computes every per-meal, per-resident debit
and credit in memory and then discards the line items, keeping only the
per-resident total. So `reconciliation_balances.amount` is `-47.13` and nothing
records which meals produced it or in what amounts.

Proposal: a `meal_charges` table, written once inside the settlement
transaction — `(meal_id, resident_id, kind, amount, multiplier, unit_cost)`
where `kind` is `debit`, `credit`, or `guest_debit`.

What it buys:

- **A statement instead of a number.** "2026-07-03, you plus one child, $4.28.
  2026-07-05, you cooked, +$62.00."
- **A tie-out in pure SQL.** `reconciliation_balances.amount` must equal the sum
  of that resident's charges across that reconciliation's meals. Two tables
  written by different code, checked against each other with no recomputation.
- **Failures that point at one meal.** For the test harness this matters a lot.
  Today a mismatch says "resident 7 is off by $0.03" and you bisect thirteen
  meals. With line items it says "meal 2026-07-05, resident 7, debit differs."

Size: about 400 rows per settlement (30 residents, 13 meals), ~5,000 a year.

**The objection, and the answer.** CLAUDE.md rule 8 bans denormalized caches for
financial data. The target of that rule is a _mutable value that can drift_ — a
counter, a running total, anything `counter_culture` used to do. `meal_charges`
is the opposite: written once inside the settlement transaction, never updated,
and protected by the same triggers as every other row on a settled meal. It is
the same category as `reconciliation_balances`, which already exists for exactly
this reason.

The distinction worth adding to rule 8: an **immutable record of what was
decided** is a ledger. A **mutable cache of what is currently true** is the thing
the rule bans.

### C. What inputs produced this, and when?

The general form of the `as_of_reconciliation_id` watermark already agreed for
`resident_balances` (see ADR 0005 follow-up work): every derived row should be
able to describe its own inputs.

Beyond the watermark, the useful addition is a `source_digest` — a hash over the
input set: sorted meal ids, bill ids with amounts, attendance ids with
multipliers, guest ids with multipliers.

The digest catches a case the watermark cannot: an input that changed without
the watermark moving. It is also a cheap pre-filter for control A — compare
digests first, and only run the full recomputation where they differ.

### D. Has anyone edited settled data behind the triggers?

`comeals_protect_settled_meal` and `comeals_reject_settled_child_write` both
honour `current_setting('comeals.allow_settled_writes')`, and
`docs/runbooks/settled-data-repair.md` documents using it. That escape hatch is
correct to have — genuine corruption needs a repair path.

But nothing detects that it was used. A session with that setting on, or direct
psql access, can rewrite a settled meal, and the only trace is the audit rows,
which the same session can also delete.

Proposal: store a `source_digest` on each `reconciliation` at settlement,
computed over its input rows, and fold in the previous reconciliation's digest
so the digests form a chain. Rewriting an old settlement then breaks its own
digest and every later one, and control A catches it. About ten lines and one
column.

Banks do not usually hash-chain their ledgers; they rely on segregation of
duties and immutable storage. This app has one person with superuser access to
the database, so segregation of duties is not available and a hash chain is the
cheap substitute.

### E. What did we believe yesterday?

`resident_balances` is one mutable row per resident, overwritten daily. There is
no history, so we cannot say when a balance changed or by how much.

Proposal: an append-only `resident_balance_snapshots` table —
`(resident_id, amount, as_of_reconciliation_id, computed_at)` — with a retention
policy.

Ranked last of the five. Line items (B) already explain the settled values, and
the running balance is meant to move constantly as people sign up, so the signal
to noise is poor. Worth building only for completeness of the pattern.

## Order

1. ~~Control A — the nightly recompute-and-diff.~~ Built 2026-07-31.
2. ~~Line items (B).~~ Built 2026-08-02. The nightly check now includes the SQL
   tie-out between two tables written by different code, which is the version
   that closes the "same mistake twice" gap. The resident-facing statement is
   not built.
3. Digest chain (D) — closes the escape-hatch blind spot. **Next**, unless the
   statement screen comes first.
4. Provenance stamps (C) — folds in with D.
5. Snapshots (E) — only for completeness.

A and B together give a full tie-out chain: source rows, then line items, then
the settled balance, then a recomputed check. Each link is verifiable on its
own, and each is written by different code at a different time.

## Still open

- **What to do when the settlement arithmetic changes on purpose.** Control A
  will then disagree with all of history, every night. The likely answer is to
  stamp each reconciliation with a calculation version at settlement, and have
  the check only recompute rows whose version matches the current code, falling
  back to the SQL tie-out against line items (B) for older ones. Decide this
  before the first deliberate change to the math, not after.
- **Where the digest evidence lives (part of D).** A hash chain stored in the
  database it protects is tamper-evident against accidents, not against the one
  person who has superuser access. Putting the digest in the settlement email
  that already goes out puts a copy in thirty mailboxes nobody can rewrite.

## Deliberately not proposed

Full event sourcing of the money path. It is the natural end of this line of
thinking, but the source data is already close to an event log — bills and
attendance are append-mostly, audited, and immutable once settled. It would
rebuild what already exists for the sake of the pattern's name.
