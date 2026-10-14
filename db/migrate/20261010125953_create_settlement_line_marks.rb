# frozen_string_literal: true

# A mark on a settlement line: "Paid" or "Let go" (ADR 0011 rule 8).
#
# After a settlement, an admin records what happened to each person's
# line: they paid, or the amount was let go, with an optional note ("paid
# $20 of $40"). A mark never changes what anyone owes. It saves who made
# it and when. A mark can be changed, and the history keeps the old one:
# each change is a new row, and a line's mark is its newest row. "none"
# takes a mark off a line that was marked by mistake.
#
# Append-only, like the other records of the money path: a trigger
# refuses UPDATE and DELETE, except with the comeals.allow_settled_writes
# bypass (docs/runbooks/settled-data-repair.md). The foreign key to the
# line also stops a marked line from being deleted, and Settlement#correct!
# refuses a settlement that has marks: once people pay from a settlement,
# its numbers stay what they were.
#
# Dated 20261010125953, before the day it was written (2026-10-14), on
# purpose, like 20261010125950: the data fixes from 20261010130000 run
# Settlement#correct!, which reads this table, and in production they run
# in the order of their dates (docs on 20261010125951).
#
# down refuses while a mark is recorded: the marks are the only record of
# who paid.
class CreateSettlementLineMarks < ActiveRecord::Migration[8.1]
  def up
    create_table :settlement_line_marks do |t|
      t.references :reconciliation_balance, null: false, foreign_key: true
      t.string :status, null: false
      t.text :note
      t.references :admin_user, null: false, foreign_key: true
      t.timestamps
    end
    add_check_constraint :settlement_line_marks, "status IN ('paid', 'let_go', 'none')",
                         name: 'settlement_line_marks_status_known'
    add_check_constraint :settlement_line_marks, "note IS NULL OR btrim(note) <> ''",
                         name: 'settlement_line_marks_note_not_blank'

    # safety_assured: strong_migrations cannot read the execute blocks. The
    # table is new and empty, so the trigger locks nothing anyone is using.
    safety_assured do
      # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
      execute <<~SQL
        CREATE FUNCTION comeals_protect_settlement_line_mark() RETURNS trigger AS $$
        BEGIN
          IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
            RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
          END IF;

          RAISE EXCEPTION '% on settlement_line_marks refused: a mark is a record of what happened after '
            'a settlement, and cannot be changed. Mark the line again; the newest mark counts. '
            'See docs/runbooks/settled-data-repair.md.',
            TG_OP;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      execute <<~SQL.squish
        CREATE TRIGGER settlement_line_marks_protect
        BEFORE UPDATE OR DELETE ON settlement_line_marks
        FOR EACH ROW EXECUTE FUNCTION comeals_protect_settlement_line_mark();
      SQL
    end
  end

  def down
    marks = select_value('SELECT count(*) FROM settlement_line_marks').to_i
    if marks.positive?
      raise "settlement_line_marks holds #{marks} mark(s). They are the only record of who paid and what " \
            'was let go, so this migration will not drop them.'
    end

    drop_table :settlement_line_marks
    safety_assured { execute 'DROP FUNCTION comeals_protect_settlement_line_mark();' }
  end
end
