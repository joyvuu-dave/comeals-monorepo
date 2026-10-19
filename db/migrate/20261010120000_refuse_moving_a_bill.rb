# frozen_string_literal: true

# A saved bill keeps its cook and its meal. A bill is "this cook on this
# meal" (ADR 0009, #135). The Bill model refuses a new cook or a new meal
# (Bill::COOK_AND_MEAL_FIXED); this trigger refuses it from every write
# that skips the model (update_columns, update_all, a rake task, psql),
# in the same words. To fix a wrong cook or meal, delete the bill and add
# a new one.
#
# Before this, the admin bill form changed the cook in place. The meal
# history then said "unknown bill changed", and the cook's older lines
# named the new cook. Production has a few such rows, all on one bill of
# an old meal. This migration does not touch them: a trigger reads only
# the write in front of it, and AuditDescription describes those rows
# ("Bill moved from <one cook> to <another>").
#
# ERRCODE check_violation, so Rails raises ActiveRecord::CheckViolation,
# the error a CHECK constraint gives. No repair bypass
# (comeals.allow_settled_writes): deleting the bill and adding a new one
# always works, so nothing needs to move a bill.
#
# The name sorts after bills_reject_settled_write, and PostgreSQL runs
# the BEFORE triggers of one table in name order. So on a settled meal
# the settled-meal trigger answers first, after it waits for a running
# settlement (spec/db/settlement_race_spec.rb moves a bill to test that
# wait). Either way the move is refused.
class RefuseMovingABill < ActiveRecord::Migration[8.1]
  def up
    # One function and one trigger. strong_migrations cannot read inside
    # execute, so it asks. A CREATE TRIGGER locks the table only for the
    # moment it runs.
    safety_assured do
      # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE FUNCTION comeals_bill_keeps_cook_and_meal() RETURNS trigger AS $$
        BEGIN
          IF NEW.resident_id IS DISTINCT FROM OLD.resident_id OR NEW.meal_id IS DISTINCT FROM OLD.meal_id THEN
            RAISE EXCEPTION 'UPDATE on bills refused (bill %): A bill''s cook and meal cannot change. '
              'To fix a wrong cook or meal, delete this bill and add a new one.',
              OLD.id
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL

      execute <<~SQL
        CREATE TRIGGER bills_same_cook_and_meal
        BEFORE UPDATE ON bills
        FOR EACH ROW EXECUTE FUNCTION comeals_bill_keeps_cook_and_meal();
      SQL
      # rubocop:enable Rails/SquishedSQLHeredocs
    end
  end

  def down
    safety_assured do
      execute 'DROP TRIGGER bills_same_cook_and_meal ON bills;'
      execute 'DROP FUNCTION comeals_bill_keeps_cook_and_meal();'
    end
  end
end
