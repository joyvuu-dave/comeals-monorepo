---
id: 27
title: Prove the money math
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-10
watches:
  - docs/adr/0008-the-ledger-grain.md
  - app/services/largest_remainder_split.rb
  - docs/proofs.md
---

# Prove the money math

## The challenge

Prove, not just test, that the money rules hold for every possible input: the lines of a dinner sum to exactly zero, each share is less than one unit from its exact value, and the cent rounding at settlement sums to zero.

## The case that breaks it

A dinner with an input no test or random seed has tried (an odd mix of multipliers, a cap, a cook who spent nothing) makes the split leave one unit over. The property specs ran 10,000 seeds each on 2026-10-27 and found nothing, but 10,000 seeds is not every input.

## Where we stand

- Dafny proofs in `proofs/` cover all three rules for every input (`docs/proofs.md`, issue #269):
  - the split: the shares sum to the total, each is less than one unit from its exact share, and the leftover units go to the shares that dropped the most, ties to the earlier position (`proofs/LargestRemainderSplit.dfy`);
  - the cent rounding: the rounded balances sum to exactly zero, each is less than one cent from its exact amount, and the cents go by the rule, ties to the lowest id; there are always enough balances to take the leftover cents, so `Settlement.assert_candidates_cover_pennies!` cannot fire on balances that sum to zero (`proofs/CentRounding.dfy`);
  - the lines of a dinner: the credits and the debits sum to the same amount on every branch (cancelled, nobody to charge, capped, subsidized, plain), and no cook is credited more than they spent (`proofs/MealLines.dfy`);
  - the sort into the tie-break order (`proofs/TieOrder.dfy`).
- Each rule also has a proof that only one answer follows it, and worked examples that pin the rule as stated to answers worked out by hand.
- The Ruby is not proven. Specs run the same inputs through the Ruby and through Python that Dafny made from the proofs, and fail on any difference: every input of a small sweep, the random ledgers of the property specs, and 4,608 small dinners built to test the tie order (`spec/services/*_against_the_proofs_spec.rb`). Since only one answer follows each rule, a match means the Ruby gives the proven answer on that input. An input no spec tries is still only covered by the tests.
- `bin/check` and CI check the proofs and that the committed Python is what Dafny makes from them. The CI `proofs` job also runs every proof on 20 solver seeds (`bin/dafny-verify --seeds 20`).
- Not proven: what reads the rows into the ledger (bills, attendance, guests and the cap from the database), the conversion between dollars and units, and the order between two guests of one host, which no stored amount depends on.

## Options

1. **Dafny proofs of the split and the cent rounding,** with the proven functions compiled or checked against the Ruby code by a spec that runs both on the same inputs.
2. **Prove in Dafny, test in Ruby:** keep the Ruby code, and add a spec that compares it with the Dafny-compiled version on every seed.

## Decision

Option 2, done in issue #269 (2026-11-09 to 2026-11-10): prove the rules in Dafny, keep the Ruby, and compare the Ruby with Python made from the proofs. Dafny cannot make Ruby.

## History

- 2026-11-07: Opened.
- 2026-11-10: Done. Proofs of all three rules and the comparison specs merged (#269).
