# Fault testing: the storm while things break

`bin/faults` (challenge 30) runs the real-server storm (`bin/storm`,
`docs/concurrency-testing.md`) while the network, the database and the
clock fail on purpose. Afterwards it checks the books, and that no write
was saved twice or answered with an error after it was saved.

```
bin/faults                                       # 16 clients, 30 s
FAULTS_SECONDS=120 FAULTS_CLIENTS=32 bin/faults
FAULTS_SEED=7 bin/faults                         # other requests, faults in another order
FAULTS_LOSE=0.2 bin/faults                       # lose a fifth of the answers to writes
FAULTS_EVERY=0.5 bin/faults                      # a fault every half second
FAULTS_SETTLEMENTS=24 bin/faults                 # 24 dinners for the settle phone (default 16)
```

`spec/bin/faults_spec.rb` runs it for 12 seconds with 6 clients, a fault
every second and a third of the answers to writes lost, so `bin/check`
and CI run it too. It must print `No problems.`

## What it starts

- **Its own PostgreSQL** (`Faults::Server`), under `tmp/faults/server`,
  on a port of its own, from the binaries `pg_config --bindir` names. It
  never restarts or stops the PostgreSQL that the worktrees and the
  development database share. Its log is `tmp/faults/server/server.log`.
- **A proxy** (`Faults::Proxy`), a small TCP proxy in Ruby. Every
  database connection, from the server and from the storm's own checks,
  goes through it.
- **A Puma** from this checkout, with `DATABASE_URL` pointing at the
  proxy. Its log is `tmp/faults/server_app.log`.

## The faults

`Faults::Driver` starts one every `FAULTS_EVERY` seconds. It goes
through every kind in an order the seed picks, then through all of them
again in a new order:

| Kind      | What happens                                                                                     |
| --------- | ------------------------------------------------------------------------------------------------ |
| `cut`     | Every open database connection is closed at once.                                                |
| `outage`  | The database cannot be reached for a moment, then can again.                                     |
| `restart` | PostgreSQL restarts (`pg_ctl restart -m fast`), ending every session.                            |
| `clock`   | The server's clock jumps forward past midnight, back an hour, or a day ahead, then is put right. |

The clock is moved with a file: Puma starts with
`RUBYOPT=-r spec/faults/server_clock.rb`, which adds the offset in
`FAULTS_CLOCK_FILE` to `Time.now`. The app never reads PostgreSQL's own
clock (`spec/db/app_clock_spec.rb`), so the offset moves every date and
time the app writes.

All the time, `Faults::LossyTransport` loses some answers to writes: the
server got the request and answered, but the phone never saw the answer.
The phone then sends the same request again, with the same headers (the
same `Idempotency-Key`), and sees only the second answer. This is the
case a timeout or a dropped connection makes.

## The settle phone

Settling is the biggest money write, so the suite settles all through a
run, not once. The seed plants `FAULTS_SETTLEMENTS` past dinners, one a
day, each with a cook who spent $40 and a guest
(`Storm::Seed.plant(settleable:)`). A settle phone (`Faults::Session#settle_phone`),
signed in as a resident who may settle, presses Settle every few seconds
with the next of those dates as the cutoff, so each press settles about
one dinner. Every one of its answers is lost once, so every press is
sent twice with the same `Idempotency-Key`. When the first send was
refused (a conflict, or no database) and the second one settled, the
phone sends it a third time, so every settle that worked is sent again.

The storm's own settler and settle requests take turns with it
(`Seed::Plan#settle_cutoff`). On every second date they ask for the
phone's date too, and race the phone and each other for that dinner. On
the other dates they ask for the date before, so the phone settles that
dinner alone. Without the turns the settler, which tries every 0.3
seconds, took every dinner first, and the phone never settled.

Before this, the storm had one settleable dinner, and the settler
settled it a few seconds into the run. After that, every settle request
was answered "nothing to settle", so no run had a settle that worked and
was sent again.

## What it checks

- The storm's own checks: every meal's ledger lines sum to zero,
  settled meals are untouched, caps hold, `ledger:verify` passes, and the
  calendar cache matches the rows.
- Every answer is one the API promises (`Storm::Client#judge`). A `503`
  that says the database could not be reached is counted, not a problem
  (`DatabaseUnreachable`).
- `Faults::Report`:
  - a write whose first send worked (2xx) and whose second send got an
    error;
  - an event or a common house booking saved twice;
  - a settle that worked, sent again, and answered with anything but the
    first answer (the same settlement; the keys of the stored answer may
    come back in another order, because PostgreSQL keeps it as `jsonb`).
- The settle phone: it settled at least once, at least one press that
  settled was sent again, and every answer was a settlement (`201`),
  nothing to settle (`400`), a conflict (`409`) or the database out of
  reach (`503`).

Sign-ups, take-offs and Late or Veg changes are left out of the first
report: the page sends them with an attendance version, and a send built
on an old version is answered 409 "stale" and the page reloads (ADR
0012). The storm client sends no version, like a page from before that
check.

## What it found

The first runs, on 2026-11-12:

1. **A lost database connection answered 500.** A cut, an outage or a
   restart made requests fail with `ActiveRecord::ConnectionFailed` or
   `ConnectionNotEstablished`. Fixed: `DatabaseUnreachable`
   (`lib/database_unreachable.rb`) answers an API request `503` with a
   `Retry-After`, and says the change may or may not have been saved.
2. **A write sent again was not safe.** An event was saved twice; a
   guest room or common house booking was answered "taken" by its own
   first send; a delete was answered 404 for the record its first send
   deleted. Fixed: ADR 0015, an optional `Idempotency-Key` on the calendar
   writes, a guest remove and a settle.

Later runs, on 2026-11-13:

3. **A close sent again after a settlement was refused.** The first
   close was saved and its answer lost, a settlement settled the dinner,
   and the second close was answered 400 "already been reconciled".
   Fixed (#280): on a settled meal, a close, a cancel, a description or
   a cap that sends the value the meal already has is answered as saved
   (`app/controllers/concerns/settled_same_value.rb`).
4. **The suite's own settler ran at READ COMMITTED.** The rake process
   connected with only a URL, which dropped `config/database.yml`'s
   `variables:` block, so a settlement there claimed a dinner from an
   old read of its costs and settled a blank cost. The app connects with
   the full configuration and never settles like this. Fixed in the
   suite: `Faults::Session` connects with the app's own settings and
   refuses to run unless its sessions are SERIALIZABLE.

The money rules held through every fault in every run.

## A full disk

The suite does not fill a disk. A request spec does the same job: a
trigger makes PostgreSQL raise its real `disk_full` error (SQLSTATE 53100) on a sign-up and on a guest add
(`spec/requests/api/v1/database_full_spec.rb`). Until 2026-11-15 the
answer was 500. Now `DatabaseFull` (`lib/database_full.rb`) answers an
API request `507` and says nothing was saved. That is true because the
error rolls the write back, and no write runs a query after its commit
(`spec/requests/no_query_after_commit_spec.rb`). A disk that fills
while PostgreSQL writes a commit stops the server, and that is the
lost connection above: `503`, "may or may not have been saved".

## When it fails

- Read the last lines: one line per kind of problem, with the action,
  the status and the error class.
- Run it again with the same `FAULTS_SEED`. The requests and the order
  of the faults are the same; their timing against each other is real
  time, so a problem that does not come back may need a few runs.
- `tmp/faults/server_app.log` has the server's side of each request.
