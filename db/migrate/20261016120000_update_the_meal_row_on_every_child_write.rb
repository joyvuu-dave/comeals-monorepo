# frozen_string_literal: true

# A write to a meal's bills, attendance or guests now updates the meal's
# row, from inside the trigger comeals_reject_settled_child_write, instead
# of only reading it FOR KEY SHARE. The two lookups stay unconditional,
# and the rules stay as they were: the repair bypass, the dinner being
# corrected (comeals.correcting), and the refusals for a settled and for a
# cancelled dinner. Only the lookup changes, from
#
#   SELECT reconciliation_id, cancelled_at ... FROM meals WHERE id = ... FOR KEY SHARE
#
# to
#
#   UPDATE meals SET updated_at = updated_at WHERE id = ...
#   RETURNING reconciliation_id, cancelled_at ...
#
# Why. A settlement and the app's cancel lock the meal row FOR UPDATE, then
# decide from what they read. A write from psql runs at READ COMMITTED and takes
# no lock of its own; the trigger's lookup was its only lock on the meal.
# When that write started first, FOR KEY SHARE made the settlement or the
# cancel wait for it, as #43 meant. But both run at SERIALIZABLE (ADR
# 0005), so their snapshot was taken when their first statement began,
# before the wait. A lock changes no row, so the wait ended with no
# conflict, and PostgreSQL's conflict check does not see a READ COMMITTED
# writer either. So they decided from the rows as they were before the
# write:
#
#   - a settlement settled a meal without a sign-up added at that moment,
#     or with one removed at that moment
#     (spec/db/settlement_after_a_raw_write_race_spec.rb);
#   - a cancel went through while a cost with money was being written, so
#     the cook was credited $0 for it (spec/db/cancel_against_a_cost_race_spec.rb).
#     The cancel's own UPDATE takes FOR NO KEY UPDATE, which does not
#     conflict with FOR KEY SHARE, so a raw cancel did not even wait.
#
# An UPDATE changes the meal row. A SERIALIZABLE settlement or cancel that
# waited for it then fails as a conflict, and is tried again with a fresh
# snapshot that has the write in it. A READ COMMITTED one, from psql, reads
# the new row after the wait. And the UPDATE takes FOR NO KEY UPDATE,
# which a raw cancel's UPDATE waits for, in both orders. A write through
# the models already did this: `touch: true` on the row's belongs_to
# updates the meal row in the same transaction. Now a raw write does it
# too.
#
# updated_at = updated_at: the row changes, the time does not.
# comeals_protect_settled_meal lets that through on a settled meal, since
# no frozen column changes.
#
# down puts back the function as 20261010125954 left it.
class UpdateTheMealRowOnEveryChildWrite < ActiveRecord::Migration[8.1]
  def up
    # strong_migrations cannot see inside execute, so it asks. CREATE OR
    # REPLACE FUNCTION changes no table and locks no row anyone is using.
    safety_assured { execute function(lookup: :update) }
  end

  def down
    safety_assured { execute function(lookup: :read) }
  end

  private

  # A PL/pgSQL body keeps its line breaks, so the heredoc is not squished.
  def function(lookup:)
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    <<~SQL
      CREATE OR REPLACE FUNCTION comeals_reject_settled_child_write() RETURNS trigger AS $$
      DECLARE
        settled_meal_id bigint;
        cancelled_meal_id bigint;
        meal_reconciliation_id bigint;
        meal_cancelled_at timestamp;
        correcting text := current_setting('comeals.correcting', true);
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          #{old_lookup(lookup)}

          IF meal_reconciliation_id IS NOT NULL AND OLD.meal_id::text IS DISTINCT FROM correcting THEN
            settled_meal_id := OLD.meal_id;
          END IF;
          IF meal_cancelled_at IS NOT NULL THEN
            cancelled_meal_id := OLD.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NULL AND cancelled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
          #{new_lookup(lookup)}

          IF meal_reconciliation_id IS NOT NULL AND NEW.meal_id::text IS DISTINCT FROM correcting THEN
            settled_meal_id := NEW.meal_id;
          END IF;
          IF meal_cancelled_at IS NOT NULL THEN
            cancelled_meal_id := NEW.meal_id;
          END IF;
        END IF;

        IF settled_meal_id IS NOT NULL THEN
          RAISE EXCEPTION '% on % refused: meal % is reconciled and its ledger rows are immutable. '
            'A mistake is fixed by a correction (MealCorrecting), which the next settlement carries. '
            'For genuine data corruption see docs/runbooks/settled-data-repair.md.',
            TG_OP, TG_TABLE_NAME, settled_meal_id;
        END IF;

        IF cancelled_meal_id IS NOT NULL THEN
          RAISE EXCEPTION '% on % refused: meal % is cancelled, and its sign-ups, guests and costs stay '
            'as they were. Restore the dinner to change them.',
            TG_OP, TG_TABLE_NAME, cancelled_meal_id;
        END IF;

        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def old_lookup(lookup)
    return <<~SQL.chomp.gsub("\n", "\n    ") if lookup == :read
      -- Unconditional, like the branch below. A DELETE takes no
      -- foreign-key lock on the parent, so this SELECT is the only thing
      -- that can make it wait for a settlement mid-flight on this meal.
      SELECT reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at FROM meals
      WHERE id = OLD.meal_id FOR KEY SHARE;
    SQL

    <<~SQL.chomp.gsub("\n", "\n    ")
      -- Unconditional, like the branch below. A DELETE takes no
      -- foreign-key lock on the parent, so this UPDATE is the only thing
      -- that can make it wait for a settlement mid-flight on this meal,
      -- and it changes the meal row, so a SERIALIZABLE settlement or
      -- cancel that waited for it fails as a conflict and tries again.
      UPDATE meals SET updated_at = updated_at WHERE id = OLD.meal_id
      RETURNING reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at;
    SQL
  end

  def new_lookup(lookup)
    return <<~SQL.chomp.gsub("\n", "\n    ") if lookup == :read
      -- Unconditional: the lock is the point. Testing reconciliation_id in
      -- the WHERE clause would match no row on an unreconciled meal, take
      -- no lock, and let this trigger decide before a running settlement
      -- commits.
      SELECT reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at FROM meals
      WHERE id = NEW.meal_id FOR KEY SHARE;
    SQL

    <<~SQL.chomp.gsub("\n", "\n    ")
      -- Unconditional: the lock and the change to the meal row are the
      -- point. Testing reconciliation_id in the WHERE clause would match
      -- no row on an unreconciled meal, take no lock, and let this trigger
      -- decide before a running settlement commits.
      UPDATE meals SET updated_at = updated_at WHERE id = NEW.meal_id
      RETURNING reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at;
    SQL
  end
end
