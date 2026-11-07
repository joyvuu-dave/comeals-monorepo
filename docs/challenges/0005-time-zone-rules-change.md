---
id: 5
title: Time zone rules change
area: time
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - spec/models/community_dinner_start_times_spec.rb
---

# Time zone rules change

## The challenge

Dinner times stay right when a government changes its clock rules: the US stops changing clocks, a state moves to another zone, or a country changes its rules with a few weeks' notice.

## The case that breaks it

1. A law ends daylight saving time in the community's state.
2. The server's time zone data is not updated.
3. Every dinner after the change shows a start time one hour off, and calendar feeds send it to people's phones.

The reverse can happen too: a rule changes for past dates, and an old dinner's start time moves.

## Where we stand

- Every dinner time is turned into an instant in the community's zone through `Community#dinner_start_at`. Specs for this include a day the clocks change (`spec/models/community_dinner_start_times_spec.rb`).
- Meals store a date, not an instant, so a rule change moves only how a dinner's time is shown, never which day the dinner is.
- On Linux, Ruby reads the zone data from the operating system. The `tzinfo-data` gem is only installed on Windows and JRuby (`Gemfile`). So on Heroku the data is as new as the Heroku stack.
- The tests once broke when the Mac's zone data said one thing and the test expected another (#266).
- Not checked: how fast Heroku updates its stack's zone data after a rule change.

## Options

1. Install `tzinfo-data` on every platform, and update it like any other gem. Then the zone data is in `Gemfile.lock`, and a rule change is a normal pull request.
2. A spec that fails when the zone data is older than some number of days.
3. Leave it to the stack, and watch for announced rule changes for the community's zone.

## Outside facts

- Linux tzinfo reads `/usr/share/zoneinfo` unless the `tzinfo-data` gem is installed. (checked 2026-11-07: Claude's memory, not the tzinfo docs)

## History

- 2026-11-07: Opened.
