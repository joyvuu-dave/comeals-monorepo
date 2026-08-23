# Plan: configurable meal schedule

Written 2026-08-07. Status: done (2026-08-08). GitHub issue: #53.

Three decisions changed during the build; the sections below keep the
original design for the record, and this list is what actually shipped:

1. **Empty weeks are allowed.** The original rule "no week is empty"
   was wrong: an empty week is how a community skips weeks (meals
   every other week is `[[0], []]`). The real rule is that the cycle
   as a whole must contain at least one day.
2. **The anchor is a visible field, not hidden state.** The form says
   "This schedule starts the week of ___". The week holding that date
   is week 1. This came out of design discussion: naming the start
   week is easier to understand than a "swap which week is next"
   button, and it answers the same question.

   **Reversed on 2026-08-08.** The label read as a start date, but the
   field never started or delayed anything — it only set the phase.
   And the phase is already expressible in the grid: moving a day to
   the other week row shifts it by a week, and the preview shows the
   result. So the field was redundant. Week 1 is now pinned by a fixed
   constant (`MealSchedule::EPOCH`); migration 20260808120000 rotated
   stored rows so generated dates did not change.

3. **There is no regenerate button.** Saving the schedule changes only
   the config. The nightly task keeps ~6 months of meals generated, so
   the new schedule reaches the calendar when generation passes the
   last existing meal. To apply it sooner, the admin deletes upcoming
   rotations (newest first) on the Rotations page and the nightly task
   recreates them under the current schedule. That path was made safe
   instead of building a one-click flow: a rotation refuses destroy if
   any meal is touched (past, closed, reconciled, or has attendees,
   cooks, or guests) or if meals exist after it (a middle gap would
   never refill), an allowed destroy deletes its own meals (no more
   orphans from `dependent: :nullify`), and rotation destroy requires
   a superuser because it now deletes meals (ADR 0004). The Community
   show page explains all of this in one sentence.

## The ask

The community wants to change, in ActiveAdmin, how many meals happen
each week and on which days. Today the schedule is fixed in code.

## What the code does today

The schedule lives in three hard-coded methods on `Community`
(`app/models/community.rb:167-177`):

- `meals_per_rotation` → 12
- `permanent_meal_days` → `[0, 4]` (every Sunday and Thursday)
- `alternating_meal_days` → `[1, 2]` (Monday one week, Tuesday the next)

`Community#create_next_rotation` (`community.rb:199-244`) walks forward
day by day and creates the next rotation's meals. To know whether the
next alternating day is Monday or Tuesday, it queries past meals for
the last Monday-or-Tuesday meal, tracks calendar week numbers, and
flips a variable as it goes. That history-derived state is most of the
method's complexity.

There is also a seed-only copy of the same idea in
`Meal.create_templates` (`meal.rb:253-284`) with the constant
`ALTERNATING_DAYS = [1, 2]`.

## The reframe that makes this simple

"Every Sunday and Thursday, alternating Monday and Tuesday" is not a
special rule. It is a two-week schedule:

- Week A: Sunday, Monday, Thursday
- Week B: Sunday, Tuesday, Thursday
- repeat

So the general model is: **a schedule is a repeating cycle of N weeks,
and each week is a set of days.**

- Every Sunday and Thursday, no alternation → a 1-week cycle.
- This community's schedule → a 2-week cycle.
- Any stranger rhythm → a 3-week (or longer) cycle.

One model covers all of them, and the "alternating" concept disappears
from the code entirely.

## The admin UI

A grid of checkboxes: 7 columns (Sun–Sat), one row per week in the
cycle, an "add a week" button, plus a number field for meals per
rotation. Anyone can read the grid at a glance.

This is why the feature stops feeling convoluted. Building UI for the
current vocabulary ("permanent days" plus "an alternating pair") is
awkward. The grid has no such vocabulary.

Two things make the form trustworthy:

1. **A preview.** Under the grid, render the next ~6 weeks of dates the
   schedule would produce ("Sun Aug 9, Mon Aug 10, Thu Aug 13, Sun
   Aug 16, Tue Aug 18, …"). The admin checks the dates instead of
   reasoning about cycle phase. If the preview is shifted by a week, a
   "swap which week is next" control (really: move the anchor date by
   7 days) fixes it.
2. **Changing the schedule never touches existing meals.** It only
   changes what the next `create_next_rotation` run produces. This
   fits the append-only rules: nothing reconciled or already announced
   can be disturbed.

## The data

Three things on `Community` (columns, not a new table — see
"Why not a separate table" below):

1. `schedule` — the grid. One array of day numbers per week, e.g.
   `[[0, 1, 4], [0, 2, 4]]`. jsonb, or an equivalent flat encoding.
   Validate that there is at least one week and no week is empty.
2. `schedule_anchor_date` — a date known to fall in week 1 of the
   cycle. This replaces all the history-derived phase logic.
3. `meals_per_rotation` — the existing method becomes a column.

## The generator gets simpler

With an anchor date, cycle phase is arithmetic, not history:

```ruby
week_in_cycle = ((date - schedule_anchor_date).to_i / 7) % schedule.length
meal_day = schedule[week_in_cycle].include?(date.wday)
```

`create_next_rotation` becomes: walk forward day by day, skip holidays
exactly as now (`Meal.is_holiday?` is unchanged), take days where the
grid cell is checked, stop at `meals_per_rotation`. The last-meal
query, the `cweek` tracking, and the day-flipping variable all go
away. `Meal.create_templates` and `ALTERNATING_DAYS` are rewritten on
top of the same grid or deleted.

## Authorization

Schedule columns on `Community` mean only a superuser can edit them
(ADR 0004: `Community` writes need a superuser because it holds
`cap`). That is consistent, not accidental: the schedule drives meal
creation, and `Meal` writes already need a superuser. Schedule changes
are rare; the superuser bar is fine.

## Why not a separate `meal_schedules` table

A table would keep a history of schedule changes and could open
editing to plain admins. Neither is needed: the meals themselves are
the durable record of what the schedule produced, and the superuser
bar is right (see above). Columns are less to build. If schedule-change
history ever matters, add the table then.

## Rejected ideas

- **iCalendar RRULEs.** The standard for recurrence, but famously hard
  to build UI for, and the community needs a tiny fraction of that
  power. The week grid is the right-sized subset.
- **Hand-picking every date.** Too much clicking as the only
  mechanism. But a hand-editable preview — generate the proposal, let
  the admin uncheck one date before creating — is a good later
  addition on top of the grid.
- **Configuring the current vocabulary directly** (columns for
  `permanent_meal_days` and `alternating_meal_days`). It works for
  this community but hard-codes "exactly one alternating pair" as the
  only kind of variation, and the UI has to teach that concept. The
  grid is both simpler and more general.

## Migration for the current community

Backfill `schedule = [[0, 1, 4], [0, 2, 4]]`, with week order and
anchor chosen so the next generated rotation continues the existing
alternation. Pick the anchor by looking at the community's last
Monday-or-Tuesday meal — the same lookup the old code did, done once,
in the migration, instead of on every run.

## Loose end, separate from this work

Meal start times are also hard-coded by weekday: 18:00 Sundays, 19:00
otherwise (`meal.rb:141`, `app/services/meal_ical_feed.rb`). The grid
gives a natural home for that later — a time per cell or per column.
Ship day-of-week configuration first; do not fold times into it.

## Done when

- The grid, anchor date, and meals-per-rotation are editable in
  ActiveAdmin by a superuser, with a live preview of upcoming dates.
- `create_next_rotation` reads only the new columns; the hard-coded
  methods and `ALTERNATING_DAYS` are gone.
- A 1-week schedule, the current 2-week schedule, and a 3-week
  schedule all generate correct dates in tests, including holiday
  skipping and phase continuity across rotations.
- The migration reproduces the current schedule exactly: the first
  rotation generated after deploy matches what the old code would have
  created.
