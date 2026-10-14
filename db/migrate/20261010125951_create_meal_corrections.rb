# frozen_string_literal: true

# Corrections to settled dinners (ADR 0011 rule 6).
#
# A settled dinner's costs and sign-ups are locked. When a mistake is
# found later, a superuser corrects the dinner: its rows change, with
# history, and each person's change in what they owe or are owed is saved
# as a line. The old settlement keeps what it settled. The next
# settlement carries every correction made since the last one.
#
# Dated 20261010125951, before the day it was written (2026-10-13), on
# purpose. The data fixes from 20261010130000 to 20261013120100 work old
# settlements out again with Settlement#correct!, which reads
# meal_corrections (Reconciliation#settlement_balances, the nightly
# check). In production every one of those is still to run, and
# migrations run in the order of their dates, so the table must come
# first. It was 20261013130000 until 2026-10-14, when a run of every
# migration on a copy of production failed at 20261010130000.
#
#   meal_corrections        the dinner, who corrected it and why, what
#                           changed (edits), and the settlement that
#                           carries it (empty until one does)
#   meal_correction_lines   each person whose amount changed, and by how
#                           much, at the ledger grain. Positive means the
#                           community owes the person more, the same sign
#                           as a settled balance (MealLedger, "Signs").
#
# The rules the database keeps, so that a console or psql cannot break
# them either:
#
#   - A correction is added only to a settled dinner, and only while that
#     dinner is being corrected: the transaction has set comeals.correcting
#     to the dinner's id (MealCorrecting). The same setting is what lets
#     the dinner's bills, attendance and guests change
#     (20261010125952).
#   - Its lines are added only then, while no settlement carries it yet,
#     and they add up to exactly zero: what one person is credited, the
#     others are charged.
#   - Nothing is ever changed or deleted, with one exception: a settlement
#     sets reconciliation_id once, from empty to itself, while it settles
#     (comeals.settling names it). A later settlement than the dinner's
#     own, since the dinner was settled before it was corrected.
#   - The repair bypass (comeals.allow_settled_writes) lets a repair
#     through, as on the rest of the money path.
#
# down refuses while a correction is recorded: the corrected rows stay
# changed, so dropping the record would leave the dinners different from
# what was settled with nothing to say why.
class CreateMealCorrections < ActiveRecord::Migration[8.1]
  def up
    create_table :meal_corrections do |t|
      t.references :meal, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.text :reason, null: false
      # What changed, one entry per edit, in words a page can show without
      # the audit rows (MealCorrecting::Edits).
      t.jsonb :edits, null: false, default: []
      t.references :reconciliation, foreign_key: true
      t.timestamps
    end
    add_check_constraint :meal_corrections, "btrim(reason) <> ''", name: 'meal_corrections_reason_present'
    add_check_constraint :meal_corrections, "jsonb_typeof(edits) = 'array'", name: 'meal_corrections_edits_list'

    create_table :meal_correction_lines do |t|
      t.references :meal_correction, null: false, foreign_key: true, index: false
      t.references :resident, null: false, foreign_key: true
      t.decimal :amount, precision: 16, scale: 8, null: false
      t.timestamps
    end
    add_index :meal_correction_lines, %i[meal_correction_id resident_id],
              unique: true, name: 'index_meal_correction_lines_once_a_person'
    add_check_constraint :meal_correction_lines, 'amount <> 0', name: 'meal_correction_lines_not_zero'

    # strong_migrations cannot see inside execute, so it asks. The tables
    # are new and empty, so the triggers lock nothing anyone is using.
    safety_assured do
      create_correction_guard
      create_line_guard
      create_lines_sum_zero
    end
  end

  def down
    corrections = select_value('SELECT count(*) FROM meal_corrections').to_i
    if corrections.positive?
      raise "meal_corrections holds #{corrections} correction(s). The dinners they changed stay changed, so " \
            'dropping the record would leave them different from what was settled with nothing to say why.'
    end

    drop_table :meal_correction_lines
    drop_table :meal_corrections
    safety_assured do
      execute 'DROP FUNCTION comeals_meal_correction_lines_sum_zero();'
      execute 'DROP FUNCTION comeals_meal_correction_line_guard();'
      execute 'DROP FUNCTION comeals_meal_correction_guard();'
    end
  end

  private

  # INSERT: a settled dinner, being corrected, carried by no settlement
  # yet. UPDATE: only the claim, by the settling settlement, later than
  # the dinner's own. DELETE: never.
  def create_correction_guard
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_meal_correction_guard() RETURNS trigger AS $$
      DECLARE
        meal_reconciliation_id bigint;
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP = 'INSERT' THEN
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals WHERE id = NEW.meal_id;
          IF meal_reconciliation_id IS NULL THEN
            RAISE EXCEPTION 'INSERT on meal_corrections refused: meal % is not settled. '
              'An open dinner is changed directly.', NEW.meal_id;
          END IF;
          IF NEW.meal_id::text IS DISTINCT FROM current_setting('comeals.correcting', true) THEN
            RAISE EXCEPTION 'INSERT on meal_corrections refused: meal % is not being corrected. '
              'A correction is written only by MealCorrecting.', NEW.meal_id;
          END IF;
          IF NEW.reconciliation_id IS NOT NULL THEN
            RAISE EXCEPTION 'INSERT on meal_corrections refused: a new correction is carried by no '
              'settlement yet.';
          END IF;
          RETURN NEW;
        END IF;

        IF TG_OP = 'UPDATE'
           AND OLD.reconciliation_id IS NULL
           AND NEW.reconciliation_id IS NOT NULL
           AND NEW.reconciliation_id::text = current_setting('comeals.settling', true)
           AND (NEW.id, NEW.meal_id, NEW.admin_user_id, NEW.reason, NEW.edits, NEW.created_at)
               IS NOT DISTINCT FROM (OLD.id, OLD.meal_id, OLD.admin_user_id, OLD.reason, OLD.edits, OLD.created_at)
        THEN
          SELECT reconciliation_id INTO meal_reconciliation_id FROM meals WHERE id = NEW.meal_id;
          IF NEW.reconciliation_id > meal_reconciliation_id THEN
            RETURN NEW;
          END IF;
        END IF;

        RAISE EXCEPTION '% on meal_corrections refused (correction %): a correction is a record and '
          'cannot be changed. Only a later settlement claims it, once. '
          'See docs/runbooks/settled-data-repair.md.',
          TG_OP, OLD.id;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER meal_corrections_guard BEFORE INSERT OR UPDATE OR DELETE ON meal_corrections
      FOR EACH ROW EXECUTE FUNCTION comeals_meal_correction_guard();
    SQL
  end

  # INSERT: only while the correction's dinner is being corrected and no
  # settlement carries it. UPDATE and DELETE: never.
  def create_line_guard
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_meal_correction_line_guard() RETURNS trigger AS $$
      DECLARE
        correction_meal_id bigint;
        carrier_id bigint;
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        IF TG_OP = 'INSERT' THEN
          SELECT meal_id, reconciliation_id INTO correction_meal_id, carrier_id
          FROM meal_corrections WHERE id = NEW.meal_correction_id;
          IF carrier_id IS NULL
             AND correction_meal_id::text = current_setting('comeals.correcting', true) THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'INSERT on meal_correction_lines refused: the lines of correction % are written '
            'only by MealCorrecting, with the correction, before a settlement carries it.',
            NEW.meal_correction_id;
        END IF;

        RAISE EXCEPTION '% on meal_correction_lines refused: a correction line is a record and cannot '
          'be changed. See docs/runbooks/settled-data-repair.md.', TG_OP;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER meal_correction_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON meal_correction_lines
      FOR EACH ROW EXECUTE FUNCTION comeals_meal_correction_line_guard();
    SQL
  end

  # After the statement that writes them, a correction's lines add up to
  # exactly zero, like a meal's (comeals_meal_charges_sum_zero).
  # MealCorrecting writes them in one statement. An AFTER ROW trigger runs
  # once that statement is done, so it sees all of them.
  def create_lines_sum_zero
    # rubocop:disable-next Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_meal_correction_lines_sum_zero() RETURNS trigger AS $$
      DECLARE
        total numeric;
      BEGIN
        SELECT COALESCE(SUM(amount), 0) INTO total
        FROM meal_correction_lines WHERE meal_correction_id = NEW.meal_correction_id;

        IF total <> 0 THEN
          RAISE EXCEPTION 'correction % refused: its lines sum to %, not zero. '
            'What one person is credited, the others are charged.',
            NEW.meal_correction_id, total;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL.squish
      CREATE TRIGGER meal_correction_lines_sum_zero AFTER INSERT ON meal_correction_lines
      FOR EACH ROW EXECUTE FUNCTION comeals_meal_correction_lines_sum_zero();
    SQL
  end
end
