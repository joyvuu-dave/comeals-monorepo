---
id: 8
title: Birthdays on February 29
area: time
status: done
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - spec/models/resident_price_band_spec.rb
---

# Birthdays on February 29

## The challenge

A child born on February 29 changes price on a fixed, written day in years with no February 29.

## The case that breaks it

A child born on 2016-02-29 turns 12 in 2028 on Feb 29, but in 2027 there is no Feb 29. If Ruby and SQL count the day differently, the child is charged one price on a dinner page and another in the settlement.

## Where we stand

- `Resident#age_on` adds the year on March 1 in a year with no February 29, and its comment says so (`app/models/resident.rb`).
- `spec/models/resident_price_band_spec.rb` pins it, and checks that the Ruby rule and the SQL rule (`Resident.adult_on`) agree on every day of a leap year and a non-leap year.

## Options

None needed.

## Decision

Done before this folder existed: a February 29 birthday counts on March 1 in a year with no February 29, in Ruby and SQL alike.

## History

- 2026-11-07: Opened and marked done; the rule and its spec were already in place.
