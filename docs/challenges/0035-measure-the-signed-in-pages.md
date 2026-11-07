---
id: 35
title: Measure the pages people use
area: quality
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# Measure the pages people use

## The challenge

The speed and accessibility of the calendar and meal pages are measured, not only the sign-in page.

## The case that breaks it

The calendar gets slower with each release (#44 was about its first draw). Lighthouse on production can only see the sign-in page, which scores well, so nobody notices.

## Where we stand

- Lighthouse 13.6.0 on production, 2026-11-07, sign-in page only: performance 95 on a phone and 100 on a desktop; accessibility, best practices and SEO 100. Largest element on screen at 2.8 s on the phone test.
- The signed-in pages were not measured: an agent does not sign in to production with a real password, and the owner decided production never gets a smoke account (#68, 2026-09-21).

## Options

1. Lighthouse against `bin/prod` on the laptop with the seed data, signed in as a seed resident, with the scores written here each time.
2. The same on staging, after a smoke resident is set up there.
3. A Lighthouse run in CI against `bin/prod`, with a minimum score that fails the build.

## History

- 2026-11-07: Opened.
