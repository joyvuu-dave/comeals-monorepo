# ADR 0008: The ledger grain, and no epsilon on the money path

- **Status:** Accepted
- **Date:** 2026-09-17
- **Issue:** #85

## Context

The money rules said that intermediate values stay at "full precision"
and that rounding happens once, at settlement. In practice there were two
roundings, and only one of them was decided on.

`MealLedger` computed each line with `BigDecimal` division, which carries
about twenty digits. The `meal_charges.amount` column is `DECIMAL(16,8)`,
and ActiveModel rounds a decimal to the column's scale on assignment. So
every stored line was the computed line rounded to eight places, and the
rounded-off part went nowhere. A meal's stored lines did not sum to zero.
They summed to whatever the rounding dropped.

That drift was allowed for by `Reconciliation::ZERO_SUM_EPSILON`, set to
0.000001. `Settlement.allocate_to_cents` accepted an input that summed to
within it, and `LedgerVerification#line_item_check` reported a fault only
when a reconciliation's stored lines summed to more than it.

The epsilon did not grow with the number of lines, and the drift did.
Equal unit costs drop the same amount in the same direction every time,
so a reconciliation of many similar meals adds those drops up. A spec with
101 one-dollar meals of three eaters each, a correct ledger, failed the
daily check. Settled rows never change, so the day that check fires for one
reconciliation it fires every day after that.

Two smaller facts came out of the same look. How exact `BigDecimal#/` is
depends on the bigdecimal gem version, so the stored charge for a $50 meal
with seven eaters was whatever the gem gave that year. And the epsilon
would also have let a small real error through: a settlement whose raw
balances were off by less than 0.000001 for a real reason was accepted.

This came up while thinking through what a Dafny model of the money path
would have to say. A model cannot say "whatever the gem does," and a
theorem "a meal's lines sum to zero" needs a bound in it unless the
arithmetic is exact. The exact version is the one a bank keeps.

## Decision

The ledger has a declared grain: 10^-8 dollars, the unit of the money
columns. Every line, charge and running balance is a whole number of those
units, so what is computed is what is stored.

The ledger never divides. A share of an amount is allocated by largest
remainder at the grain (`LargestRemainderSplit`): each share gets the whole
units of its exact share, and the units left over go one each to the shares
that lost the most, ties to the lowest resident id, then an attendee line
before a guest line of the same resident, then the lower guest id. Two
splits happen on a meal: the effective cost across the eaters by
multiplier, and on a subsidized meal the effective cost across the cooks by
what each spent. Both give out the same effective cost, so a meal's credits
and debits sum to exactly zero.

The one quotient left, the unit cost a screen shows, is cut to the grain in
one place, in `MealLedger#financials_for`. No line is computed from it.

Every check on the money path is an equality. `ZERO_SUM_EPSILON` is gone.
`allocate_to_cents` requires an input that sums to exactly zero. The
line-item check requires stored lines that sum to exactly zero. The
deferred constraint trigger `meal_charges_sum_zero` refuses a commit that
leaves a meal's lines unbalanced, and the repair bypass does not turn it
off, the same as for the balances.

Rounding to cents still happens once, at settlement, by the same
largest-remainder method at the cent (money rule 5). Nothing about that
changed.

The oracle, `spec/support/oracle/plain_ledger.rb`, was rewritten from the
new rules by a reader who had not seen the code, and the comparison specs
compare it to `MealLedger` exactly, with no tolerance.

## Consequences

- A debit is no longer exactly the unit cost times the multiplier. Two
  eaters at multiplier 2 on a $60 meal of seven units get 17.14285715 and
  17.14285714. Invisible at the cent, and the extra unit always goes to a
  known line.
- The running balance (`billing:recalculate`) changes with it, because it
  goes through the same `MealLedger`.
- Historical settlements did not move. The new arithmetic moves a line by
  at most one unit, so a settled cent amount could only change if a raw
  balance sat within a few units of a cent boundary or a tie. On a
  production copy every reconciliation (5, covering 805 meals) recomputed
  to exactly its stored cents. Production has no `meal_charges` rows yet,
  so the exact line check meets no old data. On the same copy, the one
  settlement replayed under the old arithmetic had 96 of 177 meals whose
  stored lines did not sum to zero, by up to 0.00000008 each. That is the
  drift this decision removes.
- The trigger runs one indexed sum per inserted line at commit. A
  settlement of a few hundred meals runs it a few thousand times, well
  under a second.
- Money rule 3 no longer says "use BigDecimal division with explicit
  scale." A division on the money path is now a mistake to look for.
- The "still open" question in `docs/money-path-observability.md` about
  changing the arithmetic on purpose was answered for this change by
  checking the data, not by a version stamp. A later change that moves a
  line by more than a unit will need the stamp.

## Alternatives rejected

- **Scale the epsilon by the line count.** Honest arithmetic, but it keeps
  "approximately zero" as the invariant of a ledger, and it keeps the
  dependence on the gem's division precision.
- **Drop the stored-line zero-sum check.** It is the one check that is
  independent of the code that wrote the rows.
- **Round each meal to cents.** Money rule 4 keeps sub-cent precision
  through the period on purpose: rounding every meal to cents would hand
  a penny to someone on most meals, and over a period that is unfair in a
  way a resident could notice. Eight places keeps that far below a cent.
- **Post the per-meal residual to a community rounding account.** That is
  the full double-entry answer, and it would also make the subsidy on a
  capped meal an explicit line. It needs the community to be an account in
  the ledger, which it is not today. Allocation gives an exactly balanced
  meal without that.
