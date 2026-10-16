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

## First choice: a correction

You don't edit the settled ledger. You add to it (CLAUDE.md money rule 7).

If a settled dinner was wrong — a cook's cost, who ate, an eater's price,
a guest — a superuser corrects the dinner (ADR 0011 rule 6). The
dinner's rows change, with history; each person's change is recorded as a
`MealCorrectionLine`; and the next settlement carries the correction and
adds those changes to its balances.

The way to make one is the dinner's admin page: **Correct this dinner**
(superusers only). The form shows each cook, eater and guest, and asks
for a reason. **Preview correction** shows each change and each person's
change in money, and saves nothing. **Save correction** saves only what
the preview showed. The reason goes on the dinner's page, and the cook
mail after the next settlement sends it to each cook whose cost changed.

The form adds at most one cook and one guest at a time. For more, save
one correction and make another. From the console, the same correction
is:

```ruby
meal = Meal.find(...)
MealCorrecting.save!(meal, by: AdminUser.find_by!(email: '...'), reason: 'Typed $50 for $30') do |edits|
  edits.cost(Resident.find(...), amount: BigDecimal('30'), no_cost: false)
end
```

`MealCorrecting.preview(meal) { |edits| ... }` shows each person's change
first and saves nothing. The edits are listed in `MealCorrecting::Edits`.

This keeps every past reconciliation's books exactly as they were settled
and exactly as they were emailed to residents. The nightly check then
checks that each settled dinner's rows add up to what it was settled at
plus its corrections, so a change made any other way is reported.

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
   balances themselves are corrupted and must be rebuilt, see "Rebuilding
   one reconciliation's balances" below. Never rebuild them all at once —
   settled books are history, not a cache.
3. Note what you changed and why in the relevant GitHub issue.

Do not use `ALTER TABLE ... DISABLE TRIGGER`. It takes a DDL lock and drops
the guard for every session, not just yours.

### A repair that worked the settlements out again (2026-10-10)

Migration `20261010130000` used the bypass on 11 bills of 9 settled
meals. Each was marked No cost and also had an amount, which the meal
page allowed before April 2026, so the cook was credited $0 for what they
spent. Nobody recorded what was paid or collected for those settlements,
and the owner decided that the app must show the right numbers. So, in
the same transaction as the bill fix, the migration works out again each
settlement that claimed one of the bills:

```ruby
Settlement.new(reconciliation).correct!(reason: '3 costs on these meals were marked No cost by mistake, ...') do
  # the fix of the rows, with the bypass on
end
```

`correct!` keeps the reconciliation row, its meals and its cutoff. It
refuses a settlement with any line marked Paid or Let go
(`Settlement::Marked`, ADR 0011 rule 8): once people have paid from a
settlement, its numbers stay what they were, and a mistake goes into the
next settlement as a correction (the section above). It also refuses a
settlement one of whose dinners already has such a correction
(`Settlement::DinnerCorrected`): that settlement keeps what it settled,
and the corrections carry every change; its line items written again
from the corrected rows would count the correction twice. Before
the block runs, it asks the nightly check about the settlement and
refuses, writing nothing, if the settlement already disagrees with its
rows or its line items: working it out again would fold that earlier
difference in under this reason, and `ledger:verify` would stop reporting
it. Find out where such a difference came from first. If you decide to
fold it in anyway, pass `include_earlier_differences: true`: the record
then says so and keeps what the check found.
Then it runs the block, which must end normally or raise. A block left by
`return`, `break` or `throw` raises `Settlement::FixLeftEarly` and nothing
stays, because Rails would otherwise commit the fix with no correction.
Then it copies the line items it is about to delete into the record,
deletes the line items and balances with the bypass on for those two
statements only, writes both again from the rows as they are now with
the settlement's own code (`write_ledger!`), and records each person whose
balance changed, before and after. No admin page shows the record: the
settlement page and each person's statement show the new numbers like
any other settlement's (the owner's choice, 2026-10-12). `ledger:verify`
then finds the settlement matching its rows, with no exception to
remember.

Use it the same way for the next repair of this kind, after the owner has
decided the settled numbers must change: fix the rows in the block.
Because the cents are shared out across the whole settlement, a person
who had nothing to do with the fixed rows can move by one cent. The
correction records that cent too. A settlement corrected twice keeps both
records, each with the line items it replaced.

### Reading the record of a correction

Every correction, with each changed balance before and after. A positive
amount means the community owes the person, a negative one that the
person owes (the sign convention in `MealLedger`). Read-only, so it is
safe on production with `heroku pg:psql`.

```sql
SELECT c.reconciliation_id, c.created_at, c.reason,
       r.name, l.old_amount, l.new_amount
FROM settlement_corrections c
JOIN settlement_correction_lines l ON l.settlement_correction_id = c.id
JOIN residents r ON r.id = l.resident_id
ORDER BY c.reconciliation_id, c.created_at, r.name;
```

`settlement_corrections.earlier_differences` holds what the nightly check
had already found when a correction was told to fold it in, and
`settlement_correction_charges` holds the line items a correction
replaced, column for column.

## The settled amounts themselves

`reconciliation_balances` holds what each resident was actually billed. Since
`20260731120000` it has two guards of its own.

**Rewriting is refused.** No `UPDATE`, no `DELETE`, from any path — the same
bypass above is the only way through, for the same narrow reason.

**Adding is refused too, since `20261009120000`.** An `INSERT` into
`reconciliation_balances` or `meal_charges` is refused unless the settlement
of that row's reconciliation is writing it, or the bypass above is on. The
settlement says so with a setting that lasts only for its own transaction,
`comeals.settling` = the reconciliation's id
(`Settlement::SETTLING_SETTING`). Before this, two new rows that add up to
zero passed every check: the sum-zero rule below only asks that the books
still add up. A line on a meal that is not settled yet is refused as well,
because no settlement has claimed that meal.

**Every reconciliation must sum to exactly zero, and that rule has no
bypass.** `comeals.allow_settled_writes` does not turn it off. A repair may
change what a settled balance says; it may not leave the books not adding up.
The check is a deferred constraint trigger, so it runs at `COMMIT` and judges
only the state you are committing. Inside the transaction the ledger is
allowed to be unbalanced while you work.

In practice that means a repair here always moves money between residents,
never into or out of the ledger:

```sql
BEGIN;
SET LOCAL comeals.allow_settled_writes = 'on';

UPDATE reconciliation_balances SET amount = amount + 1.00 WHERE id = 11;
UPDATE reconciliation_balances SET amount = amount - 1.00 WHERE id = 22;

COMMIT;   -- refused unless every reconciliation you touched still sums to zero
```

Two things that surprise people:

- A `DELETE` on this table queues a deferred check per row, and PostgreSQL
  refuses to `TRUNCATE` a table with pending trigger events. If you are
  clearing data and hit that, run `SET CONSTRAINTS ALL IMMEDIATE` first.
- When a deferred check fails, the error arrives at `COMMIT`, and PostgreSQL
  ends the transaction itself. A client that then sends `ROLLBACK` gets
  "WARNING: there is no transaction in progress". That warning is normal and
  means nothing was written.

### Rebuilding one reconciliation's balances

A settlement writes two tables: `meal_charges` (one line per bill, per
attendance, per guest) and `reconciliation_balances` (the per-resident totals
those lines add up to). `Settlement#rewrite!` writes both, and
it is not re-runnable on its own — re-running it would rewrite the ledger
rather than correct it. Rebuilding is a deliberate repair, and a last resort:
the stored balances are what residents were already told they owed.

`Settlement#correct!` (the section above) does these steps in one call and
also records what changed. Prefer it. The steps by hand leave no record.

```ruby
# bin/rails runner, against a reconciliation you have decided is corrupt.
reconciliation = Reconciliation.find(ID)

ActiveRecord::Base.transaction do
  # Each person's unit on the day of the settlement (ADR 0011 rule 7),
  # read before the lines that hold it are deleted.
  units = reconciliation.saved_units
  ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
  MealCharge.for_reconciliation(reconciliation).delete_all
  reconciliation.reconciliation_balances.delete_all
  Settlement.new(reconciliation).rewrite!(units: units)
end
```

Without `units:`, `rewrite!` saves each person's unit as it is now, and
the settlement's unit totals move to the units people live in today.

All of it must be in the one transaction, and both tables must be cleared.
The delete alone leaves the reconciliation with no rows, which sums to zero
and commits cleanly — and now you have a settlement with no balances at all.

`rewrite!` sets the settlement's own setting (`comeals.settling`) while it
writes, so its inserts would pass without the bypass. The bypass is still
needed for the two deletes. If you skip the deletes, `rewrite!` fails and
nothing is written. It fails on the line items' unique indexes (one credit
per cook and one debit per eater per meal). A reconciliation settled before
2026-08-02 has no line items, so for it the failure comes from the
balances: the model checks that a resident has only one balance per
reconciliation.

`meal_charges` has the same no-bypass rule as the balances, per meal: the
deferred trigger `meal_charges_sum_zero` refuses a commit that leaves any
meal's lines summing to anything but zero. A repair that edits one line by
hand must edit another line of the same meal by the same amount the other
way. Since 2026-09-17 the lines are allocated at the ledger grain, so a meal's
lines written by `Settlement` sum to exactly zero (MODELS.md, "The ledger
grain").
Clearing only one of the two tables leaves the line items and the totals
describing different things, which the nightly check will report the next
morning.
