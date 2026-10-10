# frozen_string_literal: true

# The record of a settlement whose numbers were worked out again after it
# was made (Settlement#correct!).
#
# A settlement's balances are written once, from the meals' rows as they
# were that day. If a row was wrong and gets fixed later, the owner may
# decide that the settlement must show the right numbers, not the ones
# worked out from the wrong row. The first case is migration
# 20261010130000: 11 bills on settled meals were marked No cost and also
# had an amount, so their cooks were credited $0 for them.
#
# Working the numbers out again replaces the settlement's balances and
# line items. These three tables keep what was there before, so the
# change can be read later:
#
#   settlement_corrections         when, and why; and whether the caller
#                                  let it fold in differences the nightly
#                                  check had already found, with those
#                                  findings (empty for a clean correction)
#   settlement_correction_lines    each person whose balance changed, with
#                                  the amount before and after. A person
#                                  whose balance did not change has no line.
#   settlement_correction_charges  every line item the correction deleted,
#                                  as it was (a settlement made before
#                                  2026-08-02 has none)
#
# Append-only, for the same reason as ledger_check_runs: a record that can
# be edited afterwards is not evidence. A trigger refuses UPDATE and
# DELETE, and another refuses an INSERT unless Settlement#correct! is
# writing the correction for that settlement, which it says with the same
# setting a settlement writes its balances under (comeals.settling). Both
# allow the comeals.allow_settled_writes bypass, like the rest of the
# money path.
#
# down refuses while a correction is recorded: dropping the tables would
# lose the only record of what those settlements said before, while the
# new balances and line items stay. An older release ignores these
# tables, so a rollback of the code does not need them gone.
class CreateSettlementCorrections < ActiveRecord::Migration[8.1]
  TABLES = %w[settlement_corrections settlement_correction_lines settlement_correction_charges].freeze

  def up
    create_table :settlement_corrections do |t|
      t.references :reconciliation, null: false, foreign_key: true
      t.text :reason, null: false
      # Settlement#correct!'s include_earlier_differences: true, and what
      # the nightly check found in the settlement before the caller's fix,
      # in the shape ledger_check_runs.details has.
      t.boolean :include_earlier_differences, null: false, default: false
      t.jsonb :earlier_differences, null: false, default: []
      t.timestamps
    end
    add_check_constraint :settlement_corrections, "btrim(reason) <> ''",
                         name: 'settlement_corrections_reason_present'
    add_check_constraint :settlement_corrections, "jsonb_typeof(earlier_differences) = 'array'",
                         name: 'settlement_corrections_earlier_differences_list'
    add_check_constraint :settlement_corrections,
                         "include_earlier_differences OR earlier_differences = '[]'::jsonb",
                         name: 'settlement_corrections_earlier_differences_only_when_included'

    create_table :settlement_correction_lines do |t|
      t.references :settlement_correction, null: false, foreign_key: true, index: false
      t.references :resident, null: false, foreign_key: true
      # Signed the way a settled balance is (ReconciliationBalance): positive
      # means the community owes the person. Zero when the person had no
      # balance on that side.
      t.decimal :old_amount, precision: 16, scale: 8, null: false
      t.decimal :new_amount, precision: 16, scale: 8, null: false
      t.timestamps
    end
    add_index :settlement_correction_lines, %i[settlement_correction_id resident_id],
              unique: true, name: 'index_correction_lines_on_correction_and_resident'
    add_check_constraint :settlement_correction_lines, 'old_amount <> new_amount',
                         name: 'settlement_correction_lines_changed'

    # A copy of each deleted meal_charges row, column for column, with its
    # old id and the time it was written.
    create_table :settlement_correction_charges do |t|
      t.references :settlement_correction, null: false, foreign_key: true
      t.bigint :meal_charge_id, null: false
      t.references :meal, null: false, foreign_key: true
      t.references :resident, null: false, foreign_key: true
      t.string :kind, null: false
      t.decimal :amount, precision: 16, scale: 8, null: false
      t.integer :multiplier
      t.decimal :unit_cost, precision: 16, scale: 8, null: false
      t.decimal :bill_amount, precision: 12, scale: 8
      t.datetime :charged_at, null: false
      t.timestamps
    end

    # strong_migrations cannot see inside execute, so it asks. The tables
    # are new and empty, so the triggers lock nothing anyone is using.
    safety_assured do
      # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE FUNCTION comeals_protect_settlement_correction() RETURNS trigger AS $$
        BEGIN
          IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
            RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
          END IF;

          RAISE EXCEPTION '% on % refused: a settlement correction is a record of what a settlement '
            'said before and after, and cannot be changed. See docs/runbooks/settled-data-repair.md.',
            TG_OP, TG_TABLE_NAME;
        END;
        $$ LANGUAGE plpgsql;
      SQL

      # The reconciliation the row belongs to: its own column on
      # settlement_corrections, its correction's on the other two.
      # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE FUNCTION comeals_settlement_correction_insert_by_settlement() RETURNS trigger AS $$
        DECLARE
          settlement_id bigint;
        BEGIN
          IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
            RETURN NEW;
          END IF;

          IF TG_TABLE_NAME = 'settlement_corrections' THEN
            settlement_id := NEW.reconciliation_id;
          ELSE
            SELECT reconciliation_id INTO settlement_id
            FROM settlement_corrections WHERE id = NEW.settlement_correction_id;
          END IF;

          IF settlement_id::text = current_setting('comeals.settling', true) THEN
            RETURN NEW;
          END IF;

          RAISE EXCEPTION 'INSERT on % refused: a correction of reconciliation % is written only by '
            'Settlement#correct!, while it works that settlement out again. '
            'See docs/runbooks/settled-data-repair.md.',
            TG_TABLE_NAME, settlement_id;
        END;
        $$ LANGUAGE plpgsql;
      SQL

      TABLES.each do |table|
        execute <<~SQL.squish
          CREATE TRIGGER #{table}_protect
          BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION comeals_protect_settlement_correction();
        SQL
        execute <<~SQL.squish
          CREATE TRIGGER #{table}_insert_by_settlement
          BEFORE INSERT ON #{table}
          FOR EACH ROW EXECUTE FUNCTION comeals_settlement_correction_insert_by_settlement();
        SQL
      end
    end
  end

  def down
    corrections = select_value('SELECT count(*) FROM settlement_corrections').to_i
    if corrections.positive?
      raise "settlement_corrections holds #{corrections} correction(s). They are the only record of what " \
            'those settlements said before they were worked out again, so this migration will not drop them. ' \
            'An older release ignores these tables, so a rollback of the code does not need them gone.'
    end

    TABLES.reverse_each { |table| drop_table table }
    safety_assured do
      execute 'DROP FUNCTION comeals_settlement_correction_insert_by_settlement();'
      execute 'DROP FUNCTION comeals_protect_settlement_correction();'
    end
  end
end
