# Bug hunt log

One entry per run of the `bug-hunt` skill
(`.claude/skills/bug-hunt/SKILL.md`), newest first. Say which hunts ran
and what they found, including "found nothing". The next run reads this
to pick the hunt that has waited longest.

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

Not yet run: invariant, lock, frontend seam.
