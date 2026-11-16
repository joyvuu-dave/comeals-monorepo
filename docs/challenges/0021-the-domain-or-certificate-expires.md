---
id: 21
title: The domain or its certificate expires
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-16
watches:
  - bin/lib/certificate_check.rb
---

# The domain or its certificate expires

## The challenge

comeals.com keeps working for as long as the community uses it, even if the person who registered it is not around.

## The case that breaks it

The card on file for the domain expires. The renewal fails, the emails about it go to an address nobody reads, and one day comeals.com stops resolving. The app, the emailed links, and every calendar feed stop working at once.

## Where we stand

- DNS is at DNSimple. `status.comeals.com` is a CNAME there (AGENTS.md, site monitoring).
- Better Stack checks `https://comeals.com` every 3 minutes, so an outage is noticed. Its SSL/TLS verification is on, so it alerts once the `comeals.com` certificate has run out or is wrong. It does not warn before the certificate or the domain runs out: on the free plan those settings are locked. (checked 2026-11-16, in the monitor's settings: "Upgrade your account to check for SSL expiration", and the same for domain expiration)
- The certificates are Let's Encrypt certificates from Heroku's Automatic Certificate Management, one for each of `comeals.com`, `www.comeals.com`, `admin.comeals.com` and `api.comeals.com`. Each lasts 90 days, and Heroku renews it about 30 days before it runs out. (checked 2026-11-16: `heroku certs -a comeals-monorepo` listed all four as ACM and trusted, running out between 2026-12-16 and 2027-01-12)
- `bin/deploy` and `bin/watch-deploy` read each hostname's certificate and fail when one runs out in fewer than 21 days or is not trusted for its name (`bin/lib/certificate_check.rb`, #297). They run only when someone deploys, so weeks can pass with no check. What to do when one fails: `docs/runbooks/undo-a-deploy.md`, "Certificates".
- Not checked: the domain's expiry date, whether it renews by itself, which card pays, and who gets the renewal emails.

## Options

1. Write those facts here, with dates.
2. Renew the domain for the longest term the registrar allows.
3. A monitor that warns 60 days before the domain or the certificate expires. Better Stack can do this, but only on a paid plan.
4. A second person with access to the DNSimple account (see challenge 23).

## History

- 2026-11-07: Opened.
- 2026-11-16: The owner asked for a certificate check in `bin/deploy` and `bin/watch-deploy` (#297), and the Better Stack certificate alert. The check is built; the Better Stack setting is in the owner's account.
- 2026-11-16: Better Stack's warnings before a certificate or the domain runs out need a paid plan. The owner chose to change nothing in Better Stack, so the early warning for the certificates is only the check in `bin/deploy` and `bin/watch-deploy`.
