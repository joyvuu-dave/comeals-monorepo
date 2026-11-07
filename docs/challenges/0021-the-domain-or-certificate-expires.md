---
id: 21
title: The domain or its certificate expires
area: operations
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches: []
---

# The domain or its certificate expires

## The challenge

comeals.com keeps working for as long as the community uses it, even if the person who registered it is not around.

## The case that breaks it

The card on file for the domain expires. The renewal fails, the emails about it go to an address nobody reads, and one day comeals.com stops resolving. The app, the emailed links, and every calendar feed stop working at once.

## Where we stand

- DNS is at DNSimple. `status.comeals.com` is a CNAME there (AGENTS.md, site monitoring).
- Better Stack checks `https://comeals.com` every 3 minutes, so an outage is noticed. It does not warn before the domain expires.
- Not checked: the domain's expiry date, whether it renews by itself, which card pays, who gets the renewal emails, and when the TLS certificate renews.

## Options

1. Write those facts here, with dates.
2. Renew the domain for the longest term the registrar allows.
3. A monitor that warns 60 days before the domain or the certificate expires.
4. A second person with access to the DNSimple account (see challenge 23).

## History

- 2026-11-07: Opened.
