# frozen_string_literal: true

# A dinner can be cancelled (ADR 0011 rule 11). meals.cancelled_at is when
# it was; NULL is a dinner that was not.
#
# A cancelled dinner keeps its sign-ups and guests, as the record of who
# meant to come, and charges nobody: every line the ledger writes for it
# is $0 (MealLedger). The next settlement takes it in and locks it like
# any other dinner. Until then it can be restored, and it is back as it
# was.
#
# Two rules here, under the model's, so a write that skips the model
# (psql, update_all, insert_all) is held to them too:
#
#   - comeals_reject_settled_child_write refuses every write to the bills,
#     attendance and guests of a cancelled dinner. Who comes and what the
#     cooks spent stay as they were when it was cancelled. Both lookups
#     already read the meal row with an unconditional FOR KEY SHARE; they
#     now read cancelled_at in the same SELECT. Do not make either lookup
#     conditional (20260727120000).
#   - comeals_protect_settled_meal refuses cancelling a dinner a cook spent
#     money on: a bill over $0 that is not No cost. Cancelling it would
#     credit the cook $0 for that money. And once the dinner is settled,
#     cancelled_at is frozen with cap, date and reconciliation_id.
#
# Dated 20261010125954, before the day it was written (2026-10-15), on
# purpose, like 20261010125950: the data fixes from 20261010130000 run
# Settlement#correct!, whose ledger reads this column, and in production
# they run in the order of their dates.
#
# down refuses while a dinner is cancelled: dropping the column would
# charge everyone who signed up for it.
class LetADinnerBeCancelled < ActiveRecord::Migration[8.1]
  def up
    add_column :meals, :cancelled_at, :datetime

    safety_assured do
      execute <<~SQL
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
            -- Unconditional, like the branch below. A DELETE takes no
            -- foreign-key lock on the parent, so this SELECT is the only thing
            -- that can make it wait for a settlement mid-flight on this meal.
            SELECT reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at FROM meals
            WHERE id = OLD.meal_id FOR KEY SHARE;

            IF meal_reconciliation_id IS NOT NULL AND OLD.meal_id::text IS DISTINCT FROM correcting THEN
              settled_meal_id := OLD.meal_id;
            END IF;
            IF meal_cancelled_at IS NOT NULL THEN
              cancelled_meal_id := OLD.meal_id;
            END IF;
          END IF;

          IF settled_meal_id IS NULL AND cancelled_meal_id IS NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
            -- Unconditional: the lock is the point. Testing reconciliation_id in
            -- the WHERE clause would match no row on an unreconciled meal, take
            -- no lock, and let this trigger decide before a running settlement
            -- commits.
            SELECT reconciliation_id, cancelled_at INTO meal_reconciliation_id, meal_cancelled_at FROM meals
            WHERE id = NEW.meal_id FOR KEY SHARE;

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

      # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE OR REPLACE FUNCTION comeals_protect_settled_meal() RETURNS trigger AS $$
        BEGIN
          IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
            RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
          END IF;

          IF TG_OP = 'DELETE' THEN
            IF OLD.reconciliation_id IS NOT NULL THEN
              RAISE EXCEPTION 'DELETE on meals refused: meal % is reconciled and settled source data '
                'cannot be erased. For genuine data corruption see docs/runbooks/settled-data-repair.md.',
                OLD.id;
            END IF;
            RETURN OLD;
          END IF;

          IF NEW.cancelled_at IS NOT NULL AND OLD.cancelled_at IS NULL AND EXISTS (
            SELECT 1 FROM bills WHERE meal_id = NEW.id AND amount > 0 AND NOT no_cost
          ) THEN
            RAISE EXCEPTION 'UPDATE on meals refused: meal % has a cost with money on it, so it cannot be '
              'cancelled. The cook would be credited nothing for that money.',
              NEW.id;
          END IF;

          IF OLD.reconciliation_id IS NULL THEN
            RETURN NEW;
          END IF;

          IF NEW.reconciliation_id IS DISTINCT FROM OLD.reconciliation_id
             OR NEW.cap IS DISTINCT FROM OLD.cap
             OR NEW.date IS DISTINCT FROM OLD.date
             OR NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at THEN
            RAISE EXCEPTION 'UPDATE on meals refused: meal % is reconciled; cap, date, cancelled_at and '
              'reconciliation_id are frozen. For genuine data corruption see '
              'docs/runbooks/settled-data-repair.md.',
              OLD.id;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end
  end

  def down
    cancelled = select_value('SELECT count(*) FROM meals WHERE cancelled_at IS NOT NULL').to_i
    if cancelled.positive?
      raise "#{cancelled} dinner(s) are cancelled. Dropping meals.cancelled_at would charge everyone who " \
            'signed up for them, so this migration will not run down.'
    end

    safety_assured do
      execute <<~SQL
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

      # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE OR REPLACE FUNCTION comeals_protect_settled_meal() RETURNS trigger AS $$
        BEGIN
          IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
            RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
          END IF;

          IF TG_OP = 'DELETE' THEN
            IF OLD.reconciliation_id IS NOT NULL THEN
              RAISE EXCEPTION 'DELETE on meals refused: meal % is reconciled and settled source data '
                'cannot be erased. For genuine data corruption see docs/runbooks/settled-data-repair.md.',
                OLD.id;
            END IF;
            RETURN OLD;
          END IF;

          IF OLD.reconciliation_id IS NULL THEN
            RETURN NEW;
          END IF;

          IF NEW.reconciliation_id IS DISTINCT FROM OLD.reconciliation_id
             OR NEW.cap IS DISTINCT FROM OLD.cap
             OR NEW.date IS DISTINCT FROM OLD.date THEN
            RAISE EXCEPTION 'UPDATE on meals refused: meal % is reconciled; cap, date, and '
              'reconciliation_id are frozen. For genuine data corruption see '
              'docs/runbooks/settled-data-repair.md.',
              OLD.id;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end

    remove_column :meals, :cancelled_at
  end
end
