# Project Intake Form (Existing System)

**Document Type**: Brownfield System Documentation
**Generated**: 2026-04-11
**Source**: Codebase analysis of `/Users/tejo/workspace/comeals-backend`

---

## Metadata

- **Project name**: Comeals
- **Repository**: https://github.com/joyvuu-dave/comeals-backend (backend); https://github.com/joyvuu-dave/comeals-ui (frontend)
- **Current Version**: No explicit semver tag; schema version `2026_04_10_032155`
- **Last Updated**: 2026-04-11 (most recent commit: "Re-enable Strong Parameters and fix two latent admin bugs")
- **Stakeholders**: Solo developer (Dave Riddle); co-housing community residents as end users

---

## System Overview

**Purpose**: Comeals enables a co-housing community to manage communal dinners — residents sign up to attend and volunteer to cook, and the app splits each meal's cost proportionally by attendance weight (adults=2, children=1). Periodic reconciliations settle accumulated balances across residents. A companion admin console manages community data and initiates billing periods.

**Current Status**: Production (live at `comeals.com` / `admin.comeals.com` on Heroku; Railway migration in planning)

**Users**:
- ~30 residents of a single co-housing community (Patches Way), accessing the React SPA
- 1–2 admin users managing the community via ActiveAdmin

**Tech Stack**:
- Language: Ruby 4.0.2
- Framework: Rails 8.1 (API, ActionAdmin, ActionMailer) — component gems only (no unused frameworks)
- Frontend: React/MobX SPA (separate repo: `comeals-ui`) served independently
- Database: PostgreSQL 17 (DECIMAL(12,8) for all monetary columns)
- Caching: Memcached via Dalli / MemCachier
- Real-time: Pusher (WebSocket push after every mutating API call)
- Auth (API): Custom token-based (`keys` table, scrypt hashing)
- Auth (Admin): Devise + scrypt on `admin_users`
- Audit trail: `audited` gem on all financial/sensitive models
- Serialization: `active_model_serializers` 0.10
- Admin UI: ActiveAdmin 3.0 (subdomain routing via `admin.lvh.me`)
- Background scheduling: Rufus::Scheduler (`lib/clock.rb`) run as separate clock process
- APM: Skylight (production only)
- CI/CD: GitHub Actions (lint + test on push/PR to `main`)
- Code quality: Rubocop + Qlty

---

## Problem and Outcomes (Historical)

**Problem Statement**: Co-housing communities host communal dinners several times per week. Tracking who attended, who cooked, and what was spent — then fairly splitting those costs — is a recurring accounting problem that spreadsheets handle poorly at scale. Comeals automates the full lifecycle: meal scheduling, attendance tracking, cost submission, and periodic financial settlement.

**Target Personas**:
1. **Resident**: Signs up for meals, brings guests, occasionally cooks and submits a bill. Views their current balance.
2. **Cook**: Submits grocery receipts after cooking. Balance shows net owed/owed-to.
3. **Community Admin**: Creates reconciliations, sends settlement emails, manages residents, units, and rotations.

**Success Metrics**:
- Residents can sign up for / out of meals without admin involvement
- Cooks can submit bills without admin involvement
- Billing balances are computed correctly (bank-grade precision)
- Settlement emails are sent after each reconciliation period
- Admin console gives full operational visibility

---

## Current Scope and Features

### Core Features (from API routes + models)

**Meal management**:
- List / view meals with date ranges
- Residents sign up and drop from meals (`meal_residents`)
- Guest management (adults and children) per meal per resident
- Meal close/open toggle
- Maximum attendee cap per meal
- Meal description updates

**Billing / financial**:
- Cooks submit grocery bills per meal (`bills`)
- Bills support `no_cost` flag (cook waived reimbursement)
- Cost split: proportional by multiplier (adults=2, children=1)
- Per-community cost cap (`communities.cap`): caps per-multiplier-unit cost
- `resident_balances` table: materialized cache, refreshed daily by `billing:recalculate` rake task

**Reconciliation (settlement)**:
- `Reconciliation` closes a billing period with a cutoff `end_date`
- `assign_meals` sweeps all unreconciled meals (with bills) up to cutoff
- `settlement_balances` computes final per-resident settlement using largest-remainder (Hamilton's method)
- `ReconciliationBalance` stores the per-reconciliation settlement amount
- Settlement email sent to each resident with a link to their itemized bill view

**Cooking rotation**:
- `Rotation` groups ~12 meals for scheduling cooking assignments
- Automated rotation creation (`community:create_rotations` rake task keeps 6 months of meals populated)
- Rotation notification emails sent to residents

**Community utilities**:
- iCal feeds for residents and community
- Birthday listing endpoint
- Event CRUD (community calendar events)
- Guest room reservations
- Common house reservations

**Admin console** (ActiveAdmin):
- Full CRUD for all models
- Reconciliation management + settlement balance display
- Unit balance area
- Read-only admin token for settlement email links

### Recent Additions (last 3 months, from git log)
- Re-enabled Strong Parameters; fixed latent admin bugs
- Added `COLLECT_APP.md` (in-app collection workflow)
- Switched Puma to single-worker mode (no threading races)
- Removed moment.js and npm from backend
- Added admin meal toggle UI
- Added unit balances panel to Reconciliation show page
- Fixed `ReconciliationBalance.persist_balances!` idempotency
- Fixed AMS serializer warnings

### Documented Future Work (TODO.md)
- Authenticate the resident iCal endpoint (currently public with sequential integer IDs)
- Replace `config.hosts.clear` with an explicit hostname allowlist in production

---

## Architecture (Current State)

**Architecture Style**: Modular Monolith (single Rails app serving JSON API + ActiveAdmin UI)

**Component Map**:

| Component | Location | Purpose |
|-----------|----------|---------|
| JSON API | `app/controllers/api/v1/` | Versioned REST endpoints consumed by React SPA |
| Admin UI | `app/admin/` + ActiveAdmin | Community management, reconciliation, billing oversight |
| Models | `app/models/` | Domain logic, validations, financial calculations |
| Serializers | `app/serializers/` | AMS JSON shaping for API responses |
| Mailers | `app/mailers/` | Reconciliation + resident notification emails |
| Background Jobs | `lib/clock.rb` | Rufus::Scheduler process for daily/weekly tasks |
| Rake Tasks | `lib/tasks/` | Billing recalculation, reconciliation, resident/rotation management |

**Data Models** (17 tables):

| Model | Role |
|-------|------|
| `Community` | Top-level container; has `cap` for per-unit cost ceiling |
| `Unit` | Household/apartment within community |
| `Resident` | Community member; has `multiplier` (2=adult, 1=child) and balance |
| `AdminUser` | Devise-authenticated admin |
| `Meal` | Dinner event; has attendees, guests, cooks, reconciliation assignment |
| `MealResident` | Resident attendance join; captures `multiplier` snapshot at signup |
| `Guest` | Non-resident guest brought by a resident |
| `Bill` | Cook's grocery expense; `DECIMAL(12,8)`; supports `no_cost` flag |
| `Rotation` | Cooking schedule grouping ~12 meals |
| `Reconciliation` | Billing period settlement event |
| `ReconciliationBalance` | Per-resident balance for a specific reconciliation |
| `ResidentBalance` | Running balance cache; rebuilt daily |
| `Key` | API authentication tokens |
| `Event` | Community calendar event |
| `GuestRoomReservation` | Guest room booking |
| `CommonHouseReservation` | Common house booking |
| `Audit` | Full audit trail (via `audited` gem) |

**Integration Points**:

| Service | Purpose | Notes |
|---------|---------|-------|
| Pusher | Real-time WebSocket push after every API mutation | Encrypted, external SaaS |
| MemCachier | Memcached for session/page caching | Heroku add-on; migrating to Railway alternative |
| Gmail SMTP | Transactional email delivery | Environment variable configuration |
| Skylight | APM / performance monitoring | Production only |
| Heroku Scheduler | Cron jobs (billing:recalculate, etc.) | Being replaced by Rufus::Scheduler in clock process |

---

## Scale and Performance (Current)

**Current Capacity**: Single-instance Puma (1 worker, 1 thread). Appropriate for one co-housing community (~30 residents).

**Active Users**: ~30 residents; 1–2 admins. Not public-facing. Not multi-tenant in practice (one `Community` record).

**Performance Characteristics**:
- Low traffic (small, known user base)
- Memcached for session caching
- No read replicas or horizontal scaling needed at current scale
- N+1 protection via `goldiloader` gem (auto eager loading)
- Bullet gem (development) for N+1 detection
- Rack::MiniProfiler (development) for request profiling
- Skylight (production) for APM

**Scheduled Background Tasks**:

| Task | Schedule | Purpose |
|------|---------|---------|
| `billing:recalculate` | Daily 3:00am | Refresh `resident_balances` from source data |
| `residents:set_multiplier` | Daily 3:30am | Update resident multipliers by age |
| `community:create_rotations` | Daily 4:00am | Create 6 months of future meals |
| `residents:notify` | Mondays 7:00am | Weekly rotation signup reminders |
| `rotations:notify_new` | Daily 7:15am | Notify residents of newly posted rotations |

---

## Security and Compliance (Current)

**Security Posture**: Baseline (appropriate for a private community app; not public-facing)

**Data Classification**: Internal / Confidential (resident PII: names, emails, birthdays; financial balances)

**Security Controls**:
- API authentication: Custom token per resident (`keys` table, scrypt-hashed)
- Admin authentication: Devise + scrypt (bcrypt alternative)
- Audit trail: Full `audited` gem on financial models
- Encrypted Pusher channel
- Secrets management: Environment variables only (no hardcoded credentials)
- CORS: `rack-cors` configured
- SSL: Heroku enforces HTTPS in production

**Known Security Gaps** (from TODO.md):
1. `GET /api/v1/residents/:id/ical` — unauthenticated endpoint with sequential integer IDs (enumeration risk)
2. `config.hosts.clear` in `config/environments/production.rb` — disables Rails host authorization (DNS rebinding vulnerability); should be replaced with explicit hostname allowlist

**Compliance**:
- No HIPAA, PCI-DSS, GDPR, or SOX requirements (private community app, no payment processing, no EU user data regulations in scope)
- Financial integrity requirements met via DECIMAL precision, audit trail, and largest-remainder settlement

---

## Team and Operations (Current)

**Team Size**: Solo developer (Dave Riddle)

**Development Velocity**: ~128 commits in the past year (2.5 commits/week average)

**Branch Strategy**: Direct commits to `main` with CI gate (GitHub Actions)

**Process Indicators**:
- Linting: Rubocop + Qlty enforced in CI
- Testing: RSpec on every push; 138 tests (124 model + 14 request), 73.4% line coverage
- No formal PR review process (solo project)
- Extensive project documentation (CLAUDE.md, BILLING_ANALYSIS.md, MODELS.md, WORKFLOWS.md, etc.)
- Annotated models with schema comments via `annotaterb`

**Operational Support**:
- APM: Skylight (production)
- Logging: Rails standard logger + stdout (Heroku/Railway)
- Error tracking: None detected beyond Skylight
- On-call: Solo developer

**Deployment** (current / transitioning):
- Current: Heroku (two apps: `comeals-backend`, `comeals-ui`)
- Target: Railway (migration planned, documented in `RAILWAY_MIGRATION_PLAN.md`)
- CI/CD: GitHub Actions → Heroku auto-deploy (assumed); Railway will use `Procfile`

---

## Dependencies and Infrastructure

**Key Production Gems**:

| Gem | Purpose |
|-----|---------|
| `rails` (component gems) 8.1 | Framework |
| `pg` 1.5 | PostgreSQL adapter |
| `puma` 8.0 | Web server (single worker/thread) |
| `activeadmin` 3.0 | Admin UI |
| `active_model_serializers` 0.10 | JSON API serialization |
| `devise` | Admin user auth |
| `audited` | Audit trail |
| `dalli` 3.2 | Memcached client |
| `pusher` | Real-time WebSocket push |
| `goldiloader` | Auto eager loading (N+1 prevention) |
| `icalendar` | iCal feed generation |
| `skylight` | APM (production) |
| `rack-cors` | CORS headers |
| `friendly_id` | Slug-based URL identifiers |
| `scrypt` | Password hashing |
| `oj` | JSON serialization performance |
| `rufus-scheduler` | Background task scheduling (dev/prod clock process) |

**Dev/Test Gems**:
- `rspec-rails`, `factory_bot_rails`, `faker` — testing
- `rubocop` + extensions — linting
- `simplecov` — coverage
- `bullet`, `rack-mini-profiler`, `better_errors` — development utilities
- `bundler-audit` — dependency security scanning

---

## Known Issues and Technical Debt

**Security Gaps** (open, documented in TODO.md):
- iCal endpoint authentication missing
- Host authorization disabled in production

**Technical Debt**:
- Test coverage at 73% (target: higher, especially branch coverage at 72.2%)
- No dedicated error tracking (Sentry or similar)
- `config.hosts.clear` is a workaround that should be addressed

**Architecture Notes**:
- `counter_culture` gem was removed; all counts computed from source data (correct)
- `money-rails` gem removed; BigDecimal used everywhere (correct)
- Billing remediation is complete and validated against production data (see `BILLING_ANALYSIS.md`)

**Planned Work**:
- Heroku → Railway platform migration (documented in `RAILWAY_MIGRATION_PLAN.md`)
- iCal authentication (TODO.md)
- Host allowlist in production config (TODO.md)
- Collection workflow improvements (documented in `COLLECTION_WORKFLOW.md`)
- Reconciliation workflow improvements (documented in `RECONCILIATION_WORKFLOW.md`)

---

## Why This Intake Now?

**Context**: Establishing a formal SDLC baseline for a solo-maintained production application. The billing system recently underwent a full remediation (DECIMAL precision, BigDecimal, largest-remainder settlement). A platform migration (Heroku → Railway) is in planning. The TODO list contains known security gaps that need formal tracking.

**Goals**:
- Document the system comprehensively for future reference and any potential contributors
- Establish baseline before Railway migration introduces infrastructure changes
- Track open security issues as formal work items
- Provide context for iterative improvement cycles

---

## Attachments

- Solution profile: `.aiwg/intake/solution-profile.md`
- Option matrix: `.aiwg/intake/option-matrix.md`
- Key documents: `BILLING_ANALYSIS.md`, `MODELS.md`, `WORKFLOWS.md`, `RAILWAY_MIGRATION_PLAN.md`, `COLLECT_APP.md`, `RECONCILIATION_WORKFLOW.md`, `COLLECTION_WORKFLOW.md`, `SETTLEMENT_PLAN.md`
- Codebase: `/Users/tejo/workspace/comeals-backend`
- Frontend: `/Users/tejo/workspace/comeals-ui`
