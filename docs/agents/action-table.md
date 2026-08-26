# Action table

Every action a person can take in this app, one row each, with one
column for every way that action can enter the system. Each cell names
the spec that proves the action works on that path, or says why the path
does not exist. An **EMPTY** cell is a path that exists and has no spec.
The empty cells are the work list.

Why this file exists: of the bugs found in August 2026, most were not a
wrong answer from a function. They were the same action reaching the
system by a second path that nobody tested (#73, #78), a cache that a
write on another path did not clear (#70, #76, #77), or an input at a
boundary (#60, #74, #79). A test written next to the code shares the
author's blind spot. This table is written against the routes, the admin
resources, and the rake tasks, not against the code, so it shows the
holes the code's author did not see.

## How to read it

The columns are the entry points:

- **API** — `/api/v1/...`, what the SPA calls. Specs in
  `spec/requests/api/v1/`.
- **Admin** — ActiveAdmin at `admin.comeals.com`. Specs in
  `spec/requests/admin/`.
- **Task/job** — rake tasks in `lib/tasks/` and the jobs in `app/jobs/`
  that run them on a schedule. Specs in `spec/tasks/` and `spec/jobs/`.
- **Browser** — Playwright against the real app (`tests/integration/`,
  `tests/e2e/`, `tests/admin/`). Named by test title, since one file
  holds many.

Cell values:

- a file name: that spec covers the action on that path;
- `—`: the path does not exist for this action (no route, no form, no
  task), and that is by design;
- **EMPTY**: the path exists and nothing tests it;
- **THIN**: something tests it, but not the guard or edge that matters,
  and the cell says which.

Model specs (`spec/models/`) and database specs (`spec/db/`) are not
columns. A model guard is shared by every path, so it proves nothing
about whether a given path calls it. A trigger is the last line and is
listed in the notes where it is the only thing on a path.

## How to keep it right

- When you add a route, an admin action, a rake task, or a job, add or
  update the row here in the same change. A row with a new EMPTY cell is
  fine; a missing row is not.
- When you fill an EMPTY cell, replace it with the spec name.
- The bug-hunt skill reads this file. A hunt that finds a bug on a path
  this table calls covered should fix the cell too: the spec was not
  testing what the table claimed.

## Meals: the money path

| Action                                            | API                                                                                            | Admin                                                                                                   | Task/job                                                     | Browser                                              |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------- |
| Sign a resident up                                | `meals_controller_spec` (closed, max, extras, reconciled, idempotent)                          | `attendance_correction_spec` (closed, reconciled, plain-admin refused)                                  | —                                                            | `attendance.spec.js`                                 |
| Remove a resident                                 | `meals_controller_spec` (closed-before-closing rule, reconciled)                               | `attendance_correction_spec`                                                                            | —                                                            | `attendance.spec.js`                                 |
| Change late / vegetarian flags                    | `meals_controller_spec` (one example; reconciled)                                              | — (admin only creates and destroys rows)                                                                | —                                                            | `attendance.spec.js`                                 |
| Add a guest                                       | `meals_controller_spec` (closed, max, unknown resident)                                        | `meal_form_guests_spec` (closed, extras full; the refusal is shown, not a 500)                          | —                                                            | `attendance.spec.js`                                 |
| Remove a guest                                    | `meals_controller_spec` (added-before-closing rule)                                            | `meal_form_guests_spec` (frozen guest refused with a sentence; extra removed)                           | —                                                            | `attendance.spec.js`                                 |
| Set cooks and costs (bills, no_cost)              | `update_bills_spec` (grammar, cap, race with settlement, partial failure)                      | `money_field_rendering_spec`, `reconciled_immutability_spec`, `superuser_authorization_spec`            | —                                                            | `bill-entry.spec.js`                                 |
| Close / reopen a meal                             | `meals_controller_spec` (close sets `closed_at`, reopen clears it and `max`; reconciled; race) | `reconciled_immutability_spec`; `permit_params_smoke_spec` saves `closed`                               | —                                                            | `meal-actions.spec.js` (close, reopen, reload)       |
| Set extras (`max`)                                | `meals_controller_spec` (closed only, below headcount, clear while open; reconciled; race)     | `superuser_authorization_spec` (plain admin refused); `permit_params_smoke_spec`                        | —                                                            | `meal-actions.spec.js`                               |
| Edit the menu description                         | `meals_controller_spec` (one example, under the CSRF heading)                                  | — (`description` is not in `permit_params`)                                                             | —                                                            | `meal-actions.spec.js` (debounce, switch mid-typing) |
| Move a meal to another date                       | —                                                                                              | `meal_move_spec` (old month drops it, new month lists it, against a real cache; reconciled refused)     | —                                                            | —                                                    |
| Change a meal's cap                               | —                                                                                              | — (`cap` is not in `permit_params`; it is set from the community at create and frozen after settlement) | —                                                            | —                                                    |
| Create a meal                                     | —                                                                                              | `permit_params_smoke_spec`                                                                              | `community_create_rotations_spec` (holidays, six months out) | —                                                    |
| Delete a meal                                     | —                                                                                              | `deletion_safeguards_spec` (closed refused, open deleted with signups)                                  | — (rotation delete cascades: `rotation_destroy_spec`)        | —                                                    |
| Read the meal page (cooks, attendance, next/prev) | `stale_meal_form_cache_spec`, `meal_cooks_performance_spec`, `settled_meal_cache_spec`         | `all_pages_spec` (renders), `resident_statement_spec` (line items)                                      | —                                                            | `meal-actions.spec.js`, `navigation` tests           |
| Read the meal history                             | `meals_controller_spec`                                                                        | —                                                                                                       | —                                                            | `history modal` tests                                |

## Settlement and balances

| Action                       | API                                                                        | Admin                                                                                                                                                  | Task/job                                                                                                                          | Browser |
| ---------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | ------- |
| Preview a settlement         | `reconciliations_preview_spec`, `reconciliations_authorization_spec`       | — (the admin "new reconciliation" form has no preview; adding one is a feature, and would add a cell here)                                             | —                                                                                                                                 | —       |
| Settle a period              | `reconciliations_create_spec` (409 on race, refuses today, mails as a job) | `reconciliation_immutability_spec` (refuses empty), `superuser_authorization_spec`; the refresh-and-mail contract is in `settle_and_notify_spec` (#73) | `reconciliations_create_spec` (tasks)                                                                                             | —       |
| Refresh balances             | —                                                                          | —                                                                                                                                                      | `billing_recalculate_spec`, `_correctness_spec`, `_snapshot_spec`; `refresh_balances_job_spec` (writes balances, records the run) | —       |
| Verify the ledger            | —                                                                          | `all_pages_spec` (`ledger_check_runs` renders)                                                                                                         | `ledger_verify_spec`, `ledger_verification_spec`                                                                                  | —       |
| Mail cooks after settlement  | (enqueued by settle)                                                       | (enqueued by settle)                                                                                                                                   | `notify_cooks_job_spec`, `reconciliations_email_spec`                                                                             | —       |
| Mark a settlement paid       | —                                                                          | — (no such action exists yet; listed so nobody adds it without a row)                                                                                  | —                                                                                                                                 | —       |
| Read a resident's statement  | —                                                                          | `resident_statement_spec`, `read_only_token_spec`                                                                                                      | —                                                                                                                                 | —       |
| Read the reconciliation page | —                                                                          | `reconciliation_show_spec`                                                                                                                             | —                                                                                                                                 | —       |

Notes. Every write on this path is also refused below Rails by the
triggers in `settled_meal_triggers_spec`, `settled_balance_triggers_spec`
and `settlement_race_spec`. Those specs are the reason an EMPTY admin
cell above cannot corrupt the ledger; they are not a reason to leave the
cell empty, because a trigger refusal shows the admin a 500, not a
sentence.

## Events and reservations

| Action                                     | API                                                        | Admin                                                                               | Task/job | Browser                  |
| ------------------------------------------ | ---------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------- | ------------------------ |
| Create an event                            | `events_controller_spec` (timed, all-day, no title)        | `permit_params_smoke_spec`, `superuser_authorization_spec`                          | —        | `event lifecycle`        |
| Update an event                            | `events_controller_spec` (missing fields kept, #69)        | `superuser_authorization_spec`                                                      | —        | `event lifecycle`        |
| Delete an event                            | `events_controller_spec`, `high_trust_authorization_spec`  | `superuser_authorization_spec`, `read_only_token_spec`                              | —        | `delete an event`        |
| Create a guest-room reservation            | `guest_room_reservations_controller_spec` (duplicate date) | `permit_params_smoke_spec`; refusal shown: `reservation_forms_spec`                 | —        | `guest room lifecycle`   |
| Update / delete a guest-room reservation   | `..._controller_spec`, `high_trust_authorization_spec`     | `reservation_forms_spec` (move follows on the calendar, booked day refused, delete) | —        | `guest room lifecycle`   |
| Create a common-house reservation          | `common_house_reservations_controller_spec` (overlap)      | `permit_params_smoke_spec`; overlap shown: `reservation_forms_spec`                 | —        | `common house lifecycle` |
| Update / delete a common-house reservation | `..._controller_spec` (bad dates → 400)                    | `reservation_forms_spec` (move, overlap and end-before-start refused, delete)       | —        | `common house lifecycle` |
| Read one                                   | all three controller specs (404)                           | `all_pages_spec`                                                                    | —        | edit-form tests          |

## Residents and units

| Action                                                   | API                                                       | Admin                                                                                    | Task/job                                                                  | Browser                                |
| -------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | -------------------------------------- |
| Create a resident                                        | —                                                         | `permit_params_smoke_spec`, `superuser_authorization_spec` (plain admin may)             | —                                                                         | `tests/admin` (dashboard login only)   |
| Rename a resident                                        | —                                                         | `resident_form_spec` (cooks page and calendar show the new name, real cache)             | —                                                                         | —                                      |
| Retire a resident (`active: false`)                      | —                                                         | `resident_form_spec` (leaves the sign-up list)                                           | —                                                                         | —                                      |
| Change a resident's multiplier or price category by hand | —                                                         | `resident_form_spec` (open and settled attendance snapshots stay)                        | `residents_set_multiplier_spec` (boundaries, settled snapshots untouched) | —                                      |
| Move a resident to another unit                          | —                                                         | `resident_form_spec` (cooks page shows the new unit)                                     | —                                                                         | —                                      |
| Delete a resident                                        | —                                                         | `deletion_safeguards_spec`                                                               | —                                                                         | —                                      |
| Grant / remove the reconciler role                       | —                                                         | `superuser_authorization_spec`                                                           | —                                                                         | —                                      |
| Send a password-reset email                              | `password_reset_spec`, `residents_controller_spec`        | `password_reset_button_spec`                                                             | —                                                                         | `request password reset`               |
| Set a new password                                       | `residents_controller_spec` (blank password is a feature) | —                                                                                        | —                                                                         | `set new password`                     |
| Log in / log out                                         | `sessions_controller_spec`, `residents_controller_spec`   | `admin_smoke_spec`, `admin_logout_spec`, `session_persistence_spec`, `csrf_failure_spec` | —                                                                         | `login` tests, `logout clears cookies` |
| Create a unit                                            | —                                                         | `permit_params_smoke_spec`                                                               | —                                                                         | —                                      |
| Rename a unit                                            | —                                                         | `unit_form_spec` (cooks page and calendar, real cache)                                   | —                                                                         | —                                      |
| Delete a unit                                            | —                                                         | `deletion_safeguards_spec` (inactive residents still block)                              | —                                                                         | —                                      |
| Read hosts / birthdays                                   | `communities_controller_spec`                             | `resident_index_sort_spec`                                                               | —                                                                         | —                                      |
| Subscribe to the iCal feed                               | `residents_ical_spec`, `communities_controller_spec`      | —                                                                                        | —                                                                         | `webcal` tests                         |

## Rotations and the schedule

| Action                                    | API                         | Admin                                                                                                                                       | Task/job                                                                                                  | Browser          |
| ----------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ---------------- |
| Create a rotation                         | —                           | — (no admin form since #78; rotations come from the nightly task)                                                                           | `community_create_rotations_spec`; `ensure_rotations_job_spec` (converges, idle second run, fails loudly) | —                |
| Edit a rotation                           | —                           | — (the form was removed in #78; `rotation_destroy_spec` and `all_pages_spec` pin that no edit or update route exists)                       | —                                                                                                         | —                |
| Delete a rotation                         | —                           | `rotation_destroy_spec` (past meals, holes)                                                                                                 | —                                                                                                         | —                |
| Recolor after delete                      | —                           | (model: `rotation_spec`; push: `live_update_contract_spec`)                                                                                 | —                                                                                                         | —                |
| Read a rotation                           | `rotations_controller_spec` | `all_pages_spec`                                                                                                                            | —                                                                                                         | `rotation modal` |
| Notify cooks of open slots                | —                           | —                                                                                                                                           | `residents_notify_spec` (cap, retry, #74)                                                                 | —                |
| Notify of a new rotation                  | —                           | —                                                                                                                                           | `rotations_notify_new_spec` (7-day window, retry)                                                         | —                |
| Change the week grid / meals per rotation | —                           | `schedule_preview_spec` (preview, save, plain admin refused), `schedule_grid_labels_spec`                                                   | (next nightly run: `community_create_rotations_spec`)                                                     | —                |
| Change dinner start times                 | —                           | `community_form_spec` (form → iCal shows the new time; the calendar grid shows no time by design); DST: `community_dinner_start_times_spec` | —                                                                                                         | —                |
| Change the time zone                      | —                           | `community_form_spec` (iCal TZID moves, wall-clock stays; "today" and the cached chips follow the new zone; unknown zone refused)           | —                                                                                                         | —                |

## Community settings and admin accounts

| Action                                      | API                        | Admin                                                                                                                                                                                           | Task/job                        | Browser |
| ------------------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | ------- |
| Create the community (bootstrap)            | —                          | `bootstrap_guard_spec`, `community_creation_spec`, `community_singleton_spec`                                                                                                                   | —                               | —       |
| Change the cap                              | —                          | `superuser_authorization_spec` (plain admin refused); effect on open meals: `meal_cost_summary_spec` through the model                                                                          | —                               | —       |
| Change child pricing ages                   | —                          | `child_pricing_rule_spec`                                                                                                                                                                       | `residents_set_multiplier_spec` | —       |
| Turn broadcast email on or off              | —                          | — (not a form: `BROADCAST_EMAIL_ENABLED` is an environment variable read in `config/initializers/broadcast_email.rb`; the tasks honor it: `residents_notify_spec`, `rotations_notify_new_spec`) | —                               | —       |
| Create / promote / demote / delete an admin | —                          | `superuser_management_spec` (last superuser survives)                                                                                                                                           | —                               | —       |
| Use the read-only token                     | —                          | `read_only_token_spec`                                                                                                                                                                          | —                               | —       |
| Any write refused for a conflict            | (`retry_on_conflict_spec`) | `conflict_rescue_spec`                                                                                                                                                                          | —                               | —       |

## The list of empty and thin cells

None, as of 2026-08-25. Every path in the table has a spec. When a new
route, admin action, task, or job adds a cell, list it here until its
spec exists.
