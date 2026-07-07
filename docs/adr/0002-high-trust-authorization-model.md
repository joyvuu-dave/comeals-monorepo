# ADR 0002: High-Trust Authorization Model

- **Status:** Accepted
- **Date:** 2026-07-07

## Context

Comeals runs a single co-housing community. The residents know each other,
share meals, and manage the schedule together. Everyone who can sign in is a
neighbor, not an anonymous internet user.

An authorization audit on 2026-07-07 found that the API authorizes almost
nothing beyond "are you signed in." Any authenticated resident can act on any
other resident's data: sign a neighbor up for a meal, edit or delete anyone's
reservation, close a meal, or set the bills on a meal they did not cook. iCal
feeds are served with no auth at all, keyed by a guessable id. The reconciliation
email hands every resident a shared read-only admin token that unlocks read of
the whole admin panel — every balance, every bill, every resident's contact info.

The natural reaction is to call these holes and lock them down with per-record
ownership checks and roles. That reaction is wrong for this app, today. The
threat model of a twelve-household co-housing group is not the threat model of a
public SaaS. The people using this system already trust each other with their
money, their front-door keys, and their kids. Adding an ownership-check layer
would be code and friction bought to defend against an attacker who does not
exist here.

## Decision

Authorize by authentication, not by ownership or role. We accept the following
as deliberate design, not defects:

1. **Any authenticated resident may read and write any community data.** Meal
   attendance (own and others'), guests, reservations, events, and meal controls
   (close, max, description) are all open to every signed-in resident.

2. **Any authenticated resident may set the bills on any unreconciled meal.**
   The books are collaborative. The guard that matters is immutability after
   reconciliation, not who does the entry before it.

3. **iCal feeds stay unauthenticated.** Calendar clients cannot send a bearer
   token, so a feed has to be reachable by URL alone. The feeds expose only a
   dinner schedule, which the whole community already sees.

4. **The shared read-only admin token stays shared and read-only.** It unlocks
   reads across the admin panel. Writes still require a superuser admin. The
   token going into every reconciliation email is the intended distribution.

5. **Admin writes are gated to superusers.** This is the one real authorization
   boundary in the system, and we keep it. Non-superuser admins can look but not
   touch.

6. **Community scoping is the database's job, not the query's.** There is exactly
   one community row, pinned by a unique `singleton_guard` index, and a trigger
   that refuses to delete it. Controllers do not scope queries by community
   because there is nothing to scope against.

The accountability mechanism is the audit log, not prevention. Every write is
recorded with its author. If a resident does something wrong, we can see who and
undo it — the co-housing way, not the firewall way.

## Consequences

- The code stays simple. No policy objects, no `can?` checks, no per-record
  ownership plumbing.
- A stolen or shared session is as powerful as the resident it belongs to. We
  accept this; sessions live inside a trusted group.
- Two things are load-bearing and must not regress silently: **authentication is
  required on every write**, and **admin writes require a superuser**. These are
  the boundaries we actually keep, so they are pinned by request specs
  (`spec/requests/api/v1/authentication_pinning_spec.rb` and
  `spec/requests/admin/superuser_authorization_spec.rb`).
- The open cross-resident behavior is _also_ pinned
  (`spec/requests/api/v1/high_trust_authorization_spec.rb`), so that a future
  change which quietly adds an ownership check fails a test and forces a
  conscious decision rather than a silent shift in the model.

## When to revisit

Reopen this decision if any of these become true:

- The app is made multi-community. Every open read and write becomes a
  cross-tenant leak the moment a second community exists, and the DB singleton
  is the only thing stopping it today. Multi-tenancy means adding real query
  scoping before removing the singleton constraint.
- The community grows past the point where everyone knows everyone.
- A concrete incident happens — a resident abuses the open writes or the shared
  token leaks outside the community.

Until then, the audit findings above are known and accepted. A future audit that
rediscovers them should read this ADR first and not re-file them.

## Alternatives considered

- **Add ownership checks and roles now.** Rejected: it defends against a threat
  the community does not have, at a real cost in code and friction.
- **Split the difference — lock down only the money paths.** Rejected as
  inconsistent. If bill entry needs an ownership check, so does attendance, since
  attendance drives the split. Either the group is trusted with the ledger or it
  is not. Today it is.
