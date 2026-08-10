# Deploy confidence plan

The goal: a deploy should need zero manual clicking. Every user-reachable
action is tested automatically — it works, it persists, and it looks right —
in both Chromium and WebKit. When `bin/check` is green, shipping is safe.

## Why this plan exists

In August 2026 a community member found that production renders November
2026 with every day under the wrong weekday. The cause was react-big-calendar's
dayjs localizer, which walks the month grid in 24-hour steps; a month that
contains the end of daylight saving time has a 25-hour day, so the grid
shears by one column. The bug had been in production at least since April
2026. No test caught it because the visual goldens only ever showed January —
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

### 1. Calendar month sweep

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

### 2. Any console error fails the test

One hook in the shared e2e and integration helpers. Rendering bugs almost
always log to the console before a person notices them; today those logs
are ignored outside the visual specs.

### 3. Frozen clock for the integration suite

Deterministic screenshots against a real backend need everyone to agree on
the fake date: seed data with fixed dates, Playwright's clock API freezing
the browser, and an env var the test Rails server reads so `community_today`
matches. This is the one design-heavy item; it must land before item 4 so
the action tests can assert rendering, not only persistence.

### 4. Exhaustive action inventory

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

### 5. Ratchets and known gaps

- Vitest coverage thresholds pinned at today's numbers (84% statements,
  77% branches) so they can only rise.
- Tests for `data_store_hosts.js` — 6% covered, and it is the in-flight /
  stale-response cache feeding the reservation forms.

### 6. Post-deploy smoke test

A small Playwright script `bin/deploy` runs against the live site after
switching over: log in, open a meal, open the calendar on a DST month.
Catches the class of bug where the code is fine but the deploy is not
(env vars, asset serving, the things no local test sees).

### 7. Mock fixtures generated from Rails

A rake task renders each serializer with seed data and writes the JSON the
mocked e2e suite serves. A Rails change then updates the mocks in the same
commit, and drift between the mocked suite and the real API becomes
impossible instead of merely checked (today the contract test pins key
names only).

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
