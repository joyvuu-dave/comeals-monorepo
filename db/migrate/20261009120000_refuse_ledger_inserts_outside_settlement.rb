# frozen_string_literal: true

# Only a settlement adds line items and settled balances.
#
# meal_charges_protect (20260802120000) and
# reconciliation_balances_protect_settled (20260731120000) refuse every
# UPDATE and DELETE on these two tables. They let every INSERT through,
# because the settlement writes its rows with INSERT. The sum-zero triggers
# then accept any insert that still adds up to zero. So two rows that cancel
# out — a $5 credit for Ann and a $5 guest charge for Bob — could be added
# to a settled meal from a console or psql, and Ann's settled statement
# would change. Only the nightly line-item check would see it, the next
# morning.
#
# The old migrations said a row-level trigger cannot tell the settlement's
# own inserts from a later one. It can: Settlement#write_ledger! writes
# everything inside one transaction, so it sets a setting that lasts only
# for that transaction (set_config(..., true)) and names its
# reconciliation: comeals.settling = <reconciliation id>
# (Settlement::SETTLING_SETTING). It turns the setting off again when it
# is done.
#
# These two triggers refuse an INSERT unless that setting names the
# reconciliation the row belongs to: for a balance, its reconciliation_id;
# for a line item, the reconciliation of its meal. A meal that is not
# settled has no reconciliation, so no line can be added to it at all. The
# repair bypass (comeals.allow_settled_writes) still lets a repair through,
# the same as for UPDATE and DELETE.
#
# This stops mistakes, not a person who means it: anyone who can set
# comeals.settling by hand can also set the bypass. That is the same rule
# the other protect triggers follow.
#
# The meal lookup takes no row lock, unlike the one in
# comeals_reject_settled_child_write (20260727120000). That one lets a
# write through while the meal is open, and the meal can become settled
# before the write commits, so it has to wait for a running settlement.
# This one never lets a line through for an open meal, so a write that
# runs beside a settlement has nothing to wait for: it is refused either
# way.
class RefuseLedgerInsertsOutsideSettlement < ActiveRecord::Migration[8.1]
  def up
    # Two functions and two triggers. strong_migrations cannot read inside
    # execute, so it asks. A CREATE TRIGGER locks the table only for the
    # moment it runs.
    safety_assured do
      create_line_item_guard
      create_balance_guard
    end
  end

  def down
    safety_assured do
      execute 'DROP TRIGGER reconciliation_balances_insert_by_settlement ON reconciliation_balances;'
      execute 'DROP FUNCTION comeals_balance_insert_by_settlement();'
      execute 'DROP TRIGGER meal_charges_insert_by_settlement ON meal_charges;'
      execute 'DROP FUNCTION comeals_meal_charge_insert_by_settlement();'
    end
  end

  private

  # A meal that does not exist and a meal that is not settled each get
  # their own words. The foreign key would refuse the first one too, but
  # this trigger runs before it. The words for a settled meal ("corrections
  # belong in the next reconciliation") would be wrong advice for an open
  # meal, whose bills and attendance can still be changed.
  #
  # For a settled meal, plain "=" on purpose. When the setting was never
  # set, current_setting gives NULL, and "=" with a NULL is not true, so the
  # line is refused. IS NOT DISTINCT FROM would let a NULL meet a NULL.
  def create_line_item_guard
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_meal_charge_insert_by_settlement() RETURNS trigger AS $$
      DECLARE
        meal_reconciliation_id bigint;
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN NEW;
        END IF;

        SELECT reconciliation_id INTO meal_reconciliation_id FROM meals WHERE id = NEW.meal_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'INSERT on meal_charges refused: there is no meal %.', NEW.meal_id;
        END IF;

        IF meal_reconciliation_id IS NULL THEN
          RAISE EXCEPTION 'INSERT on meal_charges refused: meal % is not settled. A meal gets its line items '
            'only from the settlement that settles it.',
            NEW.meal_id;
        END IF;

        IF meal_reconciliation_id::text = current_setting('comeals.settling', true) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'INSERT on meal_charges refused: the line items of meal % are written only '
          'by the settlement that settles it. Corrections belong in the next reconciliation. '
          'For genuine data corruption see docs/runbooks/settled-data-repair.md.',
          NEW.meal_id;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER meal_charges_insert_by_settlement
      BEFORE INSERT ON meal_charges
      FOR EACH ROW EXECUTE FUNCTION comeals_meal_charge_insert_by_settlement();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def create_balance_guard
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_balance_insert_by_settlement() RETURNS trigger AS $$
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN NEW;
        END IF;

        IF NEW.reconciliation_id::text = current_setting('comeals.settling', true) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'INSERT on reconciliation_balances refused: the balances of reconciliation % '
          'are written only by its own settlement. Corrections belong in the next reconciliation. '
          'For genuine data corruption see docs/runbooks/settled-data-repair.md.',
          NEW.reconciliation_id;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER reconciliation_balances_insert_by_settlement
      BEFORE INSERT ON reconciliation_balances
      FOR EACH ROW EXECUTE FUNCTION comeals_balance_insert_by_settlement();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end
end
