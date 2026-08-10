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

### 7. Mock fixtures generated from Rails — DONE (286544a)

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

### 8. Release process — now a daily automated deploy (design agreed 2026-08-10)

The original sketch had a person approve each release. The goal has
changed: deploy automatically once a day when everything is green, with
no human in the loop. If the pipeline stops at any step, it stops for
the day and notifies — it never retries on its own and never ships
silently.

The daily job (GitHub Actions, cron at 15:00 UTC — 8am Pacific in
summer, 7am in winter, since Actions cron has no timezone):

1. **Green gate.** Every CI check on the tip of main must have
   completed successfully — the same rule bin/deploy's preflight_ci
   enforces. Nothing to deploy (prod already runs this sha) also stops
   here, quietly. The gate also refuses while the `DEPLOY_HOLD` repo
   variable is set (see rollbacks below) — a hold means a person
   decided production should not follow main until main is fixed.
2. **Release note.** A Claude call turns the commit messages between
   the live sha and the candidate into a plain-language note: what
   changed, what you will see, how to undo. Saved as a draft GitHub
   Release on the candidate sha. Draft means "candidate"; publishing
   it later means "this is live".
3. **Staging rehearsal.** A persistent staging app sits in a Heroku
   pipeline next to production, dynos scaled to zero between runs
   (about $5/month, almost all of it the database). Each run: verify
   the app is still neutered (no clock dyno, mail off, no
   healthchecks key, its own Pusher/Bugsnag) — refuse to continue
   otherwise, because staging holds a copy of real residents' email
   addresses; restore the latest production backup (the database is
   ~5 MB); deploy the candidate; run migrations against today's real
   data. Any release-phase error, boot exception, or deprecation
   warning in the logs stops the day.
4. **Exercise staging.** Run the aggressive smoke against it: log in,
   toggle attendance, open the modals — writes are fine, it is a
   disposable copy. Watch memory and errors for a few minutes. This
   catches crashes and error spew, not slow leaks — those remain
   Bugsnag's and healthchecks' job over days.
5. **Promote, don't rebuild.** `heroku pipelines:promote` ships the
   exact compiled slug staging just ran — production never gets a
   second build that could differ from the one that passed.
6. **Watch production.** The read-only smoke (bin/smoke) plus a few
   minutes of log watching. A failed smoke or 5xx spew triggers
   `heroku rollback` — one command, code only. Rollback can always be
   code-only because migrations are backward-compatible for one
   release, enforced at author time by strong_migrations. The
   pre-deploy database backup stays as the catastrophe option.
7. **Mark it live.** Publish the draft release. `/api/v1/version`
   shows the running sha for cross-checking.

**Manual deploys** (agreed 2026-08-10): one path to production. The
same workflow, triggered by hand (workflow_dispatch), same gates —
manual skips the clock, never the checks. An emergency fix written
under stress is the change most likely to carry the second bug, and
the ~20-minute pipeline is what catches it. A `fast` input may trim
the post-staging soak minutes, never a test. The break-glass
(`DEPLOY_WITHOUT_CI=1` on bin/deploy) stays for the one case where
the pipeline itself is the casualty (CI or Actions down); it must be
loud — typed confirmation, the same notification the pipeline sends,
and a mark left behind (an auto-filed issue) so every use gets looked
at afterward.

**Manual rollbacks** (agreed 2026-08-10): production is downstream of
main, so a raw `heroku rollback` is temporary by construction — the
next 8am run would redeploy the same sha. `rollback.yml`
(workflow_dispatch; inputs: target release, required one-line reason)
does all three parts: Heroku rollback, then the read-only smoke and
an `/api/v1/version` cross-check; edit the GitHub Releases so they
tell the truth (loud "rolled back — reason" note on the bad one, the
live-again one annotated as current); set `DEPLOY_HOLD` with the
reason and file an issue. The hold clears when main is fixed —
usually `git revert`, which is the durable rollback; Heroku rollback
is only the mitigation. Caveat that belongs in the runbook: rolling
back code does not roll back data the bad version wrote — that is a
correcting-entries problem, not a deploy-tooling problem.

Secrets: `HEROKU_API_KEY` and `ANTHROPIC_API_KEY` as environment
secrets in a GitHub environment named `production`, which only the
deploy workflow declares. Notification: GitHub's failure email plus a
dedicated healthchecks.io check the job pings on completion — a
morning where the job never ran also alerts.

Build order:

- [x] strong_migrations gem (2565e9a); it flagged nothing — existing
      migrations are blessed via start_after.
- [x] Heroku pipeline `comeals`: production + comeals-staging, which
      has fresh secrets, placeholder Pusher values, no mail/healthchecks/
      Bugsnag/Skylight/scheduler, and the COMEALS_STAGING code guards
      (a06363c). Parked at zero dynos.
- [x] bin/deploy --yes (5edd972): skips the question, never the gates.
- [x] bin/staging-rehearsal: verify-neuter → fresh prod backup →
      restore → deploy → migrate → log-grep → smoke → park. First
      supervised run passed 2026-08-10, applying the pending schedule
      migrations against a copy of that day's production data. Note:
      the Procfile release phase already runs db:migrate, so promote
      will migrate production automatically.
- [x] Aggressive staging smoke (89fd533): tests/smoke/aggressive.js
      logs in and proves the attendance write path persists, locked to
      targets whose /api/v1/version says staging:true. No stored
      credentials: bin/staging-rehearsal seeds a smoke resident with a
      fresh random password each run. First full pass 2026-08-10.
- [x] deploy.yml (1155ea7): cron + workflow_dispatch with `fast`,
      hold check, green gate, Claude release note (draft release,
      commit-list fallback), rehearsal, promote, watched production
      with guarded auto-rollback, publish, healthchecks ping.
- [x] rollback.yml (537c1e6): Heroku rollback → slug check → smoke →
      release-note marking → `DEPLOY_HOLD` + follow-up issue.
- [x] Break-glass is loud: typed "break glass" phrase, auto-filed
      review issue (or a warning to file one by hand when GitHub
      itself is down).
- [ ] A few supervised runs before trusting it unattended.

## Order

Items are numbered in build order. 1 and 2 are quick and pay immediately.
3 must precede 4. Items 5–7 are about an hour each and can slot anywhere.
Item 8 is process, not tests, and can proceed in parallel.

The first deploy after items 1–4 land should be the first tagged release,
and its note leads with the November calendar fix.
