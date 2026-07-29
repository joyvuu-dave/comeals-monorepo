# ADR 0005: SERIALIZABLE by default, with retry

- **Status:** Proposed
- **Date:** 2026-07-29
- **Amends:** decision 2 of ADR 0003
- **Issue:** [#43](https://github.com/joyvuu-dave/comeals-monorepo/issues/43)

## Context

ADR 0003 decided not to adopt `SERIALIZABLE`. The reason it gave is correct and
still holds: PostgreSQL's SSI only detects conflicts among transactions that
are all `SERIALIZABLE`, so making one transaction serializable buys nothing.
The only version that works is the whole application at `SERIALIZABLE`, with a
retry on every write path. ADR 0003 called that "a large change that buys what
two lines already buy" and said to revisit only if a test found a race the
locks do not cover.

No such test has been written and no such race has been found. So this ADR is
not a correction. It is a re-costing.

Two things prompted it. One is [an article on why teams avoid
`SERIALIZABLE`](https://blog.ydb.tech/do-we-fear-the-serializable-isolation-level-more-than-we-fear-subtle-bugs-5a025401b609),
whose argument is that the fear is mostly about throughput, and that an
application without a throughput problem is giving up a strong correctness
guarantee for nothing. The other is that this app is exactly that application:
one dyno, one community, about 30 residents, Puma at 1 thread and 0 workers.

The question this ADR answers is not "is `SERIALIZABLE` better." It is "what
would it actually cost here, and are the decisions along the way obvious."

## What we found

The survey on 2026-07-29 covered the settlement path, the meal-lock path, both
rake tasks, every model callback, and the cache configuration.

### Retry safety is already there, and it is not luck

A retried transaction is only safe if nothing irreversible happened before the
commit that failed. In this codebase nothing does:

- Every Pusher trigger is `after_commit` — `unit.rb:38`, `resident.rb:85`,
  `meal.rb:154`, and the three reservation models. They fire only on success.
- Every cache invalidation is `after_commit` too. `community.rb:270` writes
  this down as a contract, not as a habit.
- Both `deliver_now` calls are outside any transaction:
  `residents_controller.rb:74` runs after the save returns, and the
  reconciliation mailers run after `Reconciliation.create!` returns.

So a retried transaction in this app re-runs pure database work. This is the
single biggest reason the change is cheaper here than it would be elsewhere,
and it is a consequence of the `after_commit` discipline that already exists.

### There is one choke point, and it already opens a transaction

`with_meal_lock` (`meals_controller.rb:339`) is an explicit transaction that
every mutating meal action goes through — nine call sites. That is the whole
API write surface for the ledger. A retry placed inside it covers the API.

### Rendering happens inside that transaction

Eight of the nine actions call `render` inside the `with_meal_lock` block, and
`with_meal_lock` itself renders the rejection when the meal turns out to be
reconciled. Re-running the block after a rollback would raise
`DoubleRenderError`. This is the concrete code change the retry forces, and it
is the bulk of the diff.

### ActiveAdmin has no such choke point

Its twelve resources open their transactions inside `resource` and
`build_resource`, where application code cannot reach them. Admin needs a
different retry boundary than the API does.

### solid_cache shares the primary database

Every `Rails.cache.write`, every Rack::Attack counter increment, and the
background trim thread's deletes become serializable transactions against the
same database as the ledger. The counters are a read-modify-write on a hot key,
which makes them the likeliest source of aborts in the whole application — on
requests that have nothing to do with money.

## Decision

### 1. Set the isolation level per connection, not per transaction

`variables: { default_transaction_isolation: serializable }` in the `default:`
block of `config/database.yml`. This is applied at connect time, which matters
for a reason found the hard way while shipping `SnapshotRead`: `SET
TRANSACTION` is refused once a transaction has run any query, so setting
isolation from application code hits a wall on every nested transaction,
including every spec running under transactional fixtures. Setting it at
connect time has no such problem.

Heroku Postgres does not allow `ALTER SYSTEM`, and generally not `ALTER
DATABASE` either, so "the whole instance" in the literal sense is not
available. `ALTER ROLE <user> SET default_transaction_isolation = 'serializable'`
covers `heroku pg:psql` and the Rails console as well. **This is unverified
against the production credentials and must be checked before the change is
planned around it.** Credential rotation is the specific risk: a rotated role
would not carry the setting. `database.yml` is the mechanism we can rely on;
the role setting is a convenience for humans at a prompt.

### 2. Keep the pessimistic locks

`SERIALIZABLE` does not replace `with_meal_lock`, `assign_meals`' `FOR UPDATE`,
or the immutability triggers. Those turn a conflict into a wait, which produces
a readable 400. `SERIALIZABLE` turns a conflict into an abort, which produces a
retry. Waiting is better when we know where the conflict is. `SERIALIZABLE`
goes underneath the locks to catch write skew on a path nobody thought to lock.

Anyone proposing to remove a lock because "`SERIALIZABLE` covers it" is
proposing to make the system slower and less legible, not simpler.

### 3. Retry at the transaction boundary for the API

Put the retry inside `with_meal_lock`. Not in Rack middleware wrapping the
whole request: that would move every `after_commit` to the end of the request
and would re-send the password-reset email at `residents_controller.rb:74` on a
retry, because that email is sent after a save that would no longer have
committed. A request-wide transaction turns the one property that makes this
change cheap into the thing that breaks.

Retries: a small fixed count, three to five, with jitter. Out of retries
returns a 409 with a message the shared screen can show. That last part is a UX
decision, not only a technical one — see `docs/` on the shared-screen
principles before choosing the wording.

### 4. Rendering moves out of the lock

Each of the nine actions changes so the block returns what to render and the
action renders it afterwards. `with_meal_lock` returns the rejection rather
than rendering it, which also removes the `performed?` check at
`meals_controller.rb:262`. Mechanical, but it touches every mutating meal
action, and it must be done before any retry is switched on.

### 5. ActiveAdmin gets an `around_action`

An `around_action` on `ActiveAdmin::BaseController` that re-runs the action and
resets `response_body`. This is the boundary rejected for the API in decision
3, and it is acceptable here for reasons that do not apply there: admin writes
are rare, admin actions do not send mail, and a re-run admin form submit is
harmless.

### 6. The batch reads are `READ ONLY DEFERRABLE`

**Shipped 2026-07-29**, ahead of the rest, because it stands on its own.
`SnapshotRead` (`app/services/snapshot_read.rb`) opens the transaction
`SERIALIZABLE READ ONLY DEFERRABLE`; `billing:recalculate` uses it.

`DEFERRABLE` is why this does not wait for the rest of the change.
A `SERIALIZABLE READ ONLY DEFERRABLE` transaction waits at the start until
PostgreSQL can give it a snapshot already free of serialization anomalies.
Having waited, it can never abort with a serialization failure and never causes
another transaction to abort. So it is strictly stronger than the
`REPEATABLE READ` it replaced while keeping the property that it needs no
retry. All three modes must be set together — `DEFERRABLE` has no effect
except on a `SERIALIZABLE READ ONLY` transaction.

One timing change to expect after the global switch: today nothing else runs at
`SERIALIZABLE`, so the snapshot is granted at once. Afterwards this block waits
for in-flight writers instead of racing them. For a nightly batch job that is
the behavior we want, but it is a change, and it is the kind that shows up as a
job that suddenly takes longer rather than as an error.

### 7. Decide the cache before switching, not after

A 40001 on a rate-limit counter must not become a 500 on a request that has
nothing to do with money. Wrap the cache store so its serialization failures
are retried and then swallowed. "The volume is too low for the counters to
contend" is probably true and is not a reason to leave it — a broken cache
breaking a request is a stupid way to find out.

### 8. Write the retry tests before the retry

At 1 thread and 0 workers, with `FOR UPDATE` held on every ledger write path,
the production abort rate will be near zero. That is the good news and the bad
news: the retry path would be code that never runs until the day it matters.
It needs deliberate fault injection, not "the suite still passes."

`spec/db/settlement_race_spec.rb` is the harness to build on. It already runs
non-transactionally with real threads, which is the hard part.

**If the fault injection turns out to be hard to build, stop and keep the locks
alone.** A retry we cannot test is worse than no retry.

## Consequences

- `spec/db/settlement_race_spec.rb` will need real work. It asserts _blocking_
  behavior — the racing write waits and is then refused by the trigger. Under
  `SERIALIZABLE` some of those cases may abort with 40001 instead. The
  assertions about the money staying correct should still hold; the assertions
  about how it fails may not. This is the most valuable spec in the repo for
  this question and also the one most likely to need rewriting.
- Every write path in the app gets a new failure mode that did not exist
  before. The locks mean it will almost never fire, which is precisely why it
  must be tested on purpose.
- `bin/check` runs the whole suite at `SERIALIZABLE` afterwards. The suite is
  single-connection under transactional fixtures, so most of it should not
  notice. The non-transactional groups are the ones to watch.
- The claim "read-only, so it cannot hit a serialization failure" stops being
  true by accident and starts being true by construction, but only for the
  transactions that go through `SnapshotRead`. Any new batch read that opens a
  plain transaction is exposed.

## Alternatives considered

- **Do nothing.** ADR 0003's position, and it is still defensible. The known
  hole is closed, and this change fixes no bug we can name. The case for acting
  anyway is that the hole in ADR 0003 was found by reading one code path, and
  reading code paths does not scale as a way to find the next one.
- **Wrap the whole request in one transaction.** Rejected in decision 3. It
  breaks the `after_commit` property that makes retry safe here.
- **Raise the isolation level only on the settlement.** Rejected, and this is
  ADR 0003's original point: SSI only detects conflicts among transactions that
  are all `SERIALIZABLE`. A serializable settlement against a `READ COMMITTED`
  admin request detects nothing.
- **Take the meal lock inside ActiveAdmin as well, and stop there.** This is
  the cheapest thing that closes the known class of problem. ADR 0003 rejected
  it as the primary fix because it is a per-call-site discipline the next new
  admin resource will forget. That objection is still right, and it is the same
  objection that argues for `SERIALIZABLE`: both are about the path nobody
  remembered to guard.

## Open questions

1. Can the production role actually set `default_transaction_isolation`, and
   does it survive credential rotation? Decision 1 is written around not
   knowing.
2. Does solid_cache surface a serialization failure as a raised error or a
   cache miss? Decision 7 assumes the worse case.
3. What does the shared screen show when a signup runs out of retries? It
   should not be a raw error, and the safe action should stay under the tap.
