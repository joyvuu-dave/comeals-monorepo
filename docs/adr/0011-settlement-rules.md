# ADR 0011: How settlements work from now on

- **Status:** Accepted. Rules 2, 3, 4, 6, 7, 8 and 9 are not built yet.
- **Date:** 2026-10-12
- **Issue:** #165 (the common house email)

## Context

A settlement (a `Reconciliation`) takes every open dinner up to a cutoff
date, works out what each person owes or is owed, and locks those
dinners.

Until now, few rules about settlements were written down, and some of
the ones in the code were wrong:

- Any dinner before today could be settled. A cook who had not entered a
  cost yet got $0, and the dinner was locked anyway.
- Once a dinner was settled, only a developer could fix a mistake in it.
  The four old settlements were all rebuilt by hand in 2023 and worked
  out again in 2026. Nobody kept a record of what anyone was billed or
  paid.
- The admin settlement form had no preview. An admin picked a date,
  clicked Create, and saw no warnings.
- A settlement page added up each unit using the unit each person is in
  today, so an old page could change.

In October 2026 we decided to make every number exact, fix the old
history once, and then follow the rules below.

## Decision

### 1. A dinner can change until it is settled

Cooks and admins can change costs and sign-ups on any dinner that is not
settled. This is how it works today.

### 2. A settlement covers only dinners at least 14 days old

The cutoff must be at least 14 days before today, in the community's
time zone. The model refuses a later cutoff, so the admin form, the API
and the rake task all follow the rule. `reconciliations:create` uses
today minus 14 days.

Why 14 days: on dinners from January to mid-August 2026, 64 cook costs
were entered. 9 of them were changed more than 1 day after the dinner, 2
more than 7 days after, and 1 more than 14 days after (on day 15).
Settlements are months apart, so a dinner that is too new waits for the
next one.

### 3. A dinner waits until every cook has a cost or "No cost"

A blank cost (`amount` 0 and `no_cost` false) means the cook has not
said yet. The meal page already calls it "pending". A settlement leaves
such a dinner open. It already does the same for a dinner where people
ate and no cook signed up, and for a dinner with a receipt and nobody to
charge.

### 4. The admin settlement form shows a preview first

The admin picks a cutoff and sees the dinners that will settle, the
dinners that will wait and why, and each person's amount. Then they
click Create.

Under the dinners that wait for a cost there is one button: "Mark these
N blank costs as No cost". It shows the list (date and cook) and asks
yes or no. It is meant for after an admin has asked those cooks.

- It changes only the costs that are still blank at the moment of the
  yes. A cost entered in between is left alone, and the answer says so.
- Each change is saved in that cost's history, with the admin's name.
- The list labels a dinner where every cook is blank: marking them all
  No cost makes that dinner free for everyone who ate.

### 5. Settling locks the dinners for good

A settled dinner's costs and sign-ups never change through the normal
screens. The database triggers already enforce this.

### 6. A mistake found later is fixed by a correction in the next settlement

The old settlement never changes. A superuser opens the dinner in admin
and makes a correction: what was wrong, the right value, and a reason.
Before saving, they see how much each person's amount will change. The
changes add up to exactly $0.

The correction changes the dinner's rows, with history, and saves each
person's change as a line of its own. So the dinner's page shows the
corrected cost, its history shows the change, and the old settlement's
page still shows the dinner as it was settled. The next settlement includes every
correction made since the last one, each as a line that names the dinner
("Correction to the January 12 dinner"). A settlement claims corrections
the same way it claims dinners, under a lock, so a correction saved
during a settlement goes into exactly one settlement.

The ledger check then checks two things. Each settlement's lines equal
its dinners plus the corrections it carries. And for each dinner, what
it was settled at plus its later corrections equals what its rows add up
to now.

A correction charges everyone who ate, including people who have moved
out. Whether anyone asks a person who moved out for money is a decision
for people, not for the app (rule 8).

### 7. A settlement saves each person's unit on the day it is made

Each settlement line saves the person's unit, and whether they lived
here that day. The unit totals on a settlement page come from those
saved values, so they never change later. People who had moved out by
that day are listed on their own under "Moved out", not inside any
unit's total.

The Units page, which shows balances for dinners not yet settled, uses
the same rule. It shows a "Moved out" line, so its totals still add up
to $0.

The app has no history of anyone's unit, so the old settlements use
each person's unit today, and their pages say so.

### 8. Each settlement line can be marked "Paid" or "Let go"

After a settlement, any admin can mark a person's line "Paid", and only a
superuser can mark it "Let go". A note can go with either (for example,
"paid $20 of $40"). The mark saves who made it and when. A mark can be
changed, and the history keeps the old one. Marks never change what
anyone owes. They record what happened after the settlement.

"Paid" records a fact: someone handed over money. "Let go" is a decision
about money, because somebody covers the amount that was let go. So it
needs a superuser, like every other decision about money (ADR 0004).

### 9. The common house email lists every balance

After a settlement, the email to the common house address uses the
settlement's own numbers. It lists everyone who lives here, by unit,
even people at $0.00, so nobody thinks they were skipped. Then it lists
everyone who moved out and still has a balance. Details are in #165.

### 10. The old history is fixed once, then closed

Where the October 2026 audit found a mistake in one of the four old
settlements, that settlement is worked out again in place, with
`Settlement#correct!`. Each time, it saves a record of when, why, and each
person's amount before and after. The admin pages show the new numbers
like any other settlement's, with no note about the correction. The query
in `docs/runbooks/settled-data-repair.md` reads the record. This is
allowed only because nobody kept a record of what was billed or paid
from those settlements.

When the audit's fixes are done and deployed, the old history is
closed. `Settlement#correct!` is removed, and every later mistake goes
through rule 6. The migrations that used it have run in production by
then, and a new database loads `db/structure.sql`, so nothing runs them
again.

## Options we did not take

- **Leaving people who moved out out of a correction.** We chose this
  first and dropped it the same day. It splits a dinner's cost
  differently for a reason that has nothing to do with the dinner, so
  nobody could check the numbers by hand. A "Let go" mark (rule 8)
  records the same decision where everyone can see it.
- **Working out an old settlement again in place for every later
  mistake.** Once people pay from a settlement, its numbers have to stay
  what they were. Rule 10 allows it once, for the old settlements
  nobody kept payment records for.
- **Recording each payment with its amount.** Most people pay the full
  amount at once. A note covers the rare partial payment.

## Consequences

- An admin can't settle last week's dinners. The newest dinners wait for
  the next settlement.
- A cook who never answers keeps their dinner open, and nobody who ate
  it is charged until someone enters the cost or marks it No cost. The
  preview shows that dinner every time.
- Someone moving out who wants to settle up before they leave can't
  include their last 14 days of dinners. They are charged in the next
  settlement, and an admin handles that by hand.
- The first settlement after the deploy covers every dinner since 2024.
  So these rules have to be built before that settlement is made. They
  don't have to be built before the deploy.
