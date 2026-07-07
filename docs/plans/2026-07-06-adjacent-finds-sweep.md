# Adjacent-Finds Sweep — Execution Plan (2026-07-06)

Works through the eight open issues filed as adjacent finds during the
2026-07-06 money-audit sweep: #18, #19, #20, #21, #23, #25, #26, #27.
(#22 was folded into that sweep; #24 is closed as a duplicate of #21.)

Each issue carries an agent brief comment from triage — **the brief is the
contract**; the issue body is context. This doc holds only the execution
order, the batching, and the status. When every box is ticked and the final
cleanup session has run, this file no longer exists.

**Sequential only.** Never run two worker sessions at once: they share one
checkout, one schema, and overlapping files.

## Operator prompt

Start each fresh session with exactly this, unchanged, until done:

> Read docs/plans/2026-07-06-adjacent-finds-sweep.md and complete exactly one
> session — the first unchecked item in the Session Queue — following the
> Worker Protocol in that doc. Use the /tdd skill for the fix. When the session
> is committed, pushed, and checked off, report and stop. If no unchecked
> sessions remain, just tell me.

## Worker Protocol

1. **Preflight.** Working tree must be clean and on `main`; run `git pull`.
   If dirty, stop and report — do not stash or discard anything.
2. **Claim.** Take the first unchecked session in the queue below. If none
   remain, report that and stop.
3. **Read.** `gh issue view <n> --comments` for the session's issue. The agent
   brief comment is the contract; its acceptance criteria define done.
   Re-verify every claim against the current code before changing anything —
   an earlier session may have moved things. If the issue no longer
   reproduces, close it with a comment explaining why, tick the box with a
   note, commit, push, and stop — that counts as a completed session.
4. **Fix test-first.** Use the /tdd skill: write a failing test that
   reproduces the failure scenario, watch it fail, then make the minimal
   correct fix. Follow CLAUDE.md's money rules — BigDecimal only, database
   constraints as the last line of defense, append-only ledger, edge cases
   tested.
5. **Scope discipline.** Fix only this session's issue. If you discover an
   adjacent problem, file a new GitHub issue (label `needs-triage`) instead of
   widening the diff.
6. **Verify.** `bin/check` must pass completely — the whole suite, not just
   the new tests. Caution: `bin/check` exits 0 even when checks fail, so read
   its output; do not trust the exit code. Known noise until Session 3 lands:
   the intermittent E2E flakes tracked in #21 — rerun a failing E2E test in
   isolation to distinguish flake from regression, and say which it was in
   your report.
7. **Update this doc.** Tick this session's checkbox and add a one-line
   outcome note under it (what changed, anything a later session should know).
8. **Commit.** One commit containing the fix, its tests, and this doc update.
   Include a `Fixes #<n>` line so the push auto-closes the issue. No
   Co-Authored-By or any other AI-attribution trailers — ever.
9. **Push.** `git push origin main`.
10. **Close out.** Add an issue comment with the commit SHA and how the fix is
    tested (`gh issue comment <n>`), and confirm the issue is closed. Report
    what you did and stop — one session per invocation.

## Session Queue

### Phase 1 — Close the live money hole

- [x] **Session 1 — #23: `host_ids=` destroys through callbacks.** One-line
      association change plus specs mirroring the #7 pins. Goes first because
      it is the only open issue where settled financial data can still be
      silently corrupted. Done: added `dependent: :destroy` to `hosts` in
      `meal.rb`; five pins in the meal spec's ids-assignment block (audit row,
      reconciled block, closed block, open meal works, post-close extra can
      back out).

### Phase 2 — Make the harness trustworthy

Every later session reads `bin/check` output; these four make that output
mean something.

- [x] **Session 2 — #20: login loader E2E.** Root cause already diagnosed in
      the brief: the test's delayed token route is shadowed by `mockApi`'s
      instant stub (Playwright matches routes last-registered-first). Fix the
      ordering, audit sibling tests for the same pattern, document the
      convention on the helper. Done: moved the delayed route after `mockApi`
      (was racy, 1-in-10 fail; 10/10 after); audit found no other shadowed
      test — every other spec overrides after the helper; convention
      documented on `mockApi` in `tests/helpers/setup.js`.
- [x] **Session 3 — #21: flake diagnosability and measurement.** Retries with
      trace capture, measured flake rate before/after, explicit waits where
      races are found. Runs after Session 2 so the one deterministic failure
      doesn't pollute the measurements. Done: `retries: 1` +
      `trace: "retain-on-failure"` — a failing attempt now always leaves a
      trace in `test-results/` and a flake shows as "flaky" (suite still
      green) instead of a hard fail; E2E moved to its own port 3037 with
      `reuseExistingServer: false` (before, bin/check silently tested the
      dev server whenever bin/dev was up); `E2E_CPU_THROTTLE` knob added to
      the mock helper for race hunting. No race found: 0 flakes in 13 full
      runs across idle, CPU-stress, CPU-throttle, and dev-server
      environments — all five flake-set tests stable; rates on #21.
- [x] **Session 4 — #27: load rake tasks once per process.** Shared guarded
      loader; drop the per-file `load_tasks` calls; keep the snapshot spec's
      and clock-runner spec's isolated-rake-state patterns working. Done:
      `RakeTasks.ensure_loaded` in `spec/support/rake_tasks.rb`, guarded by
      `task_defined?` on a sentinel task so it reloads after the snapshot
      spec's `Rake::Task.clear`; all nine task specs go through it (the
      snapshot spec keeps its `clear` and calls the helper after);
      `spec/tasks/rake_tasks_loading_spec.rb` pins the one-action invariant
      and the reload-after-clear behavior. Clock-runner spec untouched.
- [x] **Session 5 — #19: admin request specs, multiple authenticated
      requests.** Fix Warden test-mode session persistence under `api_only`,
      or (fallback) document and guard the one-request convention. Placed
      before Session 7 because the admin attendance page's specs will want
      multi-request examples. Done: root cause was middleware order — Devise
      adds `Warden::Manager` via `app_middleware`, so it sat before the
      hand-added session middleware and a test-mode sign_in never reached
      the cookie session; `application.rb` now inserts MethodOverride,
      Cookies, Session, and Flash before `Warden::Manager` (canonical Rails
      order — note this reorders production middleware too, verified by the
      admin smoke specs); `spec/requests/admin/session_persistence_spec.rb`
      pins two GETs after one sign_in and sign_out ending the session.
      Session 7 can use multi-request examples freely.

### Phase 3 — Routing correctness

- [x] **Session 6 — #18: unknown admin-subdomain GETs must 404.** Fold the
      subdomain check and the path-prefix check into one route-level
      constraint on the SPA catch-all; pin both the admin 404 and the
      still-working resident SPA deep links. Done: confirmed a route-level
      lambda constraint replaces the scope's lambda (nothing raised before
      the fix); root and glob now share one `spa_request` lambda checking
      subdomain plus path prefixes; four pins in `routing_spec.rb` (admin
      404, non-admin deep link, `/api/` and `/letter_opener` bypass); the
      reconciliation-immutability "no edit form" workaround example is now a
      direct no-edit-route RoutingError assertion. Session 7 note: unknown
      admin-subdomain GETs now 404, so admin specs can assert RoutingError
      for removed routes directly.

### Phase 4 — Build and harden (order matters)

Both sessions touch the meal write paths and guard concerns; #26's triggers
must be designed against the write paths as #25 leaves them.

- [ ] **Session 7 — #25: admin attendance-correction page.** Per-row
      MealResident add/remove in ActiveAdmin, one audit row per change,
      explicit `ClosedMealAttendanceFreeze` admin exception, reconciled meals
      absolutely refused. The issue body is the spec (design agreed
      2026-07-06); the triage comment lifts the old sequencing hold.
- [ ] **Session 8 — #26: DB trigger backstop + structure.sql switch.**
      Maintainer approved the schema-format change. Triggers mirror
      `ReconciledMealImmutability` and the Meal frozen-column guard;
      `assign_meals`' nil → id `update_all` stays legal. Last because it
      changes the migration workflow and must see the final shape of every
      write path.
- [ ] **Session 9 — Final cleanup.** Verify #18–#27 are all closed
      (`gh issue list --state open`), reopen anything missed, then `git rm`
      this plan doc, commit, push. The closed issues and git history are the
      durable record.

## Sequencing rationale (reference)

File-overlap map that produced the order above:

| Contested code                                             | Issues        | Resolution                  |
| ---------------------------------------------------------- | ------------- | --------------------------- |
| `tests/e2e/*`, `tests/helpers/setup.js`, Playwright config | #20, #21      | sequential; #20 first       |
| `meal.rb`, guard concerns, ActiveAdmin, DB schema          | #23, #25, #26 | sequential; #23 → #25 → #26 |
| spec infrastructure (`spec/support`, rails_helper)         | #19, #27      | low overlap; harness phase  |
| `config/routes.rb`                                         | #18           | isolated                    |

Money first: #23 is the one remaining path that can corrupt settled data, and
it is a one-line fix. Harness next, for the same reason the money sweep went
harness-first: every later session judges itself by `bin/check` output, so
that output has to be trustworthy. The two big builds go last, in dependency
order.
