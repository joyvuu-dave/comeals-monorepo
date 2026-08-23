# frozen_string_literal: true

# Two cleanups found by active_record_doctor.
#
# 1. Three indexes are the first column of a composite unique index on the
#    same table, so Postgres can answer every query with the composite one
#    and the single-column index is maintained on every insert for nothing.
#
# 2. residents.email had the same gap residents.name had until
#    20260816150000: the model checks uniqueness without caring about case,
#    but the index was case-sensitive. The model downcases before save, so
#    only a write that skips the model (update_all, psql) could create
#    'John@x.com' next to 'john@x.com' — and then the model would refuse
#    every later save of either row. One rule, enforced by the database:
#    unique on lower(email).
class DropRedundantIndexesAndMakeEmailIndexCaseInsensitive < ActiveRecord::Migration[8.1]
  def change
    remove_index :bills, :meal_id, name: :index_bills_on_meal_id
    remove_index :meal_residents, :meal_id, name: :index_meal_residents_on_meal_id
    remove_index :reconciliation_balances, :reconciliation_id,
                 name: :index_reconciliation_balances_on_reconciliation_id

    remove_index :residents, :email, name: :index_residents_on_email, unique: true
    # safety_assured: same reasoning as 20260816150000 — residents has a few
    # dozen rows, so a concurrent build buys nothing and would cost the
    # transaction.
    safety_assured do
      add_index :residents, 'lower(email)', unique: true, name: :index_residents_on_lower_email
    end
  end
end
