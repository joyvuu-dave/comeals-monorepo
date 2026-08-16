# Comeals Data Model Reference

## Entity Relationship Overview

```
                                    COMMUNITY
                                        |
            +----------+--------+-------+-------+--------+----------+
            |          |        |       |       |        |          |
         AdminUser   Unit   Resident  Meal  Rotation  Reconcil.  Event
                      |        |       |       |        |
                      +--< Resident    |       +--< Meal +--< Meal
                               |       |
                    +----------+-------+----------+
                    |          |       |          |
                   Bill    MealResident  Guest   Key
                  (cook)   (attendee)  (visitor) (auth)
                    |          |
                    +----< Meal +----< Meal
```

All financial entities flow through Meal. A Meal has cooks (Bills), attendees (MealResidents), and visitors (Guests). The cost of each meal is split among attendees proportional to their multiplier.

---

## Core Models

### Community

The top-level container. Everything belongs to a community.

There is at most one community row. A unique index on `singleton_guard`, which
is always 0, enforces it. `before_destroy` refuses to delete the row, and
`Community.instance` is how the rest of the app reads it. Controllers therefore do not scope queries
by community — see ADR 0002.

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

- `name` (unique) -- "Patches Way"
- `slug` (unique, via FriendlyId) -- "patches"
- `cap` DECIMAL(12,8) -- per-multiplier-unit cost cap. NULL = no cap.
- `timezone` -- one of `SUPPORTED_TIMEZONES`, e.g. "America/Los_Angeles"
- `singleton_guard` -- always 0, unique. This is what makes the table hold one row.

**Behavior:**

- `capped?` -- true when cap is set
- `unreconciled_ave_cost` -- average cost per adult across unreconciled meals
- `create_next_rotation` -- generates the next rotation of 12 meals
- `trigger_pusher(date)` -- clears the calendar cache entries that cover that date, then sends a Pusher notification on the same keys

---

### Unit

A household or apartment. Groups residents together.

```
Unit ---< Resident
```

**Key fields:**

- `name` (unique per community) -- "A", "B", etc.

**Behavior:**

- `balance` -- sum of all residents' cached balances

**Deletion:** a unit with residents refuses destroy. There is no `active` flag
on units — to retire one, retire its residents, and it drops out of the hosts
dropdown on its own.

---

### Resident

A community member. The central entity for billing.

```
Resident
  |
  +-- belongs_to Unit
  +-- has_many Keys (polymorphic, for API auth)
  +-- has_one ResidentBalance (cached balance)
  +-- has_many Bills (meals they cooked)
  +-- has_many MealResidents (meals they attended)
  +-- has_many Guests (visitors they brought)
  +-- has_many ReconciliationBalances (settled amount per period)
  +-- has_many GuestRoomReservations
  +-- has_many CommonHouseReservations
```

**Key fields:**

- `name` (unique per community)
- `email` (unique, required for active adult cooks)
- `multiplier` -- pricing weight: 2, 1, or 0. See "The Multiplier System" below.
- `active` -- false for residents who moved/died
- `can_cook` -- eligible for cooking rotation
- `vegetarian` -- the default carried onto new attendance rows
- `birthday` -- `rake residents:set_multiplier` reads it each night to set the multiplier by age. Optional: NULL means "adult, no birthday given" — the task skips them and the calendar shows nothing. Children must have one (model validation) so they age into adult pricing.
- `keys_valid_since` -- API tokens issued before this time stop working

**Scopes:**

- `adult` -- multiplier >= 2
- `active` -- active = true

**Deletion:** bills, attendance rows, guests, and reconciliation balances are
`restrict_with_error`. A resident with any of them can never be destroyed —
retire them with `active` instead. Keys, the balance cache, and reservations
are destroyed along with the resident.

**Financial methods:**

- `calc_balance` -- bill_reimbursements - meal_resident_costs - guest_costs (unreconciled meals only)
- `balance` -- reads from ResidentBalance cache (refreshed daily by rake task)
- `bill_reimbursements` -- SQL SUM of bill amounts for unreconciled meals
- `meal_resident_costs` -- sum of (meal.unit_cost \* multiplier) for attended meals
- `guest_costs` -- sum of guest costs charged to this resident

---

## Financial Models

These models implement the cost-splitting system. Money flows like this:

```
Cook pays for groceries
        |
        v
    Bill.amount         (what the cook spent, in dollars)
        |
        v
    Meal.total_cost     (sum of all bill amounts)
        |
        v
    Meal.unit_cost      (total_cost / total_multiplier)
        |
        +-------> MealResident.cost = unit_cost * resident.multiplier
        |
        +-------> Guest.cost = unit_cost * guest.multiplier
```

At reconciliation, each resident's balance is:

```
balance = money_earned_cooking - money_owed_eating - money_owed_for_guests
```

### Bill

A cook's expense for a meal. One bill per cook per meal.

```
Bill ----> Meal
Bill ----> Resident (the cook)
Bill ----> Community
```

**Key fields:**

- `amount` DECIMAL(12,8) -- what the cook spent, in dollars
- `no_cost` -- true if this cook volunteered without cost; MealLedger skips these bills when summing a meal's cost
- DB constraints: `bills_amount_non_negative` (`amount >= 0`) and
  `bills_amount_whole_cents` (`amount = round(amount, 2)`). The model also caps
  the amount at 9999.99, the largest whole-cent value DECIMAL(12,8) holds.
- One bill per cook per meal: `(meal_id, resident_id)` is unique.

**Financial methods:**

Bill has none. All cost math (skipping no_cost bills, applying the community
cap, computing per-unit cost) lives in `MealLedger`, and settlement writes the
results to `meal_charges`.

---

### Meal

A dinner event on a specific date.

```
Meal ----> Community
Meal ----> Reconciliation (optional, NULL = unreconciled)
Meal ----> Rotation (optional, cooking schedule group)
Meal ----< Bill (1-3 cooks typically)
Meal ----< MealResident (8-25 attendees typically)
Meal ----< Guest (0-5 visitors typically)
```

**Key fields:**

- `date` (unique per community)
- `description` -- menu text
- `cap` DECIMAL(12,8) -- cost cap, copied from community at creation. NULL = no cap.
- `closed` / `closed_at` -- locks attendance
- `max` -- attendance cap when closed (NULL until closed)
- `start_time` -- 6pm Sundays, 7pm other days

**Financial methods (all computed from source data, no cached columns):**

- `multiplier` -- SUM of meal_residents.multiplier + guests.multiplier
- `total_cost` -- SQL SUM of bill amounts (excludes no_cost bills)
- `effective_total_cost` -- min(total_cost, max_cost) when capped
- `unit_cost` -- effective_total_cost / multiplier (0 when multiplier is 0)
- `max_cost` -- cap \* multiplier (nil if uncapped)
- `subsidized?` -- true when total_cost exceeds max_cost
- `capped?` / `reconciled?`

**Scopes:**

- `unreconciled` -- reconciliation_id IS NULL
- `open` -- closed = false
- `closed_with_bills` -- closed meals that have at least one bill
- `with_attendees` -- at least one meal_resident or guest. A bill on a meal
  nobody ate has no financial effect: the cook absorbs the cost.

**Immutability:** once `reconciliation_id` is set, `cap`, `date`, and
`reconciliation_id` itself can no longer change. A closed or reconciled meal
also refuses destroy.

---

### MealResident

Join record: a resident attending a meal.

```
MealResident ----> Meal
MealResident ----> Resident
MealResident ----> Community
```

**Key fields:**

- `multiplier` -- copied from resident at signup time (snapshot)
- `late` -- arrived late
- `vegetarian`

**Financial methods:**

- `cost` -- meal.unit_cost \* multiplier

**Attendance rules** (`ClosedMealAttendanceFreeze`, shared with Guest):

- Can join open meals freely
- Can join closed meals if max is set and spots remain
- Cannot join closed meals if max is not set or is full
- Can only be removed from closed meals if signed up after close
- A reconciled meal refuses all of it (`ReconciledMealImmutability`, which runs
  first), backed by a database trigger for paths that skip callbacks
- The one bypass is `admin_correction`, set per row by the ActiveAdmin
  attendance page so an admin can make the record match what happened. It does
  not apply to reconciled meals.

---

### Guest

A non-resident visitor brought by a resident.

```
Guest ----> Meal
Guest ----> Resident (the host)
```

**Key fields:**

- `name`
- `multiplier` -- 2=adult, 1=child
- `late` / `vegetarian`

**Financial methods:**

- `cost` -- meal.unit_cost \* multiplier (charged to the hosting resident)

---

### Reconciliation

A billing period. Creating one sweeps meals and computes balances in the same
step.

```
Reconciliation ----> Community
Reconciliation ----< Meal
                      |
                      +----< Bill ---> Resident (cooks)
Reconciliation ----< ReconciliationBalance ---> Resident
```

**Key fields:**

- `date` -- when the reconciliation was created (defaults to today)
- `end_date` -- the cutoff. Required, and must be strictly before today.

**Behavior:**

- `finalize` (`after_create`) runs `assign_meals` then `persist_balances!`
- `assign_meals` -- claims every unreconciled meal that has at least one bill,
  is dated on or before `end_date`, and is dated strictly before today. It
  takes `SELECT ... FOR UPDATE` on those meals first and raises if a rival
  settlement claimed any of them. See ADR 0003.
- `settlement_balances` -- computes per-resident balances rounded to cents using largest-remainder allocation (Hamilton's method), guaranteeing zero-sum
- `persist_balances!` -- writes the non-zero balances to `reconciliation_balances`
- `unit_balances` -- the same balances grouped by unit, including units at $0.00
- Once a meal is reconciled, its bills, attendance, and guests cannot change

**Immutability:** the reconciliation row itself refuses both update and destroy.
`end_date` says which meals were swept, so editing it would make the stored
cutoff disagree with the settled meals. Corrections settle as new entries in the
next reconciliation.

---

### ReconciliationBalance

What one resident owed or was owed at one settlement. Written by
`persist_balances!`, rounded to cents, and never recomputed on its own.

```
ReconciliationBalance ----> Reconciliation
ReconciliationBalance ----> Resident
```

**Key fields:**

- `amount` DECIMAL(12,8) -- negative = owes, positive = is owed
- `(reconciliation_id, resident_id)` is unique

Unlike `ResidentBalance`, this is not a cache. It is the settled record — what
residents were actually told to pay.

---

### ResidentBalance

Cached balance for a resident. Refreshed daily by `rake billing:recalculate`.

```
ResidentBalance ----> Resident (one-to-one)
```

**Key fields:**

- `amount` DECIMAL(12,8) -- the resident's current balance

This is a **materialized cache**, not a source of truth. It can be rebuilt at any time from bills + meal_residents + guests records.

---

## Scheduling Models

### Rotation

Groups ~12 meals together for cooking duty assignment.

```
Rotation ----> Community
Rotation ----< Meal
```

**Key fields:**

- `description` -- auto-generated date range ("2026-01-05 to 2026-02-16")
- `color` -- one of 5 colors, cycling
- `start_date` -- date of first meal
- `place_value` -- ordering position
- `residents_notified` -- the weekly signup reminder has gone out for this rotation
- `new_rotation_notified_at` -- when the "new rotation posted" email went out

Rotations and Reconciliations are **fully decoupled**. A rotation is about cooking schedules. A reconciliation is about billing periods.

---

## Calendar Models

### Event

A community calendar event (meetings, anniversaries, etc.).

```
Event ----> Community
```

**Key fields:** `title`, `description`, `start_date`, `end_date`, `allday`

### GuestRoomReservation

A guest room booking. One per date per community.

```
GuestRoomReservation ----> Community
GuestRoomReservation ----> Resident
```

**Key fields:** `date` (unique per community)

### CommonHouseReservation

A common area booking. Validates no overlapping reservations.

```
CommonHouseReservation ----> Community
CommonHouseReservation ----> Resident
```

**Key fields:** `title`, `start_date`, `end_date`

---

## Authentication

### Key

An API session. Each login creates a new Key; revoking one means destroying the
row. `Resident#keys_valid_since` revokes every key at once. Identity is
polymorphic so admin sessions could use it later; today only residents do.

```
Key ----> identity (polymorphic: Resident or AdminUser)
```

**Key fields:** `token` (auto-generated via `has_secure_token`, unique)

### AdminUser

Devise-authenticated admin account for the ActiveAdmin interface.
`community_id` is nullable so the very first admin can be created before the
Community exists; creating the Community backfills it.

```
AdminUser ----> Community
```

**Key fields:** `email`, `superuser`

`superuser` is the one authorization boundary in the admin. A plain admin
writes everything except the ledger; a superuser writes the ledger too. A
community must always keep at least one superuser — model guards, a database
trigger, and a controller rule against self-demotion all enforce it. See
ADR 0004.

---

## The Multiplier System

The multiplier is the core unit for proportional cost splitting:

```
Resident age 12 and up:  multiplier = 2
Resident age 5 to 11:    multiplier = 1
Resident under age 5:    multiplier = 0   (eats free)
Adult guest:             multiplier = 2
Child guest:             multiplier = 1
```

`rake residents:set_multiplier` runs nightly and sets each resident's
multiplier from their birthday. A resident with no birthday is an adult
who did not give one; the task skips them and their multiplier stays
whatever the admin set. A `MealResident` copies the resident's
multiplier when the row is created, so a later birthday never changes what
someone was charged for a past meal.

A meal's total multiplier is the sum across all attendees and guests. Cost per multiplier unit = total_cost / total_multiplier. An adult pays 2x what a 5-to-11-year-old pays, and an under-5 pays nothing.

A meal whose total multiplier is 0 — nobody there is old enough to be charged —
has `unit_cost` of 0. The cook absorbs the cost and gets no credit.

Example: $60 meal, 3 adults + 1 child attending:

```
total_multiplier = 2 + 2 + 2 + 1 = 7
unit_cost = $60 / 7 = $8.57142857...
adult charge = $8.57142857 * 2 = $17.14285714...
child charge = $8.57142857 * 1 = $8.57142857...
```

Full precision is maintained during the billing period. At reconciliation, balances are rounded to cents using largest-remainder allocation (Hamilton's method), guaranteeing the rounded balances sum to exactly zero.

---

## Derived vs. Stored Data

All financial values (costs, balances, counts) are **computed from source data** — there are no cached counter columns. The only materialized cache is `resident_balances.amount`, refreshed daily by `rake billing:recalculate`. It can be rebuilt from scratch at any time.
