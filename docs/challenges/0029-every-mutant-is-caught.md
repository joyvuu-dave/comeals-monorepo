---
id: 29
title: A test catches every code change
area: proof
status: done
opened: 2026-11-07
reviewed: 2026-11-11
watches:
  - docs/mutation-testing.md
  - bin/lib/mutant_survivors.rb
  - .github/workflows/mutant.yml
---

# A test catches every code change

## The challenge

For every small change mutant makes to the code, some test fails, or there is a written reason why no test can.

## The case that breaks it

mutant changes `>=` to `>` in a money rule, and every test still passes. That line can then be broken by a real edit, and nothing would fail.

## Where we stand

- Every surviving mutation has an entry in `config/mutant/accepted_survivors/`, one file for each class, with the reason no example can kill it (`docs/mutation-testing.md`, "Accepted survivors"). An entry names the method and its whole diff, so any edit to the method makes its entries stop matching, and its survivors are read again.
- `bin/mutant` and the Mutant workflow read every mutation from the session file mutant writes, and fail on a survivor with no entry, or an entry that no longer survives (`bin/lib/mutant_survivors.rb`, `spec/bin/mutant_report_spec.rb`). A timeout or a crashed process counts as a survivor (`coverage_criteria` in `.mutant.yml`).
- The Mutant workflow runs every class every Saturday (`.github/workflows/mutant.yml`), and fails when a piece leaves no result.
- CI's `mutant-changed` job mutates the methods each push to `main` changes, and the methods whose spec files it changes or deletes (`.github/workflows/ci.yml`, `bin/mutant-spec-subjects`), and the deploy waits for CI. A change to `spec/support`, a factory or `rails_helper` can weaken any example; only the Saturday run catches that.
- The full run of 2026-11-10 on this list: 41,495 mutations, 658 survivors, each one on the list (GitHub run 42918055270, and 42936726105 for the methods changed after it).
- Not checked by a machine: whether each written reason is true. People and agents wrote them from the code and its callers, and some were checked by running the code (the entries say which). A wrong reason hides a missing example the same way a missing entry would.

## Options

1. Run every stage again, and record the rates with the date.
2. For each survivor: a test that catches it, or a written reason why it cannot be caught.
3. Make it a gate: a survivor with no reason fails a check.

## Decision

Options 2 and 3, done 2026-11-10. The reasons are a list a program checks, not prose; the full run is weekly; and every push mutates the methods it changed. Option 3 is a CI job, not a `bin/check` step: the money methods alone take two hours on a laptop.

## History

- 2026-11-07: Opened.
- 2026-11-10: Added the mutant run on the money rules.
- 2026-11-10: The owner chose a list of accepted survivors that the report checks, a CI job on changed methods, and a weekly full run. Five helper agents went through the 753 survivors of that day's full run: about 115 got new examples, the rest got entries. Mutant's work on the survivors found a 500 on a profile email change that a query cache read caused (fixed in `RetryOnConflict`), two history bugs on hand-written audit rows, and a mutant crash on Faker names (https://github.com/mbj/mutant/issues/1690). Done.
- 2026-11-11: The owner asked for the edge cases to be fixed, not written down. The `mutant-changed` job now also runs on the methods whose spec files changed or were deleted.
