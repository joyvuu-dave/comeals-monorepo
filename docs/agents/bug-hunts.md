# Bug hunt log

One entry per run of the `bug-hunt` skill
(`.claude/skills/bug-hunt/SKILL.md`), newest first. Say which hunts ran
and what they found, including "found nothing". The next run reads this
to pick the hunt that has waited longest.

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

Not yet run: frontend seam.

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
