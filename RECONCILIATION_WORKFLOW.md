# Reconciliation Workflow

## Purpose

This document captures the desired workflow for performing a reconciliation, the pain points in the current process, and ideas for improvements. It preserves the _thinking_ behind each idea so we can come back later and start implementation without re-deriving the rationale.

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
- **No preview / dry run.** The reconciler can only see what a reconciliation looks like _after_ creating it. If something's wrong, they have to delete or fix in place.
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

### 4. Finalized state

Add a way to mark a reconciliation as locked, preventing accidental changes after the reconciler has signed off on it.

**Schema: `finalized_at` timestamp** (nullable; null = not finalized, set = finalized at this time).

Why timestamp over boolean:

- Captures _when_ it was locked, which is real information ("we locked this 3 days ago, before the bug was found")
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
- Visual indicator (banner, padlock icon) when finalized
- **Unfinalize is deliberately high-friction.** Not just a confirm dialog — that's cosmetic friction and recreates the exact problem finalization is supposed to solve. Minimum bar: admin-only, audit-logged (who unlocked, when, why), and unfinalization **forces a re-derivation of the balances** on re-finalization so any drift in the underlying meal data is surfaced rather than hidden. If nothing changed underneath, the re-derivation is a no-op; if something did change, the reconciler is forced to confront it before re-locking.

**Bill immutability must land _with_ `finalized_at`, not as a follow-up.**

CLAUDE.md already commits to the principle ("financial records are append-only / immutable where possible"); finalization is the moment we finally enforce it in code. If an admin can still edit a bill on a reconciled meal after the reconciliation is "locked," the lock is theater. Worse, this becomes actively dangerous once the collection workflow lands: once money has actually moved (see `COLLECTION_WORKFLOW.md`), silent drift in the underlying ledger means the published balances no longer match the numbers on file. `settled_at` is built on the assumption that `finalized_at` means something.

Concretely: Bill, MealResident, and Guest all need validation hooks that refuse writes (create/update/destroy) when their parent meal belongs to a reconciliation with `finalized_at` set. Yes, this is a bigger change than just blocking `update_meals`. Ship them together anyway — a finalization feature that doesn't actually finalize is worse than no feature at all, because it invites false confidence.

The intentional exception: unfinalization (see above) temporarily re-enables edits, but forces a balance re-derivation on re-finalization so nothing slips through silently.

**Priority:** Simple to ship the basic version, but the bill-immutability question deserves its own discussion before we commit to a full implementation.

### 5. Pre-flight preview ("dry run")

The biggest workflow improvement of all. The reconciler's MO is "double-check dates, double-check costs, then lock." Currently they can only check _after_ creating the reconciliation. If they find a problem, they have to delete or fix in place — risky and disruptive.

A **preview page** would change this. Pick a cutoff date, click "Preview," and see exactly what _would_ happen — meal list, balances, outlier flags, mismatch warnings — without creating anything. Once satisfied, click "Create" to commit.

This turns reconciliation from "do it then fix problems" to "verify it then commit." It's the highest-leverage change in this whole list.

**Priority:** Most ambitious of the five, but the most rewarding.

**A thin preview is worth shipping much earlier.** The full vision — preview page with outlier flags, mismatch warnings, comparison to history — naturally comes last because it builds on items 1–3. But a _thin_ preview (just "here are the meals that would be swept, here are the balances that would be generated, no warnings yet") is really just a read-only version of the show page driven by a dry-run calculation. It has almost no dependencies. It's also the only item in this list that _prevents_ errors instead of flagging them after the fact — everything else is catching mistakes in a committed reconciliation. The thin preview should ship alongside the mismatch warnings (item 1), with outlier flags and historical comparisons layered in as they land. The "full preview" then becomes less a new feature and more the natural endpoint of accreting items 2–3 onto the thin one.

### Other ideas worth considering (lower priority)

- **Per-cook summary.** "Alice cooked 12 meals, Bob cooked 10, Charlie cooked 1." Quick visual sanity check on cooking distribution. Doesn't necessarily indicate an error, but a glance tells you whether the cooking burden is being shared.
- **Comparison to previous reconciliation.** "Previous: 45 meals, $1,200. This one: 50 meals, $4,800." Sudden 4× cost jump should jump out at the eye. We don't need to flag this algorithmically — just show the comparison.
- **Notes field on the reconciliation.** Free-form context: "This reconciliation includes 3 catered events." Or "Bob's bill was wrong, fixed manually."
- **Audit trail.** Who created the reconciliation, who finalized it, who added/removed which meals, when. Important for accountability in shared finances.

## Recommended sequence

1. **Mismatch warnings + thin pre-flight preview** — ship together. Deterministic checks surfaced on a read-only dry-run page. This is the first item that _prevents_ errors instead of just flagging them after the fact.
2. **Cost outlier detection** — IQR-based, with a conservative hardcoded fallback band for the cold-start period. Layered into the preview from item 1.
3. **Date outlier detection** — same UI surface as cost outliers, build together.
4. **Finalized state (with full bill/attendance immutability)** — ships as one unit. Not a "basic version first, immutability later" split — the two are inseparable, and finalization without enforcement is worse than no feature at all. Includes the hardened unfinalize flow (admin-only, audit-logged, forces balance re-derivation on re-lock).
5. **Full preview polish** — by this point the preview from item 1 has accreted all the warnings and outlier work; the remaining work is comparison-to-history and the UX for committing.

## Open questions

- **Fallback band tuning:** $1–$50 per person-equivalent is a guess for the cold-start safety net. What's the right floor and ceiling, and should it be a per-community configurable range rather than a hardcode?
- **Inflation drift:** window the historical sample, or weight recent meals more heavily?
- **Currency support:** explicitly out of scope here, but tied to the cost outlier statistical work for international communities.
- **Unfinalize audit log:** where does it live? A dedicated `reconciliation_audit_events` table, or a generic audit trail that covers other finance-sensitive actions too?
