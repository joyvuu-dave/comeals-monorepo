# frozen_string_literal: true

# Database backstop for reconciled-meal immutability (issue #26).
#
# The Rails guards (ReconciledMealImmutability, Meal's frozen-column check)
# remain the first line of defense and produce the user-facing errors.
# These triggers make PostgreSQL itself refuse writes that skip callbacks —
# update_all, delete_all, update_columns, raw SQL, a psql session — so a
# settled ledger cannot be corrupted silently from any path.
#
# Deliberate escape hatch: each trigger honors a session-scoped setting so a
# human can repair genuinely corrupt settled data on purpose:
#
#   BEGIN;
#   SET LOCAL comeals.allow_settled_writes = 'on';
#   UPDATE ...;
#   COMMIT;
#
# SET LOCAL dies with the transaction, so the guard is back at commit and
# other sessions stay protected throughout. See
# docs/runbooks/settled-data-repair.md before using it — correcting entries
# are the first-choice fix; this is for corruption only.
class AddSettledMealImmutabilityTriggers < ActiveRecord::Migration[8.1]
  CHILD_TABLES = %w[bills meal_residents guests].freeze

  def up
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    # Child rows (bills, attendance, guests) feed the meal's settlement.
    # Once the meal is reconciled they are frozen: no insert, no update, no
    # delete. UPDATE checks BOTH meals when meal_id changes, mirroring
    # ReconciledMealImmutability — a row can be moved neither onto nor out
    # of a settled meal.
    execute <<~SQL
      CREATE FUNCTION comeals_reject_settled_child_write() RETURNS trigger AS $$
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

    CHILD_TABLES.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_reject_settled_write
        BEFORE INSERT OR UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION comeals_reject_settled_child_write();
      SQL
    end

    # The meal row itself: once settled, its settlement inputs are frozen
    # (mirrors Meal::FROZEN_WHEN_RECONCILED) and the row cannot be deleted.
    # While unreconciled, everything is legal — including the one settlement
    # write, reconciliation_id nil -> id (Reconciliation#assign_meals'
    # update_all), which needs no bypass.
    execute <<~SQL
      CREATE FUNCTION comeals_protect_settled_meal() RETURNS trigger AS $$
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

    execute <<~SQL
      CREATE TRIGGER meals_protect_settled
      BEFORE UPDATE OR DELETE ON meals
      FOR EACH ROW EXECUTE FUNCTION comeals_protect_settled_meal();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    execute 'DROP TRIGGER meals_protect_settled ON meals;'
    execute 'DROP FUNCTION comeals_protect_settled_meal();'
    CHILD_TABLES.each do |table|
      execute "DROP TRIGGER #{table}_reject_settled_write ON #{table};"
    end
    execute 'DROP FUNCTION comeals_reject_settled_child_write();'
  end
end
