# Proofs

`proofs/` holds proofs, written in [Dafny](https://dafny.org), that the money rules hold for every input. Tests try some inputs; a proof covers all of them. Issue #269 is the plan, and challenge 27 ("Prove the money math") is why.

## Running them

```bash
bin/dafny-verify      # check every proof in proofs/
bin/check dafny       # the same, as the bin/check step "Dafny proofs"
```

`bin/check` runs it, and so does the `proofs` job in CI.

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
| `proofs/LargestRemainder.dfy`      | The part both use: handing out k units by the order "largest key first, ties to the earlier position". It proves the units can always be handed out, and that only one hand-out follows the order.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `proofs/Sums.dfy`                  | Facts about the sum of a list that the other proofs use.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `proofs/Arithmetic.dfy`            | Small facts about multiplying and dividing that Z3 cannot find on its own inside a larger proof.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

Next, the Ruby is compared with Python that Dafny generates from these proofs (#269, step 6).

"Only one list" is what links a proof to the Ruby. The specs `spec/services/largest_remainder_split_on_every_small_input_spec.rb` and `spec/services/settlement_allocate_to_cents_on_every_small_input_spec.rb` check that the Ruby follows the same rules on every small input. Since only one list follows each rule, the Ruby gives exactly the proven answer on each of those inputs.

## Prove the examples too

A proof shows that the code follows the rule as the proof states it. It cannot show that the rule is stated correctly: a mistake in the rule is made in the code too, and the proof still passes. That happened while writing the split proof. With ties sent to the later position in both the rule and the code, every proof still passed.

So each proof file also proves a few examples worked out by hand from the docs, such as the $60 example in MODELS.md. With ties sent the wrong way, those fail.

## Write the proofs from the rules, not from the code

A Dafny model of `LargestRemainderSplit`, `Settlement.allocate_to_cents` or `MealLedger` must be written from the rules (AGENTS.md, Money Handling Standards; MODELS.md). Never edit it to match the Ruby. It is a separate copy of the rules, like `spec/support/oracle/plain_ledger.rb`, and it is useful only when it can disagree with the Ruby.

## A proof must pass on every solver seed

Z3 makes choices as it searches, and a seed decides them. With the pinned Z3 and the default seed a run gives the same answer every time, so `bin/check` is not flaky. But a proof that passes on one seed and fails on others can break after an unrelated change to the file, which moves the search. On 2026-11-09, four proofs failed on some seeds: one on half of them. Each was fixed by writing out a step that multiplies two unknowns, which Z3 has to guess at.

After changing a proof, run every proof on 20 seeds:

```bash
D=~/.cache/comeals/dafny-4.11.0/dafny
$D/dafny measure-complexity --mutations 20 --random-seed 4242 \
  --solver-path $D/z3/bin/z3-4.14.1 --cores 4 \
  --log-format "csv;LogFileName=tmp/seeds.csv" proofs/*.dfy
```

`tmp/seeds.csv` has one row per proof and seed. Every row must say `Passed`. If one does not, the fixes that worked here:

- Name the case. Where a value is one of a few things, compute which one in a `var`, and assert the result for that case.
- Call the lemma from `proofs/Arithmetic.dfy` for each product, rather than leaving Z3 to find it.
- Add `{:isolate_assertions}` to a long lemma, so each assertion is its own question. It helped `CentRounding.BuildFollowsTheRule`; it made `LargestRemainder.CountFits` worse.
