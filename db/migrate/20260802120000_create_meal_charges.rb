# frozen_string_literal: true

# Line items for a settlement (idea B in docs/money-path-observability.md).
#
# Until now a settlement kept only the per-resident total. MealLedger computed
# every individual debit and credit and then threw them away, so
# reconciliation_balances.amount was -47.13 and nothing recorded which meals
# produced it or in what amounts. A resident could be told what they owe but
# never shown why.
#
# One row per source row: one credit per bill, one debit per attendance, one
# per guest. Written once, inside the settlement transaction, from the same
# MealLedger pass that produces the balances.
#
# == This is a ledger, not a cache
#
# CLAUDE.md money rule 8 bans denormalized caches for financial data. What
# that rule is aimed at is a mutable value that can drift — a counter, a
# running total, anything counter_culture used to do. These rows are the
# opposite: written once, never updated, refused by a trigger afterwards. The
# distinction worth holding on to is that an immutable record of what was
# decided is a ledger, and a mutable cache of what is currently true is the
# thing the rule bans. reconciliation_balances is already in the first
# category and this joins it.
#
# == No reconciliation_id
#
# A charge belongs to a meal, and the meal already says which reconciliation
# settled it. Copying that id here would be a second answer to a question
# that already has one, and two answers can disagree. The join through meals
# is indexed.
#
# == Rounding, and what can be checked in SQL
#
# These amounts are full precision. reconciliation_balances is rounded to
# cents by largest-remainder allocation. So the sum of a resident's charges
# does NOT equal their settled balance exactly — it is within one cent of it,
# which is precisely the guarantee that allocation makes.
#
# That is still a real tie-out, and it is the useful one: two tables, written
# by different code, checked against each other with no recomputation at all.
# Both must also sum to exactly zero. LedgerVerification runs it nightly.
class CreateMealCharges < ActiveRecord::Migration[8.1]
  KINDS = %w[credit debit guest_debit].freeze

  def up
    create_table :meal_charges do |t|
      t.references :meal, null: false, foreign_key: true
      t.references :resident, null: false, foreign_key: true

      t.string :kind, null: false

      # Signed, and positive means the community owes the resident. Same
      # convention as MealLedger::Line, which is where these come from: a
      # resident's balance is the plain sum of their rows.
      t.decimal :amount, precision: 12, scale: 8, null: false

      # Units eaten. Null on a credit, which is not a per-unit thing.
      t.integer :multiplier

      # What this meal cost per unit of multiplier. The same on every row for
      # a given meal, stored per row so one line explains itself without
      # needing the others.
      t.decimal :unit_cost, precision: 12, scale: 8, null: false

      # What the cook actually spent, before any cap. Null on a debit. On a
      # subsidized meal this is larger than the credit, and it is the only
      # thing that explains to a cook why they were not paid back in full.
      t.decimal :bill_amount, precision: 12, scale: 8

      t.timestamps
    end

    add_check_constraint :meal_charges, "kind IN ('credit', 'debit', 'guest_debit')",
                         name: 'meal_charges_kind_known'

    # The shape of a row follows from its kind, so the database says so
    # rather than trusting every future writer to remember.
    add_check_constraint :meal_charges, "(kind = 'credit') = (bill_amount IS NOT NULL)",
                         name: 'meal_charges_bill_amount_on_credits_only'
    add_check_constraint :meal_charges, "(kind = 'credit') = (multiplier IS NULL)",
                         name: 'meal_charges_multiplier_on_debits_only'
    add_check_constraint :meal_charges, 'multiplier IS NULL OR multiplier >= 0',
                         name: 'meal_charges_multiplier_non_negative'

    # Mirrors the uniqueness of the source rows: bills and meal_residents are
    # both unique per (meal, resident), so their lines are too. Guests are
    # not — one resident may bring several — so guest_debit is deliberately
    # left out. These also stop a settlement from writing its lines twice.
    add_index :meal_charges, %i[meal_id resident_id],
              unique: true, where: "kind = 'credit'",
              name: 'index_meal_charges_one_credit_per_cook'
    add_index :meal_charges, %i[meal_id resident_id],
              unique: true, where: "kind = 'debit'",
              name: 'index_meal_charges_one_debit_per_attendee'

    # Immutable once written, same as the balances they add up to. INSERT
    # stays open because that is how settlement writes them, and settlement
    # inserts them after the meal is already claimed — so the settled-child
    # trigger cannot be reused here, it would refuse settlement's own writes.
    # rubocop:disable Rails/SquishedSQLHeredocs -- PL/pgSQL function bodies need preserved formatting
    execute <<~SQL
      CREATE FUNCTION comeals_protect_meal_charge() RETURNS trigger AS $$
      BEGIN
        IF current_setting('comeals.allow_settled_writes', true) = 'on' THEN
          RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
        END IF;

        RAISE EXCEPTION '% on meal_charges refused: settlement line items record what a meal cost '
          'and who was charged for it, and cannot be changed. Corrections belong in the next '
          'reconciliation. For genuine data corruption see docs/runbooks/settled-data-repair.md.',
          TG_OP;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER meal_charges_protect
      BEFORE UPDATE OR DELETE ON meal_charges
      FOR EACH ROW EXECUTE FUNCTION comeals_protect_meal_charge();
    SQL
    # rubocop:enable Rails/SquishedSQLHeredocs
  end

  def down
    execute 'DROP TRIGGER meal_charges_protect ON meal_charges;'
    execute 'DROP FUNCTION comeals_protect_meal_charge();'
    drop_table :meal_charges
  end
end
