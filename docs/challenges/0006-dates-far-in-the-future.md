---
id: 6
title: Dates far in the future
area: time
status: done
opened: 2026-11-07
reviewed: 2026-11-15
watches:
  - app/models/calendar_window.rb
  - app/models/calendar_window_validator.rb
  - app/frontend/src/helpers/calendar_window.ts
  - app/models/meal_schedule.rb
---

# Dates far in the future

## The challenge

Every part of the app handles any date the database can store, not only dates near the day it was written.

## The case that breaks it

Someone types a date in the year 10000, or 2100 (a year that is not a leap year, though it divides by 4), into a dinner, a reservation or an event. One part of the app reads it with a 4-digit year pattern or a JavaScript `Date` rule that does not hold for it, and the dinner lands on the wrong day or the page fails.

## Where we stand

As of 2026-11-15.

- A new dinner, event, Common House booking or guest room booking, or a save that moves one, must fall from 10 years before the community's today to 10 years after it, and never after December 31, 9999 (`app/models/calendar_window.rb`, `CalendarWindowValidator` on the four models). The window is counted from today on every save, so it moves with the calendar and never runs out. A save that leaves the day alone is taken, so an old dinner can still be corrected (`spec/models/calendar_window_validator_spec.rb`).
- The API, admin, tasks and the console give the same words, "is more than 10 years from today" (`spec/requests/calendar_window_entry_points_spec.rb`). Birthdays and the settlement cutoff have rules of their own and are not in the window.
- The forms' day pickers offer no day outside the window, and the calendar has no month after December 9999: its Next button is off there, and the month after it is never fetched (`app/frontend/src/helpers/calendar_window.ts`, `tests/unit/components/day_picker_input.test.jsx`, `tests/unit/components/calendar_show.test.jsx`, `tests/unit/stores/calendar_channels.test.js`).
- The pages that show dates work in February 2100 and in December 9999: the calendar, the next dinner, a dinner's cooks and history, the birthdays, and both iCal feeds. February 29, 2100 is refused as a day (`spec/requests/far_future_reads_spec.rb`). A month in the year 10000 is a 400, not an error page.
- `EnsureRotationsJob` makes dinners up to December 31, 9999 and then stops without an error (`MealSchedule#upcoming_dates`, `spec/jobs/ensure_rotations_job_spec.rb`).
- The time zone rules for a far year are today's rules, carried forward by Ruby (TZInfo) and the browser. A change to the rules is challenge 5's case, not this one.
- In the local copy of production from October 2026, every dinner, event and booking is inside the window: the oldest dinner is from July 2017. Birthdays go back to 1900, which is why they are not in it.
- Not handled: a day before the year 100. dayjs reads "0099-05-01" as 1999-05-01 (checked with node on 2026-11-15). Nothing can save such a day now. To show one, someone would have to click the calendar's Previous button about 23,000 times. What the calendar then shows is not checked.

## Options

1. List every place a date enters the app, and add a spec for each with the dates 2100-02-28, 2100-03-01 and 9999-12-31.
2. Refuse dates outside a set range (say, more than 10 years from today) at every entry point, and test that the refusal is the same everywhere.

## Decision

Both, decided by the owner on 2026-11-15. Option 2 with a window that moves with today, so the app never stops working in a later year, and option 1 for the days the window will reach one day: 2100 and the end of 9999, tested by moving the clock.

## History

- 2026-11-07: Opened.
- 2026-11-15: The owner decided: refuse a new or moved dinner, event or booking more than 10 years before or after today; keep working on every day until December 31, 9999, with the calendar we have now; check both the start and the end of a time; take a save that leaves an old day alone; and read any stored day.
- 2026-11-15: Built. Two bugs found on the way: an admin dinner with a day the database cannot store gave an error page, and from July 9999 the nightly rotation job would have failed every night.
