# frozen_string_literal: true

# The record of the nightly ledger check (control A in
# docs/money-path-observability.md).
#
# The check itself recomputes every reconciliation from its source rows and
# compares the result to the balances that were stored at settlement. This
# table is what it leaves behind.
#
# Why store a row when nothing is wrong. A check that only speaks up on
# failure cannot answer the question an auditor actually asks, which is not
# "would you have noticed?" but "show me that you looked". A silent night and
# a night the job never ran look identical without this table. With it, the
# ledger has a dated, unbroken record of having been checked and having tied
# out.
#
# Append-only, for the same reason the balances are: a check record that can
# be edited afterwards is not evidence. The trigger honours the same
# comeals.allow_settled_writes bypass as the rest of the money path, so rows
# can still be pruned deliberately. Nothing prunes them today and nothing
# needs to — one row a day is 365 a year.
class CreateLedgerCheckRuns < ActiveRecord::Migration[8.1]
  def up
    create_table :ledger_check_runs do |t|
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false

      # How many reconciliations this run compared. Zero is a real answer —
      # a community that has never settled anything — and is not a failure.
      t.integer :reconciliations_checked, null: false, default: 0

      # How many disagreed with their source data. Zero means the ledger
      # ties out.
      t.integer :mismatch_count, null: false, default: 0

      # What disagreed, when anything did. Amounts are stored as strings:
      # JSON numbers are IEEE floats, and money never goes near one
      # (CLAUDE.md money rule 1).
      t.jsonb :details, null: false, default: []

      # Set when the run itself could not finish. Distinct from a mismatch:
      # one says the books are wrong, the other says we do not know.
      t.text :error

      t.timestamps
    end

    add_index :ledger_check_runs, :started_at

    add_check_constraint :ledger_check_runs, 'reconciliations_checked >= 0',
                         name: 'ledger_check_runs_checked_non_negative'
    add_check_constraint :ledger_check_runs, 'mismatch_count >= 0',
                         name: 'ledger_check_runs_mismatch_count_non_negative'
    add_check_constraint :ledger_check_runs, 'finished_at >= started_at',
                         name: 'ledger_check_runs_finished_after_started'

    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_protect_ledger_check_run() RETURNS trigger AS $$
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        RAISE EXCEPTION '% on ledger_check_runs refused: a check run is a record of what was true '
          'at a point in time and cannot be changed. See docs/runbooks/settled-data-repair.md.',
          TG_OP;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER ledger_check_runs_protect
      BEFORE UPDATE OR DELETE ON ledger_check_runs
      FOR EACH ROW EXECUTE FUNCTION comeals_protect_ledger_check_run();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    execute 'DROP TRIGGER ledger_check_runs_protect ON ledger_check_runs;'
    execute 'DROP FUNCTION comeals_protect_ledger_check_run();'
    drop_table :ledger_check_runs
  end
end
