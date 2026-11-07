---
id: 27
title: Prove the money math
area: proof
status: open
opened: 2026-11-07
reviewed: 2026-11-07
watches:
  - docs/adr/0008-the-ledger-grain.md
  - app/services/largest_remainder_split.rb
---

# Prove the money math

## The challenge

Prove, not just test, that the money rules hold for every possible input: the lines of a dinner sum to exactly zero, each share is less than one unit from its exact value, and the cent rounding at settlement sums to zero.

## The case that breaks it

A dinner with an input no test or random seed has tried (an odd mix of multipliers, a cap, a cook who spent nothing) makes the split leave one unit over. The property specs ran 10,000 seeds each on 2026-10-27 and found nothing, but 10,000 seeds is not every input.

## Where we stand

- The ledger allocates at a grain of 10^-8 dollars and never divides (`docs/adr/0008-the-ledger-grain.md`, `app/services/largest_remainder_split.rb`). That change came from thinking about what a Dafny model would need to say (2026-09-17).
- Property specs compare the ledger with a second one written from the docs (`spec/support/oracle/plain_ledger.rb`). `MONEY_PROPERTY_SEEDS=10000` runs more seeds (`spec/support/property_seeds.rb`).
- No Dafny code exists in this repo. The owner's other project, `reference_app`, has a Dafny core with proofs checked in CI.

## Options

1. **Dafny proofs of the split and the cent rounding,** with the proven functions compiled or checked against the Ruby code by a spec that runs both on the same inputs.
2. **Prove in Dafny, test in Ruby:** keep the Ruby code, and add a spec that compares it with the Dafny-compiled version on every seed.

## History

- 2026-11-07: Opened.
