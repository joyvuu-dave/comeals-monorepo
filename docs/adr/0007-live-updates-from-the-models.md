# ADR 0007: Live updates from the models, and a versioned calendar cache

- **Status:** Accepted
- **Date:** 2026-08-24
- **Amended:** 2026-10-21: a request from the meal page's sign-up list
  is pushed to its sender too, with a push token (#237). See "The
  sender and the push token".

## Context

The SPA never polls. It shows what it fetched, and it fetches again
when a Pusher message says something is stale. So the server has to
push for every write that changes what a screen shows. An audit on
2026-08-24 (every cache write, every push) found that it did not:

- Only the API pushed the meal page and the calendar. `Meal#trigger_pusher`
  ran from an `after_action` in `MealsController`. A bill, an attendance
  row or a guest written in ActiveAdmin, a meal created by the nightly
  rotation job, a rotation recolored in admin, and a settlement all
  changed rows the screens show and pushed nothing. The calendar
  cache was cleared by some of them and not by others.
- A resident change pushed the residents channel only for the four
  columns the hosts dropdown reads. A birthday added in admin (the
  calendar shows birthdays) or a `vegetarian` or `can_cook` change (the
  meal page shows both) pushed nothing. And only the hosts store
  listened to that channel: a rename never reached a calendar or a meal
  page already on screen.
- A meal page shows the ids of the meals before and after it (the
  arrows). Adding or deleting a meal changed those on the neighbours'
  pages and pushed nothing, so the last meal's "next" arrow stayed
  dead after the nightly job added the next rotation.
- The month-window test in `Community#affected_calendar_keys` used
  Monday-start weeks while the calendar draws Sunday-start weeks, so a
  Sunday that opens the next month's grid (April 26, 2026 is on May's)
  neither cleared nor pushed that month.
- An event spanning three months cleared only its first and last month.
- The calendar cache was cleared by deleting the entry. That cannot
  close this window: a request reads the rows, a write commits and
  deletes the entry, and then the request stores what it read. The
  stale copy then serves everyone for up to an hour, and the push the
  write sent makes it worse — every client refetches and gets the stale
  copy.
- A meal chip's words ("signed up", "attending", "attended") depend on
  today's date, and nothing writes at midnight, so the cached month
  said "signed up" about today's dinner until the hour ran out. The
  client had the same problem with its own copies.
- On the client, a Pusher update for the month on screen adopted a
  prefetch of that month that was still on the wire, and that prefetch
  had read the rows before the change. Two meal fetches could overlap
  (a reconnect and a push), and the older answer could land last.

## Decision

### The models push. A controller only names the sender.

Every model whose rows a screen shows notes itself in `LiveUpdate`
(`app/services/live_update.rb`) from its save and destroy callbacks:
Meal, Bill, MealResident, Guest, Event, CommonHouseReservation,
GuestRoomReservation, Rotation (and `after_remove` for meals dropped
from it), Resident, Unit. Community notes the residents channel when
its time zone changes, because every time on screen moves. `Settlement`
and `Rotation#set_place_value` (both `update_all`) note themselves by
hand. (`SetMultipliersJob` did
too from 2026-09-24 until it was removed on 2026-09-26: a birthday now
moves someone into the adult band with no write at all, so the SPA
refetches its hosts list at midnight instead.) A controller does not
push. `MealsController` sets `Current.socket_id` so the meal-page push
skips the browser that made the change, unless the request carries a
push token (see below).

Every write path therefore pushes the same way: the API, ActiveAdmin,
the nightly job, a settlement, a rake task, the console.

### The sender and the push token (amended 2026-10-21, #237)

Until 2026-10-21 the meal-page push always left out the sender's
socket, because the sender had updated its own screen. That is false
for a request the page gave up on. The page stops waiting after 35
seconds, loads the meal, and the request can still be written after
that load. Then nothing told that page, and it showed the meal without
the change: a person could be charged for a dinner their screen said
they were not signed up for.

So the six requests of the sign-up list (a sign-up, a take-off, Late,
Veg, a guest add, a guest removal) each send a new `push_token`, a
UUID. `MealsController` sets `Current.push_token` from it (`PushToken`
reads it; a malformed one is read as none). `LiveUpdate.meal` collects
the tokens of a batch:

- With a token: the push goes to every screen, the sender's too, and its
  data is `{ message: "meal updated", push_tokens: [...] }`.
- With no token (the meal page's other writes, admin, a task, a page
  loaded before this change): as before, every screen but the sender's
  socket.
- A batch with a token and also a note with no token (a settlement, in
  the same batch) is pushed to every screen with no tokens, so no page
  skips it.

The page keeps the tokens of its own requests (the last 500) and drops
a token when its request ends with no answer from the app, that is, when
the page gave up on it (`sendWithPushToken`,
`data_store_signup_requests.ts`). A push is skipped only when every
token in it is one the page kept. Any other push loads the meal.

- Normal tap: the push names the page's own token, before or after the
  answer, so the page does not load again. No extra load, no flicker.
- A request the page gave up on and that is written later: its token was
  dropped, so the push loads the meal, about a second after the write.
- Two tabs on one device: each tab has its own tokens, so each loads
  the other's changes, as two devices do.
- A full page reload mid-request: the new page has no tokens, so the
  push for the old request loads the meal.
- A push never causes a write, and a load never causes a push, so it
  cannot loop.
- Old open tabs send no token, so their pushes still leave them out.
  They read no data from a push, so a push with tokens loads them as
  any push did.
- Cost: the sender's socket now gets one more Pusher message for each
  of these writes.

### One flush per transaction, after commit.

A request can write many rows (a bills save writes one for each cook it
adds, changes or removes).
`LiveUpdate` collects the notes per open database transaction and
flushes once after the outermost commit — one cache clear per month,
one push per channel — using `ActiveRecord::Base.current_transaction`'s
`after_commit`, which Rails moves to the parent when a savepoint commits
and drops when one rolls back. A rolled-back write pushes nothing. A
note with no transaction open flushes at once.

The flush clears every cache entry itself, and hands each push to
`LivePushJob` (amended 2026-09-15; the flush used to call Pusher from
inside the request). Pusher's client waits up to 5 seconds each to
connect, send and receive, so one stalled push could hold a request for
15 seconds, which is rack-timeout's whole budget, and the person would
see an error for a write that was already in the database. Solid Queue
now makes the HTTP call after the request has answered. The job tries a
failing push three times, a few seconds apart, and then reports it
(`Rails.error.report`), never raises: the write is committed, and a
client that missed a push refetches on its next reconnect. Enqueuing is
a small transaction of its own and can be refused for a conflict, so it
is tried again (`RetryOnConflict`, three tries); a failure that stays is
reported the same way, for the same reason.

The same holds for the cache clear, and for a stronger reason (amended
2026-09-21). The clear is a DELETE on `solid_cache_entries` in the same
SERIALIZABLE session, which Postgres can refuse, and solid_cache's
failsafe does not swallow a serialization failure. The flush runs after
the commit, inside the block that `RetryOnConflict` runs again on a
conflict, for the API's meal writes and for a settlement. So a clear
that raised did not only answer 500: `RetryOnConflict` took it for a
rolled-back write and ran the block again, and the committed write was
made a second time, a guest added twice or a settlement retried against
meals it had already claimed
(`spec/requests/api/v1/live_update_cache_clear_refused_spec.rb`,
`spec/services/settle_and_notify_cache_clear_refused_spec.rb`). Now
nothing in the flush raises: each clear and each push reports its own
failure and goes on. A missed clear shows nothing stale, because the
month entry is keyed by a version read from the rows (next section).
`SettleAndNotify` also runs the settlement's clears after its retry, not
inside it: a step that runs after the commit does not belong in a block
whose retry would settle the period again.

This means live updates need the Solid Queue supervisor running, the
same as the nightly jobs (`docs/runbooks/scheduler-cutover.md`). Since
2026-10-20 the supervisor runs on its own dyno, the worker in the
Procfile, in async mode (the dispatcher, the worker and the scheduler
are threads of its one process); before that it ran inside Puma. In the
test suite the test adapter runs `LivePushJob` inline, so a spec sees
the Pusher call right after the write (`spec/rails_helper.rb`).

### The calendar cache is versioned by its rows, not only deleted.

`Community#calendar_cache_version(start_date, end_date)` is one query:
the row count and newest `updated_at` of every table the month is drawn
from (communities, residents, units, meals — whose children touch them —,
rotations, events, both reservation tables), plus today's date. The controller
reads it before it reads the rows and stores the month under it. A
stale copy stored under an old version is a miss for every later
reader. That is what closes the mid-build window; the delete stays for
writes the version cannot see (`update_all`), and the one-hour expiry
is the last resort. Today's date in the version is what rolls the
chips' words at midnight.

_Changed 2026-10-16: the version also includes the running Heroku
release (`HEROKU_RELEASE_VERSION`). A deploy or a rollback can change
the code that builds the month while no row changes. `bin/deploy` clears
the whole cache, but the Deploy and Rollback workflows do not, so a
month the old code built was served for up to an hour after a release
(`spec/requests/api/v1/calendar_cache_release_spec.rb`)._

### A resident change reaches every screen.

`Resident#note_live_update` pushes the residents channel for any change
except a list of columns no screen shows (email, phone, password and
token columns, timestamps). `Unit` pushes it on a rename. The client
subscribes once, from whichever page loads first, and on an update
drops every cached month and meal (RAM and IndexedDB) and refetches
what is on screen.

### The client drops what a change made untrustworthy.

A Pusher update for the month on screen drops the month's copies and
marks its version before it fetches, so a prefetch of that month still
on the wire drops its answer instead of storing it. Meal fetches carry
a version token, so the newest fetch's answer is the only one that
reaches the screen or the cache. Midnight refetches the month.

The browser loads the Pusher library only after the page's load event,
when the main thread is idle (at most 2 seconds later), so its download
does not slow the first screen (2026-10-24). A push sent before a
channel is confirmed reaches no one, so each confirmation fetches what
the channel covers once more (#112). That holds however late the
library connects.

## Consequences

- A new model that appears on a screen needs two things: its table in
  `calendar_cache_version` (if it is on the calendar) and save/destroy
  callbacks that note `LiveUpdate`. The list at the top of
  `app/serializers/calendar_serializer.rb` names both, and
  `spec/requests/api/v1/live_update_contract_spec.rb` is where its case
  goes. The rule in CLAUDE.md stands: a cache comes with the written
  list of every write that changes it.
- A resident change now makes every open screen refetch once. That is
  a handful of screens and a handful of writes a week.
- The calendar version query runs on every calendar request, cached
  path included. It is index lookups on small tables; the query budget
  in `spec/requests/api/v1/calendar_performance_spec.rb` still holds.
- `Meal#trigger_pusher`, `Meal#socket_id`, the `after_action` and the
  `@skip_pusher` flags in `MealsController` are gone. Nothing outside
  the models decides whether to push.

## Pinned by

- `spec/requests/api/v1/live_update_contract_spec.rb` — every write
  path pushes; one request, one push; a refused write pushes nothing;
  the request answers before Pusher is called.
- `spec/jobs/live_push_job_spec.rb` — the push job's call shape, its
  retries, and the report after the last try.
- `spec/requests/api/v1/calendar_cache_race_spec.rb` — a write that
  lands mid-build cannot leave a stale month.
- `spec/requests/api/v1/calendar_midnight_spec.rb` — the chips' words
  roll at midnight.
- `spec/models/community_spec.rb` — the Sunday that opens the next
  month's grid.
- `tests/unit/stores/live_updates.test.js` — the client half.
- `spec/requests/api/v1/late_write_push_spec.rb` and
  `tests/unit/stores/late_write_push.test.js` — the push token (#237).
