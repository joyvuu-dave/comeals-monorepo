# ADR 0007: Live updates from the models, and a versioned calendar cache

- **Status:** Accepted
- **Date:** 2026-08-24

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
from it), Resident, Unit. `Settlement` and `Rotation#set_place_value`
(both `update_all`) note themselves by hand. A controller does not
push. `MealsController` sets `Current.socket_id` so the meal-page push
skips the browser that made the change.

Every write path therefore pushes the same way: the API, ActiveAdmin,
the nightly job, a settlement, a rake task, the console.

### One flush per transaction, after commit.

A request can write many rows (a bills save writes one per cook).
`LiveUpdate` collects the notes per open database transaction and
flushes once after the outermost commit — one cache clear per month,
one push per channel — using `ActiveRecord::Base.current_transaction`'s
`after_commit`, which Rails moves to the parent when a savepoint commits
and drops when one rolls back. A rolled-back write pushes nothing. A
note with no transaction open flushes at once.

The flush clears every cache entry before the first push, and a push
that fails is reported (`Rails.error.report`), never raised: the write
is committed, and a 500 for a change that is in the database would be
wrong. A client that missed a push refetches on its next reconnect.

### The calendar cache is versioned by its rows, not only deleted.

`Community#calendar_cache_version(start_date, end_date)` is one query:
the row count and newest `updated_at` of every table the month is drawn
from (residents, units, meals — whose children touch them —, rotations,
events, both reservation tables), plus today's date. The controller
reads it before it reads the rows and stores the month under it. A
stale copy stored under an old version is a miss for every later
reader. That is what closes the mid-build window; the delete stays for
writes the version cannot see (`update_all`), and the one-hour expiry
is the last resort. Today's date in the version is what rolls the
chips' words at midnight.

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
  path pushes; one request, one push; a refused write pushes nothing.
- `spec/requests/api/v1/calendar_cache_race_spec.rb` — a write that
  lands mid-build cannot leave a stale month.
- `spec/requests/api/v1/calendar_midnight_spec.rb` — the chips' words
  roll at midnight.
- `spec/models/community_spec.rb` — the Sunday that opens the next
  month's grid.
- `tests/unit/stores/live_updates.test.js` — the client half.
