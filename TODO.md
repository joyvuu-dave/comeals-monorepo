# TODO

## Closed, so nobody re-files them

- `config.hosts.clear` is gone from `config/environments/production.rb`. Done 2026-08-16 (`ae11025`): production.rb now sets `config.hosts` to an explicit list (`comeals.com`, `www.comeals.com`, `admin.comeals.com`, `api.comeals.com`, the Heroku hostname, plus `EXTRA_HOSTS` for staging). Rails host authorization is on again, which is what defends against DNS rebinding.

- The unauthenticated resident iCal endpoint (`GET /api/v1/residents/:id/ical`) is a deliberate decision, not a gap. A calendar app cannot send a bearer token, so a feed has to be reachable by URL alone, and the feed shows only a dinner schedule the whole community already sees. See ADR 0002, point 3.
- The shared read-only admin token in reconciliation emails is also deliberate. Its real limits — no expiry, revoked only by rotating the config value, and it travels in a query string — are written down in ADR 0004 under "Not addressed here". The fix is per-resident signed links with an expiry, and that is its own piece of work.
