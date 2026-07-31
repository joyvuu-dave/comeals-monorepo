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
  `assert_candidates_cover_pennies!` in `Reconciliation`.

## What is not solved

Five questions we cannot answer today about a stored number. Ordered by what
each teaches per unit of work.

### A. Is any settled balance different today from what its source data says?

A nightly rake task that, for every reconciliation, recomputes
`settlement_balances` from source and compares it to the stored
`reconciliation_balances` rows. Any difference raises, and `Healthcheck.monitor`
turns that into an email.

**The code already exists**, in `spec/db/settlement_race_spec.rb` —
`stored_balances(r)` against `balances_from_source(r)`. It only runs in a test.
Promoting it to production is about thirty lines.

This is what a bank calls a control: not a guard that prevents a bad write, but
a check that proves the numbers still tie out. It would have caught issue #43 in
production rather than only in a test.

One design note: recomputing every reconciliation gets slower as history grows.
The settlement benchmark runs 200 meals in 0.14s, so a decade of history is
under a minute. Do not optimize this until it matters. If it ever does, check
the most recent N plus a rotating sample of older ones.

### B. What is this number made of?

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
financial data. The target of that rule is a *mutable value that can drift* — a
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

## Suggested order, if we do this

1. Control A — the nightly recompute-and-diff. The code exists.
2. Line items (B) — the biggest gain in explainability, and it makes the test
   harness able to localize failures.
3. Digest chain (D) — closes the escape-hatch blind spot.
4. Provenance stamps (C) — folds in with D.
5. Snapshots (E) — only for completeness.

A and B together give a full tie-out chain: source rows, then line items, then
the settled balance, then a recomputed check. Each link is verifiable on its
own, and each is written by different code at a different time.

## Deliberately not proposed

Full event sourcing of the money path. It is the natural end of this line of
thinking, but the source data is already close to an event log — bills and
attendance are append-mostly, audited, and immutable once settled. It would
rebuild what already exists for the sake of the pattern's name.
