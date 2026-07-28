# Runbook: repairing settled data

Database triggers refuse every write to a reconciled meal's data: its bills,
attendance, guests, and the meal's own settlement inputs (`cap`, `date`,
`reconciliation_id`). This applies even to writes that skip Rails callbacks —
`update_all`, raw SQL, a psql session. The triggers were added in
`db/migrate/20260707100000_add_settled_meal_immutability_triggers.rb`, and
`20260727120000_lock_meal_in_settled_child_write_trigger.rb` replaced the
child-write function body with the current, locking one. Read the second for
what runs today.

> **A gap that was open until 2026-07-27, and how to find what it left
> behind.** The triggers used to decide by reading the meal without taking a
> row lock. A write that started while a settlement was still running was
> judged against pre-settlement state and allowed through, so it landed on a
> meal that was reconciled by the time it committed. Two shapes of damage:
> a row added that no reconciliation counts (a cook never reimbursed,
> because `billing:recalculate` only sums unreconciled meals), and a row
> deleted that a reconciliation already counted (a balance charged or
> credited with no source row behind it).
>
> Both are closed now — the settlement holds `FOR UPDATE` on every meal it
> claims, and both of the trigger's lookups are locking reads (migration
> `20260727120000`). A racing write waits and is then refused. See
> `docs/adr/0003-concurrency-on-the-money-path.md` (issue #43).
>
> Rows written before that date can still be wrong, and nothing raised at the
> time. Do not go looking for them by `created_at` — the deleted-row shape
> leaves nothing to select. Ask the ledger instead: recompute each
> reconciliation from its source data and compare it to what was stored. They
> must match exactly.
>
> ```ruby
> # bin/rails runner — reports every reconciliation whose stored balances
> # disagree with a fresh computation from its own meals.
> Reconciliation.order(:date).each do |r|
>   stored = r.reconciliation_balances.pluck(:resident_id, :amount).to_h
>   fresh  = r.settlement_balances.reject { |_, amount| amount.zero? }
>   next if stored == fresh
>
>   puts "reconciliation #{r.id} (#{r.date}) disagrees with its source data:"
>   (stored.keys | fresh.keys).sort.each do |resident_id|
>     next if stored[resident_id] == fresh[resident_id]
>
>     puts "  resident #{resident_id}: stored #{stored[resident_id] || 0}, source says #{fresh[resident_id] || 0}"
>   end
> end
> ```
>
> This is the same check `spec/db/settlement_race_spec.rb` makes, and it
> catches both shapes. A clean run means no reconciliation was hit. Repair
> anything it finds with a correcting entry in the current period — first
> choice, below — not with the trigger bypass. The stored balances are what
> residents already paid; you correct forward, you do not rewrite them.

## First choice: correcting entries

You don't edit the ledger. You add to it (CLAUDE.md money rule 7).

If a settled amount is wrong — a cook was over- or under-credited, an
attendee was charged in error — do not touch the settled rows. Put a
correcting entry in the next billing period instead. Example: a cook's $50
bill should have been $30. Add a $20 charge (or a -$20 bill adjustment
entry) to an unreconciled meal in the current period, with a description
saying what it corrects. The next reconciliation settles the difference.

This keeps every past reconciliation's books exactly as they were settled
and exactly as they were emailed to residents.

## Last resort: the trigger bypass

Use this only for genuine data corruption — rows that are wrong in a way no
correcting entry can express (a bill attached to the wrong meal by a bug,
an impossible negative multiplier written by a bad migration). Not for
amounts someone wishes were different.

The triggers honor a session-scoped setting. In a psql session against the
production database:

```sql
BEGIN;
SET LOCAL comeals.allow_settled_writes = 'on';

-- your repair, for example:
UPDATE bills SET amount = 30.00000000 WHERE id = 123;

COMMIT;
```

`SET LOCAL` dies with the transaction: after `COMMIT` (or `ROLLBACK`) the
guard is back, and it never applied to any other session. The app stays
protected the whole time you work.

After the repair:

1. Run `rake billing:recalculate` so cached balances match the repaired
   source data.
2. If the repaired meal belongs to a reconciliation whose balances were
   already settled, re-check that reconciliation's stored balances
   (`reconciliation_balances`) — they are append-only settlement records
   and will NOT be recomputed automatically. A repair that changes them
   means residents were told wrong numbers; handle that as a correcting
   entry in the next period instead if at all possible. If the stored
   balances themselves are corrupted and must be rebuilt, recompute that
   one reconciliation from a console:
   `Reconciliation.find(id).persist_balances!`. Never rebuild them all
   at once — settled books are history, not a cache.
3. Note what you changed and why in the relevant GitHub issue.

Do not use `ALTER TABLE ... DISABLE TRIGGER`. It takes a DDL lock and drops
the guard for every session, not just yours.
