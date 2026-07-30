# Rolling out SERIALIZABLE — where we are and what is left

Working notes for [ADR 0005](adr/0005-serializable-by-default.md). The ADR
holds the decisions and the reasoning; this file holds the running state, the
order of the remaining work, and the things that cost time to learn.

Last updated 2026-07-30.

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
(`config/database.yml`, the `test:` block). That difference is on purpose. Step
5 below is where production moves too.

## Checks to run first — both done

Both were confirmed on 2026-07-29. Kept here with the commands, because they
are worth re-running after a deploy, after a credential rotation, or whenever
something on the money path does not add up.

1. **Is Bugsnag actually receiving anything?**

   Confirmed 2026-07-29: both `BUGSNAG_API_KEY` and `VITE_BUGSNAG_API_KEY` are
   set on Heroku, and the browser half is live — the key and the SDK are both
   in the deployed bundle. That last part is the one that is easy to get
   wrong, because Vite writes `VITE_*` vars into the bundle at build time:
   setting the var after a deploy does nothing until the next build. To
   re-check it later,
   fetch the script named in `https://comeals.com/` and grep it for the key.

   The Rails half is confirmed too, by `rake bugsnag:verify` on 2026-07-29.
   Both events arrived, so `BugsnagErrorSubscriber` is subscribed and the
   path that will report retry counts works. Re-run that task after any
   change to the initializer or the subscriber.

   Both verify events show in Bugsnag as **handled**, and that is correct
   rather than a bug to look into. `Bugsnag.notify` always marks handled and
   `Bugsnag::Report#unhandled` is read-only, which is why the subscriber puts
   the real `handled:` value in the `rails_error` tab. A genuine uncaught
   crash comes through the Rack middleware and shows as unhandled.

   **So error tracking is fully live.** Retries logged by `RetryOnConflict`
   will appear as handled `ActiveRecord::SerializationFailure` events with an
   `attempt` number in the `rails_error` tab.

2. **Is the production role back to READ COMMITTED?** On 2026-07-29 an
   `ALTER ROLE CURRENT_USER SET default_transaction_isolation = 'serializable'`
   was run against production and then reset. Confirmed the same day: it
   reports `read committed`, so the reset held.

   ```
   heroku pg:psql -a comeals-monorepo -c "SHOW default_transaction_isolation"
   ```

   Re-run this if anything unexplained shows up on the money path before
   step 5. If it ever says `serializable` before that step, production is at
   SERIALIZABLE without the retry code that it needs — reset it first.

**Both checks are done. Steps 1 to 4 are done. Step 5 is the last one, and it
is the one that changes production.**

## What is left, in order

### ~~Step 1 — move rendering out of `with_meal_lock`~~ — done 2026-07-29

Shipped. No `render` call sits inside a `with_meal_lock` block any more.

How it works now. The block returns the render arguments as a hash, and the
action calls `render(**result)` after `with_lock` returns. `with_lock` returns
whatever its block returns, so nothing had to be threaded through by hand.
`render_reconciled_rejection` became `reconciled_rejection`, which returns the
same hash instead of rendering it; the `reject_if_reconciled` before_action
renders it itself. The `performed?` check in `update_bills` is gone — that
block now returns `nil` on success, so a non-nil return is the rejection.

`with_meal_lock` renders nothing at all. That rule is written in a comment
above it, with the reason.

One thing this cost that was not expected: the class grew by nine lines, one
per action, and crossed the `Metrics/ClassLength` limit of 250. The limit is
now 260. A wrapper method that did the lock and the render together would have
saved about five of those lines, which is not enough to stay under 250, and it
would have hidden the render again right after we made it visible. The class is
long because `update_bills` is long. Splitting that out is a separate job.

Verified by `bin/check`: 1112 examples, 0 failures, RuboCop clean. The 441
request specs cover these actions and none of them changed.

### ~~Step 2 — retry inside `with_meal_lock`~~ — done 2026-07-29

`with_meal_lock` now calls `RetryOnConflict.call` around `@meal.with_lock`, and
rescues `ActiveRecord::TransactionRollbackError` into `conflict_rejection`.

`RetryOnConflict` goes outside `with_lock`, not inside. It refuses to retry
when a transaction is already open, so inside the lock it would do nothing at
all and the whole step would be a no-op that still passed its tests.

`conflict_rejection` returns the render arguments, the same shape as
`reconciled_rejection`, so every action picks it up through the `render(**result)`
it already does. `update_bills` reads the return value itself instead of
rendering it, and a non-nil return is already how it recognises a rejection, so
it needed no change either. The status is 409 and the message is:

> Someone else was changing this meal at the same time. Nothing was saved. Try
> again.

It sets `@skip_pusher`, because nothing was written and there is nothing to
tell the other screens about.

The SPA needed no change. Every one of these calls already has a `catch` that
reverts the optimistic change and passes the error to `handleAxiosError`, which
shows `data.message` as an error toast. So the checkbox goes back to where it
was and the message appears under it.

**Still not built: a "Try again" button.** The plan called for one. The screen
already reverts the change, so tapping the same control again is the retry, and
a button would mean a new popup pattern built for an error that has never
happened in production. Decide this after step 5, when Bugsnag can say whether
these conflicts happen at all.

Verified by `bin/check`: 1117 examples, 0 failures, RuboCop clean. Five new
examples in `spec/requests/api/v1/meals_controller_spec.rb` cover the 409, the
message, that nothing is written, that no Pusher event is sent, and that the
call really goes through `RetryOnConflict` — without that last one, deleting
the wrapper still passes everything else.

Those examples run under transactional fixtures, so they never see a real
retry; `RetryOnConflict.call` re-raises at once when a transaction is open.
They check the answer the endpoint gives, not the retrying. The attempt count
is `spec/services/retry_on_conflict_spec.rb`'s job.

`Metrics/ClassLength` went from 260 to 270. That is the second raise for this
one class. `update_bills` should be extracted rather than raising it a third
time; the reason is written next to the setting in `.rubocop.yml`.

### ~~Step 3 — teach solid_cache about serialization failures~~ — done 2026-07-29

`config/initializers/solid_cache.rb` appends
`ActiveRecord::SerializationFailure` to
`SolidCache::Store::Failsafe::TRANSIENT_ACTIVE_RECORD_ERRORS`.

solid_cache shares the primary database, so every cache write and every
Rack::Attack counter becomes a serializable transaction. Its failsafe already
swallows `ActiveRecord::Deadlocked` — the class next to it — but not
`SerializationFailure`, because it was written for READ COMMITTED. Both are
subclasses of `ActiveRecord::TransactionRollbackError`; PostgreSQL picks
between them by which rule the transaction broke.

Without this, a conflict on a rate-limit counter becomes a 500 on a request
that has nothing to do with money. With it the answer is a cache miss, which
is always correct — nothing was written, and reading through to the source
works.

Two things it depends on, both checked against solid_cache 1.0.10 and both
pinned by `spec/lib/solid_cache/store_spec.rb`: the constant is a plain array
and is not frozen, and the failsafe splats it at rescue time rather than
holding a copy.

The initializer is a plain top-level statement, not `to_prepare`. The constant
belongs to the gem, so the app's reloader never unloads it.

Four new examples: the constant holds the class, the list can still be
appended to, a refused read answers with a miss instead of raising, and the
refusal is reported through `Rails.error` so Bugsnag counts it. That last one
matters — a cache that quietly misses every read looks exactly like a cache
that works.

Verified by `bin/check`: 1121 examples, 0 failures, RuboCop clean.

### ~~Step 4 — ActiveAdmin~~ — done 2026-07-30

**The plan was an `around_action`. It cannot work, so admin got a rescue
instead.** ADR 0005 decision 5 is rewritten with the full reasoning; the short
version is that `resource` and `build_resource` memoize the row they read into
`@meal`, `@bill` and so on, so a retry inside the same controller instance
would write again from the read the database just refused.

`config/initializers/active_admin_conflict_rescue.rb` rescues
`ActiveRecord::TransactionRollbackError` on `ActiveAdmin::BaseController` and
redirects back with the same message the API sends:

> Someone else was changing this at the same time. Nothing was saved. Try
> again.

The person retries by submitting the form again. That is fine in admin, where
one person is using it at a time, and it is what the shared screen already
does.

Two things were checked before trusting that message, and both hold. No admin
path sends mail — every `deliver_now` is in a rake task, except the password
reset in `Api::V1::ResidentsController`. And no Pusher event survives a
rollback — meal, bill, attendance and guest events come from an `after_action`
in `Api::V1::MealsController`, so admin sends none, and the calendar models use
`after_commit`, which does not run on a rollback.

The refusal is reported through `Rails.error`. Nothing retries here, so
otherwise a conflict in admin would show up nowhere.

Devise's sign-in controllers inherit from Devise, not ActiveAdmin, so a
conflict while signing in is still a 500. Left alone: it is a trackable write
on a table the money code never touches.

Nine new examples in `spec/requests/admin/conflict_rescue_spec.rb`. Eight of
them fail if the initializer is deleted — checked by deleting it. The ninth
checks that ActiveAdmin still memoizes the row, so if a future version stops,
the reason for having no retry is visible and worth revisiting.

### Step 5 — switch production to SERIALIZABLE

**The code change is committed. The deploy has not happened.** Until it does,
production is still READ COMMITTED and nothing below has been seen for real.

The `variables:` block moved from `test:` to `default:` in
`config/database.yml`, so development, test and production all run the same
way.

One thing worth checking, because the whole step is a no-op if it is wrong:
Heroku sets `DATABASE_URL`, and Rails merges that into the config from this
file. Confirmed 2026-07-30 that the merge keeps `variables` — the URL replaces
host, database and username, and everything set only in the file survives:

```
RAILS_ENV=production bundle exec ruby -e '
require "active_record"
require "active_record/database_configurations"
require "erb"; require "yaml"
ENV["DATABASE_URL"] = "postgres://u:p@example.com:5432/d"
raw = YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true)
c = ActiveRecord::DatabaseConfigurations.new(raw).configs_for(env_name: "production").first.configuration_hash
puts c[:variables].inspect'
```

Deploy with `bin/deploy` (never push to Heroku directly). Then confirm what
production is actually running:

```
heroku pg:psql -a comeals-monorepo -c "SHOW default_transaction_isolation"
```

Then watch Bugsnag for handled `SerializationFailure` reports. Those are
retries that worked. A few of them means the system is working as designed.
Many of them, again and again, means two things are conflicting that should
not be.

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

**A failing cleanup in a non-transactional spec breaks every example after
it.** `delete_all` in an `after` block can be refused for a conflict like any
other statement. When that happened in `spec/db/settlement_race_spec.rb` the
rows stayed, and because that file sorts first, a thousand later examples ran
against a database that should have been empty. One failure read as
thirty-five. The rows are still there on the next run too, which makes the
problem look bigger and harder to explain than it is.

If a serializable run ever produces many failures about data that should not
exist, check for leftover rows before believing any of it:

```
psql comeals_test -c "SELECT count(*) FROM communities"
```

**`create(:reconciliation)` is not safe to run twice.** The factory's
`before(:create)` hook builds its own unit, cook, meal and bill. Wrapping it in
`RetryOnConflict` makes a retry create new records: the second attempt settles
a meal that did not exist when the race started, and you end up with two
reconciliations. Retry the calls production makes — `Reconciliation.create!` —
not factory calls. This is `RetryOnConflict`'s own "safe to run twice" rule
finding a real case in the first place it was used.

**At SERIALIZABLE the two sides of a two-settlement race change places.** At READ COMMITTED
the rival blocks on `FOR UPDATE`, wakes, and loses its compare-and-swap in
`assign_meals`. At SERIALIZABLE, SSI cancels the _first_ settlement as a pivot
where `settlement_balances` reads the bills, and the rival survives. Assert the
outcome — exactly one survivor, owning every meal, with stored balances
matching source — not which side raises.

**What the suite can and cannot tell you.** 1058 of the 1112 examples run
single-connection under transactional fixtures, where an abort essentially
cannot happen. A green suite means nothing broke structurally. Everything we
know about real abort behavior comes from `spec/db/settlement_race_spec.rb`,
because it is the only file with real threads on real connections. It is the
only test that can catch a break in this change, so treat a failure there as
serious even when the rest of the suite is green.

**The locks and triggers from ADR 0003 are unaffected.** Nine of the ten
original examples in that file, plus `settled_meal_triggers_spec.rb` and
`whole_cents_check_spec.rb`, pass unchanged at SERIALIZABLE. Do not remove a
lock on the grounds that SERIALIZABLE covers it — locks turn a conflict into a
wait and a readable 400, which is better than an abort and a retry whenever we
know where the conflict is.

## Still open

- Is the role-level isolation setting still there after Heroku rotates
  credentials? Unknown. This is why we set it in `database.yml` instead.
- Whether the shared screen needs a "Try again" button when a signup runs out
  of retries. It shows the message and reverts the change today. Decide after
  step 5, from what Bugsnag reports.
- Extract `update_bills` out of `MealsController`, so `Metrics/ClassLength`
  stops being raised.
- `CLAUDE.md` says "Four so far" about the ADRs. It is five once 0005 is
  accepted.
