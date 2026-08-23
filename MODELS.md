# Comeals Data Model Reference

## Entity Relationship Overview

```
                                    COMMUNITY  (exactly one row)
                                        |
            +----------+--------+-------+-------+--------+----------+
            |          |        |       |       |        |          |
         AdminUser   Unit   Resident  Meal  Rotation  Reconcil.  Event
                      |        |       |       |        |
                      +--< Resident    |       +--< Meal +--< Meal
                               |       |                 +--< ReconciliationBalance
                    +----------+-------+----------+----------+
                    |          |       |          |          |
                   Bill    MealResident  Guest  MealCharge  Key
                  (cook)   (attendee)  (visitor) (settled  (old auth,
                    |          |          |        line)    read only)
                    +----< Meal +----< Meal +----< Meal
```

All money flows through Meal. A Meal has cooks (Bills), attendees
(MealResidents), and visitors (Guests). The cost of each meal is split among
attendees in proportion to their multiplier. At settlement, the result is
written as MealCharge rows (one line per bill, attendee, and guest) and
ReconciliationBalance rows (one total per resident).

The arithmetic lives in one place, `MealLedger` (`app/services/meal_ledger.rb`).
No model has a cost method. See "Where the money math lives" below.

---

## Core Models

### Community

The top-level record. Everything belongs to it.

There is exactly one community row, forever. A unique index on
`singleton_guard`, which is always 0, makes a second row impossible, and
`Community#enforce_singleton` refuses a second create. `before_destroy` and
the `prevent_community_delete` database trigger both refuse to delete the row.
`Community.instance` is how the rest of the app reads it. Controllers do not
scope queries by community — see ADR 0002 and CLAUDE.md.

```
Community
  |
  +-- has_many Units
  +-- has_many Residents
  +-- has_many Meals
  +-- has_many MealResidents
  +-- has_many Bills
  +-- has_many Guests (through Residents)
  +-- has_many Rotations
  +-- has_many Reconciliations
  +-- has_many Events
  +-- has_many AdminUsers
  +-- has_many GuestRoomReservations
  +-- has_many CommonHouseReservations
```

**Key fields:**

- `name` (unique) — "Patches Way"
- `cap` DECIMAL(12,8) — cost cap per multiplier unit. NULL means no cap. The
  model requires $0.01 to $9,999.99 in whole cents. Database CHECKs:
  `communities_cap_positive_or_null` and `communities_cap_whole_cents`.
- `timezone` — one of `SUPPORTED_TIMEZONES`, e.g. "America/Los_Angeles"
- `schedule` (jsonb) — the meal schedule: a list of 1 to 6 weeks, each week a
  list of days (0 = Sunday .. 6 = Saturday). Read through `MealSchedule`.
  The `communities_schedule_shape` CHECK calls the
  `comeals_valid_meal_schedule` SQL function, which enforces the same shape
  and requires at least one meal day in the cycle.
- `meals_per_rotation` — how many meals `create_next_rotation` makes. Default 12. Model and `communities_meals_per_rotation_range` CHECK both require 1
  to 100.
- `free_below_age` (default 5) and `full_price_age` (default 12) — the child
  pricing ages. A resident younger than `free_below_age` eats free; from
  `free_below_age` up to but not including `full_price_age` pays half; at
  `full_price_age` and up pays full price. Both must be 0 or more and
  `free_below_age <= full_price_age` (model validation plus the
  `communities_child_ages_non_negative` and `communities_child_ages_ordered`
  CHECKs). See "The Multiplier System" below.
- `singleton_guard` — always 0, unique. This is what keeps the table at one
  row.

There is no `slug` column and no friendly_id gem. Migration 20260811130000
removed the slug.

**Behavior:**

- `capped?` — true when `cap` is set
- `meal_schedule` — a `MealSchedule` built from `schedule`
- `create_next_rotation` — asks `meal_schedule` for the next
  `meals_per_rotation` meal dates, starting the day after the last existing
  meal (or today), and creates one Rotation with those meals. It raises if any
  meal has no rotation yet.
- `unreconciled_ave_cost` — dashboard "cost per adult" over unreconciled
  meals. It reads `MealLedger#summary_for`, so it cannot disagree with
  settlement math.
- `unreconciled_ave_number_of_attendees`, `auto_rotation_length`,
  `auto_create_rotations` — older helpers for grouping meals that have no
  rotation.
- `trigger_pusher(date)` — deletes the calendar cache entries that cover that
  date, then sends a Pusher message on the same keys. `after_create` also
  fills in `community_id` on any AdminUser rows created before the community
  existed.

---

### Unit

A household or apartment. Groups residents together.

```
Unit ---< Resident
```

**Key fields:**

- `name` (unique: `index_units_on_name`) — "A", "B", etc.

**Behavior:**

- `balance` — sum of its residents' cached balances, signed the MealLedger
  way. Show it only through `BalanceDisplayHelper#balance_tag`.

**Deletion:** a unit with residents refuses destroy (`restrict_with_error`).
There is no `active` flag on units. To retire one, retire its residents; it
then drops out of the hosts dropdown on its own.

---

### Resident

A community member. The central record for billing.

```
Resident
  |
  +-- belongs_to Unit
  +-- has_one ResidentBalance (cached running balance)
  +-- has_many Bills (meals they cooked)
  +-- has_many MealResidents (meals they attended)
  +-- has_many Guests (visitors they brought)
  +-- has_many ReconciliationBalances (settled total per period)
  +-- has_many MealCharges (settled line items)
  +-- has_many Keys (polymorphic; old sessions only, see Key)
  +-- has_many GuestRoomReservations
  +-- has_many CommonHouseReservations
```

**Key fields:**

- `name` — required. Unique without regard to case
  (`index_residents_on_lower_name`, a unique index on `lower(name)`). The
  model check is hand-written so the error can say which unit the other
  person is in.
- `email` — optional in the database, but required for an active adult who
  can cook (`email_presence`). Unique without regard to case
  (`index_residents_on_lower_email`). Stored lowercased. An empty string is
  turned into NULL before validation.
- `password_digest` — scrypt hash. `authenticate(password)` checks it.
- `multiplier` — pricing weight, 2, 1, or 0 (`Multiplier::FULL`, `HALF`,
  `FREE`). Default 2. CHECK `residents_multiplier_non_negative`. See "The
  Multiplier System" below.
- `active` — false for residents who moved away or died
- `can_cook` — eligible for the cooking rotation
- `vegetarian` — the default copied onto new attendance rows
- `birthday` — `rake residents:set_multiplier` reads it each night to set the
  multiplier by age. Optional: NULL means "adult, no birthday given"; the
  task skips them and the calendar shows nothing. Children (multiplier below
  FULL) must have one so they age into adult pricing. The old placeholder
  1900-01-01 is refused by the model and by the
  `residents_birthday_not_sentinel` CHECK.
- `phone` — optional. `HasPhoneNumber` parses any way of typing a number and
  stores the E.164 form ("+15105552671"). The `residents_phone_e164` CHECK
  enforces that shape for writes that skip the model.
- `keys_valid_since` — JWTs issued before this time stop working. A password
  change sets it to now (and destroys any old Key rows).
- `reset_password_token` / `reset_password_sent_at` — password reset by email

**Scopes:**

- `adult` — multiplier >= `Multiplier::FULL`
- `active` — active = true
- `eligible_cooks` — active adults with `can_cook`

**Deletion:** bills, attendance rows, guests, reconciliation balances, and
meal charges are all `restrict_with_error`. A resident with any of them can
never be destroyed — retire them with `active` instead. Keys, the balance
cache, and reservations are destroyed with the resident.

**`balance`** reads the `ResidentBalance` cache (refreshed daily by
`rake billing:recalculate`). It is signed: positive means the community owes
the resident. Show it only through `BalanceDisplayHelper#balance_tag`.

**The oracle methods are not production code.** `calc_balance`,
`bill_reimbursements`, `meal_resident_costs`, `guest_costs`, and
`oracle_unit_cost` are a second, separately written copy of the balance
arithmetic. Nothing in the app calls them. The specs
(`spec/tasks/billing_recalculate_correctness_spec.rb`,
`spec/tasks/settlement_matches_running_balance_spec.rb`,
`spec/models/resident_spec.rb`) compare `MealLedger`'s answers against them.
They are plain Ruby loops over preloaded rows, not SQL sums, and they must
never read `MealLedger` — if they did, the specs would only check
`MealLedger` against itself. When the money rules change, change both.

---

## Financial Models

These models hold the source data for cost splitting. Money moves like this:

```
Cook pays for groceries
        |
        v
    Bill.amount                    what the cook spent, whole cents
        |
        v
    MealLedger.financials_for      total_cost = sum of bills (no_cost skipped)
                                   effective_cost = min(total_cost, cap * total multiplier)
                                   unit_cost = effective_cost / total multiplier
        |
        +-------> credit line  for each bill:   + cook's share of effective_cost
        +-------> debit line   for each eater:  - unit_cost * multiplier
        +-------> guest_debit  for each guest:  - unit_cost * multiplier, charged to the host
        |
        v
    MealLedger#balances            sum of a resident's lines (full precision)
        |
        +-----> rake billing:recalculate  ->  resident_balances   (running, unrounded)
        +-----> Reconciliation#finalize   ->  meal_charges        (every line, unrounded)
                                              reconciliation_balances (rounded to cents)
```

Signs: positive means the community owes the person. A credit is positive, a
debit is negative. This is set once in `MealLedger` ("Signs" section) and
every stored amount inherits it. No screen shows the sign itself; see
CLAUDE.md money rule 11.

### Bill

A cook's expense for a meal. One bill per cook per meal.

```
Bill ----> Meal
Bill ----> Resident (the cook)
Bill ----> Community
```

**Key fields:**

- `amount` DECIMAL(12,8) — what the cook spent, in dollars. Default 0.
- `no_cost` — true if this cook spent nothing. `MealLedger` makes no line for
  such a bill: it neither credits the cook nor raises what anyone pays.

**Validations and guards:**

- Whole cents, 0 to 9999.99 (the largest whole-cent value DECIMAL(12,8)
  holds). Database CHECKs: `bills_amount_non_negative` and
  `bills_amount_whole_cents`.
- One bill per cook per meal: `index_bills_on_meal_id_and_resident_id`
  (unique). There is no single-column index on `meal_id` any more; the
  composite index covers those lookups.
- `ReconciledMealImmutability`: no create, update, or destroy once the meal is
  reconciled. The `bills_reject_settled_write` trigger enforces the same rule
  for writes that skip the model.
- Audited (the `audits` table), linked to the meal.

**Financial methods:** none. All cost math is in `MealLedger`.

---

### Meal

A dinner on one date.

```
Meal ----> Community
Meal ----> Reconciliation (optional; NULL = unreconciled)
Meal ----> Rotation (optional; the cooking schedule group)
Meal ----< Bill (1-3 cooks is typical)
Meal ----< MealResident (8-25 attendees is typical)
Meal ----< Guest (0-5 visitors is typical)
Meal ----< MealCharge (written at settlement; empty until then)
```

**Key fields:**

- `date` — unique (`index_meals_on_date`)
- `description` — menu text
- `cap` DECIMAL(12,8) — copied from `community.cap` when the meal is created.
  NULL means no cap. CHECK `meals_cap_positive_or_null`.
- `closed` / `closed_at` — closing freezes attendance. `closed_at` is set
  when `closed` flips to true and cleared when it flips back.
- `max` — extra spots allowed after close. Always NULL while the meal is
  open. Cannot be less than the current attendee count.
- `start_time` — set on create: 6pm on Sundays, 7pm on other days

**Derived counts (no cached columns):**

- `multiplier` — sum of `meal_residents.multiplier` and `guests.multiplier`
- `attendees_count` — number of attendance rows plus guest rows
- `capped?`, `reconciled?`

**No cost methods, on purpose.** `total_cost`, `unit_cost`,
`effective_total_cost`, `max_cost`, and `subsidized?` do not exist on Meal.
What a meal costs is `MealLedger`'s arithmetic. Screens read it through
`MealCostSummary` (see "Where the money math lives"). A copy on this model is
how the math once ended up in three places (#48).

**Scopes:**

- `unreconciled` — reconciliation_id IS NULL
- `open` — closed = false
- `closed_with_bills` — closed meals that have at least one bill
- `with_attendees` — at least one attendance or guest row. A bill on a meal
  nobody ate has no financial effect: the cook absorbs the cost.

**Immutability:** once `reconciliation_id` is set, `cap`, `date`, and
`reconciliation_id` itself can no longer change (`FROZEN_WHEN_RECONCILED`),
and the meal refuses destroy. A closed meal also refuses destroy: reopen it
first. Both destroy guards are `prepend: true` so the bill and attendance
cascades never run before the refusal (#26). The `meals_protect_settled`
trigger enforces the same update and delete rules in the database.

`has_many :meal_charges` is `restrict_with_error`, a second reason a settled
meal cannot be destroyed.

**Other:** audited, with associated audits from its bills, attendance, and
guests (`total_audits`). `trigger_pusher` clears the meal's cache entry and
the calendar cache, then notifies Pusher.

---

### MealResident

Join record: a resident attending a meal.

```
MealResident ----> Meal
MealResident ----> Resident
MealResident ----> Community
```

**Key fields:**

- `multiplier` — copied from the resident when the row is created
  (`set_multiplier`). A later change to the resident never changes a past
  charge. Required; CHECK `meal_residents_multiplier_non_negative`.
- `late` — arrived late
- `vegetarian`

**Indexes:** `index_meal_residents_on_meal_id_and_resident_id` (unique; one
row per resident per meal) and `index_meal_residents_on_resident_id`. The
single-column `meal_id` index was dropped; the composite covers it.

**Financial methods:** none. A debit line for this row is made by
`MealLedger`.

**Attendance rules** (`ClosedMealAttendanceFreeze`, shared with Guest):

- Can join open meals freely
- Can join closed meals only if `max` is set and spots remain
- Cannot join closed meals if `max` is not set or is full
- Can be removed from a closed meal only if the row was created after the
  meal closed
- A reconciled meal refuses all of it (`ReconciledMealImmutability`, included
  first so it runs first), and the `meal_residents_reject_settled_write`
  trigger enforces the same rule for writes that skip callbacks
- The one bypass is `admin_correction`, set per row by the ActiveAdmin
  attendance page so an admin can make the record match what happened. It
  does not apply to reconciled meals.

Audited, linked to the meal.

---

### Guest

A non-resident visitor brought by a resident. The guest's cost is charged to
the host.

```
Guest ----> Meal
Guest ----> Resident (the host)
```

**Key fields:** `multiplier` (default 2, CHECK
`guests_multiplier_non_negative`), `late`, `vegetarian`, `meal_id`,
`resident_id`, timestamps. There is no `name` column and no `community_id`
column; a guest reaches the community through its host.

**Indexes:** `index_guests_on_meal_id`, `index_guests_on_resident_id`.

**Financial methods:** none. `MealLedger` makes a `guest_debit` line with the
host's `resident_id`.

**Rules:** the same `ReconciledMealImmutability` and
`ClosedMealAttendanceFreeze` as MealResident, in that order, and the
`guests_reject_settled_write` trigger. Audited, linked to the meal.

---

### Reconciliation

A settlement event. Creating one sweeps meals, writes the line items, and
writes the balances, all in one transaction.

```
Reconciliation ----> Community
Reconciliation ----< Meal
                      |
                      +----< Bill ---> Resident (cooks)
                      +----< MealCharge ---> Resident
Reconciliation ----< ReconciliationBalance ---> Resident
```

**Key fields:**

- `date` — the day the settlement ran (defaults to today)
- `end_date` — the cutoff. Required, and must be strictly before today.

**Validations:**

- `end_date` present and in the past
- On create, at least one eligible meal must exist. An empty settlement could
  never be removed (the row is append-only), so it is refused up front.

**Behavior:**

- `finalize` (`after_create`) runs `assign_meals`, then
  `persist_settlement!`.
- `assign_meals` — claims every unreconciled meal that has at least one bill,
  is dated on or before `end_date`, and is dated before today
  (`eligible_meals`, the same scope the create validation reads). It takes
  `SELECT ... FOR UPDATE` on those meals in id order first, then updates
  only rows whose `reconciliation_id` is still NULL, and raises if a rival
  settlement claimed any of them. See ADR 0003.
- `settlement_ledger` — a `MealLedger` over the claimed meals, with bills,
  attendance, and guests preloaded.
- `settlement_balances` — `MealLedger#balances` for every resident, then
  `allocate_to_cents`: largest-remainder rounding (Hamilton's method) so
  the cent amounts sum to exactly zero. Each amount is within one cent of its
  exact value. Ties go to the lowest `resident_id`. It raises if the input
  does not already sum to zero (within `ZERO_SUM_EPSILON`) or if the output
  does not sum to exactly zero.
- `persist_settlement!` — one `MealLedger` pass, then in one transaction:
  `persist_charges!` inserts every line (including zero lines) into
  `meal_charges` with `insert_all`, and `persist_balances!` writes each
  non-zero rounded balance to `reconciliation_balances`. Both tables come
  from the same read, so the lines explain the balances.
- `unit_balances` — the settled balances grouped by unit, including units at
  $0.00
- `date_range_description` — the dates of the meals it swept. Neither
  `date` nor `end_date` is the start of that period.

**Immutability:** `AppendOnly`. The row refuses both update and destroy.
`end_date` says which meals were swept, so editing it would make the stored
cutoff disagree with the settled meals. Corrections settle as new entries in
the next reconciliation. The destroy guard is prepended so the meal-nullify
and balance-destroy cascades never run (#26). Once a meal is reconciled, its
bills, attendance, and guests cannot change. Audited.

---

### MealCharge

One line of a settlement: what one resident was charged or credited for one
meal, and why. Written once by `persist_charges!`, straight from
`MealLedger#lines`, inside the settlement transaction. Never recomputed.

```
MealCharge ----> Meal
MealCharge ----> Resident
```

A charge belongs to a reconciliation only through its meal:
`MealCharge.for_reconciliation(reconciliation)` joins on
`meals.reconciliation_id`.

**Key fields:**

- `kind` — `credit` (cooked), `debit` (attended), or `guest_debit` (brought a
  guest). CHECK `meal_charges_kind_known`. `KIND_LABELS` gives the words the
  statement pages show.
- `amount` DECIMAL(16,8) — signed the MealLedger way, full precision. Show
  it only through `BalanceDisplayHelper#charge_amount_tag`.
- `unit_cost` DECIMAL(16,8) — the meal's cost per multiplier unit
- `multiplier` — units eaten. Present on debits only (CHECK
  `meal_charges_multiplier_on_debits_only`, `_non_negative`).
- `bill_amount` DECIMAL(12,8) — what the cook actually spent, before any cap.
  Present on credits only (CHECK `meal_charges_bill_amount_on_credits_only`).
  On a capped meal it is larger than `amount`, and is the only record of why
  the cook was not paid back in full.

**Indexes:** `index_meal_charges_on_meal_id`,
`index_meal_charges_on_resident_id`, and two partial unique indexes:
`index_meal_charges_one_credit_per_cook` and
`index_meal_charges_one_debit_per_attendee` (both on `(meal_id, resident_id)`,
one for `kind = 'credit'` and one for `kind = 'debit'`). A host can have
several `guest_debit` lines on one meal, so those are not unique.

**Methods:** `credit?`; `subsidized?` — true on a credit whose `bill_amount`
is larger than `amount`. This is the only `subsidized?` in the app.

**Immutability:** `AppendOnly` in the model; the `meal_charges_protect`
trigger refuses every UPDATE and DELETE in the database. Reconciliations
settled before 2026-08-02 have no lines (see
`docs/money-path-observability.md`).

---

### ReconciliationBalance

What one resident owed or was owed at one settlement. Written by
`persist_balances!`, rounded to cents, and never recomputed.

```
ReconciliationBalance ----> Reconciliation
ReconciliationBalance ----> Resident
```

**Key fields:**

- `amount` DECIMAL(16,8) — signed: positive means the community owes the
  resident ("is owed"), negative means the resident owes ("owes"). Show it
  only through `BalanceDisplayHelper#balance_tag`.
- `(reconciliation_id, resident_id)` is unique
  (`index_recon_balances_on_recon_id_and_resident_id`). There is also
  `index_reconciliation_balances_on_resident_id`. The single-column
  `reconciliation_id` index was dropped; the composite covers it.

**Immutability:** `AppendOnly` in the model. Two triggers in the database:
`reconciliation_balances_protect_settled` refuses every UPDATE and DELETE,
and `reconciliation_balances_sum_zero`, a deferred constraint trigger, checks
at commit time that the balances of every touched reconciliation sum to
exactly zero.

Unlike `ResidentBalance`, this is not a cache. It is the settled record —
what residents were actually told to pay.

---

### ResidentBalance

Cached running balance for a resident over the unreconciled meals. Refreshed
daily by `rake billing:recalculate`, which reads the meals in one
SERIALIZABLE READ ONLY snapshot, runs `MealLedger#balances`, and writes the
rows with `upsert_all` keyed on `resident_id`.

```
ResidentBalance ----> Resident (one-to-one)
```

**Key fields:**

- `amount` DECIMAL(16,8) — full precision, signed the MealLedger way
- `resident_id` unique (`index_resident_balances_on_resident_id`)
- CHECK `resident_balances_amount_not_nan`

This is a cache, not a source of truth. It can be rebuilt at any time from
bills, attendance, and guests.

---

### LedgerCheckRun

One night's record of `rake ledger:verify`. The task (`LedgerVerification`)
recomputes every reconciliation from its source rows and compares the result
to the stored balances, and checks that the stored `meal_charges` add up to
the stored `reconciliation_balances`. Every run is recorded, pass or fail.
See `docs/money-path-observability.md`.

No associations.

**Key fields:** `started_at`, `finished_at` (CHECK
`ledger_check_runs_finished_after_started`), `reconciliations_checked`,
`mismatch_count` (both CHECKed non-negative), `error` (text, NULL when the run
finished), `details` (jsonb). Index on `started_at`.

**Methods:** `passed?` (no error, zero mismatches), `failed?` (no error, some
mismatches), `errored?` (the run did not finish), `duration`. Scope:
`recent`.

**Immutability:** `AppendOnly`, plus the `ledger_check_runs_protect` trigger.
A record that can be edited afterwards is not evidence.

---

## Scheduling Models

### MealSchedule

Not a table. A value object over `communities.schedule`
(`app/models/meal_schedule.rb`), built by `Community#meal_schedule`. It is
the one home for "is this date a meal day": the rotation generator, the
admin preview, and `db/seeds.rb` all go through it.

- `weeks` — 1 to `MAX_WEEKS` (6) lists of day numbers
- `EPOCH` — a fixed Sunday, 2000-01-02. The week that holds EPOCH is week 1
  of the cycle, and the cycle repeats from there in both directions. There
  is no per-community start date. EPOCH must never change; existing
  schedules were arranged against it.
- `week_index(date)`, `meal_day?(date)`
- `upcoming_dates(from:, count:)` — the next `count` meal dates, skipping the
  holidays `Meal.is_holiday?` names. Raises instead of looping forever on a
  broken schedule.
- `dates_between(from, to)`
- `MAX_MEALS_PER_ROTATION` = 100, the upper bound of
  `communities.meals_per_rotation`

The constructor raises on a shape the model validations and the database
CHECK should already have refused.

### Rotation

Groups `meals_per_rotation` meals (default 12) for cooking duty.

```
Rotation ----> Community
Rotation ----< Meal
```

**Key fields:**

- `description` — generated date range of its meals ("2026-01-05 to
  2026-02-16"), set after save
- `color` — one of the 5 `COLORS`, cycling from the previous rotation's color
- `start_date` — date of its first meal, set after save
- `place_value` — position in date order, renumbered after create and destroy
- `residents_notified` — `rake residents:notify` has sent the signup reminder
  for this rotation
- `new_rotation_notified_at` — when `rake rotations:notify_new` sent the
  "new rotation posted" email. `no_email` (not a column) sets it at create
  so the email is skipped.

**Deletion:** `has_many :meals, dependent: :destroy`, guarded by three
prepended `before_destroy` checks. A rotation refuses destroy if any meal is
"touched" (closed, reconciled, dated today or earlier, or has any bill,
attendee, or guest), or if any meal exists after its last meal. Deleting the
newest untouched rotation is how an admin applies a schedule change early;
the nightly task recreates it under the current schedule.

Rotations and Reconciliations are fully separate. A rotation is about the
cooking schedule. A reconciliation is about billing.

---

## Calendar Models

### Event

A community calendar event (meetings, anniversaries, etc.).

```
Event ----> Community
```

**Key fields:** `title` (required), `description`, `start_date` (required),
`end_date`, `allday`. An event must have an `end_date` or be all day, and
must not end before it starts.

### GuestRoomReservation

A guest room booking. One per date.

```
GuestRoomReservation ----> Community
GuestRoomReservation ----> Resident
```

**Key fields:** `date` (unique: `index_guest_room_reservations_on_date`)

### CommonHouseReservation

A common area booking. Refuses a time period that overlaps another
reservation, and must not end before it starts.

```
CommonHouseReservation ----> Community
CommonHouseReservation ----> Resident
```

**Key fields:** `title` (optional), `start_date`, `end_date`

All three call `community.trigger_pusher` after commit for every month they
touch, including the old months when dates change.

---

## Authentication

### How login works

`POST /api/v1/residents/token` checks the password and returns a JWT from
`JwtAuth.encode` (`app/services/jwt_auth.rb`): HS256, signed with a key
derived from `secret_key_base`, with `resident_id`, `iat` (issued-at, with
fractional seconds), and `iss` = "comeals" in the payload. No database row is
written per session. `JwtAuth.authenticate` checks the signature and issuer,
loads the resident, and refuses the token if `iat` is before
`residents.keys_valid_since`. Raising `keys_valid_since` is how every session
is revoked at once; a password change does it.

### Key

An old API session. Login stopped writing Key rows when JWT auth shipped.
The table exists only so cookies issued before that deploy keep working:
`ApiController#resolve_current_session!` tries the JWT first and falls back to
`Key.find_by(token:)` when decoding fails. Issue #42 tracks removing the
model, the table, and the fallback once `Key.count` is 0 in production.

```
Key ----> identity (polymorphic: Resident or AdminUser; only residents ever used it)
```

**Key fields:** `token` (`has_secure_token`, unique), `identity_type`,
`identity_id`

### AdminUser

Devise account for the ActiveAdmin interface (`database_authenticatable`,
`recoverable`, `rememberable`, `trackable`, `validatable`).

```
AdminUser ----> Community (optional)
```

`community_id` is nullable so the very first admin can be created in
`rails c` before the Community exists; creating the Community fills it in.
This is the one model that does not include `BelongsToTheCommunity`, because
that concern calls `Community.instance`, which raises on an empty database.

**Key fields:** `email` (unique), `superuser`, `phone` (E.164, same
`HasPhoneNumber` concern and same shape CHECK, `admin_users_phone_e164`, as
residents), plus Devise's sign-in tracking columns.

`superuser` is the authorization line in the admin. A plain admin writes
everything except the ledger; a superuser writes the ledger too. A
community must always keep at least one superuser: prepended model guards
refuse demoting or destroying the last one, the
`comeals_refuse_last_superuser_removal` trigger refuses it in the database,
and a controller rule stops self-demotion. See ADR 0004.

---

## The Multiplier System

A multiplier counts half-price units. The meaning of each value is set once,
in `Multiplier` (`app/models/multiplier.rb`):

```
Multiplier::FULL = 2   full price (one adult)
Multiplier::HALF = 1   half price
Multiplier::FREE = 0   eats free
```

Which age gets which value is a community setting, not a fixed number
(`free_below_age`, default 5; `full_price_age`, default 12):

```
age <  free_below_age                     -> FREE
free_below_age <= age < full_price_age    -> HALF
age >= full_price_age                     -> FULL
```

Equal ages mean there is no half-price band. Both 0 means everyone with a
birthday pays full price.

`rake residents:set_multiplier` runs nightly, reads the two ages from the
community, and sets each resident's multiplier from their birthday. A
resident with no birthday is an adult who did not give one; the task skips
them and their multiplier stays whatever the admin set. A `MealResident`
copies the resident's multiplier when the row is created, so a later
birthday never changes what someone was charged for a past meal. The API creates every guest with the
database default of 2 (an adult guest); only an admin can set a different
value.

`MealLedger` does not read `Multiplier`. It sums the numbers and divides by
the total; it does not know that 2 means one adult. Pricing policy lives in
`Multiplier` and the nightly task; arithmetic lives in the ledger.

A meal's total multiplier is the sum across all attendees and guests. Cost
per unit = effective cost / total multiplier. An adult pays twice what a
half-price child pays, and a free child pays nothing.

A meal whose total multiplier is 0 — nobody there is old enough to be
charged — has a unit cost of 0 and makes no lines. The cook absorbs the cost
and gets no credit.

Example: $60 meal, 3 adults and 1 half-price child attending:

```
total_multiplier = 2 + 2 + 2 + 1 = 7
unit_cost = $60 / 7 = $8.57142857...
adult debit = $8.57142857 * 2 = $17.14285714...
child debit = $8.57142857 * 1 = $8.57142857...
```

Full precision is kept during the billing period. At settlement, balances
are rounded to cents by largest-remainder allocation, so the rounded
balances sum to exactly zero.

---

## Where the money math lives

- `MealLedger` (`app/services/meal_ledger.rb`) — the one place the
  arithmetic lives. Give it meals with `bills`, `meal_residents`, and
  `guests` preloaded; it runs no queries of its own. `lines` returns every
  credit, debit, and guest_debit at full precision; `balances(resident_ids)`
  sums them per resident; `summary_for(meal)` returns `total_cost`,
  `effective_cost`, `unit_cost`, and `subsidized` for a screen. Caps are
  applied here: when `cap * total multiplier` is less than the bills, the
  eaters pay the capped amount and each cook is credited their share of it
  in proportion to what they spent.
- `Reconciliation#settlement_balances` — the one place that rounds to cents.
- `MealCostSummary` (`app/services/meal_cost_summary.rb`) — what a meal cost,
  for a screen. An open meal is computed through `MealLedger`. A settled
  meal reads its stored `meal_charges`, so today's cap is never applied to a
  meal settled under an older one. A settled meal with attendance but no
  lines (settled before 2026-08-02) returns nil and the screen shows nothing.
- `Resident#calc_balance` — the test oracle, not production. See Resident.

---

## Cross-cutting rules

**`community_id` is filled in for you.** `BelongsToTheCommunity`
(`app/models/concerns/belongs_to_the_community.rb`) declares
`belongs_to :community` and sets `self.community ||= Community.instance`
before validation. Forms, controllers, factories, and rake tasks leave it
out. The column stays NOT NULL with a foreign key, and it is a plain pointer
to the one row — never scope a query or an index by it. Included by Unit,
Resident, Bill, Meal, MealResident, Reconciliation, Rotation, Event,
GuestRoomReservation, and CommonHouseReservation. Not by Guest (no column),
AdminUser (see above), or the balance, charge, and check-run tables.

**Append-only ledger.** `AppendOnly` (`app/models/concerns/append_only.rb`)
refuses update and destroy with a readable message, with the destroy guard
prepended (#26). Included by Reconciliation, ReconciliationBalance,
MealCharge, and LedgerCheckRun. Each has a database trigger that refuses the
same writes for paths that skip callbacks (`update_all`, `delete_all`, psql):
`reconciliation_balances_protect_settled`, `meal_charges_protect`,
`ledger_check_runs_protect`. The deferred constraint trigger
`reconciliation_balances_sum_zero` checks every settlement sums to zero at
commit.

**Settled meals are frozen.** `ReconciledMealImmutability` refuses create,
update, and destroy on Bill, MealResident, and Guest once their meal (or the
meal they are being moved from) is reconciled. The
`*_reject_settled_write` triggers on those three tables do the same in the
database, and both of their meal lookups take `FOR KEY SHARE`
unconditionally so an unlocked write waits for a running settlement and is
then refused. `Meal` freezes its own `cap`, `date`, and `reconciliation_id`,
backed by `meals_protect_settled`. See ADR 0003 and CLAUDE.md.

The protect and reject triggers all step aside when the session setting
`comeals.allow_settled_writes` is `on`. That is for deliberate repair only:
`docs/runbooks/settled-data-repair.md`.

**Audits.** Meal, Bill, MealResident, Guest, and Reconciliation write to the
`audits` table (the `audited` gem). Child rows are linked to their meal.

**Money columns.** A single input — `bills.amount`, `communities.cap`,
`meals.cap`, `meal_charges.bill_amount` — is DECIMAL(12,8); one input is
capped at $9,999.99, so four digits before the point is enough. A sum —
`meal_charges.amount`, `meal_charges.unit_cost`,
`reconciliation_balances.amount`, `resident_balances.amount` — is
DECIMAL(16,8), because nothing caps a sum (#60). Never Float.

---

## Derived vs. Stored Data

All running financial values (costs, balances, counts) are computed from
source data — bills, attendance rows, guests — and there are no counter
columns. `resident_balances` is a cache of the running balance, refreshed
daily by `rake billing:recalculate`, and can be rebuilt from scratch at any
time. `meal_charges` and `reconciliation_balances` are different: they are
the settled record of what residents were billed, written once and never
rebuilt. `rake ledger:verify` checks every night that they still match their
source data and each other.
