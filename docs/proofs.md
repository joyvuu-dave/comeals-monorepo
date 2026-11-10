# Proofs

`proofs/` holds proofs, written in [Dafny](https://dafny.org), that the money rules hold for every input. Tests try some inputs; a proof covers all of them. Issue #269 is the plan, and challenge 27 ("Prove the money math") is why.

## Running them

```bash
bin/dafny-verify                 # check every proof in proofs/, and proofs/generated-py
bin/check dafny                  # the same, as the bin/check step "Dafny proofs"
bin/dafny-verify --seeds 20      # the same, then every proof on 20 solver seeds
bin/dafny-verify --write-python  # make proofs/generated-py again, after changing a proof
```

`bin/check` runs `bin/dafny-verify`. The `proofs` job in CI runs it and then `--seeds 20`.

The first run downloads the Dafny 4.11.0 release zip for this machine (about 55 MB) into `~/.cache/comeals` and checks it against a SHA-256 written in `bin/dafny-verify`. Every worktree uses that one copy. Later runs take about a second.

## One Dafny and one Z3

A proof can pass on one version of Z3 (the solver Dafny asks) and fail on another. So `bin/dafny-verify` always uses the Dafny and the Z3 4.14.1 that come in the pinned zip, never a `dafny` on the PATH. To move to a new Dafny, change the version and both SHA-256 values in `bin/dafny-verify` in one commit, and expect to fix proofs in that same commit.

Only macOS on arm64 and Linux on x86-64 have a pinned zip. On any other machine the script stops and says which zip to add.

## When a run counts

`bin/dafny-verify` fails the run unless all of these hold:

- No file in `proofs/` uses `assume`, `{:axiom}` or `{:verify false}`. Each one tells Dafny to accept a claim without proving it. A lemma marked `{:axiom}` passes with "0 verified, 0 errors" and exit code 0, so only this check stops one. A comment cannot use the word "assume" either.
- Dafny exits with 0. A warning is a failure too: `--allow-warnings` is not passed. A lemma with no body raises a warning, so it fails.
- The last line is "Dafny program verifier finished with N verified, 0 errors".
- No line says "Prover error", "internal error" or "SKIPPED". Dafny 4.11.0 can mix up the questions it sends to Z3 when the machine is busy, skip a proof, and still exit with 0. The script runs Dafny on 2 cores to make that less likely. If it happens, run it again.

## What is proven so far

| File                               | What it proves                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `proofs/LargestRemainderSplit.dfy` | For every total and every list of weights: the split's shares sum to the total; each is its exact share rounded down or one unit more, so less than one unit away; a share whose exact share is whole gets no extra unit; the extra units go to the shares that dropped the most, ties to the earlier position. And only one list of shares does all of that.                                                                                                                                                                                                                                                                                                                                          |
| `proofs/CentRounding.dfy`          | For every list of balances that sums to zero: the rounded balances sum to exactly zero; each is a whole number of cents and less than one cent from its exact amount; each is cut toward zero and then either left or moved one cent back toward its exact amount; the cents all move the same way, to the balances that lost the most in the cut, ties to the lowest resident id. Only one list does all of that. And there are always enough balances that lost something on the needed side to take the leftover cents, so the guard `Settlement.assert_candidates_cover_pennies!` can never fire on balances that sum to zero.                                                                     |
| `proofs/MealLines.dfy`             | For every dinner (what each cook spent, each eater's multiplier, a cap or none, cancelled or not): the credits and the charges both sum to the effective cost, so the dinner's lines sum to exactly zero, on every branch (cancelled, a total multiplier of 0, capped, subsidized, plain). A cancelled dinner and one with a total multiplier of 0 move no money. No cook is credited more than they spent or less than 0, and no eater is charged less than 0. Only a cancel, a total multiplier of 0 or a cap makes a dinner subsidized. And only one set of lines follows the rules. It takes the cooks and the eaters already in tie-break order; it does not prove the sort that puts them there. |
| `proofs/TieOrder.dfy`              | The tie-break order: lowest resident id, then an attendee before a guest of the same resident, then the lower guest id. Sort puts any list of rows in that order without losing or adding a row, and only one order of a list is sorted.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `proofs/EntryPoints.dfy`           | What the Python runs (below). Each method takes the rows the Ruby has, in any order, sorts them, and checks while it runs every condition a proof needs, refusing an input that breaks one. So every answer it gives is a proven one.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `proofs/LargestRemainder.dfy`      | The part both use: handing out k units by the order "largest key first, ties to the earlier position". It proves the units can always be handed out, and that only one hand-out follows the order.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `proofs/Sums.dfy`                  | Facts about the sum of a list that the other proofs use.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `proofs/Arithmetic.dfy`            | Small facts about multiplying and dividing that Z3 cannot find on its own inside a larger proof.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

## The Ruby against the proofs

A proof is about the Dafny code, not about the Ruby. Two kinds of spec link them, and both rest on one fact the proofs show: only one answer follows each rule.

- **The sweep specs** check the rules themselves on the Ruby, on every small input: `spec/services/largest_remainder_split_on_every_small_input_spec.rb` and `spec/services/settlement_allocate_to_cents_on_every_small_input_spec.rb`. The inputs are in `spec/support/money_sweep.rb`.
- **The comparison specs** run the same inputs through the Ruby and through Python that Dafny made from the proofs, and fail on any answer that differs: `spec/services/largest_remainder_split_against_the_proofs_spec.rb`, `spec/services/settlement_allocate_to_cents_against_the_proofs_spec.rb` and `spec/services/meal_ledger_against_the_proofs_spec.rb`. They also run the random ledgers of the property specs, and every small dinner built from rows that test the tie-break order.

The Python is in `proofs/generated-py`, committed, so the specs run without Dafny. `bin/dafny-verify` fails when it is not what Dafny makes from the current proofs. After changing a proof, run `bin/dafny-verify --write-python` and commit what changes. `proofs/run_proven.py` turns JSON into Dafny values and back, and `spec/support/proven.rb` starts it once per spec, with `python3 -I -B`. Only `EntryPoints` gives answers, so an input that no proof covers is refused, never answered.

The Python runs the code in the proofs as written. So a definition that rebuilds a whole list for each of its entries makes the specs slow: on 2026-11-10 the cent rounding took 1.4 seconds for 30 balances. Compute a value used by every entry once, with `var`, and build lists from one entry at a time. `Sum` has a loop after `by method` that the Python runs; Dafny proves it gives the same number as the definition.

One rule is not checked by any of this: the order between two guests of one host. Their lines name the host and the multiplier, not the guest, so two guests with the same multiplier get lines that cannot be told apart, and two with different multipliers never tie for a unit. No stored amount can depend on it.

Like `spec/support/oracle/plain_ledger.rb`, the proofs are a separate copy of the rules. When a comparison spec fails, find out which side is wrong. Never edit a proof to match the Ruby.

## Prove the examples too

A proof shows that the code follows the rule as the proof states it. It cannot show that the rule is stated correctly: a mistake in the rule is made in the code too, and the proof still passes. That happened while writing the split proof. With ties sent to the later position in both the rule and the code, every proof still passed.

So each proof file also proves a few examples worked out by hand from the docs, such as the $60 example in MODELS.md. With ties sent the wrong way, those fail.

## Write the proofs from the rules, not from the code

A Dafny model of `LargestRemainderSplit`, `Settlement.allocate_to_cents` or `MealLedger` must be written from the rules (AGENTS.md, Money Handling Standards; MODELS.md). Never edit it to match the Ruby. It is a separate copy of the rules, like `spec/support/oracle/plain_ledger.rb`, and it is useful only when it can disagree with the Ruby.

## A proof must pass on every solver seed

Z3 makes choices as it searches, and a seed decides them. With the pinned Z3 and the default seed a run gives the same answer every time, so `bin/check` is not flaky. But a proof that passes on one seed and fails on others can break after an unrelated change to the file, which moves the search. On 2026-11-09, four proofs failed on some seeds: one on half of them. Each was fixed by writing out a step that multiplies two unknowns, which Z3 has to guess at.

The CI `proofs` job runs every proof on 20 seeds, with `bin/dafny-verify --seeds 20`. It takes about two minutes on a laptop. Run it before pushing a change to a proof. It names each proof that failed and the seed it failed on. The fixes that worked here:

- Name the case. Where a value is one of a few things, compute which one in a `var`, and assert the result for that case.
- Call the lemma from `proofs/Arithmetic.dfy` for each product, rather than leaving Z3 to find it.
- Split a lemma that does several things into smaller lemmas. On 2026-11-10 `TieOrder.OnlyOneOrder` failed on 2 of 20 seeds, and passed on 40 of 40 once it was split into `SameFirst` and `Rest`.
- Add `{:isolate_assertions}` to a long lemma, so each assertion is its own question. It helped `CentRounding.BuildFollowsTheRule`; it made `LargestRemainder.CountFits` worse.
