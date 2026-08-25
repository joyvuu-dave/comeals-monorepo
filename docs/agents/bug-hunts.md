# Bug hunt log

One entry per run of the `bug-hunt` skill
(`.claude/skills/bug-hunt/SKILL.md`), newest first. Say which hunts ran
and what they found, including "found nothing". The next run reads this
to pick the hunt that has waited longest.

## 2026-08-26 (dead column)

Hunt run: dead column, all the way through. Every column in
`db/structure.sql` counted against non-comment mentions in `app/`,
`lib/`, `config/` and `db/seeds.rb` (the schema annotations in models,
factories and specs were excluded, since they mention every column).
Columns with two or fewer mentions, each with a verdict:

- `admin_users.current_sign_in_ip`, `last_sign_in_ip`, `last_sign_in_at`,
  `remember_created_at`, `encrypted_password`: read and written by
  Devise (`:trackable`, `:rememberable`, `:database_authenticatable` are
  all enabled). Right.
- `keys.identity_id`, `identity_type`: read through
  `belongs_to :identity, polymorphic: true`. Right. Nothing in `app/` or
  `lib/` creates a `keys` row any more (only a factory does); the table
  is read only by the legacy session path, which #42 and #67 already
  cover.
- `mail_deliveries.about_id`, `about_type`, `sent_at`: the polymorphic
  `about` and the record's own stamp. Right.
- `communities.singleton_guard`: read by the unique index, which is its
  whole job. Right.
- `residents.keys_valid_since`: read by `JwtAuth`. Right.

No column is unread, and none of the rarely read ones has a writer that
could be wrong. The rotation columns this hunt would have flagged
(`start_date`, `description`) were dropped by the invariant hunt on
2026-08-25.

Found nothing.

## 2026-08-26 (time)

Hunt run: time, all the way through. Every place a date becomes an
instant or an instant a date, with its zone:

- Community zone, by construction: `Community#dinner_start_at`,
  `Community#today`, `LiveUpdate` (converts timestamps with the
  community zone), the schedule helper (community or draft zone).
- Community zone, only because `ApiController#set_community_timezone`
  wraps the request in `Time.use_zone`: the reservation and event
  params (`ApiController#parse_dates`, `Time.zone.local`), the calendar
  window (`Time.zone.parse(...).beginning_of_day` in
  `CalendarSerializer` and `Community#calendar_cache_version`), and the
  `strftime('%l:%M%P')` times in the event and common-house serializers.
  All API-only paths; the wrapper holds.
- **App zone, wrong: admin.** `ApplicationController` has no zone
  wrapper, so every admin form parses a typed time in Pacific and every
  admin page shows a stored time in Pacific, whatever the community's
  zone. Red spec `spec/requests/admin/admin_zone_spec.rb`: a New York
  community's "18:00" is stored as 18:00 Pacific (a DST-switch day
  included), and a stored 18:00 Eastern shows as 15:00. The one
  community is Pacific today, so nothing is wrong in production; the
  zone form makes it one click away.
- Instants, correct as instants: `closed_at` (compared to `created_at`),
  `keys_valid_since`, `reset_password_sent_at`, `sent_at`, job and
  ledger run stamps, task timing, the preview's `generated_at`
  (explicit UTC).
- Dates only, no zone: `MealSchedule` (epoch weeks, holidays,
  upcoming dates), `DateRangeDescription`, `settleable_by`,
  `Rotation.starting_within`, the reconciliation cutoff.
- Client: every displayed time goes through `toCommunityDayjs` /
  `communityNow` (cookie zone, refreshed from the month payload since
  2026-08-25); a community date becomes a browser-local midnight
  `Date` for display only.

Timestamp columns compared to date columns: none. Timestamps are
compared to timestamps (`closed_at`/`created_at`, event and reservation
ranges against a zoned window) and dates to dates.

DST-switch specs: `community_dinner_start_times_spec`,
`meal_schedule_spec`, and the new admin spec.

Fixed the same day: `ApplicationController#use_community_timezone`, an
`around_action` that wraps every request in the community's zone and
yields plainly before the first community row exists. One place, both
directions (parse and show). The spec stays as a regression test.

## 2026-08-26 (cache)

Hunt run: cache, all the way through. One server cache: the calendar
month (`CommunitiesController#calendar`, one hour, versioned by rows).
Every column the month shows, and what the version sees it through:

- meals: date, closed, max, attendees (bills, attendance and guests
  `touch` the meal) — `meals.updated_at`.
- rotations: color, place_value, first and last meal date —
  `rotations.updated_at` (`set_place_value` bumps it by hand; the recolor
  saves through the model since 2026-08-25).
- events, both reservations: own columns — their `updated_at`.
- residents and units: name, unit name, birthday, and the shortened
  first names (which depend on every resident's name) — their
  `updated_at`.
- today (the chip words) — the date is part of the version.
- **communities: `timezone`** (added to the payload 2026-08-25) — not in
  the version. Red spec `spec/requests/api/v1/calendar_cache_timezone_spec.rb`:
  a zone change told every tab to fetch the month again and the server
  answered from the old entry for up to an hour. Fixed the same day:
  `communities.updated_at` is in the version now.

Callback-skipping writes on those tables: `SetMultipliersJob`
(multiplier), the password reset (token columns),
`rotations:notify_new` (notified_at) — none shown on the month;
`set_place_value` bumps `updated_at`; the settlement's `update_all`
forgets the cached meals itself.

Expiry: an hour. A missed clear lives at most that long.

Client caches (the month in RAM and IndexedDB, the meal page, hosts) were
covered by the frontend-seam hunt the night before.

## 2026-08-26

Hunt run: money, by the skill's definition this time (the 2026-08-24 run
was by hand, before the skill existed).

- Edge list: every edge in the skill has at least one spec (nobody
  attending, one attendee, only children, only guests, zero cost and
  no_cost, capped, multi-cook, a cook who also eats, a sum past
  $9,999.99).
- Property spec, new: `spec/services/settlement_allocate_to_cents_on_random_ledgers_spec.rb` builds 100
  random ledgers in memory (1 to 40 meals; 0 to 3 cooks, some no_cost;
  0 to 12 eaters at multipliers 0, 1, 2; guests; caps on 40% of meals;
  cooks who eat) and checks that each meal's lines cancel within
  `ZERO_SUM_EPSILON`, that the rounded balances sum to exactly zero, are
  whole cents, and are within a cent of the exact amount, and that the
  rounding is deterministic. All 100 hold. `MONEY_PROPERTY_SEED=n` reruns
  one.
- Float grep: no Float on the money path. The `to_f` and `round` calls in
  `app/` are counts, display ratios, JWT times, and elapsed seconds.
- Noted, not a bug: BigDecimal `/` is not exact (50/7 leaves 3e-30 per
  meal); a 40-meal ledger stays about 1e-28 from zero, against an epsilon
  of 1e-6.

Found nothing.

## 2026-08-25 (night)

Hunt run: frontend seam, all the way through. Every API response the SPA
keeps, and what refreshes it:

- Calendar month (RAM and IndexedDB): the month's Pusher channel and the
  two adjacent months' channels; the residents channel (drops every
  cached month and meal); reconnect and the browser's `online` event;
  the midnight timer. Boot serves the IndexedDB copy and fetches again.
- Meal page (IndexedDB per meal): the meal's channel (settlement and
  neighbour changes push it); the residents channel; reconnect.
- Hosts list: the residents channel; reconnect.
- Rotation modal, history modal, "Next Meal": fetched on every open or
  click. Nothing kept.
- Deploy version: the banner polls the manifest.
- Cookies from login: `community_id`, `resident_id` (fixed for a
  session, correct); `username` (a rename leaves "logout OLDNAME" until
  re-login; cosmetic, no spec); **`timezone`: nothing refreshes it.**

Found: after the admin changes the community's time zone, every open
tab keeps the old zone until logout and login. `toCommunityDayjs` shows
every reservation and event time in the old zone, and `communityToday`
and the midnight timer run on it. Three red specs, one per piece of the
fix: the month payload carries `timezone`
(`spec/serializers/calendar_serializer_spec.rb`), the store adopts it
when a month loads (`tests/unit/stores/data_store_timezone.test.js`),
and a zone change pushes the residents channel so open tabs fetch again
(`spec/requests/api/v1/live_update_contract_spec.rb`). Fixed the same
night on the same branch; the specs stay as regression tests.

Every hunt in the skill has now run at least once.

## 2026-08-25 (evening)

Hunt run: lock, all the way through. Every write to bills, meal_residents,
guests, meals, meal_charges and the two balance tables in `app/` and
`lib/` (test tasks excluded), each either locked, refused, or explained:

- API: nine write actions in `Api::V1::MealsController`, all inside
  `with_meal_lock`, which takes the row lock and only then re-reads
  `reconciled?`. Pinned per action by the "racing the mutation endpoints"
  examples; the two create actions had no such example and got one
  (green, so a pin, not a finding).
- Settlement: `FOR UPDATE` on the claimed meals before the compare-and-swap
  `update_all`; `MealCharge.insert_all` and the balances inside the same
  transaction. `settlement_race_spec`.
- Admin, unlocked by design: bills (create/update/destroy, plus
  re-parenting through `meal_id`), attendance rows, the meal form's nested
  guests, and meal edits and deletes. Each waits on the trigger's
  `FOR KEY SHARE` lookups (both `OLD.meal_id` and `NEW.meal_id`) and is
  refused once the meal is claimed; a meal delete's cascade deletes the
  children first, so the same trigger catches it. `settlement_race_spec`,
  `settled_meal_triggers_spec`.
- Not money: `auto_create_rotations` sets `rotation_id` (not a frozen
  column); `ResidentBalance.upsert_all` writes a cache from a snapshot
  read; jobs create new meals or write residents only.

Found nothing.

## 2026-08-25

Hunt run: invariant, all the way through (108 sentences in CLAUDE.md and
the seven ADRs). Rows: `docs/agents/invariant-hunt-2026-08-25.md`.

- Found: a rotation recolored by a delete in another month can be served
  stale for an hour, because `recolor_community` writes with
  `update_column` and the month's version does not move. Red spec
  `spec/requests/api/v1/calendar_cache_recolor_race_spec.rb`.
- Found: `rotations.start_date` keeps the old date after the rotation's
  first meal is deleted or moved. Red spec
  `spec/models/rotation_start_date_spec.rb`.
- Both fixed the same day on the same branch (1af0317): the two columns
  are dropped and derived from the meals; the recolor saves with
  `update!`.
- Six rule gaps with no wrong result today (test tasks passing
  `community:`, seeds reading the app zone, untyped money in `.js`
  stores, ADR 0001's "TS by default", a superuser deleting their own
  account, the login modal outside the discard gate). Listed in the rows
  file for a decision; no specs.
- Found earlier the same day while filling the action table, and fixed
  before this hunt: dates read from `Time.zone.today` outside API
  requests (7ccb527).

All hunts have run once; pick the one that has waited longest.

## 2026-08-24

Hunts run: money (by hand, before the skill existed), cache, time, dead
column.

- Money: `MealLedger`, `Settlement`, `allocate_to_cents`, and the
  settled-child trigger checked against every rule in CLAUDE.md. Found
  nothing.
- Cache: `meal-<id>` was cached and only its own writes cleared it. Red
  spec `spec/requests/api/v1/stale_meal_form_cache_spec.rb`. Fixed by
  removing the cache (#76, 4aaef4d). The calendar month cache has the
  same gap for resident and unit renames and retirements; fixed by
  versioning the entry (#77, 38e2490).
- Time and dead column: `meals.start_time` was built in UTC since
  2018-04-30 and nothing read it. Moved to
  `communities.dinner_start_times` (c1f9dc9).

Not yet run at that time: invariant, lock, frontend seam.
