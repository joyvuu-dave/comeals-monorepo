# frozen_string_literal: true

# The cap is a dollar amount a person types, so it is whole cents — the same
# rule bills_amount_whole_cents already enforces for Bill#amount. The model
# validation catches form input; this CHECK catches writes that skip the
# model (update_all, rake tasks, psql — see CLAUDE.md).
class AddCapWholeCentsCheckToCommunities < ActiveRecord::Migration[8.1]
  def up
    # Verify, don't assume. If a sub-cent cap somehow exists, silently
    # rounding it would change what meals charge — an operator must look at
    # it and decide.
    bad = select_value('SELECT count(*) FROM communities WHERE cap IS NOT NULL AND cap <> round(cap, 2)')
    if bad.to_i.positive?
      raise "#{bad} communities row(s) have a sub-cent cap. Inspect and fix them " \
            'by hand before adding the whole-cents constraint.'
    end

    add_check_constraint :communities, 'cap IS NULL OR cap = round(cap, 2)',
                         name: 'communities_cap_whole_cents'
  end

  def down
    remove_check_constraint :communities, name: 'communities_cap_whole_cents'
  end
end
