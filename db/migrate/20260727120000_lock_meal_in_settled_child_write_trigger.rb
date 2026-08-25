# frozen_string_literal: true

# Closes the settlement race that let a settled ledger silently stop matching
# its own source data (issue #43).
#
# ## What was wrong
#
# 20260707100000 shipped comeals_reject_settled_child_write with two plain,
# conditional lookups — one for the row's old parent, one for its new one:
#
#   SELECT id INTO settled_meal_id FROM meals
#   WHERE id = OLD.meal_id AND reconciliation_id IS NOT NULL;   -- UPDATE, DELETE
#
#   SELECT id INTO settled_meal_id FROM meals
#   WHERE id = NEW.meal_id AND reconciliation_id IS NOT NULL;   -- INSERT, UPDATE
#
# While the meal is still unreconciled that predicate matches no row. No row
# means no lock, and no lock means the statement never waits. So a write that
# began while `reconciliations:create` was mid-flight was judged against
# pre-settlement state and allowed through — and then committed onto a meal
# that was reconciled by the time it landed.
#
# Two shapes of damage, pointing opposite directions:
#
#   - A row ADDED that no reconciliation counts. It sits on a settled meal but
#     is in no reconciliation's balances, and `billing:recalculate` skips it
#     because that task only sums unreconciled meals. A cook is never
#     reimbursed.
#   - A row DELETED that a reconciliation already counted. The stored balances
#     were computed from a row that no longer exists — a cook credited for a
#     bill that is gone, a resident charged with no attendance row behind it.
#     Moving a row off the meal with an UPDATE does the same thing.
#
# Neither raised anything. `allocate_to_cents` still summed to zero, because
# the row was simply not in its input.
#
# This is reachable from buttons in the UI, not only from psql. ActiveAdmin's
# forms do not take the meal row lock that the API's `with_meal_lock` takes:
# app/admin/bill.rb allows create, edit, and destroy and permits :meal_id, and
# app/admin/meal_resident.rb declares `actions :create, :destroy` — the
# attendance-correction path from issue #25.
#
# ## The fix
#
# Both lookups become unconditional locking reads. FOR KEY SHARE conflicts
# with the FOR UPDATE that Reconciliation#assign_meals now takes, so a racing
# write waits for the settlement and then decides against committed state —
# and is refused, loudly, instead of losing money quietly.
#
# The lock must be taken UNCONDITIONALLY. That is the whole point, and it is
# easy to "tidy" back into a bug: putting `AND reconciliation_id IS NOT NULL`
# back in the WHERE clause matches no row on an open meal, so it takes no lock
# and waits for nothing. The IS NOT NULL test has to happen after the SELECT,
# on the value it read, not inside it.
#
# ## Why every piece is required
#
# Three things have to be true together. Each was tested alone and each alone
# leaves a live race:
#
#   1. `Reconciliation#assign_meals` takes FOR UPDATE before claiming. Its
#      UPDATE alone takes only FOR NO KEY UPDATE, and FOR KEY SHARE does not
#      conflict with that — there would be nothing for the trigger to wait on.
#   2. The NEW.meal_id lookup locks. Without it, the trigger decides too early:
#      Postgres fires BEFORE INSERT triggers BEFORE the foreign-key check, so
#      the trigger reads the pre-settlement snapshot, the FK check then blocks,
#      the settlement commits, and the insert proceeds anyway. The lock has to
#      be taken in the trigger; leaving it to the FK is too late.
#   3. The OLD.meal_id lookup locks. This one was nearly skipped, on the
#      reasoning that a row which already belongs to a settled meal is refused
#      on state that cannot move, so locking would add contention for nothing.
#      That reasoning covers a meal that is ALREADY settled. It says nothing
#      about a meal that is BECOMING settled, which is the entire window this
#      migration is about. And a DELETE takes no foreign-key lock on the parent
#      at all — there is nothing to check on the way out — so without this lock
#      a racing delete never waits for anything.
#
# ## Cost
#
# The self-lock case is free: a path that already holds FOR UPDATE on the meal
# in the same transaction (the API's with_meal_lock) is asking for a lock it
# already owns, which never waits. If that were wrong, every RSVP and un-RSVP
# in the app would hang.
#
# Settlement now holds FOR UPDATE on every meal it claims for the length of its
# transaction. Measured warm and local: 64 ms for 30 residents and 25 meals,
# 241 ms for 300 meals. Settlement is a manual task. This costs nothing.
#
# The comeals.allow_settled_writes repair bypass is unchanged, and returns
# before either lookup — a repair transaction takes no lock here.
#
# Pinned by spec/db/settlement_race_spec.rb, for inserts, deletes, and
# re-parenting across all three child tables. Full record, including the
# experiments behind "each alone was tested and does not work":
# docs/adr/0003-concurrency-on-the-money-path.md.
class LockMealInSettledChildWriteTrigger < ActiveRecord::Migration[8.1]
  # No Rails/SquishedSQLHeredocs disable needed here, unlike `down`: the cop
  # skips a heredoc containing `--` comments, and this body has them.
  def up
    execute <<~SQL
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

  # Restores the non-locking form from 20260707100000. This reopens the race
  # described above, in both directions. It exists so the migration is
  # reversible, not because rolling back is a reasonable thing to do on a live
  # database.
  def down
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE OR REPLACE FUNCTION comeals_reject_settled_child_write() RETURNS trigger AS $$
      DECLARE
        settled_meal_id bigint;
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP IN ('UPDATE', 'DELETE') THEN
          SELECT id INTO settled_meal_id FROM meals
          WHERE id = OLD.meal_id AND reconciliation_id IS NOT NULL;
        END IF;

        IF settled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
          SELECT id INTO settled_meal_id FROM meals
          WHERE id = NEW.meal_id AND reconciliation_id IS NOT NULL;
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
