# Option Matrix (Project Context & Intent)

**Purpose**: Capture what this project IS — its nature, audience, constraints, and intent — to determine appropriate SDLC framework application.

**Generated**: 2026-04-11 (from codebase analysis)

---

## Step 1: Project Reality

### What IS This Project?

**Project Description**:

Comeals is a production financial application for a single private co-housing community (~30 residents). It manages communal dinner scheduling, attendance tracking, cooking bill submission, and periodic financial settlement. The billing core is bank-grade: DECIMAL(12,8) precision, BigDecimal in Ruby, largest-remainder allocation at settlement. It is a solo-maintained Rails 8.1 API backend paired with a React/MobX frontend (separate repo). Currently deployed on Heroku; Railway migration in planning. The app is not multi-tenant and has no plans to go multi-community — it serves one community reliably and correctly.

### Audience & Scale

**Who uses this?**
- [x] Small team (2–10 people, known individuals) — ~30 co-housing residents (all known personally)
- [ ] Just me (personal project)
- [ ] Department
- [ ] External customers
- [ ] Large scale

**Audience Characteristics**:
- Technical sophistication: Non-technical (residents are not developers)
- User risk tolerance: Expects stability (financial data; errors affect who owes money)
- Support expectations: Best-effort (solo developer, community members are neighbors)

**Usage Scale**:
- Active users: ~30 residents (daily during meal signup windows, ~3x/week)
- Request volume: Low (tens of requests per meal event, not concurrent)
- Data volume: Small (single community, 3 meals/week, years of history)
- Geographic distribution: Single location (one co-housing community)

### Deployment & Infrastructure

**Deployment Model**:
- [x] Client-server (Rails API + React SPA + PostgreSQL)
- [x] Full-stack application (API + admin UI + background clock process + caching + real-time push)

**Where does this run?**
- [x] Cloud platform (Heroku; migrating to Railway)

**Infrastructure Complexity**:
- Deployment type: Single server (1 Puma worker/thread; appropriate for load)
- Data persistence: Single database (PostgreSQL) + Memcached cache layer
- External dependencies: 4 third-party services (Pusher, MemCachier, Skylight, Gmail SMTP)
- Network topology: Client-server (React SPA → Rails API; ActiveAdmin → Rails app)

### Technical Complexity

**Codebase Characteristics**:
- Size: ~5k–10k LoC (app/ directory; modest but dense with domain logic)
- Languages: Ruby 100% (backend); Rails 8.1 framework
- Architecture: Modular monolith (MVC + admin layer + background worker)
- Team familiarity: Brownfield (established codebase, extensive domain knowledge in CLAUDE.md)

**Technical Risk Factors**:
- [x] Data integrity-critical — financial calculations (billing, reconciliation, settlement) must be exact
- [x] Security-sensitive — resident PII (names, emails, birthdays), financial balances
- [ ] Performance-sensitive (not a scale problem at this size)
- [ ] High concurrency (single-threaded Puma by design)
- [x] Complex business logic — multiplier-weighted cost splitting, capped meals, largest-remainder allocation
- [ ] Integration-heavy (4 external services is manageable)

---

## Step 2: Constraints & Context

### Resources

**Team**:
- Size: 1 developer (solo)
- Experience: Senior (30+ years domain; deep Rails expertise)
- Availability: Part-time / hobby project

**Budget**:
- Development: Zero (volunteer time)
- Infrastructure: Minimal (Heroku free/paid tier → Railway migration reduces cost)
- Timeline: No hard deadlines; improvements are driven by pain points

### Regulatory & Compliance

**Data Sensitivity**:
- [x] User-provided content (email, profile data)
- [x] Personally Identifiable Information (resident names, emails, birthdays)
- [ ] Payment information (no payment processing — settlement is out-of-app money transfer)
- [ ] Protected Health Information
- [ ] Sensitive business data

**Regulatory Requirements**:
- [x] None (private community app, no EU compliance obligations, no financial regulation)

**Contractual Obligations**:
- [x] None (community app, no SLA, no customer contracts)

### Technical Context

**Current State**:
- Current stage: Established (production system, multiple years of data)
- Test coverage: 73.4% line / 72.2% branch (automated, RSpec)
- Documentation: Comprehensive (CLAUDE.md, BILLING_ANALYSIS.md, MODELS.md, multiple workflow docs)
- Deployment automation: CI/CD basic (GitHub Actions lint + test; deploy manual or auto via Heroku git push)

**Technical Debt**:
- Severity: Minor (billing system remediation is complete; two known security gaps remain)
- Type: Security (2 items), Quality (coverage gaps)
- Priority: Should address (security items) / Can wait (coverage gaps)

---

## Step 3: Priorities & Trade-offs

### What Matters Most?

**Priority ranking** (1 = most important, 4 = least important):
1. Quality & security (build it right, avoid issues) — financial correctness is non-negotiable
2. Reliability (handle growth, stay available) — community depends on it for meal planning
3. Cost efficiency (minimize time spent) — solo developer, time is the constraint
4. Speed to delivery — not time-pressured; correctness over speed

**Priority Weights**:

| Criterion | Weight | Rationale |
|-----------|--------|-----------|
| Quality/security | 0.45 | Financial system; errors affect real money and trust |
| Reliability/scale | 0.25 | Small scale but must be dependable for meal planning |
| Cost efficiency | 0.20 | Solo, volunteer; minimize unnecessary work |
| Delivery speed | 0.10 | No competitive pressure; correctness beats speed |
| **TOTAL** | **1.00** | |

### Trade-off Context

**What are you optimizing for?**

Correctness of the financial system above all. This is a real-money application for a community of neighbors. A wrong balance is not an inconvenience — it erodes trust. The codebase reflects this: BigDecimal everywhere, DECIMAL(12,8) in the DB, largest-remainder allocation, bank-grade standards in CLAUDE.md. Secondary priority is dependability for day-to-day meal planning (residents rely on it ~3x/week).

**What are you willing to sacrifice?**

Speed to ship new features. The app is feature-complete for its current purpose. New capabilities (collection workflow improvements, Railway migration) are addressed methodically, not rushed. Test coverage growth is incremental, not all-at-once. No time pressure to add features users haven't asked for.

**What is non-negotiable?**

- Financial correctness: BigDecimal, DECIMAL(12,8), no Float, no denormalized counters
- Audit trail: `audited` gem stays; financial records are append-only
- No breaking the existing API contract (frontend `comeals-ui` is a production system)
- No Co-Authored-By trailers in commits (CLAUDE.md directive)
- Never push to Heroku remotes directly (GitHub origin only)

---

## Step 4: Intent & Decision Context

### Why This Intake Now?

**What triggered this intake?**
- [x] Documenting existing project (never had formal intake)
- [x] Preparing for scale/growth (Railway migration introduces infrastructure changes)
- [ ] Compliance requirement
- [ ] Team expansion
- [ ] Technical pivot

**What decisions need making?**

Near-term decisions:
1. When and how to execute the Heroku → Railway migration (documented in `RAILWAY_MIGRATION_PLAN.md`)
2. Whether to add error tracking (Sentry) before or after migration
3. How to approach the iCal authentication gap (token URL vs. auth endpoint)

Longer-term:
4. Whether to pursue the collection workflow improvements (in-app Venmo/Zelle tracking) or keep collection out-of-app
5. Whether `resident_balances` refresh cadence (daily) is sufficient or should be more frequent

**What's uncertain or controversial?**

- Collection workflow: The COLLECT_APP.md and COLLECTION_WORKFLOW.md document thinking about bringing money movement into the app. Unclear if this is worth the complexity vs. keeping it out-of-app. No pressure to decide now.
- Railway migration: The mechanics are documented; timing and execution sequencing need careful attention to minimize downtime.

**Success criteria for this intake process**:

Clear baseline documentation that captures the system as it exists today — architecture, scale, security gaps, pending work — so that future conversations (or any future contributor) start with shared context rather than needing to reverse-engineer it from the code.

---

## Step 5: Framework Application

### Relevant SDLC Components

**Templates** (applicable to this project):
- [x] Intake (project-intake, solution-profile, option-matrix) — this document set
- [ ] Full requirements templates — not needed; scope is clear and solo
- [ ] Architecture (SAD, ADRs) — optional; MODELS.md and BILLING_ANALYSIS.md serve this role informally
- [x] Test (test-strategy) — worth formalizing incrementally to guide coverage growth
- [ ] Security (threat-model) — overkill for a private community app; TODO.md covers the gaps
- [ ] Deployment (deployment-plan, runbook) — RAILWAY_MIGRATION_PLAN.md serves this role
- [ ] Governance (decision-log, RACI) — not applicable (solo project)

**Commands** (applicable):
- [x] Intake commands — this run
- [x] `/flow-iteration-dual-track` — useful for structured feature work when it arises
- [ ] Quality gates — not needed at this scale/team size
- [ ] Enterprise-specific commands — not applicable

**Agents** (applicable):
- [x] `sdlc:Code Reviewer` — useful for PR-equivalent review before merging changes
- [x] `sdlc:Security Auditor` — useful for addressing the two open TODO security items
- [x] `sdlc:Test Engineer` — useful for incrementally growing test coverage
- [x] `sdlc:Debugger` — useful for production issue investigation
- [ ] Operations specialists — not needed at current scale
- [ ] Enterprise specialists — not applicable

**Process Rigor Level**:
- [x] Moderate (user stories, basic architecture, test plan, runbook)

The informal documentation the project already has (CLAUDE.md, BILLING_ANALYSIS.md, MODELS.md, WORKFLOWS.md) provides moderate-to-full rigor for the financial domain. The gap is lightweight operational readiness (uptime monitoring, error tracking).

### Rationale for Framework Choices

**Why this subset of framework?**

Comeals is a solo-maintained private community app. It doesn't need enterprise process. What it needs is:
1. A clear baseline document (this intake set) for reference
2. Security-focused review for the two open gaps
3. Test coverage improvement guidance
4. Deployment planning support (Railway migration)

The billing system is already rigorously implemented — that's the hardest part, and it's done. The framework should support incremental improvements without imposing overhead that doesn't add value for a solo developer.

**What we're skipping and why:**

- Full requirements templates: The system is feature-complete for its purpose. Requirements are implicit in the codebase and workflow docs.
- Architecture SAD: MODELS.md and BILLING_ANALYSIS.md already capture this well.
- Threat modeling: The two security gaps are known and documented; no need for a full threat model for a private 30-person app.
- RACI / governance: Solo project.
- Enterprise compliance templates: No regulatory requirements.

Will revisit if: the app goes multi-tenant, a second developer joins, or requirements evolve toward a regulated data model.

---

## Step 6: Evolution & Adaptation

### Expected Changes

**How might this project evolve?**
- [x] Platform migration (Railway) — in progress
- [x] Feature improvements in collection/reconciliation workflows — documented, no timeline
- [ ] User base growth — not planned (single community by design)
- [ ] Team expansion — possible (no concrete plans)
- [ ] Commercial/monetization — not planned
- [ ] Compliance requirements — not anticipated

**Adaptation Triggers**:

| Trigger | Framework Change |
|---------|-----------------|
| Second developer joins | Add formal PR review process, lightweight ADRs for significant changes |
| Multi-community support added | Add requirements docs, architecture review (significant scope change) |
| Collection workflow implemented in-app | Add security review (handling money movement references even if not processing payments) |
| Error rate increases or incidents occur | Add formal runbook and incident response process |
| Test coverage drops below 70% | Enforce coverage gate in CI |

**Planned Framework Evolution**:
- Now: Intake baseline (this set)
- 1 month: Security gap closure (iCal auth, host allowlist)
- 2–4 months: Railway migration complete
- Ongoing: Incremental test coverage improvement, workflow enhancements per existing docs
