# frozen_string_literal: true

# Every meal's stored lines must sum to exactly zero.
#
# A meal is the ledger's journal entry: what the cooks are credited is what
# the eaters are charged. Since 2026-09-17 MealLedger allocates every share
# at the ledger grain (MODELS.md, "The ledger grain"), so the lines it
# writes sum to zero by construction. This trigger makes PostgreSQL hold the
# same rule for writes that never went through Ruby, the way
# reconciliation_balances_sum_zero (20260731120000) does for the balances.
#
# It is a CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED, so it judges the
# end of the transaction, not each statement: a settlement inserts its lines
# in one insert_all, and a repair may delete and re-insert a meal's lines in
# several statements. Both are unbalanced in the middle and balanced at
# commit, which is the only moment that matters.
#
# The escape hatch (comeals.allow_settled_writes) does not turn this off, the
# same as for the balances: a repair may rewrite a settled line, but no
# repair may leave a meal's lines not adding up.
#
# Row-level, because a constraint trigger has to be. A settlement of a few
# hundred meals runs the per-meal sum a few thousand times at commit, each
# one an index lookup on meal_id, which is well under a second.
class MealChargesMustBalance < ActiveRecord::Migration[8.1]
  def up
    # Two CREATE statements on a table this migration does not lock for
    # long; strong_migrations cannot read inside execute, so it asks.
    safety_assured { create_trigger }
  end

  def create_trigger
    # OLD and NEW are only assigned for the operations that have them, so
    # each is collected behind its own TG_OP check. An UPDATE that moves a
    # line between meals must leave both of them balanced, which is why
    # both ids are gathered rather than just one.
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_meal_charges_sum_zero() RETURNS trigger AS $$
      DECLARE
        affected bigint[] := '{}';
        target_id bigint;
        total numeric;
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          affected := affected || OLD.meal_id;
        END IF;

        IF TG_OP <> 'DELETE' THEN
          affected := affected || NEW.meal_id;
        END IF;

        FOREACH target_id IN ARRAY affected LOOP
          SELECT COALESCE(SUM(amount), 0) INTO total
          FROM meal_charges WHERE meal_id = target_id;

          IF total <> 0 THEN
            RAISE EXCEPTION 'meal % refused: its stored lines sum to %, not zero. '
              'What the cooks are credited for a meal is what the eaters are charged. '
              'See docs/runbooks/settled-data-repair.md.',
              target_id, total;
          END IF;
        END LOOP;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE CONSTRAINT TRIGGER meal_charges_sum_zero
      AFTER INSERT OR UPDATE OR DELETE ON meal_charges
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION comeals_meal_charges_sum_zero();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    safety_assured do
      execute 'DROP TRIGGER meal_charges_sum_zero ON meal_charges;'
      execute 'DROP FUNCTION comeals_meal_charges_sum_zero();'
    end
  end
end
