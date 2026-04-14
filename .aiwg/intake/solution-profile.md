# Solution Profile (Current System)

**Document Type**: Existing System Profile
**Generated**: 2026-04-11

---

## Current Profile

**Profile**: Production (small-scale, single-community, private)

**Selection Rationale**:
- Live system serving real users (co-housing community of ~30 residents)
- Financial data requiring high correctness guarantees (billing, balances, settlements)
- Solo developer — process must be lightweight but rigorous on the financial core
- No regulatory compliance requirements beyond internal correctness standards
- Established codebase with comprehensive domain documentation

---

## Current State Characteristics

### Security

**Posture**: Baseline

**Controls Present**:
- Token-based API authentication (`keys` table, scrypt)
- Devise + scrypt for admin authentication
- Full audit trail via `audited` gem on financial models
- Encrypted Pusher channels
- Secrets via environment variables only
- CORS configured with `rack-cors`
- HTTPS enforced by Heroku (Railway will also enforce)

**Gaps**:
- iCal endpoint (`GET /api/v1/residents/:id/ical`) is public with sequential IDs → enumeration risk
- `config.hosts.clear` in production disables host authorization → DNS rebinding risk
- No dedicated error tracking (Sentry or equivalent)
- No automated dependency security scanning in CI (bundler-audit in Gemfile but not in CI workflow)

**Recommendation**: Address the two documented TODO items before they become incidents. Add bundler-audit to CI. Consider Sentry or similar for production error visibility.

### Reliability

**Current SLOs**: Not formally defined. Single-instance Puma means zero redundancy.

**Availability**: No HA. Heroku Dyno restarts = brief downtime. Acceptable for a private community app.

**Monitoring Maturity**:
- Skylight APM (production) — request timing, N+1 detection
- Rufus::Scheduler logs task results to stdout
- No uptime monitoring, no alerting, no Slack/PagerDuty integration

**Recommendation**: Add uptime monitoring (e.g., Better Uptime, Freshping) for production. Acceptable to remain single-instance at current scale.

### Testing & Quality

**Test Coverage**: 73.4% line coverage, 72.2% branch coverage (SimpleCov, 2026-04-03 run)

**Test Count**: 138 tests (124 model specs + 14 request specs)

**Test Types Present**:
- Unit tests (model specs): comprehensive for financial calculations, billing, reconciliation
- Request specs: API endpoint coverage, including billing edge cases
- Factory Bot + Faker for realistic test data
- RSpec as test framework

**Quality Gates**:
- Rubocop in CI (linting)
- Qlty for code smells (local)
- Bullet (development N+1 detection)
- No SAST in CI

**Gaps**:
- Branch coverage at 72.2% could be higher (target: 80%+)
- No integration tests covering the Pusher push path
- No test for email delivery in reconciliation flow
- Some admin controller paths untested

**Recommendation**: Incrementally increase branch coverage, particularly around reconciliation and billing edge cases. The financial core has strong coverage; gaps are in peripheral features.

### Process Rigor

**SDLC Adoption**: Informal but disciplined. Extensive project documentation (CLAUDE.md, BILLING_ANALYSIS.md, MODELS.md, WORKFLOWS.md) compensates for lack of formal process.

**Code Review**: None (solo project)

**Documentation**: Strong domain documentation. CLAUDE.md enforces financial coding standards (BigDecimal, DECIMAL(12,8), largest-remainder). Workflow docs capture intent behind design decisions.

**Versioning**: No explicit semantic versioning on the backend (no Gemfile version or git tags)

**Recommendation**: Continue the current documentation-heavy approach — it is appropriate for a solo project and is already at a level that would support onboarding. No process overhead changes needed at current scale.

---

## Recommended Profile Adjustments

**Current Profile**: Production / Small-scale private
**No profile change recommended** — the current approach is appropriate.

The system doesn't need enterprise process. What it needs is:
1. Close the two known security gaps (TODO items)
2. Add minimal production observability (uptime monitoring, error tracking)
3. Complete the Railway migration
4. Maintain and grow test coverage incrementally

---

## Improvement Roadmap

### Phase 1 — Immediate (1–2 weeks)

**Security gap closure**:
- [ ] Authenticate iCal endpoint with a hard-to-guess token (replace sequential integer ID in URL)
- [ ] Replace `config.hosts.clear` with explicit hostname allowlist (`comeals.com`, `*.comeals.com`, `admin.comeals.com`)

**Observability**:
- [ ] Add uptime monitoring for production (e.g., Better Uptime free tier or Freshping)
- [ ] Consider Sentry free tier for error tracking

### Phase 2 — Railway Migration (2–4 weeks)

Per `RAILWAY_MIGRATION_PLAN.md`:
- [ ] Provision Railway services (Postgres, Memcached)
- [ ] Practice run with spare domain
- [ ] Production DNS cutover with minimal downtime
- [ ] Validate scheduled tasks run correctly on Railway

### Phase 3 — Quality & Feature Improvements (ongoing)

**Testing**:
- [ ] Increase branch coverage toward 80%+
- [ ] Add email delivery tests for reconciliation mailer
- [ ] Add bundler-audit to CI pipeline

**Workflow improvements** (per workflow docs):
- [ ] Reconciliation workflow: implement improvements documented in `RECONCILIATION_WORKFLOW.md`
- [ ] Collection workflow: implement improvements documented in `COLLECTION_WORKFLOW.md`

---

## Technical Debt Inventory

| Item | Severity | Type | Notes |
|------|---------|------|-------|
| iCal endpoint unauthenticated | High | Security | Sequential integer IDs + public access = enumeration risk |
| `config.hosts.clear` in prod | High | Security | DNS rebinding vulnerability; should be explicit allowlist |
| Branch coverage 72.2% | Medium | Quality | Target 80%+; financial paths are well-covered |
| No error tracking | Medium | Operations | Blind to production exceptions beyond Skylight |
| No uptime monitoring | Low | Operations | Solo project; acceptable risk but cheap to fix |
| No bundler-audit in CI | Low | Security | Gem is present but not wired into CI workflow |
| No explicit semantic versioning | Low | Process | Not blocking anything; useful for future changelog discipline |
