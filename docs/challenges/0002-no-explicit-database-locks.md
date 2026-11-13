---
id: 2
title: Keep every guarantee with no database locks we take ourselves
area: concurrency
status: open
opened: 2026-11-07
reviewed: 2026-11-12
watches:
  - app/models/concerns/locks_its_meal_first.rb
  - docs/adr/0003-concurrency-on-the-money-path.md
  - docs/adr/0005-serializable-by-default.md
---

# Keep every guarantee with no database locks we take ourselves

## The challenge

Remove every lock the app takes on purpose, and keep every correctness guarantee the app has.

"No locks at all" cannot happen in PostgreSQL. Every write, unique index and foreign key takes row locks inside the database, whatever the app does. And SERIALIZABLE keeps its own read records inside the database, which Postgres calls predicate locks; they never make anyone wait. So the challenge is: no lock that we take or design ourselves.

## The case that breaks it

Take out the locks and change nothing else:

1. A settlement starts and reads the sign-ups of a dinner.
2. At the same moment, someone in psql, at READ COMMITTED, adds a sign-up to that dinner.
3. The settlement commits without the new sign-up. The sign-up commits too. The dinner is settled, and a person who ate is never charged.

The same thing can happen with two people taking the last seat, or a cost written while a dinner is cancelled.

## Where we stand

The app protects these rules with four pieces (`docs/adr/0003-concurrency-on-the-money-path.md`):

1. `with_meal_lock` in `app/controllers/api/v1/meals_controller.rb` takes `FOR UPDATE` on the meal row for API writes to bills, attendance and guests.
2. `LocksItsMealFirst` (`app/models/concerns/locks_its_meal_first.rb`) makes admin, tasks and the console lock the meal before its rows, so every writer locks in the same order and two writers cannot deadlock.
3. The settlement takes `FOR UPDATE`, then claims its meals with a compare-and-swap (`app/services/settlement.rb`).
4. The trigger `comeals_reject_settled_child_write` (in `db/structure.sql`) writes the meal row on every child write. So a transaction that read that row earlier, even in psql, now conflicts with the write.

The whole app runs at SERIALIZABLE (`docs/adr/0005-serializable-by-default.md`). The specs that pin the races: `spec/db/settlement_race_spec.rb`, `spec/db/settlement_after_a_raw_write_race_spec.rb`, `spec/db/cancel_against_a_cost_race_spec.rb`.

A TLA+ model of option A, `models/SerializableOnly.tla` (challenge 28, `docs/models.md`), finds that a settled dinner keeps its rows when every writer is SERIALIZABLE and a trigger only reads the meal row, and that a psql writer breaks it when there is no check in the database.

Together they make sure:

- A settlement counts exactly the rows that exist.
- The rules that read and then write hold: the seat limit, the last open spot, a closed dinner.
- A collision becomes a wait and a readable 400, not an abort.

## Options

**A. Let SERIALIZABLE do all of it, and make it required.** If every transaction is SERIALIZABLE, Postgres promises the same result as running them one at a time. The gap is a writer that is not SERIALIZABLE, such as psql. Close it with a trigger on every money table that refuses a write unless `current_setting('transaction_isolation') = 'serializable'`. Then pieces 1 to 4 are no longer needed for correctness. Costs:

- A wait becomes an abort and a retry, everywhere: admin forms, rake tasks, and a person in psql.
- A long settlement can be aborted again and again at a busy time, because any sign-up that touches a row it read conflicts with it. It must settle one dinner at a time, or use option B.
- Under load, Postgres merges its row-level read records into page-level and table-level ones, which can abort transactions that had no real conflict. That means more retries, not wrong data.
- A database superuser can turn triggers off (`session_replication_role = replica`). The app's role on Heroku cannot.

**B. An append-only event log, and settlements that name a point in it.** Nothing is updated or deleted. Every action is a new row. A settlement says "all events up to point P", so running it twice gives the same answer, and an event written during it lands after P. The hard part is that commit order is not sequence order: event 104 can commit after event 105 is already read. The standard fix is a cutoff point that only moves forward once no transaction older than it can still be running (`pg_current_snapshot()`, `pg_snapshot_xmin()`). Challenge 3 shows a version of B that needs no global sequence. Costs: rewriting bills, attendance and guests as events, and every screen reading computed state.

**What either option also needs:** an idempotency key on each request, side effects only after commit (done: `app/services/live_update.rb`), a fixed rule for every tie, and a model checker to show it holds in every ordering (challenge 28).

My recommendation, if this is ever done: A first, and keep `with_meal_lock` anyway. It is no longer needed for correctness, but it gives people a wait and a clear message instead of a retry.

## History

- 2026-11-07: Opened, from a talk with the owner about what would make the locks unnecessary.
