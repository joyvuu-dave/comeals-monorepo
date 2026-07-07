# Runbook: repairing settled data

Database triggers refuse every write to a reconciled meal's data: its bills,
attendance, guests, and the meal's own settlement inputs (`cap`, `date`,
`reconciliation_id`). This applies even to writes that skip Rails callbacks —
`update_all`, raw SQL, a psql session. The triggers live in
`db/migrate/20260707100000_add_settled_meal_immutability_triggers.rb`.

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
   entry in the next period instead if at all possible.
3. Note what you changed and why in the relevant GitHub issue.

Do not use `ALTER TABLE ... DISABLE TRIGGER`. It takes a DDL lock and drops
the guard for every session, not just yours.
