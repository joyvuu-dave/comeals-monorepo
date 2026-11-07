---
id: 6
title: Dates far in the future
area: time
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Dates far in the future

## The challenge

Every part of the app handles any date the database can store, not only dates near the day it was written.

## The case that breaks it

Someone types a date in the year 10000, or 2100 (a year that is not a leap year, though it divides by 4), into a dinner, a reservation or an event. One part of the app reads it with a 4-digit year pattern or a JavaScript `Date` rule that does not hold for it, and the dinner lands on the wrong day or the page fails.

## Where we stand

Not checked. PostgreSQL dates go to the year 5874897. Nobody has listed every place the app reads a date (date inputs, URL paths such as `/calendar/:type/:date`, JSON, calendar feeds) or tested each with a far date.

## Options

1. List every place a date enters the app, and add a spec for each with the dates 2100-02-28, 2100-03-01 and 9999-12-31.
2. Refuse dates outside a set range (say, more than 10 years from today) at every entry point, and test that the refusal is the same everywhere.

## History

- 2026-11-07: Opened.
