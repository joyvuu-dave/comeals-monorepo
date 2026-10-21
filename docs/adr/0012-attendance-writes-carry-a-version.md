# ADR 0012: An attendance write carries the version the page expects

- **Status:** Accepted
- **Date:** 2026-10-21

## Context

A tap on a row of the meal page's sign-up list changes the screen at
once and sends one request: a sign-up (`POST`), a take-off (`DELETE`),
or a Late or Veg change (`PATCH`), all at
`/api/v1/meals/:meal_id/residents/:resident_id`. The page does not wait
for one answer before it sends the next tap. It stops waiting for an
answer after 35 seconds (`SIGNUP_TIMEOUT_MS`), loads the meal again,
and tells the person the change may not have been saved. The live push
for a write skips the screen that sent it.

Two things went wrong, and nobody saw an error:

- **A. Two taps, other order.** Ann is signed up. She taps off, then on.
  The sign-up reaches the server first and finds her row, so it changes
  nothing. Then the take-off removes the row. Her screen says signed up;
  the server says not.
- **C. A request after the page gave up on it.** Ann taps on. The
  request is held on the network. After 35 seconds the page loads the
  meal (not signed up), and she taps on and then off. Then the held
  sign-up reaches the server and signs her up. She is charged, and her
  screen says she is not signed up. On staging a request was once held
  54 seconds.

## Decision

Each person's attendance on each meal has a version: a count of the
inserts, updates and deletes of their `meal_residents` row. It is kept
in `attendance_versions` (one row per meal and person, made by the first
write) and counted by a database trigger,
`comeals_count_attendance_version`, so every write path counts: the API,
admin, a task, psql. No row means version 0.

The meal form shows each person's `attendance_version`. The page keeps
it on the row and sends it with each sign-up, take-off, Late and Veg
tap: the version it expects the server to have before this write. A tap
made while another write on the same row has no answer counts that
write, so off and then on at once send 4 and then 5.

Under the meal lock, in each try, after the settled check, the server
reads the stored version. Another number means the request was built on
a state the server no longer has. Nothing is written, and the answer is
`409` with `"type": "stale"`, as for a bills save (ADR 0009). The page
then shows the message after the person's name and loads the meal
again. A refusal of another kind wrote nothing, so the page takes back
the count of that write.

In case A, the sign-up expects 5 and finds 4, so it is refused. The
take-off is written. The page loads the meal and shows Ann not signed
up, and tells her. In case C, the held sign-up expects the version the
page had before the newer sign-up and take-off, two writes ago, so it
is refused.

### Why not the state alone

The first idea was to send the state the page expects: "not signed up"
with a sign-up, "signed up" with a take-off. That catches case A. It
does not catch case C: when the held sign-up arrives, the person is not
signed up, which is what it expects. Only a number that never goes back
can tell that state from the same state two writes earlier.

### Why its own table, and a trigger

A take-off deletes the `meal_residents` row, so a counter on that row
would be lost and would start again at the same number. A model
callback would miss a write from psql or a task.

### Pages from before this change

A request with no `attendance_version` (or `null`) is not checked, and
works as it did before. During and after a deploy, open tabs run the
old bundle and send none; they keep the old behavior, both cases
included, until they are loaded again. A copy of a meal saved on the
device before this change has no version either, so its taps send none
until the meal loads from the server. A rollback of the code alone is
safe: the old code ignores the field, and the trigger still counts.

### Order of the reads on the meal form

The form is not read in one transaction. The versions are read before
the attendance rows, so a version is never newer than the row shown
with it. If a write commits between the two reads, the next tap is
refused as stale and the meal loads again.

## Guests

A guest add already carries an `Idempotency-Key`, and a removal names
the guest by id and is not sent while another removal for that host
waits. So a guest add sent twice adds one guest, and a removal cannot
come before its add. The key does not refuse an add that arrives after
the page gave up on it.

## What this does not catch

A write that arrives after the page gave up on it, when nothing changed
since the page built it, still matches the version and is written: a
sign-up, or a guest add. The live push skips the screen that sent it, so
that screen does not show it until the next load or the next tap on that
row. This is #237.

## Costs

- A new table, a trigger on `meal_residents`, and a migration.
- One more query on the meal form, and one on each attendance write.
- A person who taps quickly while another device changes their row
  gets a refusal and a reload instead of a write.
