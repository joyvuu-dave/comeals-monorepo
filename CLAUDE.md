# CLAUDE.md - Comeals Monorepo

## Project Overview

Comeals is a meal management and cost-splitting application for a co-housing community. Residents sign up for communal dinners, volunteer to cook, and the cost is split proportionally among attendees. The system tracks attendance, cooking costs, and financial balances across billing periods (reconciliations).

This is a monorepo containing a Rails 8.1 API backend (Ruby 4.0) and a React 19 + MobX SPA frontend. In production, Rails serves the SPA from `public/` and the API from `/api/v1/`. No Express, no CORS, one Heroku dyno.

## Project Structure

```
├── app/
│   ├── admin/            # ActiveAdmin resource definitions
│   ├── controllers/      # Rails API controllers + FallbackController (SPA serving)
│   ├── frontend/         # React SPA source (Vite root)
│   │   ├── src/          # Components, stores, helpers, styles
│   │   └── index.html    # SPA entry point
│   ├── mailers/
│   ├── models/
│   ├── serializers/
│   └── views/
├── config/               # Rails configuration
├── db/                   # Migrations, schema, seeds
├── lib/                  # Clock process, rake tasks
├── public/               # Static assets + Vite build output (index.html, assets/)
├── spec/                 # RSpec tests (Ruby)
├── tests/                # Frontend tests
│   ├── e2e/              # Playwright E2E tests
│   ├── unit/             # Vitest unit tests
│   ├── fixtures/         # Test data
│   └── helpers/          # Test utilities
├── package.json          # Node dependencies and scripts
├── vite.config.js        # Vite: root=app/frontend, build to public/
├── vitest.config.js      # Vitest: jsdom, tests/unit/**
├── eslint.config.js      # ESLint for frontend source
├── playwright.config.js  # Playwright E2E config
├── Gemfile               # Ruby dependencies
└── bin/deploy            # Single-app Heroku deploy script
```

## Development Environment

```bash
bin/dev                    # Starts Rails (3000) + Vite (3036) + clock via foreman
bundle exec rspec          # Run Ruby tests
npm test                   # Run frontend unit tests (Vitest)
npm run lint               # Run ESLint on frontend source
npm run test:e2e           # Run Playwright E2E tests
npm run build              # Vite build -> public/
bundle exec rails c        # Rails console
```

### Local URLs

- **App (via Vite proxy)**: `http://localhost:3036` — SPA with HMR, API requests proxy to Rails
- **Rails direct**: `http://localhost:3000` — API endpoints, ActiveAdmin
- **ActiveAdmin**: `http://localhost:3036/admin/login` (via Vite proxy) or `http://localhost:3000/admin/login` (direct)
- **Mail inbox**: `http://localhost:3000/letter_opener`

### Key Routes

- `/` — SPA (FallbackController)
- `/api/v1/*` — API endpoints
- `/admin/*` — ActiveAdmin (Devise auth)
- `/.vite/manifest.json` — Vite manifest (FallbackController, for deploy detection)
- `/*` — SPA catch-all (excludes `/api/`, `/admin`, `/letter_opener`)

## Collaboration Style

**Be an opinionated pair programmer.** This is a personal project with one developer. There is no committee to appease. Push back on design choices that are wrong. Propose alternatives when something smells off. Don't hedge with "you could do X or Y" — say which one is right and why.

**Be rigorous.** This codebase should be a textbook example of correct software. No shortcuts. No "good enough for now." If there's a standard way to do something (an RFC, a well-known pattern, a financial industry convention), follow it.

**Err on the side of correctness over convenience.** A slow correct answer beats a fast wrong one. An explicit verbose approach beats a clever implicit one.

## Money Handling Standards

This is the most critical section. Financial calculations in this codebase must meet the same standards a bank or accounting system would use.

### Rules

1. **Never use Float for money.** Not in Ruby, not in SQL, not anywhere. Use `BigDecimal` in Ruby and `NUMERIC`/`DECIMAL` in PostgreSQL. Float arithmetic produces rounding errors (e.g., `0.1 + 0.2 != 0.3`). This is not acceptable for money.

2. **Store monetary values as DECIMAL(12, 8) in the database.** 8 decimal places beyond the dollar. This gives sub-micro-cent precision for intermediate calculations. The only exception is user-input amounts (what a cook spent), which are whole cents — but even those should be stored in DECIMAL columns for type consistency.

3. **Use BigDecimal for all arithmetic in Ruby.** When reading from the database, ensure values are BigDecimal, not Float. When dividing, use `BigDecimal` division with explicit scale: `amount / divisor` where both are BigDecimal.

4. **Round to cents only at settlement/reconciliation time.** During the billing period, all intermediate values (per-unit costs, individual charges, running balances) remain at full precision. Only when generating the final "you owe $X.XX" do we round.

5. **Use largest-remainder allocation** (Hamilton's method) for the final cent rounding at settlement. This is the standard accounting approach for apportioning monetary amounts among multiple parties. It guarantees that rounded balances sum to exactly zero — no residual pennies are silently dropped. Each value is within 1 cent of its exact full-precision amount. Ties are broken by lowest `resident_id` for deterministic, auditable results.

6. **Balances are always derived, never stored as source of truth.** The source of truth is the set of bills + attendance records. Balances are materialized views — computed from source data by a daily rake task. If the balance table is wiped, it can be perfectly reconstructed.

7. **Financial records are append-only / immutable where possible.** Once a meal is reconciled, its bills and attendance cannot change. This is an accounting principle: you don't edit the ledger, you add correcting entries.

8. **No denormalized counters or caches for financial data.** The `counter_culture` gem has been removed entirely. All derived values (costs, counts, multiplier sums) are computed from source data via SQL queries or Ruby enumeration. The only cache is `resident_balances`, refreshed daily by the rake task.

9. **Prevent race conditions by design.** The daily balance computation is a batch job that reads immutable source data and writes results. There's no concurrent write contention. For real-time operations (adding attendees, submitting bills), use database transactions.

10. **All money-related code must have tests.** Every calculation path, every edge case (zero attendees, single attendee, child-only meals, multi-cook meals, capped meals, etc.) must be covered.

### The Money Model

```
INPUT (cook's receipt):     Dollars — $50.00 stored as 50.00000000
                            (User enters whole dollars/cents; stored as DECIMAL(12,8))

INTERMEDIATE (per-unit):    Full precision DECIMAL
                            e.g., 50.00 / 7 = 7.14285714...

STORED (charges/credits):   Full precision DECIMAL(12,8)
                            Each resident's charge for each meal stored at full precision

SETTLEMENT (reconciliation): Rounded to cents using largest-remainder allocation
                             The final "you owe $X.XX" or "you are owed $X.XX"
                             Rounded balances guaranteed to sum to exactly zero
```

## Code Standards

- **No FIXME/TODO hacks in financial code.** If something needs to change, change it or create a tracked issue.
- **No hardcoded IDs.** All queries must use proper scopes (e.g., `Meal.unreconciled`), never hardcoded record IDs.
- **Explicit over implicit.** Name things clearly. `bill.amount` is the cook's actual cost. `bill.effective_amount` accounts for `no_cost` flag.
- **Test edge cases.** Zero multiplier, zero cost, single attendee, no attendees, meal with only children, meal with only guests, etc.
- **Database constraints.** Use NOT NULL, CHECK constraints, and foreign keys. Don't rely on Rails validations alone — the database is the last line of defense.
- **No Co-Authored-By trailers in commits.** Do not add `Co-Authored-By` lines or any other AI attribution metadata to git commit messages. Ever.

## Architecture Decisions

- **Reconciliations are settlement events (with a cutoff date), Rotations are cooking schedules.** These are fully decoupled. A reconciliation sweeps all unreconciled meals up to its cutoff date and can span multiple rotations.
- **Balances computed daily via rake task.** Not real-time. This eliminates drift and race conditions.
- **The `resident_balances` table is a cache.** It can be rebuilt from source data at any time.
- **Vite builds to `public/` with `emptyOutDir: false`.** Critical: Vite must not wipe Rails error pages.
- **FallbackController serves the SPA.** Rails static file middleware doesn't serve dotfile directories, so `.vite/manifest.json` needs a controller action.
- **ActiveAdmin uses path-based routing (`/admin/*`), not subdomains.** Simplifies DNS and eliminates the need for xipio/lvh.me in development.

## Heroku Deployment

- **Single app** (`comeals-backend`) with two buildpacks: Node (index 1) → Ruby (index 2)
- Node buildpack: `npm install` → `npm run build` (Vite output to `public/`)
- Ruby buildpack: `bundle install` → `rake assets:precompile` (Sprockets for ActiveAdmin)
- Deploy: `bin/deploy` handles migration detection, backup, health checks
- **Rake tasks:**
  - `rake billing:recalculate` — run daily to refresh resident balances from source data
  - `rake reconciliations:create` — manual trigger to settle all unreconciled meals
