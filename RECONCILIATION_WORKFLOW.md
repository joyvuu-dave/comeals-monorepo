# Reconciliation Workflow

## Purpose

This document captures the desired workflow for performing a reconciliation, the pain points in the current process, and ideas for improvements. It preserves the _thinking_ behind each idea so we can come back later and start implementation without re-deriving the rationale.

> **What has shipped since this was written.** Item 4 below (a "finalized"
> state) was solved a different and stronger way: a reconciliation row refuses
> update and destroy from the moment it is created, and a reconciled meal's
> bills, attendance, and guests are refused by database triggers on every path,
> including `update_all` and psql. There is no unfinalize. Corrections settle
> as new entries in the next period — see `docs/runbooks/settled-data-repair.md`.
> The `audited` gem also now records every write on the financial models, which
> covers most of the "audit trail" idea. Items 1, 2, 3, and 5 are still open.

## Background

A reconciliation is a settlement event: at a given moment in time, we compute who owes whom for all unreconciled meals up to a cutoff date. The calculation is automated, but verifying its correctness — and preventing errors — is currently a manual, high-stakes process.

## The workflow as practiced

When the person responsible for reconciliations runs one, their mental flow is:

1. **Double-check the dates.** A reconciliation has one date filter: a cutoff (`end_date`), which must be strictly before today. Everything unreconciled and older gets swept, however old. So an old or stray meal is easy to pull in without noticing. A bill created manually for a meal from 3 years ago might be legitimate cleanup or might be a mistake. Either way, the reconciler wants to be made aware so they can investigate.

2. **Double-check the costs.** Easy for a cook to mis-enter a bill (typo: $400 for a $40 meal, or $4 for a $40 meal). Outliers should be flagged based on the community's actual cost history, not hardcoded thresholds. Different communities will have different typical cost ranges, especially across currencies.

3. **Lock the numbers.** The reconciler used to do this by printing the numbers. The system now does it: creating the reconciliation is the lock. The row cannot be updated or destroyed, and its meals' bills, attendance, and guests are frozen by database triggers. The catch is that the lock happens at the same instant as the calculation, so there is still no moment between "see the numbers" and "commit to them." That is what item 5 is about.

## Pain points

- **No outlier detection.** Errors only get caught if someone manually notices them.
- **No data quality warnings.** Bills with no attendees, attendees with no bills, $0 bills not flagged as `no_cost` — all pass without comment.
- **No preview / dry run.** The reconciler can only see what a reconciliation looks like _after_ creating it — and by then it is locked. They cannot delete it or fix it in place; the only path is a correcting entry in the next period. So the missing preview matters more now than it did before, not less.
- **No comparison to history.** A 4× cost rise from the previous reconciliation should be obvious, but today you have to compare by hand.

## Improvement ideas

These are loosely ordered by recommended implementation priority. Each captures the rationale, not just the idea.

### 1. Mismatch warnings (data quality)

Deterministic checks for common data-entry errors:

- **Bill with no attendees** — someone cooked but nobody ate? Probably wrong.
- **Attendance with no bill** — people ate but no cost was recorded? Probably the cook forgot to enter their receipt.
- **Bill amount of $0 with `no_cost: false`** — typo (forgot to enter the amount, OR the amount IS $0 but they forgot to flag it as no_cost).
- **Cook also marked as eating but multiplier 0** — unusual configuration, worth flagging.

These are deterministic, cheap to compute, easy to act on. They should appear as warnings on the reconciliation show page in an "Issues to Review" panel (which would also house the statistical outliers below).

**Priority:** Easiest to implement, catches the most basic and most common errors. Do this first.

### 2. Cost outlier detection

**Statistical bounds derived from the community's actual history**, not hardcoded.

**Method: IQR (interquartile range), not standard deviation.**

Why IQR over stddev:

- Standard deviation assumes a bell curve, but meal costs are right-skewed (cluster around a typical value, long tail of expensive ones). Stddev gets distorted by the tail and produces nonsensical bounds.
- IQR is robust — outliers in the source data don't poison the bounds (which is exactly what we're trying to detect).
- It's the textbook approach for skewed data (Tukey's fences).
- Easy to explain to non-engineers: "this meal is unusually expensive compared to your community's typical range."

Algorithm:

1. Compute Q1 (25th percentile) and Q3 (75th percentile) of unit cost across all historical reconciled meals for this community
2. IQR = Q3 - Q1
3. Lower bound = Q1 - 1.5 × IQR
4. Upper bound = Q3 + 1.5 × IQR
5. Flag any meal whose unit cost falls outside

Notes:

- **Use unit cost** (`total_cost / total_multiplier`), not total cost. Total cost without per-person normalization is meaningless.
- **Include capped meals** in the historical sample. A capped meal hitting its cap is itself a signal worth surfacing.
- **Cold-start problem:** A brand-new community has no history, so IQR isn't meaningful. But "no flagging until 20 meals" gives zero protection during exactly the period where mistakes are most likely — new community, unfamiliar process, everyone still learning. Use a **conservative hardcoded fallback band** (e.g., $1–$50 per person-equivalent unit cost) as a crude safety net until ~20 reconciled meals exist, then switch to IQR. The fallback doesn't need to be smart — it just needs to catch obvious typos ($400 for a $40 meal) during the period where statistical methods can't.
- **Inflation drift:** Costs change over time. We could weight recent meals more heavily, or use only the last N months. Start with all-time and refine if it becomes a problem.

**Priority:** Highest-value statistical feature. Solid second after mismatch warnings.

### 3. Date outlier detection

The challenge: "outlier" depends on context. A meal from 3 years ago is suspicious if all other meals are from the last 6 months, but normal if the community has been dormant. Absolute thresholds ("anything older than X days") will over-warn and under-warn at different times.

**Approach: relative outliers, not absolute.**

Detect dates that are outliers _relative to the other meals in the same reconciliation_. Possible methods:

- **Gap detection:** Sort meals by date. If there's a large gap between the oldest meal and the next-oldest meal, the oldest is suspect. (50 meals from Feb–March + 1 from 3 years ago = 2.5-year gap = obvious outlier.)
- **Median + spread:** Compute the median date. Flag any meal more than N times the typical spread before the median.

Gap detection is the simpler heuristic and probably enough.

**Priority:** Same UI surface as cost outliers. Build them together as part of the "Issues to Review" panel.

### 4. Finalized state — SHIPPED, in a stronger form. Kept for the reasoning.

The plan here was a nullable `finalized_at` timestamp: create the reconciliation, review it, then lock it, with a high-friction unfinalize for the cases where the reconciler changed their mind.

**We did not build that.** What shipped instead is simpler and harder:

- A reconciliation is locked from the moment it exists. `before_update` and `before_destroy` both refuse, always. There is no unfinalized state, so there is no unfinalize.
- Bill, MealResident, and Guest refuse create, update, and destroy on a reconciled meal (`ReconciledMealImmutability`), and `cap`, `date`, and `reconciliation_id` on the meal row are frozen too.
- Those refusals are also database triggers, so `update_all`, a rake task, and psql all hit them. The plan above only covered Rails validation hooks, which `update_all` walks straight past.
- The one bypass is `SET LOCAL comeals.allow_settled_writes = 'on'` inside a single transaction, for genuine data corruption. `docs/runbooks/settled-data-repair.md` is the procedure.

Two pieces of the reasoning above turned out to be right and are worth keeping:

**Bill immutability had to land with the lock, not after it.** It did. A lock on the reconciliation row alone would have been theater, since the balances are derived from bills and attendance.

**A timestamp beats a boolean.** Still true in general, but it stopped applying here: with no unlocked state to leave, `date` already answers "when."

What we gave up by not building `finalized_at`: there is no review window. Creating the reconciliation and locking it are one act, so a mistake can only be corrected forward, in the next period. That cost is what makes item 5 the most valuable thing left on this list.

### 5. Pre-flight preview ("dry run")

The biggest workflow improvement of all. The reconciler's habit is "double-check dates, double-check costs, then lock." Currently they can only check _after_ creating the reconciliation, and creating it is the lock. If they find a problem, they cannot delete it or fix it in place — the only remedy is a correcting entry in the next period.

A **preview page** would change this. Pick a cutoff date, click "Preview," and see exactly what _would_ happen — meal list, balances, outlier flags, mismatch warnings — without creating anything. Once satisfied, click "Create" to commit.

This turns reconciliation from "do it then fix problems" to "verify it then commit." It's the highest-leverage change in this whole list.

**Priority:** Most ambitious of the five, but the most rewarding.

**A thin preview is worth shipping much earlier.** The full vision — preview page with outlier flags, mismatch warnings, comparison to history — naturally comes last because it builds on items 1–3. But a _thin_ preview (just "here are the meals that would be swept, here are the balances that would be generated, no warnings yet") is really just a read-only version of the show page driven by a dry-run calculation. It has almost no dependencies. It's also the only item in this list that _prevents_ errors instead of flagging them after the fact — everything else is catching mistakes in a committed reconciliation. The thin preview should ship alongside the mismatch warnings (item 1), with outlier flags and historical comparisons layered in as they land. The "full preview" then becomes less a new feature and more the natural endpoint of accreting items 2–3 onto the thin one.

### Other ideas worth considering (lower priority)

- **Per-cook summary.** "Alice cooked 12 meals, Bob cooked 10, Charlie cooked 1." Quick visual sanity check on cooking distribution. Doesn't necessarily indicate an error, but a glance tells you whether the cooking burden is being shared.
- **Comparison to previous reconciliation.** "Previous: 45 meals, $1,200. This one: 50 meals, $4,800." A sudden 4× rise in cost should be easy to see. We don't need to flag this algorithmically — just show the comparison.
- **Notes field on the reconciliation.** Free-form context: "This reconciliation includes 3 catered events." Or "Bob's bill was wrong, fixed manually."
- **Audit trail.** Mostly done: the `audited` gem records every write on Meal, Bill, MealResident, Guest, and Reconciliation, with the author. What is missing is a view that reads it back in reconciliation terms.

## Recommended sequence

1. **Mismatch warnings + thin pre-flight preview** — ship together. Deterministic checks surfaced on a read-only dry-run page. This is the first item that _prevents_ errors instead of just flagging them after the fact.
2. **Cost outlier detection** — IQR-based, with a conservative hardcoded fallback band for the cold-start period. Layered into the preview from item 1.
3. **Date outlier detection** — same UI surface as cost outliers, build together.
4. ~~Finalized state~~ — done, see item 4.
5. **Full preview polish** — by this point the preview from item 1 has accreted all the warnings and outlier work; the remaining work is comparison-to-history and the UX for committing.

## Open questions

- **Fallback band tuning:** $1–$50 per person-equivalent is a guess for the cold-start safety net. What's the right floor and ceiling, and should it be a per-community configurable range rather than a hardcode?
- **Inflation drift:** window the historical sample, or weight recent meals more heavily?
- **Currency support:** explicitly out of scope here, but tied to the cost outlier statistical work for international communities.
