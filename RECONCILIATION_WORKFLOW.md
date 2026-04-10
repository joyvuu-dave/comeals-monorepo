# Reconciliation Workflow

## Purpose

This document captures the desired workflow for performing a reconciliation, the pain points in the current process, and ideas for improvements. It preserves the *thinking* behind each idea so we can come back later and start implementation without re-deriving the rationale.

## Background

A reconciliation is a settlement event: at a given moment in time, we compute who owes whom for all unreconciled meals up to a cutoff date. The calculation is automated, but verifying its correctness — and preventing errors — is currently a manual, high-stakes process.

## The workflow as practiced

When the person responsible for reconciliations runs one, their mental flow is:

1. **Double-check the dates.** Now that we sweep all unreconciled meals (no `start_date` filter), it's even easier for an old or stray meal to sneak in. A bill created manually for a meal from 3 years ago might be legitimate cleanup or might be a mistake. Either way, the reconciler wants to be made aware so they can investigate.

2. **Double-check the costs.** Easy for a cook to mis-enter a bill (typo: $400 for a $40 meal, or $4 for a $40 meal). Outliers should be flagged based on the community's actual cost history, not hardcoded thresholds. Different communities will have different typical cost ranges, especially across currencies.

3. **Lock the numbers.** Once the reconciler is satisfied that everything is correct, they mentally treat the reconciliation as final. Today this happens by physically printing the numbers; the system has no concept of "this reconciliation is finalized, don't touch it." Anyone editing the underlying meal data could silently invalidate the printed numbers.

## Pain points

- **No outlier detection.** Errors only get caught if someone manually notices them.
- **No data quality warnings.** Bills with no attendees, attendees with no bills, $0 bills not flagged as `no_cost` — all silently slip through.
- **No way to lock a finalized reconciliation.** Anyone can change the underlying data after the fact and silently invalidate the published balances.
- **No preview / dry run.** The reconciler can only see what a reconciliation looks like *after* creating it. If something's wrong, they have to delete or fix in place.
- **No comparison to history.** A 4× cost jump from the previous reconciliation should jump out, but currently you'd have to manually compare.

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
- **Cold-start problem:** A brand-new community has no history, so IQR isn't meaningful. Don't flag anything until ~20 reconciled meals exist.
- **Inflation drift:** Costs change over time. We could weight recent meals more heavily, or use only the last N months. Start with all-time and refine if it becomes a problem.

**Priority:** Highest-value statistical feature. Solid second after mismatch warnings.

### 3. Date outlier detection

The challenge: "outlier" depends on context. A meal from 3 years ago is suspicious if all other meals are from the last 6 months, but normal if the community has been dormant. Absolute thresholds ("anything older than X days") will over-warn and under-warn at different times.

**Approach: relative outliers, not absolute.**

Detect dates that are outliers *relative to the other meals in the same reconciliation*. Possible methods:

- **Gap detection:** Sort meals by date. If there's a large gap between the oldest meal and the next-oldest meal, the oldest is suspect. (50 meals from Feb–March + 1 from 3 years ago = 2.5-year gap = obvious outlier.)
- **Median + spread:** Compute the median date. Flag any meal more than N times the typical spread before the median.

Gap detection is the simpler heuristic and probably enough.

**Priority:** Same UI surface as cost outliers. Build them together as part of the "Issues to Review" panel.

### 4. Finalized state

Add a way to mark a reconciliation as locked, preventing accidental changes after the reconciler has signed off on it.

**Schema: `finalized_at` timestamp** (nullable; null = not finalized, set = finalized at this time).

Why timestamp over boolean:
- Captures *when* it was locked, which is real information ("we locked this 3 days ago, before the bug was found")
- Standard Rails idiom (`published_at`, `archived_at`, `deleted_at`)
- A boolean answers yes/no; a timestamp answers yes/no AND when

**Why "finalized" works as a name:**
- Past tense, implies done
- Reads naturally for both fresh and ancient reconciliations: "finalized on April 5, 2025"
- Better than "closed" (sounds like you can't read it) or "locked" (implies you'll unlock)

**Behavior:**
- `update_meals` action refuses if `finalized_at` is set
- Editing `end_date` refuses if `finalized_at` is set
- Read actions are unaffected
- A "Finalize" / "Unfinalize" toggle on the show page (toggleable, but with friction — confirm dialog)
- Visual indicator (banner, padlock icon) when finalized

**Open question: should the lock also block editing the underlying meal data (bills, attendance)?**

CLAUDE.md states the *principle* that reconciled meals should be immutable, but that principle isn't actually enforced in code today. If we're going to take the lock seriously, we should enforce immutability of bills/attendance for meals in a finalized reconciliation. Otherwise, an admin could "lock" the reconciliation and someone could still edit a bill on one of its meals.

This is a bigger change (validation hooks on Bill, MealResident, Guest) and could be a follow-up. The MVP is just blocking `update_meals`.

**Priority:** Simple to ship the basic version, but the bill-immutability question deserves its own discussion before we commit to a full implementation.

### 5. Pre-flight preview ("dry run")

The biggest workflow improvement of all. The reconciler's MO is "double-check dates, double-check costs, then lock." Currently they can only check *after* creating the reconciliation. If they find a problem, they have to delete or fix in place — risky and disruptive.

A **preview page** would change this. Pick a cutoff date, click "Preview," and see exactly what *would* happen — meal list, balances, outlier flags, mismatch warnings — without creating anything. Once satisfied, click "Create" to commit.

This turns reconciliation from "do it then fix problems" to "verify it then commit." It's the highest-leverage change in this whole list.

**Priority:** Most ambitious of the five, but the most rewarding. Save for last so it can build on the outlier and warning work.

### Other ideas worth considering (lower priority)

- **Per-cook summary.** "Alice cooked 12 meals, Bob cooked 10, Charlie cooked 1." Quick visual sanity check on cooking distribution. Doesn't necessarily indicate an error, but a glance tells you whether the cooking burden is being shared.
- **Comparison to previous reconciliation.** "Previous: 45 meals, $1,200. This one: 50 meals, $4,800." Sudden 4× cost jump should jump out at the eye. We don't need to flag this algorithmically — just show the comparison.
- **Notes field on the reconciliation.** Free-form context: "This reconciliation includes 3 catered events." Or "Bob's bill was wrong, fixed manually."
- **Audit trail.** Who created the reconciliation, who finalized it, who added/removed which meals, when. Important for accountability in shared finances.

## Recommended sequence

1. **Mismatch warnings** — easiest, deterministic, immediate value
2. **Cost outlier detection** — IQR-based, most valuable statistical feature
3. **Date outlier detection** — same UI as cost outliers, build together
4. **Finalized state** — simple basic version, defer bill-immutability discussion
5. **Pre-flight preview** — biggest workflow win, build on the foundation of items 1-3

## Open questions

- **Cold-start handling for cost outliers:** hardcoded fallback bounds, or no flagging until enough history?
- **Inflation drift:** window the historical sample, or weight recent meals more heavily?
- **Finalized lock and bill immutability:** enforce or defer to a follow-up?
- **Currency support:** explicitly out of scope here, but tied to the cost outlier statistical work for international communities.
