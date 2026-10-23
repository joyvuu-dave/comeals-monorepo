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
ReconciliationBalance rows (one total per resident). A mistake found in a
settled dinner later is fixed by a MealCorrection: the dinner's rows
change, each person's change is a MealCorrectionLine, and the next
settlement carries it (ADR 0011 rule 6). An old settlement worked out
again during the October 2026 history fixes keeps a SettlementCorrection
of what changed (rule 10).

The arithmetic lives in one place, `MealLedger` (`app/services/meal_ledger.rb`).
No model has a cost method. See "Where the money math lives" below.

---

## Core Models

### Community

The top-level record. Everything belongs to it.

There is exactly one community row, forever. A unique index on
`singleton_guard`, which a CHECK keeps at 0
(`communities_singleton_guard_is_zero`), makes a second row impossible, and
`Community#enforce_singleton` refuses a second create. `before_destroy` and
the `prevent_community_delete` database trigger both refuse to delete the row.
The `before_destroy` is `prepend: true`, so it refuses before the dependent
cascades delete anything (#26).
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
- `dinner_start_times` (jsonb) — seven `"HH:MM"` strings, Sunday first,
  default 19:00. `Community#dinner_start_at(date)` turns one into an
  instant in the community's zone. The `communities_dinner_start_times_shape`
  CHECK calls `comeals_valid_dinner_start_times`.
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
- `singleton_guard` — always 0 (a CHECK), unique. This is what keeps the
  table at one row, even for a write that skips the model.

There is no `slug` column and no friendly_id gem. The slug was removed
in August 2026.

**Behavior:**

- `capped?` — true when `cap` is set
- `meal_schedule` — a `MealSchedule` built from `schedule`
- `create_next_rotation` — asks `meal_schedule` for the next
  `meals_per_rotation` meal dates, starting the day after the last existing
  meal (or today), and creates one Rotation with those meals. This is why
  the admin meal forms refuse a date after the last meal (`Meal`, `date`).
- `averaged_meals` — the meals both dashboard averages read: the ones
  whose costs are final. That is what a settlement with yesterday as its
  cutoff would claim (`Meal.settleable_by`: not settled, from a day that
  is over, at least one cook, someone to charge or no money spent, and
  every cost entered when someone is charged, or cancelled), less any
  cancelled dinner, any meal with a cook's cost not entered yet
  (`Meal.a_cost_not_entered`), and only meals someone ate at. Tonight's meal waits until its day is over. Until
  2026-10-10 the averages counted tonight's meal and every past meal with
  no cook or no cost at $0 (upcoming meals were left out by #98).
- `meals_left_out_of_averages` — how many unsettled meals people ate at,
  on a day that is over, the averages leave out, by reason: cancelled, a
  cost not entered, no cook, or nobody to charge. Each meal is counted
  once: a cancelled dinner only as cancelled, and any other under the
  first reason that fits. The dashboard shows these counts next to
  `averaged_meal_count`, so a missing receipt stays in view.
- `unreconciled_ave_cost` — dashboard "cost per adult" over
  `averaged_meals`. It reads `MealLedger#summary_for`, so it cannot
  disagree with settlement math, and it rounds the BigDecimal half up,
  like `number_to_currency`.
- `unreconciled_ave_number_of_attendees` — dashboard "attendees per meal"
  over `averaged_meals`, the same meals as the cost.
- Clearing the calendar cache and pushing is not the community's job:
  every model a screen shows notes itself in `LiveUpdate` from its own
  `note_live_update` callback, and `LiveUpdate` clears and pushes after the
  commit (ADR 0007). `after_create` also
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
- A resident has no `multiplier` column (dropped in 2026-10, #89). The price
  band is computed from the birthday (`Resident#multiplier_on(date)`), see
  "The Multiplier System" below.
- `active` — false for residents who moved away or died
- `can_cook` — eligible for the cooking rotation
- `can_reconcile` — may preview and create a settlement through the API
  (`Api::V1::ReconciliationsController#require_reconciler`). Only a
  superuser can grant it.
- `vegetarian` — what a tap on the name on the meal page signs a
  resident up with, when they are not signed up
  (`MealFormSerializer#vegetarian`). Their Veg switch is off until they
  are signed up, like Late, because a switch shows only what is saved; a
  tap on it signs them up as a vegetarian. The SPA sends the value on
  sign-up, and the API saves what it sends. The admin form that adds
  someone to a meal sends no value, so it copies this column onto the
  new attendance row (#140).
- `birthday` — two uses: the calendar shows it, and the price band is
  computed from it for the day of each meal (`multiplier_on`). Optional:
  NULL means an adult who gave none, and the calendar shows nothing. A
  child needs one, so the price follows their age; the admin form says
  which the person is (`kind`, a virtual attribute, "adult" or "child"),
  and the model refuses a child without a birthday and a statement the
  birthday contradicts. An adult can remove theirs later from the admin
  resident page. The old placeholder 1900-01-01 is refused by the model
  and by the `residents_birthday_not_sentinel` CHECK.
- `phone` — optional. `HasPhoneNumber` parses any way of typing a number and
  stores the E.164 form ("+15105552671"). The `residents_phone_e164` CHECK
  enforces that shape for writes that skip the model.
- `keys_valid_since` — JWTs issued before this time stop working. A password
  change sets it to now (and destroys any old Key rows).
- `reset_password_token` / `reset_password_sent_at` — password reset by email
- `password_digest`, `reset_password_token`, `reset_password_sent_at` and
  `keys_valid_since` are never sent out. `Resident#serializable_hash` leaves
  them out of every JSON of a resident, the admin's JSON download included,
  and ActiveAdmin's `filter_attributes` (`config/initializers/active_admin.rb`)
  leaves them out of the CSV download. No admin index can be filtered or
  sorted by them either: they are not in `Resident.ransackable_attributes`,
  and both Ransack's filters and `AdminOrderClause`
  (`lib/admin_order_clause.rb`, for `?order=`) read that list.

**Scopes:**

- `adult_on(date)` — no birthday, or `full_price_age` or older on that date,
  counted from the birthday in SQL the same way `Resident#age_on` counts it
- `adult` — `adult_on` the community's today
- `active` — active = true
- `eligible_cooks` — active adults with `can_cook`

**Deletion:** bills, attendance rows, guests, reconciliation balances, meal
charges, settlement correction lines and charges, meal correction lines,
and mail deliveries are all `restrict_with_error`. A resident with any of them can
never be destroyed — retire them with `active` instead. Keys, the balance
cache, and reservations are destroyed with the resident.

**`balance`** reads the `ResidentBalance` cache (refreshed daily by
`rake billing:recalculate`). It is signed: positive means the community owes
the resident. Show it only through `BalanceDisplayHelper#balance_tag`.

**The plain ledger is the stronger oracle.** `spec/support/oracle/plain_ledger.rb`
is a second copy of the balance arithmetic, written on 2026-09-09 from
CLAUDE.md and this file alone by an agent that was told not to open the app,
so it cannot share a misreading with `MealLedger` or `Settlement`. It takes
plain hashes, not rows. Two specs compare the app against it.
`spec/services/meal_ledger_against_plain_ledger_spec.rb` feeds both sides 400
random ledgers and eleven named edges in memory and compares every (meal,
resident) amount, every balance, and the rounding to cents.
`spec/tasks/stored_ledger_against_plain_ledger_spec.rb` writes random ledgers
to the database, runs `billing:recalculate` and a settlement, and compares
what the tables hold. Its independence is the whole point: when a money rule
changes, write the rule down here first, then have someone who has read the
rule and not the code change the plain ledger. Never edit it to match
`MealLedger`.

Until 2026-09-09 `Resident` carried an older oracle (`calc_balance` and four
helpers). It was written next to the code, so it read like the code, and it
picked meals with the app's own scopes. The plain ledger replaced it.

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
                                   unit_cost = effective_cost / total multiplier, cut to the grain
        |
        +-------> credit line  for each bill:   + cook's share of effective_cost
        +-------> debit line   for each eater:  - eater's share of effective_cost, by multiplier
        +-------> guest_debit  for each guest:  - guest's share of effective_cost, charged to the host
        |
        v
    MealLedger#balances            sum of a resident's lines (at the grain, see below)
        |
        +-----> rake billing:recalculate  ->  resident_balances   (running, at the grain)
        +-----> Settlement#settle!        ->  meal_charges        (every line, at the grain)
                                              reconciliation_balances (rounded to cents)
```

Every share above is allocated, never divided. See "The ledger grain".

Signs: positive means the community owes the person. A credit is positive, a
debit is negative. This is set once in `MealLedger` ("Signs" section) and
every stored amount inherits it. No screen shows the sign itself; see
CLAUDE.md money rule 11.

### The ledger grain

Every amount the ledger produces is a whole number of units of 10^-8
dollars. That is the grain of the money columns (DECIMAL(16,8)) and of every
line, so what is computed is what is stored. Nothing on the money path
holds more digits than that.

A split never divides. When an amount has to be shared out in proportion to
weights, it is allocated by largest remainder at the grain:

1. Each line first gets the whole units of its exact share: the amount
   times its weight, divided by the total weight, rounded down.
2. The units left over (fewer than there are lines) go one each to the
   lines whose exact share lost the most in step 1.
3. Ties go to the lowest resident id. Between an attendee line and a guest
   line of the same resident, the attendee line comes first. Between two
   guest lines of the same host, the lower guest id comes first.

So the lines of a split sum to exactly the amount that was split, and each
line is within one unit of its exact share.

Two splits happen on a meal:

- The effective cost across the eaters (attendees and guests), each
  weighted by their multiplier. These are the debit and guest_debit lines,
  negated.
- On a subsidized meal only, the effective cost across the cooks, each
  weighted by their bill amount. These are the credit lines. On a meal that
  is not subsidized, each cook's credit is their bill amount as it is.

Both splits give out the same effective cost, so a meal's credits and debits
sum to exactly zero, and every check on the money path is an equality: no
tolerance, no epsilon. The database holds the same rule: the deferred
constraint trigger `meal_charges_sum_zero` refuses a commit that leaves a
meal's stored lines summing to anything but zero.

The unit cost a screen shows (effective cost divided by the total
multiplier) is cut to the grain, rounded down. It is a figure for a person
to read. No line is computed from it, so a debit of an eater with
multiplier 2 can differ from twice the unit cost by one unit.

Rounding to cents happens once, at settlement, on the per-resident totals,
by the same largest-remainder method at the cent (CLAUDE.md money rule 5).

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
  such a bill: it neither credits the cook nor raises what anyone pays. A
  bill marked No cost has amount 0 (below).

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
- A saved bill keeps its cook and its meal: a bill is "this cook on this
  meal" (ADR 0009, #135). The model refuses a new `resident_id` or
  `meal_id` on update (`Bill::COOK_AND_MEAL_FIXED`), and the
  `bills_same_cook_and_meal` trigger refuses it from writes that skip the
  model, in the same words, as a check violation. Only the amount and
  `no_cost` change. To fix a wrong cook or meal, delete the bill and add
  a new one; the meal history then says who was removed and who was
  added. The trigger's name sorts after `bills_reject_settled_write`, so
  on a settled meal that trigger answers first. Until 2026-10-10 the
  admin form could change the cook in place. Production holds a few rows
  that changed one old bill's cook; the history reads them as "Bill moved
  from X to Y", with two names (`AuditDescription`).
- A bill marked No cost has no amount, because "No cost" means the cook
  spent nothing. The model refuses both at once in words
  (`Bill::NO_COST_MEANS_NO_AMOUNT`: "A bill marked No cost can't have an
  amount. Clear the amount, or turn No cost off."), the bills save answers
  400 in the same words, and the CHECK `bills_no_cost_means_no_amount`
  (`NOT no_cost OR amount = 0`) refuses it from writes that skip the
  model. Before April 2026 the meal page let a cost be typed into a row
  marked No cost, and `MealLedger` left that cost out, so the cook was
  credited $0 for what they spent. The owner decided on 2026-10-10 to fix
  every such bill during the deploy, with no person doing anything, in
  three migrations (run, and since deleted):
  1. The first added the CHECK `NOT VALID`, so every bill added or
     changed from then on was checked. It came first so that the old
     release, which kept serving while the migrations ran, could not write
     a bill with both after step 2 had looked.
  2. The second turned No cost off, and kept the amount, on every
     bill that had both. Some of those bills were on meals not settled yet,
     whose amounts counted at the next settlement, and some were on
     settled meals. It wrote one audit row
     for each, so the meal history says "Bill for (the cook) no longer
     marked as no cost, so the (amount) now counts in the meal's cost".
     On a settled meal it used the repair bypass for that one write. Then,
     in the same transaction, it worked out again
     each settlement that claimed one of the fixed bills
     (`Settlement#correct!`, under Reconciliation below), so those
     settlements count the amounts too.
  3. The third validated the CHECK.
- **The settlements of those settled meals were worked out again.**
  The owner decided on 2026-10-10 that every settled number must be
  right; nobody recorded what was paid or collected for them. Each keeps
  its row, its meals and its cutoff, and gets new balances and line items
  and a `SettlementCorrection` with each changed balance before and
  after. A balance can move by a leftover cent even for a person who ate
  at none of the fixed meals, because the cents are allocated again
  across the whole settlement. `MealLedger` still
  leaves out a no-cost bill whatever it holds, though no bill in the
  table has both now.
- Audited (the `audits` table), linked to the meal. The history names the
  cook of each update row from the bill's own audit rows, in order, not
  from the bill as it is now, and reads the amount the same way.

**Financial methods:** none. All cost math is in `MealLedger`.

---

### Meal

A dinner on one date.

```
Meal ----> Community
Meal ----> Reconciliation (optional; NULL = unreconciled)
Meal ----> Rotation (required; the cooking schedule group)
Meal ----< Bill (1-3 cooks is typical)
Meal ----< MealResident (8-25 attendees is typical)
Meal ----< Guest (0-5 visitors is typical)
Meal ----< MealCharge (written at settlement; empty until then)
```

**Key fields:**

- `date` — unique (`index_meals_on_date`). The admin New Meal form and the
  meal edit form refuse a date after the last meal of the calendar, the end
  of the last rotation (#143): "This date is after the last rotation, which
  ends Mar 3, 2027. Add the meal once the calendar reaches that date." The
  next rotation starts the day after the last meal, so with a meal after
  the end, the schedule days between the end and that meal would never get
  a meal. On an edit the meal counts at the date it has before the edit, so
  the last meal can move earlier but not later. Only the forms set the flag
  the check runs on (`from_admin_form`); the nightly job and the seeds make
  the meals after the end. With no meal at all, any date is allowed.
- `rotation_id` — required by the model and by NOT NULL (#100). The nightly
  job makes each rotation with its meals. A one-off meal from the admin New
  Meal form goes in the rotation the admin picks; the form chooses the
  rotation whose first-to-last meal dates contain the date, and asks the
  admin when no rotation does (`RotationChoicesHelper`).
- `description` — menu text
- `cap` DECIMAL(12,8) — copied from `community.cap` when the meal is created.
  NULL means no cap. CHECK `meals_cap_positive_or_null`.
- `closed` / `closed_at` — closing freezes attendance. `closed_at` is set
  when `closed` flips to true and cleared when it flips back.
- `max` — extra spots allowed after close. NULL while the meal is open:
  any save through the model of an open meal sets it to NULL before
  validation (`conditionally_set_max`), so a reopen clears it. Only the
  model does this. The database has no CHECK for it, so `update_all` or
  psql can store a max on an open meal. A new max cannot be less than
  the current attendee count. The check runs only when max changes,
  because an admin attendance correction can add a person past it, and the
  meal must still take a menu edit or a reopen then (#93).
- `cancelled_at` — when the dinner was cancelled; NULL for one that was not
  (ADR 0011 rule 11). `cancel!` sets it and `restore!` clears it; each
  does nothing when the dinner is already that way. A cancelled dinner
  keeps its sign-ups, guests and cooks and charges nobody (every line is
  $0, see "The Multiplier System"). While it is cancelled, only its
  description can change: its sign-ups, guests and costs are frozen
  (`CancelledDinnerFreeze`, and the trigger
  `comeals_reject_settled_child_write`), and so are `closed`, `max`, `date`,
  `cap` and `rotation_id`. A dinner with a cost over $0 not marked no-cost
  cannot be cancelled (the model, and the trigger `meals_protect_settled`).
  It refuses destroy until it is restored. The next settlement takes it in
  whatever its costs and sign-ups, and then `cancelled_at` is frozen like
  `cap` and `date`.

**Derived counts (no cached columns):**

- `multiplier` — sum of `meal_residents.multiplier` and `guests.multiplier`
- `attendees_count` — number of attendance rows plus guest rows
- `capped?`, `reconciled?`, `cancelled?`

**No cost methods, on purpose.** `total_cost`, `unit_cost`,
`effective_total_cost`, `max_cost`, and `subsidized?` do not exist on Meal.
What a meal costs is `MealLedger`'s arithmetic. Screens read it through
`MealCostSummary` (see "Where the money math lives"). A copy on this model is
how the math once ended up in three places (#48).

**Scopes:**

- `unreconciled` — reconciliation_id IS NULL
- `cancelled` / `not_cancelled` — cancelled_at set or NULL
- `open` — closed = false
- `closed_with_bills` — closed meals that have at least one bill
- `with_attendees` — at least one attendance or guest row.
- `a_cost_not_entered` (an Arel condition, not a scope) — a bill of $0
  not marked no-cost: the cook has not entered a cost yet. The meal page
  reads a bill the same way (`cooksMissingCost`). The dashboard averages
  leave such a meal out (`Community#averaged_meals`).
- `waiting_for_a_cost` — someone to charge (an attendance row with a
  multiplier above 0, or a guest) and a cost not entered. A settlement
  leaves such a meal open (`settleable_by`) until every cook enters a
  cost or marks No cost, and the preview lists it as `cost_not_entered`
  (ADR 0011 rule 3). Until 2026-10 it was settled and the blank cost was
  locked at $0. A meal with nobody to charge does not wait for a cost:
  no money moves whatever the cook enters, so it settles with no effect,
  and the preview lists its blank cost as `zero_bill_not_flagged`.
- `receipt_and_nobody_to_charge` — a bill with money on it, no
  attendance row with a multiplier above 0, and no guest (a guest always
  pays, as an adult or as a child): nobody signed up, or only residents
  who eat free did. Nobody can be charged a share, so settling
  would credit the cook $0 for good. A settlement holds such a meal back
  (`settleable_by`), and the preview lists it as `bill_with_no_attendees`
  or `bill_with_only_free_eaters`. A meal with nobody to charge whose cook
  slots are all $0 or no-cost settles with no effect. A correction to a
  settled meal is refused when it would leave the meal in this scope
  (`MealCorrecting::NobodyToCharge`, ADR 0011 rule 6). (Until 2026-09-10 a
  meal nobody signed up for was settled with no lines, and until
  2026-10-09 a meal only free eaters ate was settled with every line at
  $0, #94.)

**Immutability:** once `reconciliation_id` is set, `cancelled_at`, `cap`,
`date`, and `reconciliation_id` itself can no longer change
(`FROZEN_WHEN_RECONCILED`),
and the meal refuses destroy. A closed meal also refuses destroy: reopen it
first. Both destroy guards are `prepend: true` so the bill and attendance
cascades never run before the refusal (#26). The `meals_protect_settled`
trigger enforces the same update and delete rules in the database.

`has_many :meal_charges` is `restrict_with_error`, a second reason a settled
meal cannot be destroyed.

**Other:** audited, with associated audits from its bills, attendance, and
guests (`total_audits`). `note_live_update` notes the meal's page and its
month in `LiveUpdate`, which clears the calendar cache and pushes after the
commit (ADR 0007).

---

### MealResident

Join record: a resident attending a meal.

```
MealResident ----> Meal
MealResident ----> Resident
MealResident ----> Community
```

**Key fields:**

- `multiplier` — the resident's price band for the meal's date, as of the
  row's creation (`Resident#multiplier_on`), copied in when none is given
  (`set_multiplier`) and refused when a different one is given
  (`multiplier_is_the_residents`). A later birthday or a changed age rule
  never changes a past charge. Two things change it. One is an admin
  moving the meal to another date: every row then gets the band for the
  new date (`Meal#restamp_attendance_for_new_date`). The meal history
  names each such change in the price words, for example "Sam: Child to
  Adult" (`AuditDescription`). The other is a superuser's correction of
  a settled dinner that reprices the sign-up
  (`MealCorrecting::Edits#reprice_eater`, ADR 0011 rule 6), for a price
  that was wrong when the person signed up: the row gets the resident's
  band for the meal's date as the rule stands at the correction, and
  the correction saves the change in what each person owes. Required;
  CHECK `meal_residents_multiplier_non_negative`.
- `late` — arrived late. Required: true or false. A nil (a flag left out
  of a sign-up, or sent as `""`) is refused with "must be true or false"
  (#121).
- `vegetarian` — required: true or false, the same as `late`.

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
- Can be moved to another meal only if it could leave the old meal and join
  the new one under the rules above: a move is a removal and an addition
- Can change its price (`multiplier`) on a closed meal only if it could be
  removed: a lower price raises every other eater's share, the same as a
  removal (#92)
- Can change who it charges (`resident_id`: a guest's host, or the person
  on an attendance row) on a closed meal only if it could be removed: it
  moves a whole share from one person to another. Nothing in the app
  changes the person on an attendance row (the model and the database
  still allow it; a few production rows on one old meal did it, and the
  history reads them as "Sign-up moved from X to Y", with two names);
  the admin meal form offers a host for every guest. To fix a wrong host on a closed meal, reopen the
  meal, change the host, and close it again. Reopening clears `max` and
  the close time, so extras added after the first close can no longer
  leave
- A save that closes the meal (the admin form's Closed box) counts as
  closed for its rows: every row already on the meal was there before the
  close, so a removal, a new price or a new host in that same save is
  refused
- A reconciled meal refuses all of it (`ReconciledMealImmutability`, included
  first so it runs first), and the `meal_residents_reject_settled_write`
  trigger enforces the same rule for writes that skip callbacks
- The one bypass is `admin_correction`, set per row by the ActiveAdmin
  attendance page so an admin can make the record match what happened. It
  does not apply to reconciled meals. `Meal#restamp_attendance_for_new_date`
  sets it too, so a closed meal an admin moves to another date takes the
  bands for the new date.

Audited, linked to the meal.

---

### Guest

A non-resident visitor brought by a resident. The guest's cost is charged to
the host.

```
Guest ----> Meal
Guest ----> Resident (the host)
```

**Key fields:** `multiplier` — 2 (Adult, the default) or 1 (Child),
nothing else (`Multiplier::GUEST_PRICES`, a model validation, and CHECK
`guests_multiplier_adult_or_child`). A guest is never free: free is a price
only a resident's age gives. The admin meal form offers exactly these two,
so it can always show the price a guest has, and a save never changes a
price nobody touched. Until 2026-10-09 the column took any number of 0 or
more, and the form sent Adult for any other value. Also `late`,
`vegetarian`, `meal_id`, `resident_id` (the host), timestamps. There is no `name` column and no `community_id`
column; a guest reaches the community through its host. `late` and
`vegetarian` are required: true or false. A nil is refused with "must be
true or false" (#121). Nothing in the app writes a guest's `late` today:
the API and the admin form leave it at the column default, false.

**Indexes:** `index_guests_on_meal_id`, `index_guests_on_resident_id`.

**Financial methods:** none. `MealLedger` makes a `guest_debit` line with the
host's `resident_id`.

**Rules:** the same `ReconciledMealImmutability` and
`ClosedMealAttendanceFreeze` as MealResident, in that order, and the
`guests_reject_settled_write` trigger. On a closed meal, a guest who was
there when it closed keeps its price and its host. Audited, linked to the
meal. The meal history names a new host ("Guest of Ann moved to Bob") and a
new price ("Guest of Ann: Adult to Child"), with the host the guest had
when the change was made (`AuditDescription`).

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
- `end_date` — the cutoff. Required, and must be at least 14 days before
  today (`Reconciliation::DAYS_TO_WAIT`, ADR 0011 rule 2), so a cook has
  time to fix a cost before the dinner is locked.
- `units_recorded_on` — the day each line's unit was saved. A settlement
  made before units were saved has a later day than its `date`
  (`units_recorded_later?`), and its page says so.

**Validations:**

- `end_date` present and at least 14 days before today, in the
  community's time zone (`Reconciliation.cutoff_refusal`, which
  `Settlement.preview` also reads)
- On create, at least one eligible meal, or one correction no settlement
  carries yet (`MealCorrection.waiting`), must exist. An empty settlement
  could never be removed (the row is append-only), so it is refused up
  front.

**Behavior:**

- A reconciliation row is only ever written by `Settlement`
  (`app/services/settlement.rb`), in the same transaction that claims the
  meals and writes the ledger. `Reconciliation.create!` on its own raises
  `Reconciliation::NotSettled`, so no path can leave a settlement that
  settled nothing. The rake task, the API and the admin form call
  `Settlement.settle!` through `SettleAndNotify`, and the seeds and the
  specs call `Settlement.run!(cutoff:)`; the pipeline is:
  1. save the row (validations run here);
  2. `assign_meals` — claim every meal in `eligible_meals`
     (`Meal.settleable_by(end_date)`: unreconciled, dated on or before the
     cutoff, from a day that is over, and either cancelled, or with a bill,
     someone with a price to charge or nothing owed, and every cost
     entered or marked No cost when someone is charged). It takes
     `SELECT ... FOR UPDATE` on those meals in id order first, then updates
     only rows whose `reconciliation_id` is still NULL, and raises if a rival
     settlement claimed any of them. See ADR 0003.
  3. `claim_corrections` — claim every correction no settlement carries
     yet (ADR 0011 rule 6), the same way: `SELECT ... FOR UPDATE` in id
     order, then an update only where `reconciliation_id` is still NULL,
     with `comeals.settling` on for that update, and `Contested` if a
     rival claimed one first.
  4. `write_ledger!` — one `MealLedger` pass, then, in a savepoint inside
     the settlement's transaction:
     every line (including zero lines) into `meal_charges` with
     `insert_all!`, and each non-zero rounded balance into
     `reconciliation_balances`. Both tables come from the same read, so the
     lines explain the balances. While it writes, it sets the database
     setting `comeals.settling` (`Settlement::SETTLING_SETTING`) to the
     reconciliation's id, and it turns the setting off when it is done. The
     database refuses an insert into either table without it (see
     "Append-only ledger" below). `insert_all!` and not `insert_all`:
     without the bang, a line already on the meal would make it skip the
     real line with no error.
  5. with the fingerprint of a preview (the admin form's Create button),
     refuse when the claimed meals and corrections or the stored balances
     differ from what that preview showed (`Settlement.fingerprint`,
     `Settlement::Changed`, ADR 0011 rule 4). Everything rolls back.
  6. after commit, clear the cached calendar months of the claimed meals,
     and tell each claimed meal's page to reload (`forget_cached_meals`,
     through `LiveUpdate`).
- `eligible_meals` — the scope above; the create validation and the claim
  read the same one, so they cannot disagree.
- `settlement_ledger` — a `MealLedger` over the claimed meals, with bills,
  attendance, and guests preloaded. The settlement writes from this.
- `settlement_balances` — `MealLedger#balances` for every resident, plus
  the lines of the corrections this settlement carries, minus the lines
  of every correction made later to one of its own meals (those changed
  the meals' rows, which the ledger reads as they are now, so taking them
  off keeps what it settled), then `Settlement.allocate_to_cents`: largest-remainder rounding (Hamilton's
  method) so the cent amounts sum to exactly zero. Each amount is within one
  cent of its exact value. Ties go to the lowest `resident_id`. It raises if
  the input does not already sum to exactly zero (a meal's lines always do,
  see "The ledger grain") or if the output does not. `rake ledger:verify`
  recomputes through this method.
- `Settlement#rewrite!` — repair only: rewrites the ledger of an existing
  row after both tables were cleared inside one transaction with the
  settled-write bypass on (`docs/runbooks/settled-data-repair.md`).
- `Settlement#correct!(reason:) { fix the rows }` — fixes a settled
  period's rows in the block and works the period out again from them,
  when the owner decides the settlement must show the right numbers. In
  its own savepoint: it locks the reconciliation row; refuses, writing
  nothing, a settlement with a line marked Paid or Let go
  (`Settlement::Marked`) or with a dinner that has a correction
  (`Settlement::DinnerCorrected`: that settlement keeps what it settled,
  and its line items written again from the corrected rows would count
  the correction twice); asks the nightly
  check about the settlement (`LedgerVerification#findings_for`) and
  refuses with `Settlement::EarlierDifference`, writing nothing, if it
  already disagrees with its rows or its line items, since the correction
  would fold that in under the caller's reason (a caller that means to
  passes `include_earlier_differences: true`, and the record keeps that
  and what the check found); runs the block, which must end normally or
  raise (one left by `return`, `break` or `throw` raises
  `Settlement::FixLeftEarly`, because Rails would commit the savepoint
  with the fix and no correction); copies the
  line items it is about to delete into the record; clears both tables
  with the bypass on for those two deletes only; writes them again with
  `write_ledger!` (so a settlement from before line items gets them); and
  records a line per changed balance. The row, its meals and its cutoff
  stay. Because the cents are shared out across the whole settlement, a
  person who ate at none of the fixed meals can move by one cent; the
  record keeps that too. `settlement_corrections` lists them, oldest
  first. No admin page shows them; `docs/runbooks/settled-data-repair.md`
  has the query that reads them.
  The code is in `SettlementCorrecting` (`app/services/settlement_correcting.rb`),
  which `Settlement` includes.
- `unit_balances` — the settled balances grouped by unit, including units at
  $0.00

**Immutability:** `AppendOnly`. The row refuses both update and destroy.
`end_date` says which meals were swept, so editing it would make the stored
cutoff disagree with the settled meals. Corrections settle as new entries in
the next reconciliation, except where the owner decides a settlement's
numbers must be worked out again (`Settlement#correct!`, above). The
destroy guard is prepended so the meal-nullify
and balance-destroy cascades never run (#26). Once a meal is reconciled, its
bills, attendance, and guests cannot change. Audited.

---

### SettlementCorrection

The record of a settlement worked out again after it was made
(`Settlement#correct!`): when (`created_at`), why (`reason`), whether the
caller let it fold in differences the nightly check had already found
(`include_earlier_differences`) and what the check found just before
(`earlier_differences`, in the shape of `ledger_check_runs.details`), a
`SettlementCorrectionLine` for each person whose settled balance changed,
with `old_amount` and `new_amount`, and a `SettlementCorrectionCharge` for
each line item the correction deleted, column for column, with its old id
(`meal_charge_id`) and the time it was written (`charged_at`). The amounts
are signed like a settled balance and a line item; a line's amount is zero
when the person had no balance on that side. No screen shows the record
(the owner's choice, 2026-10-12); the runbook has the query.

```
SettlementCorrection ----> Reconciliation
SettlementCorrection ----< SettlementCorrectionLine ----> Resident
SettlementCorrection ----< SettlementCorrectionCharge ----> Meal, Resident
```

A record of what a settlement said before and after, so it never changes:
`AppendOnly` on the three models, and a trigger on the three tables
refuses UPDATE and DELETE unless the repair bypass is on
(`comeals_protect_settlement_correction`). Another trigger refuses an INSERT unless
`comeals.settling` names the correction's reconciliation, which
`Settlement#correct!` sets while it writes the record, or the bypass is
on. CHECKs: the reason is not blank; a line's two amounts differ (the model
checks that too); `earlier_differences` is a list, and empty unless
`include_earlier_differences` (the model checks that too). One line per person per correction (unique
index). The migration's down refuses while a correction is recorded.

---

### MealCorrection

A correction to a settled dinner (ADR 0011 rule 6), written only by
`MealCorrecting` (`app/services/meal_correcting.rb`): the dinner
(`meal_id`), who made it (`admin_user_id`), why (`reason`), what changed
(`edits`, one entry per edit: `what` is cost, eater or guest,
`resident_id` the cook, eater or guest's host, `from` and `to` the value
before and after, nil when a row was added or removed), and the
settlement that carries it (`reconciliation_id`, empty until one does).
A `MealCorrectionLine` for each person whose amount changed, at the
ledger grain, signed like a line item; a correction's lines sum to
exactly zero. `CorrectionWords` turns each edit into a sentence for the
admin pages and the API preview.

```
MealCorrection ----> Meal (the dinner it corrects, settled)
MealCorrection ----> AdminUser
MealCorrection ----> Reconciliation (the settlement that carries it)
MealCorrection ----< MealCorrectionLine ----> Resident
```

How a correction is made: `MealCorrecting.save!` locks the meal row FOR
UPDATE, refuses an open meal (`NotSettled`) and a meal whose rows
already differ from what it was settled at plus its earlier corrections
(`EarlierDifference`, `SettledDinnerDifference`), works out what each
person is credited or charged for the dinner from its rows
(`MealLedger`), sets `comeals.correcting` to the meal's id, runs the
edits (`MealCorrecting::Edits`: a cook's cost, add or remove a cook, add
or remove an eater, an eater's price for their age on the dinner's date,
add or remove a guest), works it out again, and records the difference
for each person. `MealCorrecting.preview` does the same and rolls back;
its `fingerprint` lets the save refuse (`Changed`) a correction that
came out different from the preview. A correction that changes nothing
is refused (`NothingChanged`); one that moves no money (a blank cost
marked No cost) is recorded with no lines. A correction that leaves the
dinner with money on a cost and nobody who pays is refused
(`NobodyToCharge`, #172), read with `Meal.receipt_and_nobody_to_charge`,
the scope a settlement holds an open dinner back by: the next settlement
would credit the cook $0 for that money.

The admin form (`MealCorrectionForm`) sends every row of the dinner, so
it also sends a code made from the rows it showed when it was opened
(`correction[seen]`, `MealCorrectionForm::Rows#seen`: each cook and
their cost, each eater and their price, each guest). Preview and Save
are refused (`MealCorrectionForm::STALE`) when the dinner's rows now
make another code, or when the form sent none, so a row the admin did
not touch never writes back a value someone corrected after the form
was opened. The rows are checked when the form is read and again under
the meal's lock.

A settlement made before line items existed (2026-08-02) stored nothing
its dinners were settled at, so for a dinner of such a settlement the
refusal comes from the nightly check's own checks of the whole
settlement instead (`LedgerVerification#findings_for`: the recompute
check, at the cent). Such a dinner can be corrected like any other.

The database keeps the rules for psql too (`comeals_meal_correction_guard`,
`comeals_meal_correction_line_guard`, and the `comeals.correcting` check in
`comeals_reject_settled_child_write`): a correction is inserted only for a settled meal
that `comeals.correcting` names, with no settlement yet; its lines only
while the same holds; the lines sum to zero
(`meal_correction_lines_sum_zero`) and are never zero (CHECK). Nothing
changes or is deleted, except that a settlement sets `reconciliation_id`
once, from empty to itself, while `comeals.settling` names it, and only
a settlement later than the meal's own. The settled-meal trigger
(`comeals_reject_settled_child_write`) lets through writes to the bills,
attendance and guests of the one meal `comeals.correcting` names. The
repair bypass lets all of it through. The migration's down refuses while
a correction is recorded.

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
- `amount` DECIMAL(16,8) — signed the MealLedger way, a whole number of
  units at the ledger grain. Show it only through
  `BalanceDisplayHelper#charge_amount_tag`.
- `unit_cost` DECIMAL(16,8) — the meal's cost per multiplier unit, cut to
  the grain; a display figure, no line is computed from it
- `multiplier` — units eaten. Present on debits only (CHECK
  `meal_charges_multiplier_on_debits_only`, `_non_negative`).
- `bill_amount` DECIMAL(12,8) — what the cook actually spent, before any cap.
  Present on credits only (CHECK `meal_charges_bill_amount_on_credits_only`).
  On a subsidized meal it is larger than `amount`, and is the only record of
  why the cook was not paid back in full.

**Indexes:** `index_meal_charges_on_meal_id`,
`index_meal_charges_on_resident_id`, and two partial unique indexes:
`index_meal_charges_one_credit_per_cook` and
`index_meal_charges_one_debit_per_attendee` (both on `(meal_id, resident_id)`,
one for `kind = 'credit'` and one for `kind = 'debit'`). A host can have
several `guest_debit` lines on one meal, so those are not unique.

**Methods:** `credit?`; `subsidized?` — true on a credit whose `bill_amount`
is larger than `amount`: the cook was credited less than they spent, for any
reason (a cap, or nobody who ate had a price). There are two `subsidized?`
methods: this one, which `MealCostSummary` reads for a settled meal, and
`MealLedger`'s private one, which `summary_for` uses for an open meal. Both
ask the same question, so a meal's screen says the same thing before and
after it is settled (#94).

**Immutability:** `AppendOnly` in the model; the `meal_charges_protect`
trigger refuses every UPDATE and DELETE in the database, and
`meal_charges_insert_by_settlement` refuses every INSERT except one from
the settlement of the meal's reconciliation. A meal that is not settled
has no reconciliation, so no line can be added to it. The deferred
constraint trigger `meal_charges_sum_zero` refuses a commit that leaves a
meal's lines summing to anything but zero, and the repair bypass does not
turn it off. Reconciliations
settled before 2026-08-02 have no lines (see
`docs/money-path-observability.md`).

---

### ReconciliationBalance

What one resident owed or was owed at one settlement. Written by
`persist_balances!`, rounded to cents, and never recomputed.

```
ReconciliationBalance ----> Reconciliation
ReconciliationBalance ----> Resident
ReconciliationBalance ----> Unit
```

**Key fields:**

- `amount` DECIMAL(16,8) — signed: positive means the community owes the
  resident ("is owed"), negative means the resident owes ("owes"). Show it
  only through `BalanceDisplayHelper#balance_tag`.
- `unit_id` and `lived_here` — the person's unit and active flag on the
  day of the settlement (ADR 0011 rule 7). The settlement page adds up
  each unit from these, and the lines with `lived_here` false on a line of
  their own, "Moved out", so the totals never change later. A rework
  (`Settlement#correct!`) keeps them (`Reconciliation#saved_units`).
  `reconciliations.units_recorded_on` is the day they were saved; for the
  settlements made before 2026-10-10 it is the day a migration filled
  them in. Such a settlement's `lived_here` is about that
  later day, so its page counts everyone in their unit, with no "Moved
  out" line, and says so (`Reconciliation#records_who_moved_out?`).
- `(reconciliation_id, resident_id)` is unique
  (`index_recon_balances_on_recon_id_and_resident_id`). There is also
  `index_reconciliation_balances_on_resident_id`. The single-column
  `reconciliation_id` index was dropped; the composite covers it.

**Immutability:** `AppendOnly` in the model. Three triggers in the database:
`reconciliation_balances_protect_settled` refuses every UPDATE and DELETE,
`reconciliation_balances_insert_by_settlement` refuses every INSERT except
one from the reconciliation's own settlement, and
`reconciliation_balances_sum_zero`, a deferred constraint trigger, checks
at commit time that the balances of every touched reconciliation sum to
exactly zero.

Unlike `ResidentBalance`, this is not a cache. It is the settled record —
what residents were actually told to pay.

---

### SettlementLineMark

What happened to a settlement line after the settlement (ADR 0011 rule 8):
Paid, Let go, or none (a mark taken off), with an optional note ("paid $20
of $40"), the admin who made it, and when. A mark never changes what anyone
owes. Each change is a new row; the newest counts
(`ReconciliationBalance#current_mark`), and the rest are the history the
settlement page shows. Written only by `SettlementLineMarking`, which locks
the line and refuses a change made on a page that did not see the newest
mark.

```
SettlementLineMark ----> ReconciliationBalance
SettlementLineMark ----> AdminUser
```

Any admin may mark a line Paid. Setting or changing a Let go mark needs a
superuser (`SuperuserAdapter`, the `:let_go` action). Append-only:
`AppendOnly` in the model and the trigger `settlement_line_marks_protect`
(`comeals_protect_settlement_line_mark`), with the repair bypass. The foreign key keeps a
marked line from being deleted, and `Settlement#correct!` refuses a
settlement with a mark.

---

### ResidentBalance

Cached running balance for a resident over the unreconciled meals, plus
the lines of the corrections no settlement carries yet (`MealCorrection`,
ADR 0011 rule 6). Refreshed daily by `rake billing:recalculate`, which
reads the meals and the waiting correction lines in one SERIALIZABLE READ
ONLY snapshot, runs `MealLedger#balances`, adds the correction lines, and
writes the rows with `upsert_all` keyed on `resident_id`.

```
ResidentBalance ----> Resident (one-to-one)
```

**Key fields:**

- `amount` DECIMAL(16,8) — at the ledger grain, signed the MealLedger way
- `resident_id` unique (`index_resident_balances_on_resident_id`)
- CHECK `resident_balances_amount_not_nan`

This is a cache, not a source of truth. It can be rebuilt at any time from
bills, attendance, and guests.

---

### LedgerCheckRun

One night's record of `rake ledger:verify`. The task (`LedgerVerification`)
runs three checks on every reconciliation:

1. `recompute`: it works the settlement out again from its source rows and
   compares the result to the stored balances.
2. `line_items`: it checks that the stored `meal_charges`, plus the lines
   of the corrections the settlement carries, add up to the stored
   `reconciliation_balances`.
3. `dinners`: it checks that each settled dinner's rows add up to what the
   dinner was settled at plus its corrections, for every person
   (`SettledDinnerDifference`).

A settlement made before `meal_charges` existed has no lines, so it gets
the first check only. Every run is recorded, pass or fail. See
`docs/money-path-observability.md`.

No associations.

**Key fields:** `started_at`, `finished_at` (CHECK
`ledger_check_runs_finished_after_started`), `reconciliations_checked`,
`mismatch_count` (both CHECKed non-negative), `error` (text, NULL when the run
finished), `details` (jsonb). Index on `started_at`. Each detail names the
check that found it: `recompute`, `line_items` or `dinners`. The first runs, from
2026-08-02, name none and mean `recompute`, the only check then. The shape
never changes, because past runs use it (`LedgerVerification#detail`).

**Methods:** `passed?` (no error, zero mismatches), `failed?` (some
mismatches, whether or not the run then finished), `errored?` (the run did not
finish), `duration`. A run that found a difference and then crashed is both
failed and errored. Scope: `recent`.

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
  holidays `Holidays.holiday?` names. Raises instead of looping forever on a
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

- `description` — the date range of its meals ("Jan 5 – Feb 16, 2026",
  `DateRangeDescription`), read from the meals every time. Not a column.
- `color` — one of the 5 `COLORS`, cycling from the previous rotation's color
- `start_date` — the date of its first meal, read from the meals every
  time. Not a column.
- `place_value` — position in date order, renumbered after create and destroy
- `residents_notified` — `rake residents:notify` has sent the signup reminder
  for this rotation
- `new_rotation_notified_at` — when `rake rotations:notify_new` sent the
  "new rotation posted" email. `no_email` (not a column) sets it at create
  so the email is skipped.

**Deletion:** `has_many :meals, dependent: :destroy`, guarded by two
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
`end_date`, `allday`. An event must have an `end_date` or be all day. A
timed event must end after it starts. An end before the start is
refused on every save. An end equal to the start is refused only when a
save sets or changes the times, or turns all day off (#141), so events
saved before that rule that end when they start (three in a copy of
production from September 2026) can still be saved with a new title. The one exception is midnight to midnight in
the community's zone, which is how a notice is saved. A timed event must
start and end on the same day in the community's zone (#154): an event
that ends at the next midnight ends on the next day. This is checked
when a save sets or changes the times, or turns all day off, the same
writes the trigger below checks. A change of the community's zone can
leave an event that ends on the next day (20:00 to 23:00 in Los Angeles
is 23:00 to 02:00 in New York), and it can still be saved with a new
title (#173). The admin community form shows how many events and
bookings a new zone would move, and which would cross midnight, before
it saves the zone (`ZoneChange`). The API keeps the stored times when
an edit form sends back the day and times the event shows.
The database refuses an end before the start with a CHECK
(`events_end_not_before_start`, #149). A trigger (`events_one_day`)
refuses a write that gives a timed event an end on a later day in the
community's zone, so two copies of one event, saved one after the other,
cannot leave one. The model answers each refusal in its own words
(`ConstraintMessages`).

### GuestRoomReservation

A guest room booking. One per date.

```
GuestRoomReservation ----> Community
GuestRoomReservation ----> Resident
```

**Key fields:** `date` (unique: `index_guest_room_reservations_on_date`)

### CommonHouseReservation

A common area booking. Refuses a time period that overlaps another
reservation. A booking must end after it starts. An end before the
start is refused on every save. An end equal to the start is refused
only when a save sets or changes the times (#141), so bookings
saved before that rule that end when they start (one in a copy of
production from September 2026) can still be saved with a new title. The one exception is midnight to midnight in the
community's zone, which is how a notice is saved. A booking must start
and end on the same day in the community's zone (#154), checked when a
save sets or changes the times, so a booking that a change of zone left
ending on the next day can still be saved with a new title (#173).

The database has the same three rules about time. A CHECK refuses an
end before the start (`common_house_reservations_end_not_before_start`,
#149). A trigger refuses a write that gives a booking an end on a later
day in the community's zone (`common_house_reservations_one_day`, #154).
An EXCLUDE refuses an overlap (`common_house_reservations_no_overlap`,
#149, each booking the range [start, end)). A booking that ends when it starts,
such as a notice, is an empty range: it overlaps nothing, and the model's
overlap check (`period_is_free`) agrees. When two bookings for one time
are saved at the same moment, the second gets the model's own words,
"Time period is already taken" (`ConstraintMessages`), not an error.

```
CommonHouseReservation ----> Community
CommonHouseReservation ----> Resident
```

**Key fields:** `title` (optional), `start_date`, `end_date`

All three note every month they touch in `LiveUpdate` (`note_live_update`),
including the old months when dates change, and it clears the calendar cache
and pushes after the commit (ADR 0007).

---

## Browser Counts

### BrowserCount

Page loads per day and kind of browser, and the result of the browser
check that runs in `index.html` before the app
(`app/frontend/browser_check.js`). The check sends one report per page
load to `POST /api/v1/browser-reports`, and `BrowserReportJob` adds one to
the row for that day and browser (`BrowserCount.add_one!`, one `INSERT ...
ON CONFLICT DO UPDATE`). A browser that runs no script at all, a crawler,
and a page restored from the browser's back-and-forward cache send nothing
and are not counted. A reload is a second page load. The admin Browsers
page adds the rows up by month (`BrowserCount.by_month`).

Counts only. No IP address, no resident, and no User-Agent string are
stored. Not linked to the community: it is a fact about browsers.

No associations.

**Key fields:** `date` (the community's day when the report arrived, through
`Community#today`), `browser` (the browser's name, or `Unknown`), `major`
(the browser's major version, NULL when it could not be read), `os`,
`device` (`phone`, `tablet`, `desktop` or `unknown`), `result` (`passed`,
`failed` or `error`), `count` (page loads, at least 1). A unique index on
`(date, browser, COALESCE(major, 0), os, device, result)` makes one row per
kind, so a browser with no version adds up in one row too. CHECKs keep
`device` and `result` to their lists, `count` and `major` above 0, and the
names 1 to 60 characters.

There is no OS version. Safari on an iPad sends the same User-Agent as
Safari on a Mac, so the check also sends whether the screen takes touch, and
a "Mac" with a touch screen is counted as iPadOS. Newer Safari and Chrome
send a frozen OS version, so the browser's own version is the number to read:
on an iPad or iPhone, Safari's version is the iOS version
(`BrowserDescription`).

Two page loads of the same kind at the same moment write the same row, and
at SERIALIZABLE the second is refused. The job retries it
(`RetryOnConflict`), and reports a write that keeps failing; it never raises.

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
`ApiController#resolve_current_session` tries the JWT first and falls back to
`Key.find_by(token:)` when decoding fails. The model, the table and the
fallback stay for good (decided 2026-09-21, #42 and #67): removing them
gains nothing and could sign out a person whose device still holds an old
token, and the table has no last-used column, so nothing can prove a row
is dead.

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

A resident's band is not stored. `Resident#multiplier_on(date)` computes
it from the birthday and the two ages, for the day of the meal: a child
who turns full-price age before a meal pays full price at that meal,
whenever they signed up. A resident with no birthday is an adult who did
not give one. The hosts list computes "adult today" in SQL
(`Resident.adult_on`), pinned against the Ruby rule on a February 29
birthday. (Until 2026-09-26 a nightly task copied the band into a column,
so a price was wrong from a birthday until the next run.) A `MealResident`
copies the band for the meal's date when the row is created, so a later
birthday or a changed age rule never changes what someone was charged for
a past meal. The API creates every guest with the
database default of 2 (an adult guest); only an admin can make a guest a
child (1). A guest is never free (`Multiplier::GUEST_PRICES`).

`MealLedger` does not read `Multiplier`. It sums the numbers and shares the
cost out in proportion to them; it does not know that 2 means one adult. Pricing policy lives in
`Multiplier`, `Community#multiplier_for_age` and `Resident#multiplier_on`;
arithmetic lives in the ledger.

A meal's total multiplier is the sum across all attendees and guests. The
effective cost is shared out across the eaters in proportion to their
multipliers, by largest remainder at the ledger grain ("The ledger grain"
above). An adult pays twice what a half-price child pays, give or take one
unit of 10^-8 dollars, and a free child pays nothing.

A meal whose total multiplier is 0 — nobody there is old enough to be
charged — has a unit cost of 0, and every one of its lines is 0: each cook
is credited 0 and each eater is charged 0. The lines still exist, each at
$0, because a line is a fact about what happened and a settled meal's
screen reads its lines. Its total cost is still what the cooks spent, and
it is subsidized when they spent anything. A settlement holds such a meal
back when a receipt has money on it (`Meal.receipt_and_nobody_to_charge`),
so the cook is not credited 0 for good; it settles only when its cook
slots hold no money (#94). In the nightly running balance the cook is
credited 0 while the meal waits.

A cancelled meal (`cancelled_at` set, ADR 0011 rule 11) charges nobody:
its effective cost is 0, so every one of its lines is 0, whatever its
multiplier and whatever its cooks entered. The lines still exist, the same
as on a meal nobody can be charged for. No cook can have money on a
cancelled meal (a meal with a bill over $0 that is not no-cost cannot be
cancelled), so no cook loses money to this.

Example: $60 meal, 3 adults (residents 1, 2, 3) and 1 half-price child
(resident 4) attending:

```
total_multiplier = 2 + 2 + 2 + 1 = 7
$60 is 6,000,000,000 units
adult share  = 6,000,000,000 * 2 / 7 = 1,714,285,714.28...  -> 1,714,285,714 units
child share  = 6,000,000,000 * 1 / 7 =   857,142,857.14...  ->   857,142,857 units
handed out so far: 5,999,999,999; one unit is left over
the adults lost .28 of a unit, the child .14: the unit goes to an adult,
and between the three adults to the lowest resident id
adult 1 debit = $17.14285715
adult 2 debit = $17.14285714
adult 3 debit = $17.14285714
child   debit = $ 8.57142857
sum           = $60.00000000, exactly the cook's credit
unit cost shown on screens = $60 / 7 cut to the grain = $8.57142857
```

At settlement, each resident's total is rounded to cents by the same
largest-remainder method, so the rounded balances sum to exactly zero.

---

## Where the money math lives

- `MealLedger` (`app/services/meal_ledger.rb`) — the one place the
  arithmetic lives. Give it meals with `bills`, `meal_residents`, and
  `guests` preloaded; it runs no queries of its own. `lines` returns every
  credit, debit, and guest_debit at the ledger grain; `balances(resident_ids)`
  sums them per resident; `summary_for(meal)` returns `total_cost`,
  `effective_cost`, `unit_cost`, and `subsidized` (the cooks are credited
  less than they spent, for any reason) for a screen. Caps are
  applied here: when `cap * total multiplier` is less than the bills, the
  eaters pay the capped amount and each cook is credited their share of it
  in proportion to what they spent. Every share is allocated by
  `LargestRemainderSplit` (`app/services/largest_remainder_split.rb`), so
  a meal's lines sum to exactly zero.
- `Settlement.allocate_to_cents` — the one place that rounds to cents. A
  settlement (`Reconciliation#settlement_balances`) and the preview both
  call it.
- `MealCostSummary` (`app/services/meal_cost_summary.rb`) — what a meal cost,
  for a screen. An open meal is computed through `MealLedger`. A settled
  meal reads its stored `meal_charges`, so the screen shows what the
  settlement charged even after the ledger's rules change (ADR 0008 changed
  how a share is split). A settled meal with attendance but no
  lines (settled before 2026-08-02) returns nil and the screen shows nothing.
- `spec/support/oracle/plain_ledger.rb` — the test oracle, not production:
  a second copy of the arithmetic written from this file and CLAUDE.md by
  someone who had not read the code. Compared in
  `spec/services/meal_ledger_against_plain_ledger_spec.rb` and
  `spec/tasks/stored_ledger_against_plain_ledger_spec.rb`. Never edit it to
  match `MealLedger`; when a rule changes, change the rule here first and
  have a fresh reader change the oracle.

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
MealCharge, LedgerCheckRun, SettlementCorrection,
SettlementCorrectionLine, SettlementCorrectionCharge, SettlementLineMark,
MealCorrection and MealCorrectionLine (whose triggers are `meal_corrections_guard` and
`meal_correction_lines_guard`). Each has a
database trigger that refuses the same writes for paths that skip
callbacks (`update_all`, `delete_all`, psql):
`reconciliation_balances_protect_settled`, `meal_charges_protect`,
`ledger_check_runs_protect`, and `settlement_corrections_protect`,
`settlement_correction_lines_protect`, `settlement_correction_charges_protect`,
`settlement_line_marks_protect`.
Two deferred constraint triggers check the
books at commit: `reconciliation_balances_sum_zero`, that every settlement's
balances sum to zero, and `meal_charges_sum_zero`, that every meal's lines
do.

Only a settlement adds rows to the settled ledger. Since October 2026,
`meal_charges_insert_by_settlement` and
`reconciliation_balances_insert_by_settlement` refuse an INSERT unless the
setting `comeals.settling` names the reconciliation the row belongs to (for
a line, the reconciliation of its meal). `Settlement#write_ledger!` sets it
with `set_config(..., true)`, so it lasts at most until the end of its
transaction, and turns it off when it is done. Without this, two rows that
add up to zero could be added to a settled meal from a console, and the
sum-zero triggers would accept them. The three correction tables have the
same rule (`*_insert_by_settlement`, `comeals_settlement_correction_insert_by_settlement`):
`Settlement#correct!` sets the setting while it writes the record. A spec
that writes these rows by hand uses `SettledWrites`
(`spec/support/settled_writes.rb`).

**Settled meals are frozen.** `ReconciledMealImmutability` refuses create,
update, and destroy on Bill, MealResident, and Guest once their meal (or the
meal they are being moved from) is reconciled. The
`*_reject_settled_write` triggers on those three tables do the same in the
database. Both of their meal lookups run unconditionally, and each one
updates the meal row (`updated_at = updated_at`, in `comeals_reject_settled_child_write`)
rather than only reading it. So an unlocked write that comes after a running
settlement waits for it and is then refused, and a settlement or a cancel
that waited for a write that came first finds the meal row changed: at
SERIALIZABLE it fails as a conflict and is tried again with a fresh
snapshot, and at READ COMMITTED (psql) it reads the new row. `Meal` freezes
its own `cancelled_at`, `cap`, `date`, and `reconciliation_id`, backed by
`meals_protect_settled`. See ADR 0003 and CLAUDE.md.

The protect, reject and insert triggers all step aside when the session
setting `comeals.allow_settled_writes` is `on`. That is for deliberate
repair only: `docs/runbooks/settled-data-repair.md`. A person who sets
either setting on purpose can still write these rows. The triggers are
there to stop mistakes.

**Audits.** Meal, Bill, MealResident, Guest, and Reconciliation write to the
`audits` table (the `audited` gem). Child rows are linked to their meal.

**True/false columns.** Every true/false column is NOT NULL, and its model
refuses a nil with "must be true or false" (`TrueOrFalse::MESSAGE`), so a
value left out or sent as `""` (Rails reads `""` as nil) is a form error
in admin and a 400 in the API, not a 500: `meals.closed`, `bills.no_cost`,
`residents.active`, `can_cook`, `vegetarian` and `can_reconcile`,
`meal_residents.late` and `vegetarian`, `guests.late` and `vegetarian`,
`events.allday`, `rotations.residents_notified`, `admin_users.superuser`,
`reconciliation_balances.lived_here`,
`settlement_corrections.include_earlier_differences` (#121, #139). Two
NOT NULL true/false columns have no such model check.
`guest_add_keys.vegetarian` is written only by `GuestAdd`, which has
already read the flag with `TrueOrFalse` and refused a missing one.
`solid_queue_recurring_tasks.static` belongs to Solid Queue, not to the
app. The API reads a true/false value from a request by one
rule, `TrueOrFalse` (`app/services/true_or_false.rb`): it takes `true`,
`false`, `1`, `0`, `"true"`, `"false"`, `"1"` and `"0"`, and refuses
everything else (#138). Rails would read `"no"` or `"False"` as true.

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
rebuilt, except by `Settlement#correct!` when the owner decides a settlement
must be worked out again after its rows were fixed; that leaves a
`SettlementCorrection`. A later mistake in a settled dinner changes the
dinner's rows and is recorded as a `MealCorrection`, which the next
settlement carries; the old settlement's rows stay as they were. `rake
ledger:verify` checks every night that they still match their source data
and each other, and that each settled dinner's rows add up to what it was
settled at plus its corrections.
