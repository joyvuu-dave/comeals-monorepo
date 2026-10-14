# frozen_string_literal: true

# A correction changes a settled dinner's rows (ADR 0011 rule 6).
#
# comeals_reject_settled_child_write refuses every write to the bills,
# attendance and guests of a settled meal (20260727120000). This keeps
# that, and lets through the one dinner the transaction is correcting:
# MealCorrecting sets comeals.correcting to the dinner's id, for its own
# transaction only (set_config(..., true)), and records the correction in
# the same transaction (20261013130000).
#
# Both meals are checked when a row moves between meals, the way the
# trigger checked them before. A row cannot move off the dinner being
# corrected onto another settled dinner, or the other way round, because
# the other dinner is not the one named.
#
# The locks are the same as before: both lookups are unconditional
# FOR KEY SHARE reads, so an unlocked write still waits for a running
# settlement. Do not make either one conditional; see 20260727120000.
#
# This stops mistakes, not a person who means it: anyone who can set
# comeals.correcting by hand can also set the repair bypass. A change
# made that way, with no correction recorded, is found by the nightly
# check, which compares each settled dinner's rows with what it was
# settled at plus its corrections (LedgerVerification).
class LetACorrectionWriteASettledMeal < ActiveRecord::Migration[8.1]
  def up
    # A PL/pgSQL body keeps its line breaks, so the heredoc is not squished.
    safety_assured { execute <<~SQL }
      CREATE OR REPLACE FUNCTION comeals_reject_settled_child_write() RETURNS trigger AS $$
      DECLARE
        settled_meal_id bigint;
        meal_reconciliation_id bigint;
        correcting text := current_setting('comeals.correcting', true);
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          -- Unconditional, like the branch below. A DELETE takes no
          -- foreign-key lock on the parent, so this SELECT is the only thing
          -- that can make it wait for a settlement mid-flight on this meal.
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals
          WHERE id = OLD.meal_id FOR KEY SHARE;

          IF meal_reconciliation_id IS NOT NULL AND OLD.meal_id::text IS DISTINCT FROM correcting THEN
            settled_meal_id := OLD.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
          -- Unconditional: the lock is the point. Testing reconciliation_id in
          -- the WHERE clause would match no row on an unreconciled meal, take
          -- no lock, and let this trigger decide before a running settlement
          -- commits.
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals
          WHERE id = NEW.meal_id FOR KEY SHARE;

          IF meal_reconciliation_id IS NOT NULL AND NEW.meal_id::text IS DISTINCT FROM correcting THEN
            settled_meal_id := NEW.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NOT NULL THEN
          RAISE EXCEPTION '% on % refused: meal % is reconciled and its ledger rows are immutable. '
            'A mistake is fixed by a correction (MealCorrecting), which the next settlement carries. '
            'For genuine data corruption see docs/runbooks/settled-data-repair.md.',
            TG_OP, TG_TABLE_NAME, settled_meal_id;
        END IF;

        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  # The function as 20260727120000 left it.
  def down
    # A PL/pgSQL body keeps its line breaks, so the heredoc is not squished.
    safety_assured { execute <<~SQL }
      CREATE OR REPLACE FUNCTION comeals_reject_settled_child_write() RETURNS trigger AS $$
      DECLARE
        settled_meal_id bigint;
        meal_reconciliation_id bigint;
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          -- Unconditional, like the branch below. A DELETE takes no
          -- foreign-key lock on the parent, so this SELECT is the only thing
          -- that can make it wait for a settlement mid-flight on this meal.
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals
          WHERE id = OLD.meal_id FOR KEY SHARE;

          IF meal_reconciliation_id IS NOT NULL THEN
            settled_meal_id := OLD.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
          -- Unconditional: the lock is the point. Testing reconciliation_id in
          -- the WHERE clause would match no row on an unreconciled meal, take
          -- no lock, and let this trigger decide before a running settlement
          -- commits.
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals
          WHERE id = NEW.meal_id FOR KEY SHARE;

          IF meal_reconciliation_id IS NOT NULL THEN
            settled_meal_id := NEW.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NOT NULL THEN
          RAISE EXCEPTION '% on % refused: meal % is reconciled and its ledger rows are immutable. '
            'Corrections belong in the next reconciliation. For genuine data corruption see '
            'docs/runbooks/settled-data-repair.md.',
            TG_OP, TG_TABLE_NAME, settled_meal_id;
        END IF;

        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
