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

| File                               | What it proves                                                                                                                                                                                                                                                                                                                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `proofs/LargestRemainderSplit.dfy` | For every total and every list of weights: the split's shares sum to the total; each is its exact share rounded down or one unit more, so less than one unit away; a share whose exact share is whole gets no extra unit; the extra units go to the shares that dropped the most, ties to the earlier position. And only one list of shares does all of that. |
| `proofs/Sums.dfy`                  | Facts about the sum of a list that the other proofs use.                                                                                                                                                                                                                                                                                                      |
| `proofs/Arithmetic.dfy`            | Small facts about multiplying and dividing that Z3 cannot find on its own inside a larger proof.                                                                                                                                                                                                                                                              |

The cent rounding and the lines of a dinner come next (#269, steps 4 and 5).

"Only one list" is what links the proof to the Ruby. `spec/services/largest_remainder_split_on_every_small_input_spec.rb` checks that the Ruby follows the same rule on every small input. Since only one list follows the rule, the Ruby gives exactly the proven answer on each of those inputs.

## Prove the examples too

A proof shows that the code follows the rule as the proof states it. It cannot show that the rule is stated correctly: a mistake in the rule is made in the code too, and the proof still passes. That happened while writing the split proof. With ties sent to the later position in both the rule and the code, every proof still passed.

So each proof file also proves a few examples worked out by hand from the docs, such as the $60 example in MODELS.md. With ties sent the wrong way, those fail.

## Write the proofs from the rules, not from the code

A Dafny model of `LargestRemainderSplit`, `Settlement.allocate_to_cents` or `MealLedger` must be written from the rules (AGENTS.md, Money Handling Standards; MODELS.md). Never edit it to match the Ruby. It is a separate copy of the rules, like `spec/support/oracle/plain_ledger.rb`, and it is useful only when it can disagree with the Ruby.
