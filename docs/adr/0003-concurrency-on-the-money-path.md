# ADR 0003: Concurrency on the money path

- **Status:** Accepted
- **Date:** 2026-07-27
- **Issue:** [#43](https://github.com/joyvuu-dave/comeals-monorepo/issues/43)

## Context

Puma runs with 1 thread and 0 workers. The comment in `config/puma.rb` used to
say this was to "eliminate thread-safety concerns in financial code." Issue #43
asked whether that setting is still buying what it appears to buy.

It is not, and it never did. This ADR records what the git history actually
says, what really protects the ledger, one real hole that was found and
verified, and what we decided to do.

### What the history says

The premise that single-threaded Puma is an old, considered response to a money
bug does not survive a look at the log:

| Commit    | Date       | What happened                                                       |
| --------- | ---------- | ------------------------------------------------------------------- |
| `083ca01` | 2017-08-05 | "make it single threaded"                                           |
| `dc6ebe2` | 2017-08-06 | "bring back threads" — reverted the next day                        |
| `07fae93` | 2026-04-01 | 5 threads → 1 thread, **and 0 workers → 2 workers, `preload_app!`** |
| `a2eb8b9` | 2026-04-10 | "Switch Puma to single mode" — workers back to 0                    |

Three things follow.

1. The app ran multi-threaded from August 2017 to April 2026. The current
   setting is four months old, not years old.
2. The commit that introduced "single thread for thread-safety" **raised**
   concurrency in the same diff: 2 worker processes × 1 thread. Separate
   processes have every database race that threads have. For nine days in April
   2026 this app served two requests at once in production.
3. No commit message anywhere describes a money bug. If one happened, it left
   no trace in the repo.

The 2017 pair reads as a one-day experiment that was reverted, not as a
response to an incident.

**On the `counter_culture` theory.** Issue #43 suggests the original bug may
have been a lost update on a denormalized counter. Commit `1873dd7`
(2026-03-26) removed the gem and eight cached columns. But counter_culture
drifts by _missed callbacks_ — `update_all`, `delete_all`, bulk operations —
not by a thread race. Single-threaded Puma would not have fixed that. The
theory is plausible as the original bug and its fix has shipped, but it does
not justify the thread count either.

### Where concurrency actually comes from today

Not from Puma. From out-of-band processes:

- **`billing:recalculate`** runs on Heroku Scheduler at 03:00 UTC. It **cannot
  corrupt the ledger.** It reads under `REPEATABLE READ` and writes only
  `resident_balances`, a derived cache the next daily run rebuilds.
  _Amended 2026-08-23: it now reads through `SnapshotRead`, which opens the
  transaction `SERIALIZABLE READ ONLY DEFERRABLE`. See ADR 0005, decision 6._
- **`reconciliations:create`** is the one task that writes the ledger, and it
  is **not scheduled**. `lib/clock_schedule.rb` lists it under "Manual tasks."
  It runs when a human types `heroku run rake reconciliations:create`.

So the concurrent-write surface is one manually triggered task racing whatever
requests happen to be in flight. Real, rare, and unmonitored.

### What actually protects the ledger

This was verified, not assumed. It is correct and should not be re-audited:

- **The API path is genuinely serialized.** `with_meal_lock`
  (`app/controllers/api/v1/meals_controller.rb`) takes `SELECT ... FOR UPDATE`
  on the meal row; `Settlement#assign_meals`' `update_all` takes
  `FOR NO KEY UPDATE` on the same row. Those two conflict, so request and
  settlement serialize in **both** orders, and the loser sees `reconciled?` on
  a fresh reload and returns a 400. All 9 mutating meal actions go through it.
- **Compare-and-swap in `assign_meals`** raises if a rival settlement claimed a
  plucked meal, rolling the whole settlement back.
- **Balances are derived, never stored** as source of truth, and there are no
  denormalized counters (`counter_culture` is gone entirely).
- **`Current` is `ActiveSupport::CurrentAttributes`** — per-thread and reset by
  the Rails executor. Not shared mutable state. There is no class-level mutable
  state in `app/`.
- **Database triggers** refuse writes to a reconciled meal's rows from any
  path, including ones that skip callbacks.

## The hole we found

There turned out to be two of it, pointing in opposite directions. The first
was found by reading the code; the second was found by reviewing the fix for
the first and asking what it deliberately left alone.

### Adding a row that no reconciliation counts

**ActiveAdmin writes bills without taking the meal lock.** `app/admin/bill.rb`
exposes a full create/edit/destroy form; its only guard is
`block_if_reconciled`, a plain non-locking read. The same applies to any other
path that writes a meal's child rows without going through `with_meal_lock`.

The mechanism, confirmed by direct experiment against a copy of the
development database on 2026-07-27:

| Session A holds on the `meals` row            | Concurrent `INSERT INTO bills` for that meal   |
| --------------------------------------------- | ---------------------------------------------- |
| `FOR NO KEY UPDATE` (what `update_all` takes) | **not blocked** — insert goes straight through |
| `FOR UPDATE` (what an explicit `.lock` takes) | **blocked** — waits for A                      |

An `INSERT` into a child table takes `FOR KEY SHARE` on the parent row to
enforce the foreign key. `FOR KEY SHARE` does **not** conflict with
`FOR NO KEY UPDATE`. So this sequence is possible right now, at 1 thread and
0 workers:

1. Settlement claims the meals with `update_all` and computes balances from the
   bills as they are.
2. An admin inserts a bill on one of those meals. Nothing blocks it. The
   immutability trigger runs a plain `SELECT` and still sees
   `reconciliation_id IS NULL`, so it allows the write.
3. Settlement commits.

The bill now sits on a reconciled meal. It is not in that reconciliation's
balances, and `billing:recalculate` skips it because that task only sums
_unreconciled_ meals. **The cook is never reimbursed and nothing raises** —
`allocate_to_cents` still sums to zero, because the row is simply not in its
input.

This is silent money loss. It has nothing to do with Puma's thread count: a
single-threaded web dyno plus `heroku run rake` reproduces it exactly.

### Deleting a row that a reconciliation already counted

The first fix (below) locks the trigger's lookup on `NEW.meal_id`. It left the
lookup on `OLD.meal_id` — the one `UPDATE` and `DELETE` use — as a plain read,
on this reasoning: a row that already belongs to a settled meal is refused on
state that cannot move, so locking there would add contention for nothing.

That reasoning covers a meal that is **already** settled. It does not cover a
meal that is **becoming** settled, which is the entire window this ADR is
about. And a `DELETE` of a child row takes no lock on the parent meal at all —
there is no foreign key to check on the way out — so it never waits for
anything.

Verified with the same spec harness, the write changed to a `DELETE` fired
after the balance reads: the statement was **not blocked**, no error was
raised, the row was gone, and the reconciliation's stored balances no longer
matched its source data. Deleting a bill left a cook credited $30 for a bill
that does not exist. Deleting an attendance row left a resident charged $25
with no attendance row behind it.

This is reachable from buttons in the UI, not only from `psql`.
`app/admin/meal_resident.rb` declares `actions :create, :destroy` and is the
attendance-correction path from issue #25. `app/admin/bill.rb` allows destroy,
and permits `:meal_id`, so its form can also move a bill **off** a settling
meal — same damage, same missing lock.

It is not as bad as the first hole. The stored balances are what residents
actually pay, so this corrupts the audit trail rather than losing a cook's
money outright. But "the settled ledger silently stops matching its own source
data" is the specific thing the money rules exist to prevent, and a later
audit that recomputes a reconciliation would find a mismatch with no way to
tell which side is right.

The fix is symmetric: the `OLD.meal_id` lookup becomes unconditional and
locking too. The self-lock case stays free — a path holding `FOR UPDATE` on
the meal is asking for a lock it already owns.

### The fix needs two parts, not one

The obvious fix — make `assign_meals` take `FOR UPDATE` before claiming — is
**not sufficient on its own**. This was tested and failed. Postgres fires a
`BEFORE INSERT` trigger _before_ the foreign-key check, so the trigger makes
its decision on the pre-settlement snapshot, then the FK check blocks, then the
settlement commits, then the insert proceeds anyway. Verified: the bill lands
on the reconciled meal.

The trigger fix alone is also insufficient, and was also tested. Making the
trigger's lookup a locking read does nothing while `assign_meals` holds only
`FOR NO KEY UPDATE`, because `FOR KEY SHARE` does not conflict with it. There
is nothing to wait on. Verified: the stray bill still lands.

Both together do close it, and this combination was verified end to end:

1. **`Settlement#assign_meals` takes an explicit row lock before claiming:**

   ```ruby
   Meal.where(id: meal_ids).order(:id).lock.pluck(:id)   # FOR UPDATE
   ```

   `ORDER BY id` keeps the lock order deterministic so two settlements cannot
   deadlock against each other.

2. **The immutability trigger's INSERT/UPDATE lookup becomes an unconditional
   locking read**, so its decision is made after the wait, against committed
   post-settlement state:

   ```sql
   SELECT reconciliation_id INTO rec_id FROM meals WHERE id = NEW.meal_id FOR KEY SHARE;
   IF rec_id IS NOT NULL THEN ... RAISE EXCEPTION ...
   ```

   The lock must be taken **unconditionally**. The current form
   (`WHERE id = ... AND reconciliation_id IS NOT NULL`) matches no row when the
   meal is still unreconciled, so it takes no lock and never waits.

With both in place the admin insert blocks on the settlement and then fails
loudly with the trigger's exception. Silent loss becomes a visible error.

**This fix shipped on 2026-07-27** (issue #43). Part 1 is in
`Settlement#assign_meals` (it was `Reconciliation#assign_meals` until
2026-08-23, when the settlement pipeline moved out of the model's
`after_create` callback into `app/services/settlement.rb`, unchanged); part 2
is migration `20260727120000`, which
locks **both** lookups, replaces the function body with
`CREATE OR REPLACE FUNCTION`, and leaves the already-applied `20260707100000`
untouched. `spec/db/settlement_race_spec.rb` pins it for inserts, deletes, and
re-parenting across all three child tables, and the money-level assertion in
that spec is what fails first without the fix: the reconciliation's stored
balances stop matching its own source data. That was confirmed by reverting
the migration on the test database, and separately by applying a
`NEW.meal_id`-only version of it, and watching exactly the matching examples
fail on that assertion.

The two lookups were written as two migrations while the second hole was being
found, then merged into one before anything was committed. Nothing shipped in
between, so there is no half-fixed state to migrate through — a database is
either on `20260707100000`'s non-locking function or on this one.

One detail the spec had to get right, because it is easy to write a test that
passes for the wrong reason. The dangerous instant is not when `assign_meals`
claims the meals. It is after `write_ledger!` has read the bills,
attendance, and guests — the latest moment a racing write can start and still
be missed by the balances. Firing the racing write there is the hardest
version of the test; anything earlier only waits longer.

(Before the fix, that was also the only window that cost anything: a write
committing before those reads was picked up by the settlement itself, since
under `READ COMMITTED` each statement takes a fresh snapshot. After the fix
the distinction is moot — `assign_meals` holds `FOR UPDATE` for the whole
transaction, so no racing write commits anywhere between the claim and the
reads. They all block, and are all refused.)

## Decision

1. **Fix the settlement lock and the trigger together.** Both parts, or
   neither — each alone is proven not to close the hole. And lock **both** of
   the trigger's lookups, `NEW.meal_id` and `OLD.meal_id`. Leaving either one
   as a plain read leaves a live race in that direction; that is not a
   deduction, it is what happened on the first attempt.

2. **Do not adopt `SERIALIZABLE`.** Issue #43 calls it "the single largest
   available upgrade." It is not, because of a detail the issue misses:
   **Postgres SSI only detects conflicts among transactions that are all
   `SERIALIZABLE`.** Making `Reconciliation.create!` serializable would not
   detect write skew against a `READ COMMITTED` admin request. Catching the
   hole above that way would mean running the whole app at `SERIALIZABLE`, with
   a retry wrapper on every request — a large change that buys what two lines
   already buy. Revisit only if a test finds a race the locks do not cover.

   _Re-costed on 2026-07-29 in ADR 0005, now Accepted: the whole app runs at
   `SERIALIZABLE` since 2026-08-02. No test found such a race; the reasoning
   above still holds. What changed is the estimate of what the
   whole-application version would cost here._

3. **Scope the concurrency tests to the unlocked paths.** Issue #43 asks for N
   threads against every endpoint. The API endpoints are already serialized by
   the row lock; testing them mostly tests Postgres. Test what skips the lock:
   an admin bill write racing a settlement, and two settlements racing each
   other.

4. **Leave the Puma thread and worker counts alone.** There is no throughput
   problem anywhere in this repo — one dyno, one community, roughly 30
   residents. The setting stays at 1/0 because nothing needs more, **not**
   because it protects anything.

## Consequences

- `config/puma.rb`, `config/database.yml`, and the `with_meal_lock` comment no
  longer claim the thread count is a safety mechanism. That claim was false and
  would have misled the next reader into treating a throughput knob as a
  correctness guarantee.
- Anyone raising the thread or worker count must not assume it is safe _because
  of_ this ADR. The hole above is closed, so the unlocked admin paths now fail
  loudly instead of losing money quietly — but that is one race, found by
  reading one code path, not a general guarantee.
- Settlement now holds `FOR UPDATE` on every swept meal for the whole
  transaction. Writes to those meals wait for it. Measured on a warm local
  database: 64 ms for 30 residents and 25 meals (about a month), 241 ms for
  the same community and 300 meals (about a year). Milliseconds, and
  settlement is a manual task, so this costs nothing worth optimizing.
- **A practical constraint on the tests:** `spec/rails_helper.rb` sets
  `config.use_transactional_fixtures = true`. Threaded specs cannot see the
  outer transaction's uncommitted data, so these tests need their own
  non-transactional tag. Budget for that; it is not a one-line spec.
- The `.aiwg/intake/` documents described the system as of 2026-04-11 and
  repeated the "no threading races" claim. At the time, the three affected
  lines were annotated in place with a pointer to this ADR. The documents
  were removed in the 2026-08 dead-code cleanup; they live in git history.
- The lesson worth keeping from the second hole: when a fix deliberately
  leaves a branch alone, write down the case the exemption covers, then check
  whether the race you are fixing is that case. Here it was not — the
  exemption reasoned about a meal that is already settled, and the race is
  about one that is becoming settled. That gap was a comment away from being
  visible.

## When to revisit

- A test finds a race the pessimistic locks do not cover — then reconsider
  `SERIALIZABLE` application-wide, with retry.
  _Amended 2026-08-23: done. Since 2026-08-02 every session runs at
  `SERIALIZABLE` (the `variables:` block in `config/database.yml`) and
  `RetryOnConflict` retries the API's meal writes. See ADR 0005._
- A real throughput problem appears. Then the thread/worker conversation is
  worth having, and connection-pool math comes with it: pool ≥ threads plus
  background threads, per dyno, under the Postgres tier's connection cap.
- A second community is added, or `reconciliations:create` is moved onto a
  schedule. Scheduling it turns a rare human-triggered race into a daily one.

## Alternatives considered

- **Raise the thread count and rely on `SERIALIZABLE` plus retry.** Rejected:
  see decision 2. It solves a throughput problem the app does not have, using a
  mechanism that only works if applied everywhere.
- **Take the meal lock inside ActiveAdmin too.** Reasonable, and it would close
  the same hole for the paths that exist today. Rejected as the primary fix
  because it is a per-call-site discipline that the next new admin resource
  will silently forget. The trigger is enforced by the database for every path,
  present and future.
- **Do nothing, on the grounds that the race needs a human running a manual
  rake task at exactly the wrong moment.** Rejected. The failure is silent, and
  silent is the specific thing this codebase's money rules exist to prevent.
