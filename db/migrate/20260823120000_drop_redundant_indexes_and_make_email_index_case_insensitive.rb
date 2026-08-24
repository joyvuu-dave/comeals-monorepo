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

    # Two rows whose emails differ only by case would make the new index
    # fail to build, and bin/deploy runs migrations with the app scaled to
    # zero, so the app would stay down until someone fixed the rows by hand.
    # Refuse first, with the rows named, so the fix happens before the deploy.
    reversible { |dir| dir.up { refuse_case_only_duplicates } }

    remove_index :residents, :email, name: :index_residents_on_email, unique: true
    # safety_assured: same reasoning as 20260816150000 — residents has a few
    # dozen rows, so a concurrent build buys nothing and would cost the
    # transaction.
    safety_assured do
      add_index :residents, 'lower(email)', unique: true, name: :index_residents_on_lower_email
    end
  end

  private

  def refuse_case_only_duplicates
    duplicates = select_rows(<<~SQL.squish)
      SELECT lower(email), string_agg(email, ', ' ORDER BY email)
      FROM residents
      WHERE email IS NOT NULL
      GROUP BY lower(email)
      HAVING count(*) > 1
    SQL
    return if duplicates.empty?

    listed = duplicates.map { |_, emails| emails }.join('; ')
    raise "residents has emails that differ only by case: #{listed}. " \
          'Merge or change them, then run this migration again.'
  end
end
