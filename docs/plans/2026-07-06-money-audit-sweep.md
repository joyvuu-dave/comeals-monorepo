# Money-Audit Sweep — Execution Plan (2026-07-06)

Fixes all 15 issues (#3–#17) from the 2026-07-06 money-path audit, one worker
session at a time. The issues are the spec — this doc holds only the execution
order, the batching, and the status. When every box is ticked and the final
cleanup session has run, this file no longer exists.

**Sequential only.** Never run two worker sessions at once: they share one
checkout, one schema, and overlapping files.

Severity tags in issue titles (`[high]`/`[medium]`/`[low]`) are audit severity,
not execution order. The queue below is execution order.

## Operator prompt

Start each fresh session with exactly this, unchanged, until done:

> Read docs/plans/2026-07-06-money-audit-sweep.md and complete exactly one
> session — the first unchecked item in the Session Queue — following the
> Worker Protocol in that doc. Use the /tdd skill for the fix. When the session
> is committed, pushed, and checked off, report and stop. If no unchecked
> sessions remain, just tell me.

## Worker Protocol

1. **Preflight.** Working tree must be clean and on `main`; run `git pull`.
   If dirty, stop and report — do not stash or discard anything.
2. **Claim.** Take the first unchecked session in the queue below. If none
   remain, report that and stop.
3. **Read.** `gh issue view <n>` for each issue in the session. Bodies contain
   files, line numbers, failure scenarios, and suggested fixes. Re-verify every
   claim against the current code before changing anything — line numbers may
   have drifted and an earlier session may have partially addressed it. If an
   issue no longer reproduces, close it with a comment explaining why, tick the
   box with a note, commit, push, and stop — that counts as a completed session.
4. **Fix test-first.** Use the /tdd skill: write a failing test that reproduces
   the issue's failure scenario, watch it fail, then make the minimal correct
   fix. Follow CLAUDE.md's money rules — BigDecimal only, database constraints
   as the last line of defense, append-only ledger, edge cases tested.
5. **Scope discipline.** Fix only this session's issues. If you discover an
   adjacent problem, file a new GitHub issue (label `needs-triage`) instead of
   widening the diff.
6. **Verify.** `bin/check` must pass completely — the whole suite, not just the
   new tests. Caution: `bin/check` exits 0 even when checks fail, so read its
   output; do not trust the exit code. Baseline on 2026-07-06 was fully green.
7. **Update this doc.** Tick this session's checkbox and add a one-line outcome
   note under it (what changed, anything a later session should know).
8. **Commit.** One commit containing the fix, its tests, and this doc update.
   Include a `Fixes #<n>` line per issue so the push auto-closes them. No
   Co-Authored-By or any other AI-attribution trailers — ever.
9. **Push.** `git push origin main`.
10. **Close out.** For each issue, add a comment with the commit SHA and how the
    fix is tested (`gh issue comment <n>`), and confirm the issue is closed.
    Report what you did and stop — one session per invocation.

## Session Queue

### Phase 1 — Make the test harness real

The correctness oracle and settlement-rounding tests are the safety net for
every later session; they go first.

- [ ] **Session 1 — #12 + #13: billing correctness spec into the default run;
      fix the zero-multiplier oracle divergence.** Split the `:benchmark`-tagged
      correctness spec so a small deterministic dataset (capped / multi-cook /
      no_cost / guests) runs in every `rspec` invocation; add the
      `total_mult.zero?` short-circuit to `Resident#bill_reimbursements`; pin
      child-only meals across oracle, rake task, and settlement. Batched because
      #13 adds cases to the exact spec #12 restructures.
- [ ] **Session 2 — #14 + #16: allocate_to_cents negative-residual coverage,
      then hardening.** First pin the untested branch (fractional-cent credits →
      penny lands on most-positive remainder, ties by lowest resident_id), then add
      the input zero-sum assertion and a descriptive candidate-exhaustion error.
      Batched because both touch the same method, and #14's pinning tests must
      exist before #16 modifies it.

### Phase 2 — Reconciliation lifecycle

- [ ] **Session 3 — #3: stop sweeping meals that haven't happened.**
      `reconciliations:create` cutoff + `assign_meals` date predicate +
      `end_date_not_in_future` tightening, so neither the rake task nor the
      ActiveAdmin form can settle tonight's meal at $0.
- [ ] **Session 4 — #4: settled reconciliations are immutable in ActiveAdmin.**
      Freeze `end_date` after create; remove or replace `update_meals` with an
      append-only correction flow. Runs before Session 5 because it decides the
      fate of `update_meals`, which #8 would otherwise also patch.
- [ ] **Session 5 — #8: assignment TOCTOU.** Re-assert
      `reconciliation_id: nil` in the `update_all` WHERE clause and raise on
      row-count mismatch, in every assignment path that survived Session 4.

### Phase 3 — Write-path integrity (model guards → endpoints → locking → pin)

All four code sessions overlap in `meal.rb`, the guard models, and
`meals_controller.rb` — order matters and each builds on the last.

- [ ] **Session 6 — #9: model-layer immutability holes.** Re-parenting guard
      must check the OLD meal (`meal_id_was`); add a Meal-level guard freezing
      settlement inputs (`cap`, `date`, …) once reconciled.
- [ ] **Session 7 — #5: guest writes on closed meals.** Give Guest the same
      closed-meal create/destroy guards as MealResident, mirrored in the
      controller.
- [ ] **Session 8 — #7: no more delete_all through ids-assignment.** Diff and
      `destroy!` bills/attendance explicitly inside the meal lock so callbacks,
      guards, and audits run; drop `attendee_ids` from the ActiveAdmin permit list.
- [ ] **Session 9 — #6: locking pass.** Wrap every meal-mutation endpoint in
      `@meal.with_lock` and re-verify reconciled/closed state after the lock's
      reload, exactly as the create paths do. Last in the cluster so it wraps the
      endpoints as reshaped by Sessions 7–8. Evaluate the issue's suggested
      DB-level backstop; if deferring it, file a follow-up issue.
- [ ] **Session 10 — #15: pin update_bills rollback atomicity.** Request spec:
      later bill in a multi-bill payload fails → earlier writes rolled back;
      also pin negative-amount rejection. Test-only; runs after Sessions 8–9 so it
      pins the endpoint's final shape.

### Phase 4 — Isolated cleanups (no file overlap with anything above)

- [ ] **Session 11 — #10: consistent snapshot for billing:recalculate.** Wrap
      the reads in one `isolation: :repeatable_read` transaction.
- [ ] **Session 12 — #11: dashboard 'Cost per adult' mirrors settlement math.**
      Filter `with_attendees`, use effective (capped) cost.
- [ ] **Session 13 — #17: clock.rb reenable in ensure.** One transient failure
      must not permanently disable a scheduled task.
- [ ] **Session 14 — Final cleanup.** Verify issues #3–#17 are all closed
      (`gh issue list --state open`), reopen anything missed, then `git rm` this
      plan doc, commit, push. The closed issues and git history are the durable
      record.

## Sequencing rationale (reference)

File-overlap map that produced the order above:

| Contested code                                                | Issues              | Resolution                       |
| ------------------------------------------------------------- | ------------------- | -------------------------------- |
| `spec/tasks/billing_recalculate_correctness_spec.rb`          | #12, #13            | batched (Session 1)              |
| `Reconciliation#allocate_to_cents` + settlement specs         | #14, #16            | batched, test-first (Session 2)  |
| `Reconciliation#assign_meals` / `app/admin/reconciliation.rb` | #3, #4, #8          | sequential; #4 before #8         |
| `meal.rb`, guard models, `meals_controller.rb`                | #5, #6, #7, #9, #15 | guards → endpoints → locks → pin |
| isolated (`recalculate.rake`, `community.rb`, `clock.rb`)     | #10, #11, #17       | any order, last                  |

Harness-first reasoning: #12 revealed that the only spec checking production
batch math against the oracle never runs (`:benchmark`-excluded), and #13 that
the oracle itself diverges on zero-multiplier meals. Every Phase 2–3 session
changes money-adjacent code; they should do so with the correctness net live.
