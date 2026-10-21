# frozen_string_literal: true

# The app serves exactly one community. The unique index on
# communities.singleton_guard refuses a second row only when it has the
# same value, and nothing made the value 0, so a write that skips the
# model (insert_all, a rake task, psql) could add a second community by
# giving it another value. This CHECK makes the value always 0, so the
# unique index refuses every second row.
#
# The one community's row already has 0 (the column's default, and no
# code sets it), so the CHECK passes on existing data. The previous
# release's code never sets the column either, so it runs beside this
# migration without a change.
class RequireSingletonGuardToBeZero < ActiveRecord::Migration[8.1]
  def change
    # safety_assured: strong_migrations wants the constraint added unvalidated
    # and validated in a second migration, to avoid a long lock on a big
    # table. communities has one row; validation is instant.
    safety_assured do
      add_check_constraint :communities, 'singleton_guard = 0',
                           name: 'communities_singleton_guard_is_zero'
    end
  end
end
