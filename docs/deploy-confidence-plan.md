# Deploy confidence plan

The goal: a deploy should need zero manual clicking. Every user-reachable
action is tested automatically — it works, it persists, and it looks right —
in both Chromium and WebKit. When `bin/check` is green, shipping is safe.

## Why this plan exists

In August 2026 a community member found that production renders November
2026 with every day under the wrong weekday. The cause was react-big-calendar's
dayjs localizer, which walks the month grid in 24-hour steps; a month that
contains the end of daylight saving time has a 25-hour day, so the grid
shears by one column. The bug had been in production at least since April 2026. No test caught it because the visual goldens only ever showed January —
a month with no DST transition. The fix (bd1b46e, a performance change that
swapped the localizer for date-fns) sat on main, undeployed.

Lessons, each mapped to an item below:

- A rendering bug can live for months in a state no test ever renders.
  So: render every month (item 1), and screenshot real flows (item 3).
- "All tests pass" meant "all tested states pass." So: enumerate every
  action and test each one (item 4).
- The fix existed but had not shipped, and nobody could see what was
  deployed versus what was fixed. So: tagged releases and a visible
  version (item 8).

## Already done

- [x] The e2e suite (visual snapshots included) and the integration suite
      run under WebKit as well as Chromium (a154821). Safari's engine is
      what every iPhone browser uses, and the rendering escapes that
      reached users were Safari-side.

## Worklist

### 1. Calendar month sweep — DONE (3646a15)

The calendar is the most shared surface in the app, and the November bug
would have been caught by rendering more months. A test that walks every
month across a multi-year span (this covers both DST transitions, leap
February, and months starting on every weekday) and asserts, for each:

- the right number of week rows;
- the first cell is the month's true first weekday;
- the day cells are sequential with no repeats;
- no console errors.

Plus visual goldens for a handful of representative months — November
permanently among them.

### 2. Any console error fails the test — DONE (3646a15)

One hook in the shared e2e and integration helpers. Rendering bugs almost
always log to the console before a person notices them; today those logs
are ignored outside the visual specs.

### 3. Frozen clock for the integration suite — DONE (5606761)

Deterministic screenshots against a real backend need everyone to agree on
the fake date: seed data with fixed dates, Playwright's clock API freezing
the browser, and an env var the test Rails server reads so `community_today`
matches. This is the one design-heavy item; it must land before item 4 so
the action tests can assert rendering, not only persistence.

### 4. Exhaustive action inventory — DONE (d35f6bc)

Walk the SPA code and list every action a user can take. Every action gets
an integration test: perform it against real Rails, reload, assert the
database state came back, screenshot that it looks right. Known list so far
(the walk may find more):

- Meal page: attend toggle, late toggle, veg toggle, add/remove guest,
  cook selection, cook cost, no-cost switch, description, extras/max,
  close, reopen, prev/next navigation, history modal, rotation signup.
- Calendar: month navigation, today button, opening each tile type,
  event create/edit/delete, common house reservation create/edit/delete,
  guest room reservation create/edit/delete, the discard gate on every
  dirty modal, webcal subscribe links.
- Session: login, logout, password reset request, password reset via
  token, session expiry.

The seed task grows dedicated meals for the mutating tests so tests stay
independent; lifecycle tests (create, edit, delete) clean up after
themselves. Roughly 30–40 new tests, all doubled across both engines.

### 5. Ratchets and known gaps — DONE (712985b)

- Vitest coverage thresholds pinned at today's numbers (84% statements,
  77% branches) so they can only rise.
- Tests for `data_store_hosts.js` — 6% covered, and it is the in-flight /
  stale-response cache feeding the reservation forms.

### 6. Post-deploy smoke test — DONE (9367389)

A small Playwright script `bin/deploy` runs against the live site after
switching over: log in, open a meal, open the calendar on a DST month.
Catches the class of bug where the code is fine but the deploy is not
(env vars, asset serving, the things no local test sees).

### 7. Mock fixtures generated from Rails — DONE

`rake test:generate_fixtures` seeds the fixture story (meal 42,
Jane/Bob/Alice, January 2026) with pinned ids and a frozen clock, then
captures eight real API responses through the full controller stack —
an ActionDispatch integration session — into tests/fixtures/. Two runs
write identical bytes. bin/check regenerates them and fails on any git
diff, so a Rails change that alters an API response must carry its
fixture change in the same commit. Drift between the mocked suite and
the real API is now impossible, not merely checked.

What the drift had been hiding (found 2026-08-09, fixed here): the
handwritten calendar.json gave tiles titles like "CH: Book Club" that
production never shows; the hosts stub served email addresses where
production serves names and units; the handwritten history.json showed
three tidy rows where the real audit trail has nine, including noisy
"Meal, update" rows from touch audits (tracked as its own issue). The
mocked suite now renders exactly what production renders.

The cost, as predicted: assertion updates across the e2e and unit
suites, and 63 of 92 visual goldens re-recorded (both browsers, both
platforms). MealFormSerializer#residents gained an ORDER BY so the
captured JSON cannot depend on Postgres row order.

Design decisions (approved 2026-08-09):

1. Generate through the real controller stack — an integration session
   hitting the seeded endpoints — not by calling serializers directly.
   Same output as production by construction.
2. Keep today's fixture story (meal 42, Jane/Bob/Alice, January 2026),
   just with the true serializer output. Smallest assertion and golden
   churn.
3. A bin/check step regenerates the fixtures and fails if git status
   shows a change, so a fixture edit always travels in the same commit
   as the Rails change that caused it.

### 8. Release process (the other half of confidence)

Tests gate the tag; the process gates the deploy.

- Every deploy is an annotated git tag with a GitHub Release note in plain
  language: what changed, what you will see, how to undo.
- A designated community member approves a release before it deploys.
- `bin/rollback`: redeploy the previous tag in one command (`bin/deploy`
  already takes a database backup first).
- The release page always shows which tag is live (`/api/v1/version`).

## Order

Items are numbered in build order. 1 and 2 are quick and pay immediately.
3 must precede 4. Items 5–7 are about an hour each and can slot anywhere.
Item 8 is process, not tests, and can proceed in parallel.

The first deploy after items 1–4 land should be the first tagged release,
and its note leads with the November calendar fix.
