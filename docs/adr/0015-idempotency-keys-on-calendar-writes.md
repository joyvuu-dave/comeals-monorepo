# ADR 0015: Calendar writes, guest removes and settles take an Idempotency-Key

- **Status:** Accepted
- **Date:** 2026-11-12

## Context

A phone sends a write. The server saves it, but the answer never reaches
the phone: the network dropped, or the server lost its database
connection after the commit. The phone cannot tell whether the write was
saved, so the person presses the button again and the page sends the
same request.

`bin/faults` (challenge 30, `docs/fault-testing.md`) does this on
purpose: it runs the storm, cuts connections, restarts PostgreSQL and
moves the clock, and for some writes it throws the answer away and sends
the request again. The money rules held. But a write sent again was
wrong in these ways:

- An event was saved twice.
- A guest room or common house booking was answered 400 "taken". The
  booking that took the day was the person's own first send.
- A delete of an event, a guest room booking, a common house booking or
  a guest was answered 404, for a record the first send deleted.
- A settle was answered 400 "nothing to settle", for a period the first
  send settled.

A bills save and a guest add already take a key (ADR 0009, S2), with a
table of their own each, because each answer is built from a meal's
rows. Attendance writes carry a version instead (ADR 0012), and the page
reloads the meal when a write's answer does not come.

## Decision

1. **The header.** The same `Idempotency-Key` header as a bills save,
   read by the same rules (IETF draft
   `draft-ietf-httpapi-idempotency-key-header-07`, `IdempotencyKeyHeader`):
   a quoted string of 1 to 255 printable characters. It is optional. A
   page loaded before this change sends none, and its writes work as
   before.
2. **Which writes.** Create, update and delete of an event, a guest room
   booking and a common house booking; a guest remove; and a settle
   (`POST /api/v1/reconciliations`). Attendance writes keep their
   version (ADR 0012). A bills save and a guest add keep their own keys
   (ADR 0009).
3. **One table for all of them.** `request_keys` holds the sender
   (`Resident:<id>` or `CommonHouseLogin:<id>`), the key, a SHA-256 of
   the request, and the answer (status and body). The key is unique per
   sender, so two people's keys never meet.
4. **The row is written with the write.** In the same transaction, so a
   row exists exactly when the write was saved. A settle writes it
   inside the settlement's transaction (`SettleAndNotify`'s `also:`).
5. **Only an answer that saved something is kept** (a 2xx). A refused
   write saved nothing. Sending it again is safe, and it is worked out
   again, so a booking refused as "taken" can be tried again once the
   day is free.
6. **What a second send gets.**
   - The same key and the same request: the stored answer, with the
     header `Idempotent-Replayed: true`. Nothing is written. This check
     runs before the record is looked up, so a delete sent again is not
     answered 404.
   - The same key and another request: 422, and nothing is written.
   - A header that is not a key: 400.
7. **What "the same request" means.** The method, the path, and the
   parameters as sent in the body and the query string, with their keys
   sorted. `token`, `socket_id` and `push_token` are left out: the first
   says who sent it (the sender column), and the two push fields name the
   browser's Pusher connection, which can be new by the time the page
   sends again. The body is read as sent, not from Rails' params: the
   params wrapper adds a copy of the body under the model's name, and
   which fields it copies depends on whether the model's columns were
   loaded yet.
8. **Two sends at the same moment.** Both find no row and both write.
   Each looked the key up inside its transaction, so PostgreSQL refuses
   the one that commits second as a conflict (not a unique violation),
   and `RetryOnConflict` runs it again; then it finds the row and gets
   the stored answer (`spec/requests/api/v1/request_key_race_spec.rb`).
   A settle that loses is refused by the settlement's own checks instead,
   and its rescue looks the key up again.
9. **What the page sends.** A calendar form makes a new key when what
   it sends changes, and sends the same key when the person presses the
   button again with the same fields (`use_request_key.js`). Only the
   last key is kept: a save of A, then B, then A again is three requests,
   because B may have been saved over A. A delete's key is built from the
   record's id (`delete-event-12`, `remove-guest-40`): a record is
   deleted once and its id is never used again, so every send of that
   delete is the same request.
10. **How long.** A key is kept 7 days, like a bills save's.
    `RequestKey.delete_expired` runs every hour (`config/recurring.yml`).

### Why not a key on attendance writes

ADR 0012 already answers a take-off or a sign-up sent again: it carries
the version the page expected, a second send carries an old version and
is answered 409 "stale", and the page loads the meal again. The storm
client sends no version, like a page from before ADR 0012, so the fault
report leaves those routes out.

### Why not a table per write

A bills save and a guest add each keep extra columns that their answers
are built from (the guest the add made, which can be removed later).
These writes answer with a short message or a small object that does not
change after the write, so the answer itself can be stored.

## Costs

- One more table, and one more hourly job.
- A keyed write runs two more statements: the lookup and the insert.
- The stored answer is the answer at the time of the first send. That is
  the point: the second send is told what the first one did.
