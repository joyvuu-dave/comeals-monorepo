# Rolling out SERIALIZABLE — where we are and what is left

Working notes for [ADR 0005](adr/0005-serializable-by-default.md). The ADR
holds the decisions and the reasoning; this file holds the running state, the
order of the remaining work, and the things that cost time to learn.

Last updated 2026-07-29.

## Where we are

Shipped and deployed to production:

| Commit    | What                                                                            |
| --------- | ------------------------------------------------------------------------------- |
| `33672d4` | `SnapshotRead`; `billing:recalculate` reads `SERIALIZABLE READ ONLY DEFERRABLE` |
| `573d7fd` | ADR 0005, drafted                                                               |
| `d18dbb5` | Bugsnag error tracking, Rails and browser                                       |
| `73d7b63` | ADR 0005, estimates replaced with measurements                                  |
| `bf4b21e` | `RetryOnConflict`; the test environment runs at SERIALIZABLE                    |

**Production still runs at READ COMMITTED.** Only the test environment moved
(`config/database.yml`, the `test:` block). That gap is deliberate and closes
at step 5 below.

## Verify first — these are not confirmed

Do these before writing any new code. Both are quick and both change what
comes next if they come back wrong.

1. **Is Bugsnag actually receiving anything?** The code is deployed but the
   config vars may not be set. The Rails half needs `BUGSNAG_API_KEY`; the
   browser half needs `VITE_BUGSNAG_API_KEY` **set before the build**, because
   Vite bakes it into the bundle — setting it after a deploy does nothing
   until the next one.

   ```
   heroku config -a comeals-monorepo | grep -i bugsnag
   heroku run rake bugsnag:verify -a comeals-monorepo
   ```

   `bugsnag:verify` sends one error down each path and prints what it means if
   only the first arrives. Two events should appear in the `comeals` project
   within a minute. If only one does, `BugsnagErrorSubscriber` is not
   subscribed, and that is the half that will carry the retry counts.

2. **Is the production role back to READ COMMITTED?** On 2026-07-29 an
   `ALTER ROLE CURRENT_USER SET default_transaction_isolation = 'serializable'`
   was run and then reset. Confirm the reset held:

   ```
   heroku pg:psql -a comeals-monorepo -c "SHOW default_transaction_isolation"
   ```

   Expect `read committed`. If it says `serializable`, production is running
   ahead of the retry work — reset it and do the remaining steps first.

## What is left, in order

### Step 1 — move rendering out of `with_meal_lock`

`app/controllers/api/v1/meals_controller.rb`. Nine actions call
`with_meal_lock`; eight of them call `render` inside the block, and
`with_meal_lock` itself renders the rejection at
`render_reconciled_rejection`. Re-running that block after a rollback would
raise `DoubleRenderError`, so this has to happen before any retry goes in.

Each action changes so the block returns what to render and the action renders
it afterwards. This also removes the `performed?` check in `update_bills`.

**No dependency on SERIALIZABLE.** Behavior is unchanged, the existing request
specs cover it, and it is the biggest single piece of the diff. Ship it alone.

Done when: `bin/check` is green and no `render` call sits inside a
`with_meal_lock` block.

### Step 2 — retry inside `with_meal_lock`

Wrap the lock's transaction in `RetryOnConflict`. Needs step 1 first.

Out of retries should return a 409 with a message the shared screen can show.
That wording is a UX decision — see the shared-screen principles before
picking it. It must not be a raw error, and the safe action stays under the
tap.

### Step 3 — teach solid_cache about serialization failures

One line in an initializer:

```ruby
SolidCache::Store::Failsafe::TRANSIENT_ACTIVE_RECORD_ERRORS << ActiveRecord::SerializationFailure
```

solid_cache shares the primary database, so every cache write and every
Rack::Attack counter becomes a serializable transaction. Its failsafe already
swallows `ActiveRecord::Deadlocked` — the sibling class — but not
`SerializationFailure`, because it assumed READ COMMITTED. The constant is not
frozen. Verified 2026-07-29.

Without this, a conflict on a rate-limit counter becomes a 500 on a request
that has nothing to do with money.

### Step 4 — ActiveAdmin `around_action`

Twelve resources open their transactions inside `resource` and
`build_resource`, where application code cannot reach them, so admin needs an
`around_action` on `ActiveAdmin::BaseController` that re-runs the action and
resets `response_body`. This is the request-wide boundary that decision 3
rejects for the API; it is acceptable here because admin writes are rare, admin
actions send no mail, and a re-run form submit is harmless.

### Step 5 — flip production

Move the `variables:` block in `config/database.yml` from `test:` to
`default:`. Deploy with `bin/deploy` (never push to Heroku directly).

Then watch Bugsnag for handled `SerializationFailure` reports. Those are
retries that worked. A few is the system behaving; a steady stream means
something is contending that should not be.

## Things that cost time to learn

**`SET TRANSACTION` is refused after a transaction's first query.** This is why
the isolation level is set through `variables:` in `database.yml`, which issues
`SET SESSION` at connect time, and not from application code. Under
transactional fixtures a transaction is always open and has already run
queries, so any application-level attempt fails in every spec.

**`heroku pg:psql` connects as the same role the app uses.** So running
`ALTER ROLE ... SET default_transaction_isolation` to "check whether it works"
is not a check — it is the change, applied to production on the next dyno
restart. Verify on a role the app does not use, or accept that you are making
the change.

**A failing cleanup in a non-transactional spec poisons everything after it.**
`delete_all` in an `after` block can be refused for a conflict like any other
statement. When that happened in `spec/db/settlement_race_spec.rb` the rows
stayed, and because that file sorts first, a thousand later examples ran
against a database that should have been empty. One failure read as
thirty-five. The rows also survived into the next run, which makes it look
worse and more mysterious than it is.

If a serializable run ever produces a pile of failures about data that should
not exist, check for leftovers before believing any of it:

```
psql comeals_test -c "SELECT count(*) FROM communities"
```

**`create(:reconciliation)` is not safe to run twice.** The factory's
`before(:create)` hook builds its own unit, cook, meal and bill. Wrapping it in
`RetryOnConflict` makes a retry manufacture fresh work: the second attempt
settles a meal that did not exist when the race started, and two reconciliations
result. Retry production-shaped calls — `Reconciliation.create!` — not factory
calls. This is `RetryOnConflict`'s own "safe to run twice" rule catching a real
case in the first place it was used.

**At SERIALIZABLE the roles in a two-settlement race swap.** At READ COMMITTED
the rival blocks on `FOR UPDATE`, wakes, and loses its compare-and-swap in
`assign_meals`. At SERIALIZABLE, SSI cancels the _first_ settlement as a pivot
where `settlement_balances` reads the bills, and the rival survives. Assert the
outcome — exactly one survivor, owning every meal, with stored balances
matching source — not which side raises.

**What the suite can and cannot tell you.** 1058 of the 1112 examples run
single-connection under transactional fixtures, where an abort essentially
cannot happen. A green suite means nothing broke structurally. Everything we
know about real abort behavior comes from `spec/db/settlement_race_spec.rb`,
because it is the only file with real threads on real connections. Treat it as
the load-bearing test for this whole change.

**The locks and triggers from ADR 0003 are unaffected.** Nine of the ten
original examples in that file, plus `settled_meal_triggers_spec.rb` and
`whole_cents_check_spec.rb`, pass unchanged at SERIALIZABLE. Do not remove a
lock on the grounds that SERIALIZABLE covers it — locks turn a conflict into a
wait and a readable 400, which is better than an abort and a retry whenever we
know where the conflict is.

## Still open

- Does the role-level isolation setting survive Heroku credential rotation?
  Unknown. `database.yml` is the mechanism we rely on for this reason.
- What the shared screen shows when a signup runs out of retries. A UX
  decision, needed for step 2.
- `CLAUDE.md` says "Four so far" about the ADRs. It is five once 0005 is
  accepted.
