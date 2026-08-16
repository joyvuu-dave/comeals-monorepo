# frozen_string_literal: true

# The model checks name uniqueness without caring about case, but the old
# index was case-sensitive. So a write that skips validations (update_all,
# a rake task, psql) could create 'john smith' next to 'John Smith' — and
# the model would then refuse every later save of either row. One rule
# now, enforced by the database: unique on lower(name).
class MakeResidentNameIndexCaseInsensitive < ActiveRecord::Migration[8.1]
  def change
    remove_index :residents, :name, name: :index_residents_on_name, unique: true
    # safety_assured: strong_migrations wants indexes built concurrently so
    # they do not block writes. residents has a few dozen rows, so this
    # build takes milliseconds — not worth losing the transaction (a
    # concurrent build needs disable_ddl_transaction!, and then a failure
    # would leave the old index dropped and the new one missing).
    safety_assured do
      add_index :residents, 'lower(name)', unique: true, name: :index_residents_on_lower_name
    end
  end
end
