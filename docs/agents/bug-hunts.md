# Bug hunt log

One entry per run of the `bug-hunt` skill
(`.claude/skills/bug-hunt/SKILL.md`), newest first. Say which hunts ran
and what they found, including "found nothing". The next run reads this
to pick the hunt that has waited longest.

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
- Six rule gaps with no wrong result today (test tasks passing
  `community:`, seeds reading the app zone, untyped money in `.js`
  stores, ADR 0001's "TS by default", a superuser deleting their own
  account, the login modal outside the discard gate). Listed in the rows
  file for a decision; no specs.
- Found earlier the same day while filling the action table, and fixed
  before this hunt: dates read from `Time.zone.today` outside API
  requests (7ccb527).

Not yet run: lock, frontend seam.

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
