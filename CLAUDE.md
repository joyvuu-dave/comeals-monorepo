# CLAUDE.md - Comeals Monorepo

## Project Overview

Comeals is a meal management and cost-splitting application for a co-housing community. Residents sign up for communal dinners, volunteer to cook, and the cost is split proportionally among attendees. The system tracks attendance, cooking costs, and financial balances across billing periods (reconciliations).

In production, Rails serves the SPA from `public/` and the API from `/api/v1/`. No Express, no CORS, one Heroku dyno.

**The app serves exactly one community, forever.** The `communities` table can never hold a second row: `singleton_guard` is a constant 0 with a unique index, and `Community#enforce_singleton` refuses a second create. Multi-community support is not a future plan — it is a rejected design. So never scope a query, an index, or a uniqueness rule by `community_id` "for when there are more communities"; `community_id` columns are plain foreign keys to the one row. The `BelongsToTheCommunity` concern fills them in before validation, so never pass `community_id` or `community:` from a form, a controller, a rake task, or a seed. (Factories still set it, so a spec can create a record without creating the community first. Raw SQL and `insert_all` skip the model, so they still need it.) `AdminUser` is the one model that sets its own, because the bootstrap admin exists before the community does. If a global rule looks wrong to you (say, the unique index on `lower(residents.name)` with no community scope), this is why it is right.

## Development Environment

```bash
bin/dev                    # Starts Rails (3000) + Vite (3036) + Solid Queue (bin/jobs) via foreman
bin/prod                   # Builds the production bundle, serves it from Rails alone (3000)
bin/check                  # Full health check: tests, linters, security, freshness
```

### Local URLs

- **App (via Vite proxy)**: `http://localhost:3036` — SPA with HMR, API requests proxy to Rails
- **Rails direct**: `http://localhost:3000` — API endpoints
- **ActiveAdmin**: `http://admin.lvh.me:3000/login` — admin subdomain, served by Rails directly (no Vite proxy)
- **Mail inbox**: `http://localhost:3000/letter_opener`

## Parallel agents and worktrees

Other Claude sessions may be working in sibling worktrees of this repo at the same time. The rules that keep them from colliding (full rulebook: `docs/agents/worktrees.md`):

- **The main checkout belongs to the human.** If you are asked to change code and you are in the main checkout (`comeals-monorepo`), first run `bin/agent-worktree <short-task-name>` and work in the worktree it creates: `../comeals-<task-name>`, branch `agent/<task-name>`. Do not edit files in the main checkout.
- **Your test database is yours alone.** The worktree's `.env` sets `TEST_DB_SUFFIX`, so RSpec, rake, and `bin/check` there use a private database. Run tests freely and in parallel with other sessions.
- **If tests fail on code you did not touch, do not fix that code.** Another worktree's changes cannot be in your worktree, so the failure comes from your branch's base or your own edits. Rebase on `main` and rerun before digging further.
- **Your test servers are yours alone too; only the dev server is shared.** The worktree's `.env` also sets `TEST_PORT_INTEGRATION`, `TEST_PORT_E2E`, and `TEST_PORT_ADMIN_E2E`, and the admin e2e database gets the same suffix as the test database — so the browser suites (integration, e2e, admin e2e) run in every worktree at once and `bin/check` there runs everything. The dev server (3000/3036) keeps fixed ports. If a script still says a port is in use, something is wrong (a leftover server, a shared `.env`): do not kill anything; report which port was taken and which suites did not run.
- **Never migrate the development database from a worktree.** New migrations run against your own test database only (`RAILS_ENV=test rails db:prepare`). `bin/check` knows this: in a worktree, its migration check looks at the test database.
- **Finish = a branch, a report, and a question.** Rebase on `main`, run `bin/check`, commit. Then report: what changed, the branch name, how to view the diff, how to try it — and ask for a yes. If the rebase conflicts in shared files (`Gemfile.lock`, `db/structure.sql`, factories, shared CSS), stop and report the conflict instead of resolving it silently. On the human's explicit yes ("merge it"), and only then: from the main checkout, run `bin/agent-merge <task-name>`. It fast-forward merges, pushes, migrates the development database if the branch added migrations, removes the worktree, and deletes the branch — and it refuses (with instructions) if the checkout is dirty, if `main` has unpushed local commits, or if the branch needs a rebase. A yes covers one branch. Never merge or push without one. The full flow: `docs/agents/worktrees.md`.

## Collaboration Style

**Be an opinionated pair programmer.** This is a personal project with one developer. There is no committee to appease. Push back on design choices that are wrong. Propose an alternative when something looks wrong, even if you cannot yet say exactly why. Don't hedge with "you could do X or Y" — say which one is right and why.

**A suspected bug is not a finding until there is a failing spec.** Write the red spec in a worktree first, then report the spec, not the hunch. A spec proves the bug is real, shows exactly what is wrong, and stays as the regression test after the fix. The `bug-hunt` skill (`.claude/skills/bug-hunt/SKILL.md`) is the checked-in way to look for bugs on purpose.

**Be rigorous.** This codebase should be a textbook example of correct software. No shortcuts. No "good enough for now." If there's a standard way to do something (an RFC, a well-known pattern, a financial industry convention), follow it.

**Err on the side of correctness over convenience.** A slow correct answer beats a fast wrong one. An explicit verbose approach beats a clever implicit one.

## Money Handling Standards

This is the most critical section. Financial calculations in this codebase must meet the same standards a bank or accounting system would use.

### Rules

1. **Never use Float for money.** Not in Ruby, not in SQL, not anywhere. Use `BigDecimal` in Ruby and `NUMERIC`/`DECIMAL` in PostgreSQL. Float arithmetic produces rounding errors (e.g., `0.1 + 0.2 != 0.3`). This is not acceptable for money.

2. **Store monetary values as DECIMAL with 8 decimal places in the database.** 8 decimal places beyond the dollar gives sub-micro-cent precision for intermediate calculations. Single user inputs (a bill's amount, a cap) are DECIMAL(12, 8): one input is capped at $9,999.99, so 4 digits before the point is enough. Columns that hold sums (charges, unit costs, balances) are DECIMAL(16, 8), because nothing caps a sum — a cook's balance over a period can pass $10,000 (issue #60). User-input amounts are whole cents, but even those are stored in DECIMAL columns for type consistency.

3. **Use BigDecimal for all arithmetic in Ruby.** When reading from the database, ensure values are BigDecimal, not Float. When dividing, use `BigDecimal` division with explicit scale: `amount / divisor` where both are BigDecimal.

4. **Round to cents only at settlement/reconciliation time.** During the billing period, all intermediate values (per-unit costs, individual charges, running balances) remain at full precision. Only when generating the final "you owe $X.XX" do we round.

5. **Use largest-remainder allocation** (Hamilton's method) for the final cent rounding at settlement. This is the standard accounting approach for apportioning monetary amounts among multiple parties. It guarantees that rounded balances sum to exactly zero — no residual pennies are silently dropped. Each value is within 1 cent of its exact full-precision amount. Ties are broken by lowest `resident_id` for deterministic, auditable results.

6. **Balances are always derived, never stored as source of truth.** The source of truth is the set of bills + attendance records. Balances are materialized views — computed from source data by a daily rake task. If the balance table is wiped, it can be perfectly reconstructed.

7. **Financial records are append-only / immutable where possible.** Once a meal is reconciled, its bills and attendance cannot change. This is an accounting principle: you don't edit the ledger, you add correcting entries.

8. **No denormalized counters or caches for financial data.** The `counter_culture` gem has been removed entirely. All derived values (costs, counts, multiplier sums) are computed from source data via SQL queries or Ruby enumeration. There are exactly two caches. `resident_balances` is rebuilt daily from source data. The calendar month is cached for one hour in `CommunitiesController#calendar`, the list of every write that clears it is at the top of `app/serializers/calendar_serializer.rb`, and resident and unit changes are covered by a version in the entry (`Community#calendar_cache_version`, #77) because their names can appear in any month. **A cache entry must come with a written list of every write that changes its data, and each of those writes must clear it.** If you cannot write that list, do not cache. This is how #76 happened: the cooks form was cached per meal, only that meal's own writes cleared it, and a renamed or retired resident stayed on the form for a day. Fresh queries are the default. A cache has to show a measured cost before it is added, and the list of clearing writes is part of the change.

9. **Prevent race conditions by design.** The daily balance computation is a batch job that reads immutable source data and writes results. For real-time operations (adding attendees, submitting bills), use database transactions **and take the meal row lock** — `with_meal_lock` in `Api::V1::MealsController`. The lock, not the Puma thread count, is what serializes a request against a running settlement. Any new path that writes bills, attendance, or guests must take it. See `docs/adr/0003-concurrency-on-the-money-path.md`.

10. **All money-related code must have tests.** Every calculation path, every edge case (zero attendees, single attendee, child-only meals, multi-cook meals, capped meals, etc.) must be covered.

11. **The sign convention: positive means the community owes the person.** Set once in `MealLedger` (its "Signs" section); every stored balance and settlement line inherits it. A credit (cooking) is positive, a debit (eating) is negative. **No screen may show the sign to a person.** A minus sign has no fixed meaning for money — bank statements and credit card statements disagree about it — so readers get it backwards. Render every balance through `BalanceDisplayHelper#balance_tag` ("owes $8.00" / "is owed $8.00") and every settlement line through `#charge_amount_tag` ("charged" / "credited"). Never call `number_to_currency` directly on a signed amount in a view. "Signed" means balances and settlement lines, where the sign carries a direction; a bill's `amount` is a receipt cost that can never be negative (database CHECK, model validation, and input grammar all forbid it), so printing it directly is fine. Getting this backwards on screen — telling someone they owe money when they are owed it — is the worst display bug this app can have, so the direction words are pinned by tests (`spec/helpers/balance_display_helper_spec.rb`) that derive the expected words from `MealLedger` itself, not from a copied constant.

### The Money Model

```
INPUT (cook's receipt):     Dollars — $50.00 stored as 50.00000000
                            (User enters whole dollars/cents; stored as DECIMAL(12,8))

INTERMEDIATE (per-unit):    Full precision DECIMAL
                            e.g., 50.00 / 7 = 7.14285714...

STORED (charges/credits):   Full precision DECIMAL(16,8)
                            Each resident's charge for each meal stored at full precision
                            (16, not 12: a charge or balance is a sum, and a sum can
                            pass the $9,999.99 single-bill cap)

SETTLEMENT (reconciliation): Rounded to cents using largest-remainder allocation
                             The final "you owe $X.XX" or "you are owed $X.XX"
                             Rounded balances guaranteed to sum to exactly zero
```

## Code Standards

- **No FIXME/TODO hacks in financial code.** If something needs to change, change it or create a tracked issue.
- **No hardcoded IDs.** All queries must use proper scopes (e.g., `Meal.unreconciled`), never hardcoded record IDs.
- **Explicit over implicit.** Name things clearly. `bill.amount` is the cook's actual cost; `bill.no_cost` marks a cook who spent nothing, and `MealLedger` skips those bills when summing a meal's cost.
- **Test edge cases.** Zero multiplier, zero cost, single attendee, no attendees, meal with only children, meal with only guests, etc.
- **Database constraints.** Use NOT NULL, CHECK constraints, and foreign keys. Don't rely on Rails validations alone. A validation only runs when the write goes through the model, so `update_all`, `delete_all`, a rake task, or psql all skip it. The constraint still holds.
- **No Co-Authored-By trailers in commits.** Do not add `Co-Authored-By` lines or any other AI attribution metadata to git commit messages. Ever.

## Architecture Decisions

- **Reconciliations are settlement events (with a cutoff date), Rotations are cooking schedules.** These are fully decoupled. A reconciliation sweeps all unreconciled meals up to its cutoff date and can span multiple rotations.
- **Balances computed daily via rake task.** Not real-time. This eliminates drift and race conditions.
- **The `resident_balances` table is a cache.** It can be rebuilt from source data at any time.
- **Every wall-clock time is a community setting, read in the community's zone.** Dinner start times live in `communities.dinner_start_times` (seven `"HH:MM"` strings, Sunday first, default 19:00) and become instants only through `Community#dinner_start_at(date)`, which uses `ActiveSupport::TimeZone[timezone].local(...)`. Never build a time with `Date#to_datetime + N.hours` — that is UTC, and it made every meal's start time noon Pacific from 2018-04-30 until 2026-08-24 (c1f9dc9) without anyone noticing, because nothing read the column. Never use `Time.now` or `Date.today` either; use `Time.current` and `Date.current` in the community zone. Meals have no start-time column and must not get one back. Every spec that turns a date into an instant must include a DST-switch day (`spec/models/community_dinner_start_times_spec.rb` shows how).
- **The production cache is solid_cache, in the primary database.** Entries live in `solid_cache_entries` alongside everything else. The solid_cache installer assumes a second "cache" database and generates `db/cache_schema.rb` plus a `database.yml` entry — we do not use that layout, because the whole database is about 33 MB and a second one would be cost and moving parts for nothing. Leaving `database:` out of `config/solid_cache.yml` is what makes solid_cache use the primary connection, so the table is an ordinary migration in the ordinary schema. This replaced memcached (MemCachier via dalli), which forced a `dalli ~> 3.2` pin because MemCachier needs SASL and dalli 5 dropped it. One gotcha: `Rack::Attack.reset!` no longer works, because it clears counters with `delete_matched` and solid_cache cannot match keys by pattern — use `Rails.cache.clear`. A second one: specs must build stores with `build_solid_cache_store` (`spec/support/solid_cache.rb`), never `SolidCache::Store.new`. The default store trims old entries on a background thread, and that thread deadlocks against the connection RSpec pins to the running example.
- **API JSON is built by Alba (`app/serializers`), not ActiveModelSerializers.** AMS 0.10 is no longer developed (its own README says so), so it was replaced on 2026-08-21. A serializer is a class that includes `Alba::Resource`. A method with the same name as an attribute wins over the model's method, and Alba calls it with the record as the one argument: `def title(meal)`. Extra inputs go in `params:` (`CalendarSerializer.new(community, params: { start_date: ... })`). Nothing is implicit: `render json: meals` would call `to_json` on the records and leak every column, so every render names its serializer (`render json: MealSerializer.new(@meal)`), and every association names its serializer with `resource:`. Settings (Oj Rails-mode encoder, symbol keys, no inference) and their reasons: `config/initializers/alba.rb`.
- **Vite builds to `public/` with `emptyOutDir: false`.** Critical: Vite must not wipe Rails error pages.
- **FallbackController serves the SPA, and index.html stays in `public/`.** One build layout for every path: `config.public_file_server.index_name` names a file that never exists, so the static server never resolves "/" to index.html and the router's subdomain constraints stay in charge — FallbackController is the only thing that serves it. (The build used to move index.html to `app/frontend/dist/`, which gave the repo two layouts, #52.) Rails static file middleware doesn't serve dotfile directories, so `.vite/manifest.json` needs a controller action.
- **ActiveAdmin uses subdomain routing (`admin.comeals.com` in prod, `admin.lvh.me:3000` in dev), not paths.** Restored in 30e4a0e after a path-based experiment. Admin is served by Rails directly — the Vite proxy only handles `/api`. The SPA catch-all carries the subdomain check in its own route-level constraint because Rails replaces a scope's lambda constraint instead of merging it (#18).
- **Puma runs 1 thread and 0 workers for throughput reasons, not safety.** It does not protect the money code and never did — `reconciliations:create` is a manual rake task in its own dyno, so a settlement already commits mid-request today. The real protection is `SELECT ... FOR UPDATE` on the meal row, the compare-and-swap in `Settlement#assign_meals`, and the immutability triggers. ActiveAdmin still writes bills and attendance without the meal lock, but that no longer corrupts the ledger: `assign_meals` takes `FOR UPDATE` before claiming, and **both** of the child-write trigger's lookups — `OLD.meal_id` and `NEW.meal_id` — are unconditional `FOR KEY SHARE` reads (`20260727120000`), so an unlocked write waits for a running settlement and is then refused. **All three pieces are required.** The settlement lock and the trigger were each tested alone and neither works. Locking only `NEW.meal_id` leaves deletes and re-parenting free to run, which silently drops a row a reconciliation already counted — a DELETE takes no foreign-key lock on the parent, so nothing else makes it wait. Do not make either lookup conditional again; a `WHERE ... AND reconciliation_id IS NOT NULL` matches no row on an open meal and so takes no lock. Pinned by `spec/db/settlement_race_spec.rb`. Making one transaction `SERIALIZABLE` buys nothing — Postgres SSI only detects conflicts between transactions that are all `SERIALIZABLE`. That is why the whole app runs at `SERIALIZABLE` since 2026-08-02: the `variables:` block in `config/database.yml` sets it per session, `RetryOnConflict` retries the API's meal writes, and admin shows a "try again" message (`docs/adr/0005-serializable-by-default.md`, Accepted). The locks and triggers stay — a lock turns a conflict into a wait and a readable 400, which is better than an abort and a retry wherever we know where the conflict is. Full record and the verified experiments: `docs/adr/0003-concurrency-on-the-money-path.md` (#43).
- **Deletion policy: refuse harmful deletes, allow mistake cleanup.** Units with residents, residents with ledger rows (bills, attendance, guests, settled balances), and closed or reconciled meals all refuse destroy at the model level. Database foreign keys backstop paths that skip callbacks. Admin destroy is enabled and shows the refusal reason. Retire a resident with the `active` flag; reopen a meal that never happened to delete it. **Units have no `active` flag** — only `residents` has that column. A unit is either empty, and can be deleted, or it still has residents, and the way to retire it is to retire those residents. Destroy guards on Meal and Reconciliation must stay `prepend: true` — the dependent cascades run first otherwise, and inside an enclosing transaction the swallowed inner rollback leaves partial deletes (#26).
- **The calendar's modal forms (Guest Room, Common House, Event) are drafts with a Create/Update button, permanently — never make them real-time.** A reservation is one compound fact (person, day, times); mid-edit states are wrong on purpose, the server checks conflicts, and other people watch this calendar live. Dismissing a dirty form (click outside, Escape, the X) asks "Discard your changes?" through the gate in `calendar/show.jsx`; a clean form closes silently. Every modal form must report through `useDirtyReport` and a `setDirty` prop, or dismissal silently discards its changes. Full record: `docs/adr/0006-draft-modals-and-the-discard-gate.md`.
- **Admin authorization has three levels, split at the money path.** A read-only token reads an allowlist and writes nothing; a plain admin reads everything and writes everything except the ledger; a superuser does anything. `SuperuserAdapter` holds both rules. Writing Bill, Guest, Meal, MealResident, Reconciliation, or either balance table needs a superuser, and so does AdminUser (it grants the flag) and Community (it holds `cap`). Residents, units, events, rotations and reservations are open to any admin — attendance snapshots its own `meal_residents.multiplier`, so editing a resident never reaches back into a settled meal. Two traps. **ActiveAdmin authorizes inside `resource` and `build_resource`, not in a `before_action`** — a hand-written action that loads its own records is unauthorized until it calls `authorize!` itself, which is how `meal_resident.rb` went unguarded. And **the read-only token is read-only by construction, not because of the account behind it**: the adapter refuses writes on any token request, so pointing `READ_ONLY_ADMIN_ID` at a superuser cannot widen the emailed links. A community must always keep one superuser — model guards, a database trigger (`20260728120000`), and a controller rule against self-demotion. Full record: `docs/adr/0004-admin-authorization.md`, which supersedes points 4 and 5 of ADR 0002.

## Heroku Deployment

- **Single app** (`comeals-monorepo`) with two buildpacks: Node (index 1) → Ruby (index 2)
- Node buildpack: `npm install` → `npm run build` (Vite output to `public/`)
- Ruby buildpack: `bundle install` → `rake assets:precompile` (Sprockets for ActiveAdmin)
- Deploy: `bin/deploy` handles migration detection, backup, health checks
- **Rake tasks:**
  - `rake billing:recalculate` — run daily to refresh resident balances from source data
  - `rake ledger:verify` — run daily to check every settled balance against its source data. Records every run, pass or fail, in `ledger_check_runs`. See `docs/money-path-observability.md`.
  - `rake reconciliations:create` — manual trigger to settle all unreconciled meals
- **Job monitoring:** scheduled tasks wrap their body in `Healthcheck.monitor` (`app/services/healthcheck.rb`), which pings healthchecks.io on success or failure. Pings are off unless `HEALTHCHECKS_PING_KEY` is set (production only). A job that stops running entirely triggers a "check is late" email from healthchecks.io.
- **Site monitoring:** Better Stack (uptime.betterstack.com, team t586972) checks `https://comeals.com` and `https://comeals.com/api/v1/version` every 3 minutes from four regions, and alerts by email when a keyword is missing from the response (`<title>Comeals</title>`, `"version"`). The public status page is `https://status.comeals.com` (a CNAME at DNSimple to `statuspage.betteruptime.com`). Phone-call alerts need a paid Better Stack seat; the free plan alerts by email only. This replaced a GitHub Actions cron workflow (`site-up.yml`, removed 2026-08-22): GitHub delays and drops scheduled runs, so the "every 5 minutes" workflow actually ran every 20–100 minutes, and its healthchecks.io check fired false "late" alerts.

## Agent skills

### Issue tracker

GitHub Issues at `joyvuu-dave/comeals-monorepo`, accessed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) — defaults, no aliases. See `docs/agents/triage-labels.md`.

### Domain docs

Architecture decisions live in `docs/adr/`. See `docs/agents/domain.md`.
