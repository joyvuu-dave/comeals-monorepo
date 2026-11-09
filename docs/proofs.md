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

| File              | What it proves                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `proofs/Sums.dfy` | The sum of a list, the sum of two lists put together, and the sum after one element changes. The other proofs use these. |

The split, the cent rounding and the lines of a dinner come next (#269, steps 3 to 5).

## Write the proofs from the rules, not from the code

A Dafny model of `LargestRemainderSplit`, `Settlement.allocate_to_cents` or `MealLedger` must be written from the rules (AGENTS.md, Money Handling Standards; MODELS.md). Never edit it to match the Ruby. It is a separate copy of the rules, like `spec/support/oracle/plain_ledger.rb`, and it is useful only when it can disagree with the Ruby.
