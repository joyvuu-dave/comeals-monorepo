# frozen_string_literal: true

# A cook's cost is whole cents (issue #29). The SPA blocks input that breaks
# this, the API rejects it with a 400, and Bill validates it — this CHECK
# makes PostgreSQL itself refuse a sub-cent amount from any write path.
#
# The column stays DECIMAL(12,8) for type consistency with the other money
# columns (CLAUDE.md, money model): bills.amount is an input value and is
# whole cents by rule; the extra scale is used by intermediate calculations
# elsewhere, never here.
class AddWholeCentsCheckToBills < ActiveRecord::Migration[8.1]
  def up
    violations = select_values('SELECT id FROM bills WHERE amount <> round(amount, 2)')
    if violations.any?
      raise "Cannot add whole-cents CHECK: bills #{violations.join(', ')} have sub-cent amounts. " \
            'Correct them first (an accounting decision — do not round silently).'
    end

    add_check_constraint :bills, 'amount = round(amount, 2)', name: 'bills_amount_whole_cents'
  end

  def down
    remove_check_constraint :bills, name: 'bills_amount_whole_cents'
  end
end
