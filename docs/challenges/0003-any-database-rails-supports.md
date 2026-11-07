---
id: 3
title: The same guarantees on every database Rails supports
area: portability
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - config/database.yml
  - docs/adr/0008-the-ledger-grain.md
---

# The same guarantees on every database Rails supports

## The challenge

The app runs with the same correctness guarantees on any database and version that our Rails version supports: PostgreSQL, MySQL and MariaDB (mysql2 and trilogy adapters), a MySQL Galera cluster, SQLite, and adapters outside Rails such as Oracle and CockroachDB. It does this with no locks we take ourselves (challenge 2), and under heavy use (challenge 4).

## The case that breaks it

On a Galera cluster:

1. A dinner has 11 of 12 seats taken.
2. Two people sign up at the same moment, on two different nodes.
3. Each node counts 11 sign-ups, sees a free seat, and adds a row.
4. The two writes are to different rows, so Galera finds no conflict. Both commit, and 13 people are in a 12-seat dinner.

SERIALIZABLE does not stop this. Galera does not support it across the cluster, and `SELECT ... FOR UPDATE` locks only on the node where it runs.

## Where we stand

The app depends on PostgreSQL in many places:

- SERIALIZABLE for every session (`config/database.yml`).
- Triggers and CHECK constraints in `db/structure.sql`, which is PostgreSQL SQL.
- Expression indexes such as the unique index on `lower(name)`.
- `pg_trgm`, partial indexes and `RETURNING`.
- Money in `numeric` columns at 8 decimal places (`docs/adr/0008-the-ledger-grain.md`).

None of this was tried on another database.

## Options

The design has to use only what every one of these databases guarantees:

1. A transaction is all or nothing.
2. A conditional update of one row is atomic. `UPDATE ... WHERE id = 400 AND version = 7` changes 1 row or 0 rows, and two writers cannot both get 1. Rails returns that count from `update_all`.
3. A unique index refuses a second copy, including across Galera nodes.

**The design: one write list per dinner, with numbered positions.**

```
meal_events(meal_id, position, kind, data, idempotency_key)
UNIQUE (meal_id, position)
UNIQUE (idempotency_key)
```

A write reads the dinner's events (say the last position is 37), runs one decision function ("is there a seat? is it closed? is it settled?"), and inserts the new event at position 38. If someone else took 38, the unique index refuses the insert (Galera refuses it at commit), and the write starts again with the new events. Two writes to one dinner always collide on the same key, so every database refuses one of them, at any isolation level. Each dinner has its own positions with no gaps, so the "commit order is not sequence order" problem of a global sequence (challenge 2, option B) does not come up.

Settlement becomes one small step per dinner: append "settled at position 37" at position 38. If a sign-up took 38 first, that dinner's settlement starts again and includes it. A sign-up that read the dinner before the settlement collides on 38, reads again, and sees "settled". Settling a dinner twice does nothing the second time. The reconciliation lists each dinner and the position it was settled at, so the cent rounding gives the same answer every time.

**What else it needs:**

1. **Money as whole units of 10^-8 dollars in a `bigint` column.** SQLite has no real DECIMAL: a decimal value that is not whole is stored as a float, which keeps about 15 to 16 digits, and DECIMAL(16,8) has 16. The ledger already computes in these units (ADR 0008). A bigint holds about $92 billion in them.
2. **Every rule in the one decision function.** No triggers (each database writes them differently) and no CHECKs we depend on (see Outside facts). A CHECK can stay as a second check where it works.
3. **Retry a known list of errors, and nothing else:** PostgreSQL's serialization failure, the MySQL and Galera deadlock error (Galera can raise it at `COMMIT`), SQLite's busy error, and a unique index refusal on the position key.
4. **An idempotency key per request,** so a retry after a timeout cannot sign someone up twice.
5. **Jobs that are safe to run twice** (see Outside facts on Galera and `SKIP LOCKED`).
6. **Side effects only after commit.** Done (`app/services/live_update.rb`).
7. **Text compared in Ruby, not in the database.** Store a `name_key` column that Ruby fills with one rule, and put a plain unique index on it. The same for email. See Outside facts for how the databases compare text.
8. **A person sees their own write.** On Galera, a write on node A may not be visible on node B yet. Send each person to one node, or turn on `wsrep_sync_wait` for those reads.
9. **Order by position, never by time or id.** Galera nodes have their own clocks, and Galera's auto-increment ids have gaps, so a newer row can have a smaller id.
10. **A Rails schema.rb file (not written yet) instead of `db/structure.sql`.** Every PostgreSQL-only feature goes.

**What we would lose:** today the database refuses a bad write from anyone, including a person in psql. Under this design only writes through the app follow the rules. That becomes finding the problem afterwards: each event stores a hash of the one before it in its dinner's list, and the daily ledger check verifies the hashes and recomputes everything. A portable design can only use what every database guarantees, and "refuse a bad write from any source" is not on that list.

**How to show it works:** run `spec/concurrency/` and `bin/storm` on every database (PostgreSQL, MySQL with both adapters, MariaDB, a 3-node Galera cluster, SQLite). Stop a Galera node while writes run. And write a TLA+ model that assumes only the three guarantees above (challenge 28).

## Outside facts

- Galera does not support SERIALIZABLE across the cluster. `SELECT ... FOR UPDATE` locks only on its own node, and a conflict between nodes is found at commit and reported as a deadlock error. (checked 2026-11-07: Claude's memory, not the Galera docs)
- MySQL before 8.0.16 accepts a CHECK constraint and ignores it. (checked 2026-11-07: Claude's memory, not the MySQL docs)
- In MySQL InnoDB, SERIALIZABLE turns plain reads into shared locks. (checked 2026-11-07: Claude's memory, not the MySQL docs)
- SQLite stores a non-whole value in a NUMERIC or DECIMAL column as an 8-byte float. (checked 2026-11-07: Claude's memory, not the SQLite docs)
- SQLite allows one writer at a time for the whole database. (checked 2026-11-07: Claude's memory, not the SQLite docs)
- Oracle's SERIALIZABLE is snapshot isolation, so two transactions can each read the same rows and write different ones. (checked 2026-11-07: Claude's memory, not the Oracle docs)
- MySQL 8's default text comparison ignores case and accents, so "Jose" equals "José". Older default comparisons also ignore spaces at the end. (checked 2026-11-07: Claude's memory, not the MySQL docs)
- Solid Queue claims jobs with `SKIP LOCKED`. On Galera that skips only rows locked on the same node. (checked 2026-11-07: Claude's memory, not the Solid Queue or Galera docs)

## History

- 2026-11-07: Opened, from a talk with the owner about running on every database Rails supports.
