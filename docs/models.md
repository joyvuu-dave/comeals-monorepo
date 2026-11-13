# Models of the concurrency rules

`models/` holds TLA+ models of the rules that keep a settled dinner from
changing (challenge 28). TLC, the TLA+ model checker, runs every order
of the steps in a model and checks that a property holds in every state
it reaches. The race specs in `spec/db/` try a few orders on purpose;
TLC tries all of them, for the small number of transactions in a model.

```
bin/tla-check                          # every case, about 30 seconds
bin/tla-check MealSettlement.today     # one case
```

`bin/check` runs it (the "TLA+ models" step), and so does the CI
`models` job. It needs Java; on a Mac, `brew install openjdk@21`.

## The properties

- **SettledRowsStay.** Once a settlement commits, the dinner's rows are
  exactly the rows the settlement charged. No row is added, removed, or
  moved to another dinner after the settlement read them.
- **SettledOnce.** A dinner is settled by one settlement, never two.

In the models, one row stands for every child row of a dinner: bills,
attendance and guests are written the same way and the trigger treats
them the same way.

## The cases

Each case is a file `models/cases/<Model>.<case>.cfg`. Its first line
says what TLC must find: `holds`, or `violates <Property>`. A case that
must fail is part of the check too. It shows that the piece the case
takes away is needed, and if it ever starts to hold, the run fails.

### MealSettlement: today's protocol (ADR 0003)

A settlement (or two at once) settles a dinner while an API write, an
admin form and a psql session change its rows. The API and the admin run
at SERIALIZABLE; psql runs at READ COMMITTED. Each piece of the protocol
is a switch in the case file:

| Switch                | The piece                                                                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------------------- |
| `SettleLocks`         | `Settlement#assign_meals` takes `FOR UPDATE` on the meals before it claims them.                                |
| `ClaimIfUnclaimed`    | The claim is a compare-and-swap: `UPDATE ... WHERE reconciliation_id IS NULL`.                                  |
| `Trigger`             | `comeals_reject_settled_child_write`: `"update"` (today), `"keyshare"` (2026-07-27 to 2026-10-16), or `"none"`. |
| `TriggerOld`          | The trigger looks up `OLD.meal_id` as well as `NEW.meal_id`.                                                    |
| `SettleReadCommitted` | The settlement runs at READ COMMITTED, as it would from psql.                                                   |

| Case                            | Result                   | What it shows                                                                                                                                                                                                   |
| ------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `today`                         | holds                    | Today's protocol, with all three kinds of writer.                                                                                                                                                               |
| `two-settlements`               | holds                    | The same with two settlements at once.                                                                                                                                                                          |
| `settlement-read-committed`     | holds                    | Two settlements run from psql at READ COMMITTED, beside a psql writer.                                                                                                                                          |
| `no-settlement-lock`            | holds                    | Without the settlement's `FOR UPDATE`. See below.                                                                                                                                                               |
| `no-claim-check`                | holds                    | Two SERIALIZABLE settlements without the compare-and-swap. See below.                                                                                                                                           |
| `no-trigger`                    | violates SettledRowsStay | A psql insert commits after the settlement, and adds a row to the settled dinner.                                                                                                                               |
| `trigger-key-share`             | violates SettledRowsStay | The trigger as it was until 2026-10-16. A psql insert commits after the settlement took its snapshot and before it locked the meal. The settlement charges the rows in its snapshot and leaves the new row out. |
| `trigger-new-only`              | violates SettledRowsStay | A psql delete or move looks up no meal (a delete has no `NEW`), so it removes a row the settlement already charged.                                                                                             |
| `no-claim-check-read-committed` | violates SettledOnce     | Two READ COMMITTED settlements without the compare-and-swap: the second one waits for the first, then claims the dinner again.                                                                                  |

### What the cases say about the three pieces

At SERIALIZABLE, **the trigger is the piece that keeps both properties
true.** The settlement's `FOR UPDATE` and the compare-and-swap are not
needed for them:

- Without the settlement's lock, a writer that committed after the
  settlement's snapshot has updated the meal row (the trigger's
  `UPDATE meals SET updated_at = updated_at`). The settlement's claim
  then updates the same row and fails with a serialization error. A
  writer that comes after the claim waits for the settlement, and its
  trigger then reads the settled row and refuses.
- Without the compare-and-swap, the second of two SERIALIZABLE
  settlements fails the same way when it locks or updates the meal row
  the first one changed.

The compare-and-swap is needed when a settlement runs at READ COMMITTED
(`no-claim-check-read-committed`): a READ COMMITTED update that waited
for a lock works on the newest row, so without the `WHERE` it claims the
dinner a second time.

The lock is still useful. It turns a serialization error into a wait,
so a settlement and a writer meet with a short wait and a readable
answer instead of an abort and a retry (ADR 0005). These cases only say
it is not what keeps the two properties true.

ADR 0003 says the settlement lock and the trigger "were each tested
alone and neither works". That test was made with the `FOR KEY SHARE`
trigger, which `trigger-key-share` shows fails. With today's trigger,
the model says the trigger alone is enough at SERIALIZABLE.
`spec/db/settlement_without_its_lock_spec.rb` checks this against a real
PostgreSQL: it runs a settlement with its `FOR UPDATE` taken out against
a raw READ COMMITTED write, before and after the claim, and the stored
balances match the rows each time. With the trigger changed back to a
`FOR KEY SHARE` read, every example fails.

### SerializableOnly: challenge 2, option A

Every transaction is SERIALIZABLE, and there are no locks the app takes
itself. PostgreSQL promises the same result as running the transactions
one at a time in some order, so the model runs each transaction as one
step, in every order.

| Case                    | Result                   | What it shows                                                                                                            |
| ----------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `app-writers`           | holds                    | When every writer runs the app's own check, nothing else is needed.                                                      |
| `psql-without-db-check` | violates SettledRowsStay | A psql writer runs no app code, so only a check in the database can stop it.                                             |
| `psql-with-db-check`    | holds                    | A trigger that only reads the meal row is enough. It does not need to write it, because the database promises the order. |

This model assumes the promise holds for psql too. Option A keeps that
promise with a trigger that refuses a write from any isolation level
other than SERIALIZABLE.

### MealEventList: challenge 3

One numbered list of events per dinner, with a unique index on
`(meal_id, position)`, and a settlement that is an event too. The model
assumes only what challenge 3 says every database promises: a
transaction is all or nothing, and a unique index refuses a second row
with the same key. Every read is READ COMMITTED.

| Case               | Result                 | What it shows                                                                                          |
| ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------ |
| `unique-positions` | holds                  | Two writers and two settlements. The settled event is always last, and it is the only one.             |
| `no-unique-index`  | violates SettledIsLast | Without the unique index, a sign-up takes the same position as the settlement, after it read the list. |

## How far to trust a result

**A "holds" result is sound for what the model contains.** The
MealSettlement model lets any transaction abort at any step, which
covers a deadlock, a timeout, a crash and PostgreSQL's own serialization
checks. An abort writes nothing, so allowing more aborts can only show
more orders. The model leaves out PostgreSQL's serializable checks
between two SERIALIZABLE transactions (SSI), and it never fails a
`FOR KEY SHARE`. Both of those only abort transactions in PostgreSQL, so
leaving them out lets more transactions commit, not fewer.

**A "fails" result has to be read.** Because SSI is left out, TLC could
show an order that PostgreSQL would stop. Each failing case above was
checked by hand: in every one, the transaction that does the damage is
a READ COMMITTED one (the psql writer, or a settlement from psql), and
SSI never aborts a READ COMMITTED transaction. A new failing case needs
the same check. TLC prints the order of steps that breaks the property.

## What the models leave out

- Cancelling a dinner and corrections to a settled dinner.
- Rails' `touch: true`, which also updates the meal row. It can only
  add conflicts, so it cannot make a property fail that holds here.
- The rules that read and then write inside one dinner: the seat
  limit, the last open spot, a closed dinner.
- More than two settlements, more than one writer of each kind, and
  more than two dinners. TLC checks every order for the sizes in the
  case files, not for every size.

## Adding or changing a case

1. Copy a case file and change its switches. Keep the first line,
   `\* expect: ...`, and put one comment line under it that says what the
   case shows.
2. Run `bin/tla-check <Model>.<case>`.
3. For a failing case, read the order of steps TLC prints and check that
   PostgreSQL would really allow it (see "How far to trust a result").
4. Add a row to the table above.

A new model needs at least one case, or `bin/tla-check` fails.

The tools: TLC from TLA+ 1.7.4 (`tla2tools.jar`, pinned by its SHA-256
in `bin/tla-check`), downloaded once into `~/.cache/comeals`.
